import os
import time
from collections import defaultdict
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from contextlib import asynccontextmanager
from dotenv import load_dotenv

load_dotenv()

from .core.database import init_db, DATABASE_PATH
from .api import feed, debug, search
from .managers.oauth import OAuthManager
from .managers.provider import ProviderManager
from .services.background_service import BackgroundRefreshService


oauth_manager: OAuthManager = None
background_service: BackgroundRefreshService = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifecycle manager."""
    global oauth_manager, background_service
    
    # Ensure data directory exists
    os.makedirs(os.path.dirname(DATABASE_PATH), exist_ok=True)
    
    # Initialize database
    await init_db()
    
    # Initialize OAuth manager
    oauth_manager = OAuthManager(
        client_id=os.getenv("REDDIT_CLIENT_ID", ""),
        client_secret=os.getenv("REDDIT_CLIENT_SECRET", ""),
        user_agent=os.getenv("REDDIT_USER_AGENT", "RedSlide/1.0")
    )
    await oauth_manager.initialize()

    app.state.oauth_manager = oauth_manager
    app.state.provider_manager = ProviderManager()

    # Initialize and start background service
    background_service = BackgroundRefreshService()
    await background_service.start()
    
    yield
    
    # Cleanup on shutdown
    if background_service:
        await background_service.stop()


app = FastAPI(
    title="RedSlide API",
    description="Media discovery backend for RedSlide Android app",
    version="1.0.0",
    lifespan=lifespan
)


class SlidingWindowRateLimiter:
    """In-memory sliding window rate limiter.

    Tracks request timestamps per client IP using a sliding window.
    Old entries are pruned lazily on each request.
    """

    def __init__(self, max_requests: int = 60, window_seconds: float = 60.0):
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self._clients: dict[str, list[float]] = defaultdict(list)

    def check(self, client_ip: str) -> bool:
        now = time.time()
        cutoff = now - self.window_seconds
        timestamps = self._clients[client_ip]
        # Prune old entries
        self._clients[client_ip] = [t for t in timestamps if t > cutoff]
        if len(self._clients[client_ip]) >= self.max_requests:
            return False
        self._clients[client_ip].append(now)
        return True


rate_limiter = SlidingWindowRateLimiter(max_requests=60, window_seconds=60.0)


@app.middleware("http")
async def rate_limit_middleware(request: Request, call_next):
    client_ip = request.client.host if request.client else "unknown"
    if not rate_limiter.check(client_ip):
        return JSONResponse(
            status_code=429,
            content={"detail": "Too many requests. Please slow down."},
        )
    return await call_next(request)


app.include_router(feed.router, prefix="/api")
app.include_router(debug.router, prefix="/api")
app.include_router(search.router, prefix="/api")