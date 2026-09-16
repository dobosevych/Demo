"""Pydantic models: the shape of the JSON on the wire.

An ORM model never leaves the service directly.
"""

from app.schemas.meeting import MeetingCreate, MeetingRead, MeetingUpdate
from app.schemas.participant import ParticipantCreate, ParticipantRead, ParticipantUpdate

__all__ = [
    "MeetingCreate",
    "MeetingRead",
    "MeetingUpdate",
    "ParticipantCreate",
    "ParticipantRead",
    "ParticipantUpdate",
]
