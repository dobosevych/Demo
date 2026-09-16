"""Engine, session factory, session dependency."""

from collections.abc import Iterator

from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

from app.config import settings

engine = create_engine(settings.database_url, pool_pre_ping=True)

SessionLocal = sessionmaker(
    bind=engine,
    class_=Session,
    autoflush=False,
    # Responses are serialized after commit, so attributes must stay loaded.
    expire_on_commit=False,
)


def get_session() -> Iterator[Session]:
    """Per-request session. Rolls back if the handler raises."""
    with SessionLocal() as session:
        yield session
