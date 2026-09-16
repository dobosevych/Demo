"""HTTP layer: routers and request handlers.

The only place that knows about HTTP. Mounted under ``/api`` by ``app.main``.
"""

from fastapi import APIRouter

from app.api.meetings import router as meetings_router
from app.api.participants import router as participants_router

api_router = APIRouter()
api_router.include_router(meetings_router)
api_router.include_router(participants_router)

__all__ = ["api_router"]
