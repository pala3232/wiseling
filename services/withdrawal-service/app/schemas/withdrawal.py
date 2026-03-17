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
    recipient_email: Optional[str] = None              # add this
    recipient_account_number: Optional[str] = None     # add this
    transfer_type: Optional[str] = 'withdrawal'
    status: str
    created_at: datetime

    class Config:
        from_attributes = True