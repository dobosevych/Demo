"""HTTP layer for the ``Participant`` resource."""

import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.db import get_session
from app.models import Participant
from app.schemas import ParticipantCreate, ParticipantRead, ParticipantUpdate

router = APIRouter(prefix="/participants", tags=["participants"])


def resolve_participants(session: Session, emails: list[str]) -> list[Participant]:
    """Get-or-create one participant row per address, preserving order.

    Shared with the meetings router: inviting an address that is already known
    reuses its row instead of copying the person.
    """
    wanted = list(dict.fromkeys(emails))
    if not wanted:
        return []

    found = {
        participant.email: participant
        for participant in session.scalars(select(Participant).where(Participant.email.in_(wanted)))
    }
    for email in wanted:
        if email in found:
            continue
        try:
            # A savepoint, so a concurrent insert of the same address costs this
            # address and not the whole request.
            with session.begin_nested():
                participant = Participant(email=email)
                session.add(participant)
                session.flush()
        except IntegrityError:
            participant = session.scalar(select(Participant).where(Participant.email == email))
        found[email] = participant

    return [found[email] for email in wanted]


def get_participant(session: Session, participant_id: uuid.UUID) -> Participant:
    participant = session.get(Participant, participant_id)
    if participant is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="participant not found")
    return participant


@router.get("", response_model=list[ParticipantRead])
def list_participants(
    session: Session = Depends(get_session),
    email: str | None = Query(None),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
) -> list[Participant]:
    statement = select(Participant).order_by(Participant.email).limit(limit).offset(offset)
    if email is not None:
        statement = statement.where(Participant.email == email.strip().lower())
    return list(session.scalars(statement))


@router.post("", response_model=ParticipantRead, status_code=status.HTTP_201_CREATED)
def create_participant(
    payload: ParticipantCreate,
    session: Session = Depends(get_session),
) -> Participant:
    participant = Participant(email=payload.email, display_name=payload.display_name)
    session.add(participant)
    try:
        session.commit()
    except IntegrityError:
        session.rollback()
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            detail=f"a participant with email {payload.email} already exists",
        ) from None
    return participant


@router.get("/{participant_id}", response_model=ParticipantRead)
def read_participant(
    participant_id: uuid.UUID,
    session: Session = Depends(get_session),
) -> Participant:
    return get_participant(session, participant_id)


@router.patch("/{participant_id}", response_model=ParticipantRead)
def update_participant(
    participant_id: uuid.UUID,
    payload: ParticipantUpdate,
    session: Session = Depends(get_session),
) -> Participant:
    participant = get_participant(session, participant_id)
    changes = payload.model_dump(exclude_unset=True)
    if "display_name" in changes and changes["display_name"] is not None:
        participant.display_name = changes["display_name"]
    session.commit()
    return participant


@router.delete("/{participant_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_participant(
    participant_id: uuid.UUID,
    session: Session = Depends(get_session),
) -> Response:
    participant = get_participant(session, participant_id)
    # Their links go with them; the meetings themselves stay.
    session.delete(participant)
    session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
