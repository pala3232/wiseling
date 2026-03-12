"""
Outbox poller for withdrawal-service.
Runs as a SEPARATE POD in Kubernetes.

Reads PENDING rows from the outbox table and publishes to SQS.
wallet-service consumer debits the wallet.
withdrawal-processor drives the state machine.
"""
import asyncio
import json
import boto3
from datetime import datetime
from sqlalchemy import select
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
        result = await db.execute(
            select(OutboxEvent)
            .where(OutboxEvent.status == "PENDING")
            .order_by(OutboxEvent.created_at.asc())
            .limit(100)
        )
        events = result.scalars().all()

        if not events:
            return

        sqs = _sqs()
        for event in events:
            try:
                sqs.send_message(
                    QueueUrl=settings.SQS_WITHDRAWALS_QUEUE_URL,
                    MessageBody=json.dumps({
                        "event_type": event.event_type,
                        "payload": json.loads(event.payload),
                    }),
                )
                event.status = "PUBLISHED"
                event.published_at = datetime.utcnow()
                print(f"[outbox-poller] Published {event.event_type} {event.id}")
            except Exception as e:
                event.status = "FAILED"
                print(f"[outbox-poller] Failed to publish {event.id}: {e}")

        await db.commit()


async def main():
    print("[outbox-poller] withdrawal-service outbox poller starting...")
    while True:
        try:
            await poll_once()
        except Exception as e:
            print(f"[outbox-poller] Error: {e}")
        await asyncio.sleep(1)


if __name__ == "__main__":
    asyncio.run(main())
