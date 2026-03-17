from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession
from app.db.session import get_db
from app.schemas.conversion import ConversionRequest, ConversionResponse
from app.services.conversion import create_conversion, list_conversions
from app.core.dependencies import get_current_user_id
from sqlalchemy import select
from app.models.conversion import Conversion

router = APIRouter(prefix="/api/v1/conversions", tags=["conversions"])


@router.post("", response_model=ConversionResponse, status_code=201)
async def convert(
    body: ConversionRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    return await create_conversion(
        db, user_id, body.from_currency, body.to_currency, body.amount, body.idempotency_key
    )


@router.get("", response_model=list[ConversionResponse])
async def list_all(user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    return await list_conversions(db, user_id)


@router.get("/rates")
async def rates():
    from app.services.rates import get_provider
    return await get_provider().list_rates()

@router.patch("/internal/{conversion_id}/complete", include_in_schema=False)
async def complete_conversion(conversion_id: str, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Conversion).where(Conversion.id == conversion_id))
    conversion = result.scalar_one_or_none()
    if conversion:
        conversion.status = "COMPLETED"
        await db.commit()
    return {"ok": True}