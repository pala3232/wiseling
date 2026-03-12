import uuid
from datetime import datetime
from sqlalchemy import String, DateTime, Text
from sqlalchemy.orm import Mapped, mapped_column
from app.db.base import Base


class OutboxEvent(Base):
    """
    Transactional outbox table.
    Written in the SAME transaction as the withdrawal record.
    The outbox poller reads PENDING rows and publishes them to SQS.
    """
    __tablename__ = "outbox"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    event_type: Mapped[str] = mapped_column(String, nullable=False)
    payload: Mapped[str] = mapped_column(Text, nullable=False)  # JSON string
    status: Mapped[str] = mapped_column(String, default="PENDING")  # PENDING | PUBLISHED | FAILED
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    published_at: Mapped[datetime] = mapped_column(DateTime, nullable=True)
