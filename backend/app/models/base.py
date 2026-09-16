from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    """Declarative base. Alembic reads ``Base.metadata`` to generate migrations."""
