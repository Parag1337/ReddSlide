import os
from fastapi import FastAPI
from contextlib import asynccontextmanager
from dotenv import load_dotenv

load_dotenv()

from .core.database import init_db, DATABASE_PATH
from .api import feed, debug, search
from .managers.oauth import OAuthManager
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

app.include_router(feed.router, prefix="/api")
app.include_router(debug.router, prefix="/api")
app.include_router(search.router, prefix="/api")