"""Engine, session factory, session dependency."""

from collections.abc import Iterator

from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import NullPool

from app.config import settings

engine = (
    create_engine(settings.database_url, pool_pre_ping=True)
    if settings.db_keep_connections
    else create_engine(settings.database_url, poolclass=NullPool)
)

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
