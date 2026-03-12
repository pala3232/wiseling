import uuid
import random
from datetime import datetime
from sqlalchemy import String, DateTime
from sqlalchemy.orm import Mapped, mapped_column
from app.db.base import Base


def _generate_account_number() -> str:
    """Generate a 12-digit account number in XXXX-XXXX-XXXX format."""
    digits = [random.randint(0, 9) for _ in range(12)]
    s = ''.join(str(d) for d in digits)
    return f"{s[0:4]}-{s[4:8]}-{s[8:12]}"


class User(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    email: Mapped[str] = mapped_column(String, unique=True, nullable=False, index=True)
    hashed_password: Mapped[str] = mapped_column(String, nullable=False)
    account_number: Mapped[str] = mapped_column(String, unique=True, nullable=False, index=True, default=_generate_account_number)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)