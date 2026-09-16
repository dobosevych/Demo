"""The ``meeting_participants`` many-to-many join.

Two UUID columns and nothing else: no surrogate id, no payload. The composite
primary key makes a duplicate invitation impossible and indexes "who is in this
meeting"; the reverse index serves "which meetings is this person in".
"""

import sqlalchemy as sa

from app.models.base import Base

meeting_participants = sa.Table(
    "meeting_participants",
    Base.metadata,
    sa.Column(
        "meeting_id",
        sa.Uuid(),
        sa.ForeignKey("meetings.id", ondelete="CASCADE"),
        primary_key=True,
        nullable=False,
    ),
    sa.Column(
        "participant_id",
        sa.Uuid(),
        sa.ForeignKey("participants.id", ondelete="CASCADE"),
        primary_key=True,
        nullable=False,
    ),
    sa.Index(
        "ix_meeting_participants_participant_id_meeting_id",
        "participant_id",
        "meeting_id",
    ),
)
