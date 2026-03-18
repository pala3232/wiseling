import asyncio
import json
import httpx
import redis.asyncio as aioredis
from fastapi import APIRouter, Depends, HTTPException, Request, Query
from fastapi.responses import StreamingResponse
from jose import JWTError, jwt
from sqlalchemy.ext.asyncio import AsyncSession
from app.db.session import get_db
from app.schemas.wallet import WalletResponse, InitWalletsRequest
from app.services.wallet import get_wallets, init_wallets, list_transfers, list_ledger
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


@router.get("/api/v1/wallet/transfers")
async def get_transfers(user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    return await list_transfers(db, user_id)


@router.get("/api/v1/wallet/ledger")
async def get_ledger(user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    return await list_ledger(db, user_id)


@router.get("/internal/wallet/balance/{user_id}/{currency}", include_in_schema=False)
async def internal_balance(user_id: str, currency: str, db: AsyncSession = Depends(get_db)):
    wallets = await get_wallets(db, user_id)
    wallet = next((w for w in wallets if w.currency == currency), None)
    if not wallet:
        raise HTTPException(status_code=404, detail="Wallet not found")
    return {"balance": str(wallet.balance)}


@router.get("/api/v1/events")
async def sse_events(request: Request, token: str = Query(...)):
    try:
        payload = jwt.decode(token, settings.JWT_SECRET_KEY, algorithms=[settings.ALGORITHM])
        user_id = payload.get("sub")
        if not user_id:
            raise HTTPException(status_code=401, detail="Invalid token")
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")

    async def stream():
        redis = aioredis.from_url(settings.REDIS_URL, decode_responses=True)
        pubsub = redis.pubsub()
        await pubsub.subscribe(f"user:{user_id}")
        try:
            yield "event: ping\ndata: {}\n\n"
            tick = 0
            while True:
                if await request.is_disconnected():
                    break
                msg = await pubsub.get_message(ignore_subscribe_messages=True, timeout=1.0)
                if msg and msg["type"] == "message":
                    payload = json.loads(msg["data"])
                    event = payload.get("event", "balance_update")
                    data = json.dumps(payload.get("data", {}))
                    yield f"event: {event}\ndata: {data}\n\n"
                tick += 1
                if tick % 300 == 0:
                    yield "event: ping\ndata: {}\n\n"
                await asyncio.sleep(0.1)
        finally:
            await pubsub.unsubscribe(f"user:{user_id}")
            await redis.aclose()

    return StreamingResponse(stream(), media_type="text/event-stream", headers={
        "Cache-Control": "no-cache",
        "X-Accel-Buffering": "no",
    })