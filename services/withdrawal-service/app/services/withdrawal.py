import json
import httpx
from decimal import Decimal
from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from app.models.withdrawal import Withdrawal
from app.models.outbox import OutboxEvent
from app.core.config import settings
from shared.dynamo.client import write_to_dynamo


async def create_transfer(
    db: AsyncSession,
    user_id: str,
    currency: str,
    amount: Decimal,
    idempotency_key: str,
    to_account_number: str,
) -> Withdrawal:
    existing = await db.execute(select(Withdrawal).where(Withdrawal.idempotency_key == idempotency_key))
    if record := existing.scalar_one_or_none():
        return record

    async with httpx.AsyncClient(timeout=5.0) as client:
        resp = await client.get(
            f"{settings.AUTH_SERVICE_URL}/api/v1/auth/lookup/{to_account_number}"
        )
        if resp.status_code == 404:
            raise HTTPException(status_code=404, detail="Recipient account not found")
        resp.raise_for_status()
        recipient = resp.json()

    recipient_id = recipient["user_id"]
    if recipient_id == user_id:
        raise HTTPException(status_code=400, detail="Cannot transfer to yourself")

    transfer = Withdrawal(
        user_id=user_id,
        idempotency_key=idempotency_key,
        currency=currency,
        amount=amount,
        fee=Decimal("0"),
        net_amount=amount,
        recipient_id=recipient_id,
        recipient_email=recipient["email"],
        recipient_account_number=to_account_number,
        transfer_type="transfer",
        status="PENDING",
    )

    payload = {
        "transfer_id": "",
        "sender_id": user_id,
        "recipient_id": recipient_id,
        "currency": currency,
        "amount": str(amount),
    }

    db.add(transfer)
    await db.flush()
    payload["transfer_id"] = transfer.id
    db.add(OutboxEvent(
        event_type="transfer.requested",
        payload=json.dumps(payload),
        status="PENDING",
    ))
    await db.commit()
    await db.refresh(transfer)

    write_to_dynamo(service="withdrawal", record_id=transfer.id, payload=payload)
    return transfer


async def list_withdrawals(db: AsyncSession, user_id: str) -> list[Withdrawal]:
    result = await db.execute(
        select(Withdrawal).where(Withdrawal.user_id == user_id).order_by(Withdrawal.created_at.desc())
    )
    return result.scalars().all()

async def list_received_transfers(db: AsyncSession, user_id: str) -> list[Withdrawal]:
    result = await db.execute(
        select(Withdrawal).where(
            Withdrawal.recipient_id == user_id,
            Withdrawal.transfer_type == 'transfer'
        ).order_by(Withdrawal.created_at.desc())
    )
    return result.scalars().all()