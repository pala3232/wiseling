from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.api.v1.endpoints.wallet import router
from app.core.config import settings
from app.db.session import engine       
from app.db.base import Base             
from app.models.wallet import Wallet, LedgerEntry
from prometheus_fastapi_instrumentator import Instrumentator


@asynccontextmanager
async def lifespan(app: FastAPI):
    async with engine.begin() as conn: 
        await conn.run_sync(Base.metadata.create_all)
    if settings.RECONCILE_ON_STARTUP:
        try:
            from app.services.reconciler import reconcile
            reconcile()
        except Exception as e:
            
            print(f"[startup] Reconciler error (non-fatal): {e}")
    yield


app = FastAPI(title="Wiseling Wallet Service", version="0.1.0", lifespan=lifespan)
Instrumentator().instrument(app).expose(app)


app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(router)


@app.get("/health")
async def health():
    return {"service": "wallet", "status": "ok"}