"""
SQS consumer for wallet-service.
Listens on both conversions and withdrawals queues.
Handles debits and credits atomically.
"""
import asyncio
import json
import httpx
import boto3
from decimal import Decimal
from app.core.config import settings
from app.db.session import AsyncSessionLocal
from app.services.wallet import debit, credit


def get_sqs():
    return boto3.client("sqs", region_name=settings.AWS_REGION)


async def handle_event(event_type: str, payload: dict):
    async with AsyncSessionLocal() as db:
        if event_type == "conversion.requested":
            await debit(
                db, payload["user_id"], payload["from_currency"],
                Decimal(payload["from_amount"]), "conversion", payload["conversion_id"],
            )
            await credit(
                db, payload["user_id"], payload["to_currency"],
                Decimal(payload["to_amount"]), "conversion", payload["conversion_id"],
            )
            try:
                async with httpx.AsyncClient(timeout=5.0) as client:
                    await client.patch(
                        f"{settings.CONVERSION_SERVICE_URL}/api/v1/conversions/internal/{payload['conversion_id']}/complete"
                    )
            except Exception as e:
                print(f"[wallet] Could not mark conversion complete: {e}")
            print(f"[wallet] Settled conversion {payload['conversion_id']}")

        elif event_type == "withdrawal.requested":
            await debit(
                db, payload["user_id"], payload["currency"],
                Decimal(payload["amount"]), "withdrawal", payload["withdrawal_id"],
            )
            print(f"[wallet] Debited withdrawal {payload['withdrawal_id']}")

        elif event_type == "transfer.requested":
            await debit(
                db, payload["sender_id"], payload["currency"],
                Decimal(payload["amount"]), "transfer_out", payload["transfer_id"],
            )
            await credit(
                db, payload["recipient_id"], payload["currency"],
                Decimal(payload["amount"]), "transfer_in", payload["transfer_id"],
            )
            try:
                async with httpx.AsyncClient(timeout=5.0) as client:
                    await client.patch(
                        f"{settings.WITHDRAWAL_SERVICE_URL}/api/v1/withdrawals/internal/{payload['transfer_id']}/complete"
                    )
            except Exception as e:
                print(f"[wallet] Could not mark transfer complete: {e}")
            print(f"[wallet] Settled transfer {payload['transfer_id']}")


async def poll_queue(queue_url: str, sqs):
    response = await asyncio.to_thread(
        sqs.receive_message,
        QueueUrl=queue_url,
        MaxNumberOfMessages=10,
        WaitTimeSeconds=10,
    )
    messages = response.get("Messages", [])
    for msg in messages:
        body = json.loads(msg["Body"])
        event_type = body.get("event_type")
        payload = body.get("payload", {})
        try:
            await handle_event(event_type, payload)
            await asyncio.to_thread(
                sqs.delete_message,
                QueueUrl=queue_url,
                ReceiptHandle=msg["ReceiptHandle"],
            )
        except Exception as e:
            print(f"[wallet] Failed to process {event_type}: {e}")


async def main():
    sqs = get_sqs()
    print("[wallet-consumer] Starting SQS consumer...")
    while True:
        if settings.SQS_CONVERSIONS_QUEUE_URL:
            await poll_queue(settings.SQS_CONVERSIONS_QUEUE_URL, sqs)
        if settings.SQS_WITHDRAWALS_QUEUE_URL:
            await poll_queue(settings.SQS_WITHDRAWALS_QUEUE_URL, sqs)
        await asyncio.sleep(1)


if __name__ == "__main__":
    asyncio.run(main())