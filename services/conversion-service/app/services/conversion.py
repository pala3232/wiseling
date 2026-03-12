import json
from decimal import Decimal
from datetime import datetime
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from app.models.conversion import Conversion
from app.models.outbox import OutboxEvent
from app.services.rates import get_provider
from app.core.config import settings
from shared.dynamo.client import write_to_dynamo

FEE_RATE = Decimal("0.003")


async def create_conversion(
    db: AsyncSession,
    user_id: str,
    from_currency: str,
    to_currency: str,
    amount: Decimal,
    idempotency_key: str,
) -> Conversion:
    # Idempotency check
    existing = await db.execute(select(Conversion).where(Conversion.idempotency_key == idempotency_key))
    if record := existing.scalar_one_or_none():
        return record

    provider = get_provider()
    rate = await provider.get_rate(from_currency, to_currency)
    fee = (amount * FEE_RATE).quantize(Decimal("0.00000001"))
    to_amount = ((amount - fee) * rate).quantize(Decimal("0.00000001"))

    payload = {
        "conversion_id": "",  # filled after flush
        "user_id": user_id,
        "from_currency": from_currency,
        "to_currency": to_currency,
        "from_amount": str(amount),
        "to_amount": str(to_amount),
    }

    conversion = Conversion(
        user_id=user_id,
        idempotency_key=idempotency_key,
        from_currency=from_currency,
        to_currency=to_currency,
        from_amount=amount,
        to_amount=to_amount,
        rate=rate,
        fee=fee,
        status="PENDING",
    )

    # ── ATOMIC: conversion record + outbox event in ONE transaction ──────────
    # The session from get_db() already has an active transaction, so we use
    # flush() + commit() directly instead of db.begin() to avoid double-transaction.
    db.add(conversion)
    await db.flush()  # get conversion.id before outbox write

    payload["conversion_id"] = conversion.id
    db.add(OutboxEvent(
        event_type="conversion.requested",
        payload=json.dumps(payload),
        status="PENDING",
    ))
    await db.commit()
    # ── END ATOMIC ───────────────────────────────────────────────────────────

    await db.refresh(conversion)

    # ── DYNAMO BUFFER: short-lived safety net for cross-region replication gap
    # Non-fatal if this fails — RDS has the committed data.
    # Only matters if the entire region dies in the next ~5 seconds.
    write_to_dynamo(
        service="conversion",
        record_id=conversion.id,
        payload=payload,
    )

    return conversion


async def list_conversions(db: AsyncSession, user_id: str) -> list[Conversion]:
    result = await db.execute(
        select(Conversion).where(Conversion.user_id == user_id).order_by(Conversion.created_at.desc())
    )
    return result.scalars().all()