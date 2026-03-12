from decimal import Decimal
from datetime import datetime
from pydantic import BaseModel
from typing import Optional


class TransferRequest(BaseModel):
    to_account_number: str
    currency: str
    amount: Decimal
    idempotency_key: str


class WithdrawalResponse(BaseModel):
    id: str
    currency: str
    amount: Decimal
    fee: Decimal
    net_amount: Decimal
    recipient_id: Optional[str] = None
    transfer_type: Optional[str] = 'withdrawal'
    status: str
    created_at: datetime

    class Config:
        from_attributes = True