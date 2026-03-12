from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    DATABASE_URL: str = "postgresql+asyncpg://auth:auth@auth-db:5432/auth"
    JWT_SECRET_KEY: str = "change-me-in-production"
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 60 * 24

    # URL of wallet-service — called after register to create initial wallets
    WALLET_SERVICE_URL: str = "http://wallet-service:8001"

    class Config:
        env_file = ".env"


settings = Settings()
