"""A meeting and the invitee list it reaches through the join."""

from __future__ import annotations

import uuid
from datetime import datetime

import sqlalchemy as sa
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base
from app.models.join import meeting_participants
from app.models.participant import Participant


class Meeting(Base):
    __tablename__ = "meetings"
    __table_args__ = (
        sa.CheckConstraint("ends_at > starts_at", name="ck_meetings_ends_after_starts"),
        sa.Index("ix_meetings_starts_at_id", "starts_at", "id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(sa.Uuid(), primary_key=True, default=uuid.uuid4)
    title: Mapped[str] = mapped_column(sa.String(200), nullable=False)
    description: Mapped[str] = mapped_column(
        sa.String(2000), nullable=False, default="", server_default=""
    )
    starts_at: Mapped[datetime] = mapped_column(sa.DateTime(timezone=True), nullable=False)
    ends_at: Mapped[datetime] = mapped_column(sa.DateTime(timezone=True), nullable=False)

    # selectin: a page of meetings loads every invitee list in one extra query
    # across the join, never one query per meeting.
    participants: Mapped[list[Participant]] = relationship(
        secondary=meeting_participants,
        back_populates="meetings",
        lazy="selectin",
        order_by=Participant.email,
    )
