"""
Reconciler for wallet-service.
Runs ONCE on startup (and can be triggered manually after failover).

PURPOSE:
  After a regional failover, the promoted RDS replica may be missing
  up to ~5 seconds of transactions that committed in us-east-1 but
  hadn't replicated yet. Those transactions ARE in DynamoDB Global Tables
  (written by conversion-service and withdrawal-service as a safety net).

  This reconciler:
  1. Scans DynamoDB for PENDING rows (these are the missing transactions)
  2. For each missing transaction, publishes the event to SQS
  3. wallet-service consumer processes them normally
  4. Idempotency keys prevent double-processing if record did replicate

WHEN TO RUN:
  - Automatically on every pod startup (safe — idempotency handles duplicates)
  - Manually after a failover: kubectl rollout restart deployment/wallet-service

WHAT IT DOES NOT DO:
  - Write directly to RDS (that's the wallet-consumer's job via SQS)
  - Assume any record is missing (it verifies via idempotency keys)
"""
import json
import boto3
from app.core.config import settings
from shared.dynamo.client import scan_pending, mark_cleaned


def _sqs():
    return boto3.client(
        "sqs",
        region_name=settings.AWS_REGION,
    )


def reconcile():
    print("[reconciler] Starting DynamoDB reconciliation...")
    sqs = _sqs()
    replayed = 0

    for service in ["conversion", "withdrawal"]:
        pending = scan_pending(service)
        queue_url = (
            settings.SQS_CONVERSIONS_QUEUE_URL
            if service == "conversion"
            else settings.SQS_WITHDRAWALS_QUEUE_URL
        )

        for item in pending:
            record_id = item["record_id"]
            payload = json.loads(item["payload"])

            event_type = (
                "conversion.requested"
                if service == "conversion"
                else "withdrawal.requested"
            )

            try:
                sqs.send_message(
                    QueueUrl=queue_url,
                    MessageBody=json.dumps({
                        "event_type": event_type,
                        "payload": payload,
                    }),
                )
                # Mark as cleaned — wallet-consumer will process it
                # idempotency keys prevent double-processing
                mark_cleaned(service, record_id)
                replayed += 1
                print(f"[reconciler] Replayed {service} {record_id}")
            except Exception as e:
                print(f"[reconciler] Failed to replay {service} {record_id}: {e}")

    print(f"[reconciler] Done. Replayed {replayed} transactions.")


if __name__ == "__main__":
    reconcile()
