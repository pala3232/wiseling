import httpx
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from app.db.session import get_db
from app.schemas.wallet import WalletResponse, InitWalletsRequest
from app.services.wallet import get_wallets, init_wallets
from app.core.dependencies import get_current_user_id
from app.core.config import settings

router = APIRouter(tags=["wallet"])


@router.get("/api/v1/wallet/balances", response_model=list[WalletResponse])
async def balances(user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    return await get_wallets(db, user_id)


@router.get("/api/v1/wallet/lookup/{account_number}")
async def lookup_recipient(account_number: str, user_id: str = Depends(get_current_user_id)):
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(
                f"{settings.AUTH_SERVICE_URL}/api/v1/auth/lookup/{account_number}",
            )
            if resp.status_code == 404:
                raise HTTPException(status_code=404, detail="Account not found")
            resp.raise_for_status()
            return resp.json()
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=503, detail="Could not reach auth service")


@router.post("/internal/wallets/init", include_in_schema=False)
async def init(body: InitWalletsRequest, db: AsyncSession = Depends(get_db)):
    await init_wallets(db, body.user_id)
    return {"ok": True}