from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    DATABASE_URL: str = "postgresql+asyncpg://wallet:wallet@wallet-db:5432/wallet"
    JWT_SECRET_KEY: str = "change-me-in-production"
    ALGORITHM: str = "HS256"

    # SQS queues — wallet-service consumes both
    SQS_CONVERSIONS_QUEUE_URL: str = ""
    SQS_WITHDRAWALS_QUEUE_URL: str = ""
    AWS_REGION: str = "ap-southeast-2"
    AWS_ACCESS_KEY_ID: str = ""
    AWS_SECRET_ACCESS_KEY: str = ""

    # DynamoDB — used by reconciler on startup after failover
    DYNAMO_OUTBOX_TABLE: str = "wiseling-outbox"

    # Auth service — used for account number lookup during transfers
    AUTH_SERVICE_URL: str = "http://auth-service:8000"
    WITHDRAWAL_SERVICE_URL: str = "http://withdrawal-service:8003"


    # Run reconciler on startup (set to False in normal ops, True after failover)
    RECONCILE_ON_STARTUP: bool = False

    class Config:
        env_file = ".env"


settings = Settings()