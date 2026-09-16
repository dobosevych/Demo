"""A person, not an invitation: one row per human, shared by every meeting."""

from __future__ import annotations

import uuid
from typing import TYPE_CHECKING

import sqlalchemy as sa
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base
from app.models.join import meeting_participants

if TYPE_CHECKING:
    from app.models.meeting import Meeting


class Participant(Base):
    __tablename__ = "participants"

    id: Mapped[uuid.UUID] = mapped_column(sa.Uuid(), primary_key=True, default=uuid.uuid4)
    # Globally unique, stored lowercased by the schema layer: the natural key the
    # API resolves people by.
    email: Mapped[str] = mapped_column(sa.String(320), nullable=False, unique=True)
    display_name: Mapped[str] = mapped_column(
        sa.String(200), nullable=False, default="", server_default=""
    )

    meetings: Mapped[list[Meeting]] = relationship(
        secondary=meeting_participants,
        back_populates="participants",
    )
