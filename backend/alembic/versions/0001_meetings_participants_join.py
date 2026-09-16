"""meetings, participants, and the many-to-many join between them

Revision ID: 0001
Revises:
Create Date: 2026-09-16
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "meetings",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("title", sa.String(length=200), nullable=False),
        sa.Column("description", sa.String(length=2000), server_default="", nullable=False),
        sa.Column("starts_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ends_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_meetings"),
        sa.CheckConstraint("ends_at > starts_at", name="ck_meetings_ends_after_starts"),
    )
    op.create_index("ix_meetings_starts_at_id", "meetings", ["starts_at", "id"])

    op.create_table(
        "participants",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("email", sa.String(length=320), nullable=False),
        sa.Column("display_name", sa.String(length=200), server_default="", nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_participants"),
        sa.UniqueConstraint("email", name="uq_participants_email"),
    )

    op.create_table(
        "meeting_participants",
        sa.Column("meeting_id", sa.Uuid(), nullable=False),
        sa.Column("participant_id", sa.Uuid(), nullable=False),
        sa.ForeignKeyConstraint(
            ["meeting_id"],
            ["meetings.id"],
            name="fk_meeting_participants_meeting_id",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["participant_id"],
            ["participants.id"],
            name="fk_meeting_participants_participant_id",
            ondelete="CASCADE",
        ),
        # Composite primary key: a duplicate invitation is impossible, and this
        # is the index for "who is in this meeting".
        sa.PrimaryKeyConstraint("meeting_id", "participant_id", name="pk_meeting_participants"),
    )
    # The other direction: every meeting one person is in, without a table scan.
    op.create_index(
        "ix_meeting_participants_participant_id_meeting_id",
        "meeting_participants",
        ["participant_id", "meeting_id"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_meeting_participants_participant_id_meeting_id",
        table_name="meeting_participants",
    )
    op.drop_table("meeting_participants")
    op.drop_table("participants")
    op.drop_index("ix_meetings_starts_at_id", table_name="meetings")
    op.drop_table("meetings")
