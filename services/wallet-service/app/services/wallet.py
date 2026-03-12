from decimal import Decimal
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from app.models.wallet import Wallet, LedgerEntry
from fastapi import HTTPException

STARTER_BALANCES = {"USD": Decimal("10000"), "EUR": Decimal("0"), "GBP": Decimal("0")}


async def init_wallets(db: AsyncSession, user_id: str) -> list[Wallet]:
    wallets = []
    for currency, balance in STARTER_BALANCES.items():
        w = Wallet(user_id=user_id, currency=currency, balance=balance)
        db.add(w)
        wallets.append(w)
    await db.commit()
    return wallets


async def get_wallets(db: AsyncSession, user_id: str) -> list[Wallet]:
    result = await db.execute(select(Wallet).where(Wallet.user_id == user_id))
    return result.scalars().all()


async def list_transfers(db: AsyncSession, user_id: str) -> list[dict]:
    result = await db.execute(
        select(LedgerEntry)
        .where(
            LedgerEntry.user_id == user_id,
            LedgerEntry.reason.in_(["transfer_out", "transfer_in"]),
        )
        .order_by(LedgerEntry.created_at.desc())
    )
    entries = result.scalars().all()
    return [
        {
            "id": e.id,
            "currency": e.currency,
            "amount": str(abs(e.amount)),
            "direction": "out" if e.reason == "transfer_out" else "in",
            "reason": e.reason,
            "reference_id": e.reference_id,
            "created_at": e.created_at.isoformat(),
        }
        for e in entries
    ]


async def transfer(
    db: AsyncSession,
    sender_id: str,
    recipient_id: str,
    currency: str,
    amount: Decimal,
    reference_id: str,
) -> dict:
    if sender_id == recipient_id:
        raise HTTPException(status_code=400, detail="Cannot transfer to yourself")

    sender_wallet = await _get_wallet(db, sender_id, currency)
    if sender_wallet.balance < amount:
        raise HTTPException(status_code=400, detail=f"Insufficient {currency} balance")

    recipient_wallet = await _get_or_create_wallet(db, recipient_id, currency)

    sender_wallet.balance -= amount
    db.add(LedgerEntry(
        user_id=sender_id, currency=currency,
        amount=-amount, reason="transfer_out", reference_id=reference_id,
    ))

    await db.flush()
    recipient_wallet.balance += amount
    db.add(LedgerEntry(
        user_id=recipient_id, currency=currency,
        amount=amount, reason="transfer_in", reference_id=reference_id,
    ))

    await db.commit()
    return {"ok": True, "reference_id": reference_id}


async def debit(
    db: AsyncSession, user_id: str, currency: str, amount: Decimal,
    reason: str, reference_id: str,
) -> Wallet:
    wallet = await _get_wallet(db, user_id, currency)
    if wallet.balance < amount:
        raise HTTPException(status_code=400, detail=f"Insufficient {currency} balance")
    wallet.balance -= amount
    db.add(LedgerEntry(
        user_id=user_id, currency=currency,
        amount=-amount, reason=reason, reference_id=reference_id,
    ))
    await db.commit()
    return wallet


async def credit(
    db: AsyncSession, user_id: str, currency: str, amount: Decimal,
    reason: str, reference_id: str,
) -> Wallet:
    wallet = await _get_or_create_wallet(db, user_id, currency)
    wallet.balance += amount
    db.add(LedgerEntry(
        user_id=user_id, currency=currency,
        amount=amount, reason=reason, reference_id=reference_id,
    ))
    await db.commit()
    return wallet


async def _get_wallet(db: AsyncSession, user_id: str, currency: str) -> Wallet:
    result = await db.execute(
        select(Wallet).where(Wallet.user_id == user_id, Wallet.currency == currency)
    )
    w = result.scalar_one_or_none()
    if not w:
        raise HTTPException(status_code=404, detail=f"No {currency} wallet found")
    return w


async def _get_or_create_wallet(db: AsyncSession, user_id: str, currency: str) -> Wallet:
    result = await db.execute(
        select(Wallet).where(Wallet.user_id == user_id, Wallet.currency == currency)
    )
    w = result.scalar_one_or_none()
    if not w:
        w = Wallet(user_id=user_id, currency=currency, balance=Decimal("0"))
        db.add(w)
    return w