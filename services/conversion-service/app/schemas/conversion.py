from decimal import Decimal
from datetime import datetime
from pydantic import BaseModel


class ConversionRequest(BaseModel):
    from_currency: str
    to_currency: str
    amount: Decimal
    idempotency_key: str


class ConversionResponse(BaseModel):
    id: str
    from_currency: str
    to_currency: str
    from_amount: Decimal
    to_amount: Decimal
    rate: Decimal
    fee: Decimal
    status: str
    created_at: datetime

    class Config:
        from_attributes = True
