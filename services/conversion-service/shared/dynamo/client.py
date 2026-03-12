"""
Shared DynamoDB client.
Used by conversion-service and withdrawal-service to write the
short-lived safety net buffer (last ~5 minutes of transactions).

Table schema:
  PK: service#id  (e.g. "conversion#uuid")
  SK: created_at  (ISO string)
  TTL: epoch seconds (DynamoDB auto-deletes after 5 min)
  status: PENDING | REPLAYED | CLEANED
  payload: full transaction payload as JSON string
  service: "conversion" | "withdrawal"
"""
import os
import json
import time
import boto3
from typing import Optional

DYNAMO_TABLE = os.getenv("DYNAMO_OUTBOX_TABLE", "wiseling-outbox")
TTL_SECONDS = int(os.getenv("DYNAMO_OUTBOX_TTL_SECONDS", "300"))  # 5 minutes


def get_dynamo():
    return boto3.resource(
        "dynamodb",
        region_name=os.getenv("AWS_REGION", "us-east-1"),
        aws_access_key_id=os.getenv("AWS_ACCESS_KEY_ID"),
        aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
    )


def write_to_dynamo(service: str, record_id: str, payload: dict) -> bool:
    """
    Write a transaction to DynamoDB as a short-lived safety net.
    Returns True on success, False on failure (non-fatal — RDS has the data).
    TTL ensures auto-cleanup even if the cleaner pod fails.
    """
    try:
        table = get_dynamo().Table(DYNAMO_TABLE)
        table.put_item(Item={
            "pk": f"{service}#{record_id}",
            "service": service,
            "record_id": record_id,
            "payload": json.dumps(payload),
            "status": "PENDING",
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "ttl": int(time.time()) + TTL_SECONDS,
        })
        return True
    except Exception as e:
        # Non-fatal: RDS has the committed data.
        # Alert ops — this record won't be in the DynamoDB safety net.
        print(f"[dynamo] WARNING: failed to write {service}#{record_id}: {e}")
        return False


def mark_cleaned(service: str, record_id: str) -> None:
    """Mark a DynamoDB row as cleaned after RDS replication confirmed."""
    try:
        table = get_dynamo().Table(DYNAMO_TABLE)
        table.update_item(
            Key={"pk": f"{service}#{record_id}"},
            UpdateExpression="SET #s = :s",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":s": "CLEANED"},
        )
    except Exception as e:
        print(f"[dynamo] WARNING: failed to mark cleaned {service}#{record_id}: {e}")


def scan_pending(service: str) -> list[dict]:
    """
    Scan DynamoDB for PENDING rows for a given service.
    Used by the reconciler after regional failover to find
    transactions that committed to RDS but may not have replicated.
    """
    try:
        table = get_dynamo().Table(DYNAMO_TABLE)
        result = table.scan(
            FilterExpression="service = :s AND #st = :st",
            ExpressionAttributeNames={"#st": "status"},
            ExpressionAttributeValues={":s": service, ":st": "PENDING"},
        )
        return result.get("Items", [])
    except Exception as e:
        print(f"[dynamo] ERROR scanning pending: {e}")
        return []
