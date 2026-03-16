from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.api.v1.router import router
from app.db.session import engine
from app.db.base import Base
from app.models.user import User
import os



app = FastAPI(title="Wiseling Auth Service", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(router)

@app.on_event("startup")
async def startup():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        
@app.get("/health")
async def health():
    return {"service": "auth", "status": "ok"}
@app.get("/api/v1/envinfo")
async def get_env_info():
    return {
        "pod_name": os.environ.get("HOSTNAME", "unknown"),
        "node_name": os.environ.get("NODE_NAME", "unknown"),
        "cluster_name": os.environ.get("CLUSTER_NAME", "unknown"),
        "aws_region": os.environ.get("AWS_REGION", "unknown"),
        "aws_az": os.environ.get("AWS_AZ", "unknown"),
    }