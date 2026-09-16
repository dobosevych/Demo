"""Pydantic models for the ``Meeting`` resource."""

import uuid
from datetime import UTC, datetime
from typing import Annotated, Self

from pydantic import (
    AwareDatetime,
    BaseModel,
    ConfigDict,
    StringConstraints,
    field_serializer,
    model_validator,
)

from app.schemas.participant import Email, ParticipantRead

Title = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]
Description = Annotated[str, StringConstraints(max_length=2000)]


class MeetingCreate(BaseModel):
    title: Title
    description: Description = ""
    # AwareDatetime rejects a timestamp without a timezone.
    starts_at: AwareDatetime
    ends_at: AwareDatetime
    # Email addresses, not objects: the backend resolves each to a participant row.
    participants: list[Email] = []

    @model_validator(mode="after")
    def _ends_after_starts(self) -> Self:
        if self.ends_at <= self.starts_at:
            raise ValueError("ends_at must be after starts_at")
        return self


class MeetingUpdate(BaseModel):
    """Only the keys present are changed.

    ``ends_at``/``starts_at`` are compared against the stored meeting by the
    handler, which is the only place that knows the values being merged into.
    """

    title: Title | None = None
    description: Description | None = None
    starts_at: AwareDatetime | None = None
    ends_at: AwareDatetime | None = None
    # Present: replace the whole invitee list. Absent: leave it alone.
    participants: list[Email] | None = None


class MeetingRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    title: str
    description: str
    starts_at: datetime
    ends_at: datetime
    participants: list[ParticipantRead]

    @field_serializer("starts_at", "ends_at")
    def _as_utc_z(self, value: datetime) -> str:
        """ISO 8601 with an explicit Z, as the contract states."""
        return value.astimezone(UTC).isoformat().replace("+00:00", "Z")
