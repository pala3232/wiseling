from decimal import Decimal
from typing import Optional
from pydantic import BaseModel


class WalletResponse(BaseModel):
    id: str
    currency: str
    balance: Decimal

    class Config:
        from_attributes = True


class InitWalletsRequest(BaseModel):
    user_id: str


class LedgerEntryResponse(BaseModel):
    id: str
    currency: str
    amount: Decimal
    balance_after: Optional[Decimal] = None
    reason: str
    reference_id: str

    class Config:
        from_attributes = True