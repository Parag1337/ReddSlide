from fastapi import APIRouter
from ..models.schemas import HealthResponse
from ..services.queue_manager import QueueManager
from ..managers.provider import ProviderManager
from ..core.database import get_db

router = APIRouter()


@router.get("/health", response_model=HealthResponse)
async def health():
    """System health status."""
    db_healthy = True
    queue_size = 0
    
    try:
        async with get_db() as db:
            cursor = await db.execute("SELECT COUNT(*) as count FROM media_queue")
            row = await cursor.fetchone()
            queue_size = row["count"] if row else 0
    except Exception:
        db_healthy = False
    
    return HealthResponse(
        status="ok" if db_healthy else "degraded",
        database=db_healthy,
        oauth_valid=False,  # Requires setup
        queue_size=queue_size,
        providers={"primary": "reddit_oauth", "fallback": "redlib"}
    )


@router.get("/debug/providers")
async def debug_providers():
    """Provider health status and metrics."""
    pm = ProviderManager()
    return await pm.get_provider_status()


@router.get("/debug/queue")
async def debug_queue():
    """Queue statistics and diagnostics."""
    qm = QueueManager()
    queue_size = await qm.count_queue_items()
    return {
        "queue_size": queue_size,
        "max": 1000,
        "min": 500,
        "refill_threshold": 300,
        "emergency_threshold": 100
    }