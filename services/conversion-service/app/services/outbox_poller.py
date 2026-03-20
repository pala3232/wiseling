"""
Outbox poller for conversion-service.
Runs as a SEPARATE POD in Kubernetes.

Reads PENDING rows from the outbox table (in RDS) and publishes
them to SQS. This is the ONLY thing that publishes to SQS —
the service itself never calls SQS directly anymore.

Safety guarantee:
  - Outbox row written atomically with conversion record
  - If poller crashes mid-publish, it restarts and retries
  - Idempotency keys on wallet-service prevent double-processing
"""
import asyncio
import json
import boto3
from datetime import datetime
from sqlalchemy import select, update
from app.core.config import settings
from app.db.session import AsyncSessionLocal
from app.models.outbox import OutboxEvent


def _sqs():
    return boto3.client(
        "sqs",
        region_name=settings.AWS_REGION,
    )


async def poll_once():
    async with AsyncSessionLocal() as db:
        # FOR UPDATE SKIP LOCKED: each pod atomically claims a batch of rows.
        # Concurrent pollers skip locked rows and pick different ones,
        # preventing duplicate publishes without a distributed lock.
        result = await db.execute(
            select(OutboxEvent)
            .where(OutboxEvent.status == "PENDING")
            .order_by(OutboxEvent.created_at.asc())
            .limit(100)
            .with_for_update(skip_locked=True)
        )
        events = result.scalars().all()

        if not events:
            return

        sqs = _sqs()
        for event in events:
            try:
                sqs.send_message(
                    QueueUrl=settings.SQS_CONVERSIONS_QUEUE_URL,
                    MessageBody=json.dumps({
                        "event_type": event.event_type,
                        "payload": json.loads(event.payload),
                    }),
                    # MessageDeduplicationId not needed — standard queue
                    # wallet-service idempotency keys handle duplicates
                )
                # Mark as published
                event.status = "PUBLISHED"
                event.published_at = datetime.utcnow()
                print(f"[outbox-poller] Published {event.event_type} {event.id}")
            except Exception as e:
                event.status = "FAILED"
                print(f"[outbox-poller] Failed to publish {event.id}: {e}")

        await db.commit()


async def main():
    print("[outbox-poller] conversion-service outbox poller starting...")
    while True:
        try:
            await poll_once()
        except Exception as e:
            print(f"[outbox-poller] Error: {e}")
        await asyncio.sleep(1)


if __name__ == "__main__":
    asyncio.run(main())
