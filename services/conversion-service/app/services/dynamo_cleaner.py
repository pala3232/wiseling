"""
DynamoDB cleaner for conversion-service.
Runs as a SEPARATE POD in Kubernetes.

Checks RDS replica lag via CloudWatch. Once a transaction is
confirmed replicated to the cross-region replica, deletes its
DynamoDB safety net row. DynamoDB TTL (5 min) is the backstop
if this cleaner fails.

Flow:
  1. Scan DynamoDB for PENDING rows older than replica_lag + buffer
  2. Verify the record exists in RDS (confirms replication)
  3. Mark DynamoDB row as CLEANED (TTL handles physical deletion)
"""
import asyncio
import json
import boto3
from sqlalchemy import select
from app.core.config import settings
from app.db.session import AsyncSessionLocal
from app.models.conversion import Conversion
from shared.dynamo.client import scan_pending, mark_cleaned, get_dynamo, DYNAMO_TABLE


def get_cloudwatch():
    return boto3.client(
        "cloudwatch",
        region_name=settings.AWS_REGION,
    )


def get_replica_lag_seconds() -> float:
    """
    Get RDS cross-region replica lag from CloudWatch.
    Falls back to conservative 30s if metric unavailable.
    """
    try:
        cw = get_cloudwatch()
        from datetime import datetime, timedelta
        response = cw.get_metric_statistics(
            Namespace="AWS/RDS",
            MetricName="ReplicaLag",
            Dimensions=[{"Name": "DBInstanceIdentifier", "Value": settings.RDS_REPLICA_IDENTIFIER}],
            StartTime=datetime.utcnow() - timedelta(minutes=5),
            EndTime=datetime.utcnow(),
            Period=60,
            Statistics=["Maximum"],
        )
        datapoints = response.get("Datapoints", [])
        if datapoints:
            return max(d["Maximum"] for d in datapoints)
    except Exception as e:
        print(f"[cleaner] Could not get replica lag: {e}")
    return 30.0  # conservative fallback


async def clean_once():
    lag = get_replica_lag_seconds()
    safe_age_seconds = lag + 10  # buffer

    pending = scan_pending("conversion")
    if not pending:
        return

    import time
    now = time.time()

    async with AsyncSessionLocal() as db:
        for item in pending:
            created_epoch = item.get("ttl", 0) - 300  # TTL = created + 300s
            age_seconds = now - created_epoch

            if age_seconds < safe_age_seconds:
                continue  # not old enough to be safe yet

            record_id = item["record_id"]

            # Verify record exists in RDS (confirms it replicated)
            result = await db.execute(
                select(Conversion).where(Conversion.id == record_id)
            )
            if result.scalar_one_or_none():
                mark_cleaned("conversion", record_id)
                print(f"[cleaner] Cleaned conversion {record_id} from DynamoDB")
            else:
                print(f"[cleaner] WARNING: conversion {record_id} in DynamoDB but not in RDS")


async def main():
    print("[cleaner] conversion-service DynamoDB cleaner starting...")
    while True:
        try:
            await clean_once()
        except Exception as e:
            print(f"[cleaner] Error: {e}")
        await asyncio.sleep(30)  # run every 30 seconds


if __name__ == "__main__":
    asyncio.run(main())
