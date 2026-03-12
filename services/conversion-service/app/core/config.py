from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    DATABASE_URL: str = "postgresql+asyncpg://conversion:conversion@conversion-db:5432/conversion"
    JWT_SECRET_KEY: str = "change-me-in-production"
    ALGORITHM: str = "HS256"

    SQS_CONVERSIONS_QUEUE_URL: str = ""
    AWS_REGION: str = "us-east-1"
    AWS_ACCESS_KEY_ID: str = ""
    AWS_SECRET_ACCESS_KEY: str = ""

    # DynamoDB safety net buffer
    DYNAMO_OUTBOX_TABLE: str = "wiseling-outbox"
    DYNAMO_OUTBOX_TTL_SECONDS: int = 300  # 5 minutes

    # RDS cross-region replica identifier (for lag checking in cleaner)
    RDS_REPLICA_IDENTIFIER: str = ""

    # Pluggable rates provider: "static" | "openexchangerates"
    RATES_PROVIDER: str = "static"
    OPEN_EXCHANGE_RATES_APP_ID: str = ""

    FX_RATES: dict = {
        "USD/EUR": 0.9183, "USD/GBP": 0.7841,
        "EUR/USD": 1.0889, "EUR/GBP": 0.8540,
        "GBP/USD": 1.2753, "GBP/EUR": 1.1709,
    }

    class Config:
        env_file = ".env"


settings = Settings()
