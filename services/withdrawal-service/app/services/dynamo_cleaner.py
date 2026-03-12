"""
DynamoDB cleaner for withdrawal-service.
Same pattern as conversion-service cleaner.
"""
import asyncio
import time
import boto3
from sqlalchemy import select
from app.core.config import settings
from app.db.session import AsyncSessionLocal
from app.models.withdrawal import Withdrawal
from shared.dynamo.client import scan_pending, mark_cleaned


def get_replica_lag_seconds() -> float:
    try:
        cw = boto3.client(
            "cloudwatch",
            region_name=settings.AWS_REGION,
        )
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
    return 30.0


async def clean_once():
    lag = get_replica_lag_seconds()
    safe_age_seconds = lag + 10
    now = time.time()
    pending = scan_pending("withdrawal")

    async with AsyncSessionLocal() as db:
        for item in pending:
            created_epoch = item.get("ttl", 0) - 300
            if (now - created_epoch) < safe_age_seconds:
                continue

            record_id = item["record_id"]
            result = await db.execute(select(Withdrawal).where(Withdrawal.id == record_id))
            if result.scalar_one_or_none():
                mark_cleaned("withdrawal", record_id)
                print(f"[cleaner] Cleaned withdrawal {record_id} from DynamoDB")
            else:
                print(f"[cleaner] WARNING: withdrawal {record_id} in DynamoDB but not in RDS")


async def main():
    print("[cleaner] withdrawal-service DynamoDB cleaner starting...")
    while True:
        try:
            await clean_once()
        except Exception as e:
            print(f"[cleaner] Error: {e}")
        await asyncio.sleep(30)


if __name__ == "__main__":
    asyncio.run(main())
