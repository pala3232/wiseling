import uuid
from datetime import datetime
from sqlalchemy import String, DateTime, Text
from sqlalchemy.orm import Mapped, mapped_column
from app.db.base import Base


class OutboxEvent(Base):
    """
    Transactional outbox table.
    Written in the SAME transaction as the business record.
    The outbox poller reads PENDING rows and publishes them to SQS.
    This guarantees: if the conversion is saved, the SQS event WILL be published
    — even if the app crashes between commit and SQS publish.
    """
    __tablename__ = "outbox"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    event_type: Mapped[str] = mapped_column(String, nullable=False)
    payload: Mapped[str] = mapped_column(Text, nullable=False)  # JSON string
    status: Mapped[str] = mapped_column(String, default="PENDING")  # PENDING | PUBLISHED | FAILED
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    published_at: Mapped[datetime] = mapped_column(DateTime, nullable=True)
