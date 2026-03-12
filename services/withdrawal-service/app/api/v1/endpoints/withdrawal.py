from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from app.db.session import get_db
from app.models.withdrawal import Withdrawal
from app.schemas.withdrawal import WithdrawalResponse, TransferRequest
from app.services.withdrawal import create_transfer, list_withdrawals, list_received_transfers
from app.core.dependencies import get_current_user_id

router = APIRouter(prefix="/api/v1/withdrawals", tags=["withdrawals"])


@router.post("/transfer", response_model=WithdrawalResponse, status_code=201)
async def transfer(
    body: TransferRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    return await create_transfer(
        db, user_id, body.currency, body.amount, body.idempotency_key, body.to_account_number
    )


@router.get("", response_model=list[WithdrawalResponse])
async def list_all(user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    return await list_withdrawals(db, user_id)


@router.get("/received", response_model=list[WithdrawalResponse])
async def list_received(user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    return await list_received_transfers(db, user_id)


@router.patch("/internal/{transfer_id}/complete", include_in_schema=False)
async def complete_transfer(transfer_id: str, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Withdrawal).where(Withdrawal.id == transfer_id))
    transfer = result.scalar_one_or_none()
    if transfer:
        transfer.status = "COMPLETED"
        await db.commit()
    return {"ok": True}