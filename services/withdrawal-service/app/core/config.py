from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    DATABASE_URL: str = "postgresql+asyncpg://withdrawal:withdrawal@withdrawal-db:5432/withdrawal"
    JWT_SECRET_KEY: str = "change-me-in-production"
    ALGORITHM: str = "HS256"

    SQS_WITHDRAWALS_QUEUE_URL: str = ""
    AWS_REGION: str = "us-east-1"
    AWS_ACCESS_KEY_ID: str = ""
    AWS_SECRET_ACCESS_KEY: str = ""

    DYNAMO_OUTBOX_TABLE: str = "wiseling-outbox"
    DYNAMO_OUTBOX_TTL_SECONDS: int = 300
    RDS_REPLICA_IDENTIFIER: str = ""

    AUTH_SERVICE_URL: str = "http://auth-service:8000"  # NEW

    class Config:
        env_file = ".env"


settings = Settings()