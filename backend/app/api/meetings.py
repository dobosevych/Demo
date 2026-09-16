"""HTTP layer for the ``Meeting`` resource and its invitee links."""

import uuid
from datetime import UTC, datetime

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.api.participants import get_participant, resolve_participants
from app.db import get_session
from app.models import Meeting, meeting_participants
from app.schemas import MeetingCreate, MeetingRead, MeetingUpdate

router = APIRouter(prefix="/meetings", tags=["meetings"])


def _utc(value: datetime) -> datetime:
    return value.astimezone(UTC)


def _get_meeting(session: Session, meeting_id: uuid.UUID) -> Meeting:
    meeting = session.get(Meeting, meeting_id)
    if meeting is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="meeting not found")
    return meeting


@router.get("", response_model=list[MeetingRead])
def list_meetings(
    session: Session = Depends(get_session),
    from_: datetime | None = Query(None, alias="from"),
    to: datetime | None = Query(None),
    participant_id: uuid.UUID | None = Query(None),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
) -> list[Meeting]:
    statement = (
        select(Meeting)
        # Ordered by (starts_at, id), so paging is stable.
        .order_by(Meeting.starts_at.asc(), Meeting.id.asc())
        .limit(limit)
        .offset(offset)
    )
    if from_ is not None:
        statement = statement.where(Meeting.ends_at >= _utc(from_))
    if to is not None:
        statement = statement.where(Meeting.starts_at < _utc(to))
    if participant_id is not None:
        statement = statement.where(
            select(meeting_participants.c.meeting_id)
            .where(
                meeting_participants.c.meeting_id == Meeting.id,
                meeting_participants.c.participant_id == participant_id,
            )
            .exists()
        )
    return list(session.scalars(statement))


@router.post("", response_model=MeetingRead, status_code=status.HTTP_201_CREATED)
def create_meeting(
    payload: MeetingCreate,
    session: Session = Depends(get_session),
) -> Meeting:
    meeting = Meeting(
        title=payload.title,
        description=payload.description,
        starts_at=_utc(payload.starts_at),
        ends_at=_utc(payload.ends_at),
        # Missing people are created and linked in this same transaction.
        participants=resolve_participants(session, payload.participants),
    )
    session.add(meeting)
    session.commit()
    return meeting


@router.get("/{meeting_id}", response_model=MeetingRead)
def read_meeting(
    meeting_id: uuid.UUID,
    session: Session = Depends(get_session),
) -> Meeting:
    return _get_meeting(session, meeting_id)


@router.patch("/{meeting_id}", response_model=MeetingRead)
def update_meeting(
    meeting_id: uuid.UUID,
    payload: MeetingUpdate,
    session: Session = Depends(get_session),
) -> Meeting:
    meeting = _get_meeting(session, meeting_id)
    changes = payload.model_dump(exclude_unset=True)

    if changes.get("title") is not None:
        meeting.title = changes["title"]
    if changes.get("description") is not None:
        meeting.description = changes["description"]
    if changes.get("starts_at") is not None:
        meeting.starts_at = _utc(changes["starts_at"])
    if changes.get("ends_at") is not None:
        meeting.ends_at = _utc(changes["ends_at"])
    if meeting.ends_at <= meeting.starts_at:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="ends_at must be after starts_at",
        )

    if changes.get("participants") is not None:
        # Replace the invitee list: links only. The participant rows are untouched.
        meeting.participants = resolve_participants(session, changes["participants"])

    session.commit()
    return meeting


@router.delete("/{meeting_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_meeting(
    meeting_id: uuid.UUID,
    session: Session = Depends(get_session),
) -> Response:
    meeting = _get_meeting(session, meeting_id)
    # Its links go with it; the participants themselves stay.
    session.delete(meeting)
    session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.put(
    "/{meeting_id}/participants/{participant_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
def invite_participant(
    meeting_id: uuid.UUID,
    participant_id: uuid.UUID,
    session: Session = Depends(get_session),
) -> Response:
    """Write one join row. Idempotent, and never creates a participant."""
    _get_meeting(session, meeting_id)
    get_participant(session, participant_id)

    statement = (
        insert(meeting_participants)
        .values(meeting_id=meeting_id, participant_id=participant_id)
        # Already invited: the link is the desired state either way.
        .on_conflict_do_nothing(index_elements=["meeting_id", "participant_id"])
    )
    session.execute(statement)
    session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete(
    "/{meeting_id}/participants/{participant_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
def uninvite_participant(
    meeting_id: uuid.UUID,
    participant_id: uuid.UUID,
    session: Session = Depends(get_session),
) -> Response:
    """Delete one join row. Idempotent, and never deletes a participant."""
    _get_meeting(session, meeting_id)
    get_participant(session, participant_id)

    session.execute(
        delete(meeting_participants).where(
            meeting_participants.c.meeting_id == meeting_id,
            meeting_participants.c.participant_id == participant_id,
        )
    )
    session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
