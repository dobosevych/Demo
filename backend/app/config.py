"""Settings read from environment variables.

The only module that touches ``os.environ``. Everything else imports ``settings``.
"""

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    database_url: str
    cors_origins: tuple[str, ...]


def _load() -> Settings:
    database_url = os.environ.get("DATABASE_URL", "").strip()
    if not database_url:
        raise RuntimeError(
            "DATABASE_URL is not set. The backend has no default that works "
            "outside docker compose."
        )
    raw_origins = os.environ.get("CORS_ORIGINS", "http://localhost:5173")
    origins = tuple(origin.strip() for origin in raw_origins.split(",") if origin.strip())
    return Settings(database_url=database_url, cors_origins=origins)


settings = _load()
