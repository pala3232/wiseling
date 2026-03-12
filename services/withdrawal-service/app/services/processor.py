"""
Withdrawal processor — runs as a SEPARATE POD in Kubernetes.
Consumes withdrawal.debited events from SQS and drives the state machine:
PENDING → PROCESSING → COMPLETED

In production: replace the sleep with your real payment rail (SEPA/SWIFT) here.
"""
import asyncio
import json
import boto3
from sqlalchemy import select
from app.core.config import settings
from app.db.session import AsyncSessionLocal
from app.models.withdrawal import Withdrawal


def _sqs():
    return boto3.client(
        "sqs",
        region_name=settings.AWS_REGION,
    )


async def process_withdrawal(withdrawal_id: str):
    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Withdrawal).where(Withdrawal.id == withdrawal_id))
        w = result.scalar_one_or_none()
        if not w or w.status != "PENDING":
            return

        w.status = "PROCESSING"
        await db.commit()
        print(f"[processor] {withdrawal_id} → PROCESSING")

        # Simulate payment rail — replace with real SEPA/SWIFT call here
        await asyncio.sleep(2)

        w.status = "COMPLETED"
        await db.commit()
        print(f"[processor] {withdrawal_id} → COMPLETED")


async def poll():
    sqs = _sqs()
    print("[processor] Polling SQS for withdrawal events...")
    while True:
        try:
            resp = sqs.receive_message(
                QueueUrl=settings.SQS_WITHDRAWALS_QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=10,
            )
            for msg in resp.get("Messages", []):
                body = json.loads(msg["Body"])
                if body.get("event_type") == "withdrawal.requested":
                    withdrawal_id = body["payload"]["withdrawal_id"]
                    await process_withdrawal(withdrawal_id)
                sqs.delete_message(
                    QueueUrl=settings.SQS_WITHDRAWALS_QUEUE_URL,
                    ReceiptHandle=msg["ReceiptHandle"],
                )
        except Exception as e:
            print(f"[processor] Error: {e}")
        await asyncio.sleep(1)


if __name__ == "__main__":
    asyncio.run(poll())
