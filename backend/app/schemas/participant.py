"""Pydantic models for the ``Participant`` resource."""

import re
import uuid
from typing import Annotated

from pydantic import AfterValidator, BaseModel, ConfigDict, StringConstraints

_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s.]+(?:\.[^@\s.]+)+$")


def _normalize_email(value: str) -> str:
    """Trim and lowercase, so Ada@Example.com and ada@example.com are one person."""
    value = value.strip().lower()
    if len(value) > 320 or not _EMAIL_RE.match(value):
        raise ValueError("not a valid email address")
    return value


Email = Annotated[str, AfterValidator(_normalize_email)]
DisplayName = Annotated[str, StringConstraints(max_length=200)]


class ParticipantCreate(BaseModel):
    email: Email
    display_name: DisplayName = ""


class ParticipantUpdate(BaseModel):
    """``email`` is immutable: it is the key the rest of the API resolves people by."""

    display_name: DisplayName | None = None


class ParticipantRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    email: str
    display_name: str
