import asyncio
import time
import os
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.interval import IntervalTrigger
from ..core.database import get_db
from .queue_manager import QueueManager, QUEUE_REFILL
from .reddit_client import RedditClient
from ..managers.oauth import OAuthManager
from ..managers.provider import ProviderManager


class BackgroundRefreshService:
    """Background service for queue management.

    Operates solely from subreddit_configs table — no hardcoded subreddits.
    Waits for client sync before fetching any content.
    """

    REFRESH_INTERVAL = 60  # 1 minute
    FETCH_BATCH_SIZE = 50
    CLEANUP_INTERVAL = 86400  # 24 hours

    def __init__(self):
        self.scheduler = AsyncIOScheduler()
        self.queue_manager = QueueManager()
        self.oauth_manager = OAuthManager(
            client_id=os.getenv("REDDIT_CLIENT_ID", ""),
            client_secret=os.getenv("REDDIT_CLIENT_SECRET", ""),
            user_agent=os.getenv("REDDIT_USER_AGENT", "RedSlide/1.0")
        )
        self.provider_manager = ProviderManager()
        self.reddit_client = RedditClient(
            oauth_manager=self.oauth_manager,
            provider_manager=self.provider_manager
        )
        self._is_running = False

    async def start(self):
        """Start background service.

        Does NOT seed any default subreddits.
        Does NOT automatically fetch Reddit content.
        Waits for client to call /api/subreddits/sync.
        """
        if self._is_running:
            return

        self._is_running = True
        await self.queue_manager.initialize()
        await self.oauth_manager.initialize()

        self.scheduler.add_job(
            self._refresh_job,
            IntervalTrigger(seconds=self.REFRESH_INTERVAL),
            id="refresh_job",
            replace_existing=True
        )
        self.scheduler.add_job(
            self._cleanup_job,
            IntervalTrigger(seconds=self.CLEANUP_INTERVAL),
            id="cleanup_job",
            replace_existing=True
        )

        if not self.scheduler.running:
            self.scheduler.start()

    async def stop(self):
        """Stop background service."""
        if not self._is_running:
            return

        self._is_running = False
        if self.scheduler.running:
            self.scheduler.shutdown()

    async def _get_all_subreddits(self) -> list[str]:
        """Get all enabled subreddits from subreddit_configs only.

        Never falls back to hardcoded defaults. Returns [] if none configured.
        """
        async with get_db() as db:
            cursor = await db.execute(
                "SELECT subreddit FROM subreddit_configs WHERE enabled=1"
            )
            rows = await cursor.fetchall()
            return [row["subreddit"] for row in rows]

    async def _get_subreddits_needing_refill(self) -> list[tuple[str, int]]:
        """Return subreddits with asset count below QUEUE_REFILL, sorted by count ascending."""
        subreddits = await self._get_all_subreddits()
        needs_refill = []
        for subreddit in subreddits:
            count = await self.queue_manager.count_subreddit_items(subreddit)
            if count < QUEUE_REFILL:
                needs_refill.append((subreddit, count))
        needs_refill.sort(key=lambda x: x[1])
        return needs_refill

    async def _refresh_job(self):
        """Refresh queue with new media from subreddits.

        Only fetches for subreddits with asset count below QUEUE_REFILL threshold.
        Picks the subreddit with the lowest count.
        """
        try:
            await self.queue_manager.manage_queue()

            needs_refill = await self._get_subreddits_needing_refill()

            if not needs_refill:
                return

            subreddit, count = needs_refill[0]
            try:
                sort = "hot"
                stored_after = await self.queue_manager.get_stored_cursor(subreddit, sort)
                assets, new_cursor = await self.reddit_client.fetch_subreddit_media(
                    subreddit, limit=self.FETCH_BATCH_SIZE, after=stored_after, sort=sort
                )
                added = 0
                for asset in assets:
                    if await self.queue_manager.add_to_queue(asset):
                        added += 1
                if added == 0 and new_cursor is None:
                    await self.queue_manager.set_stored_cursor(subreddit, sort, None)
                else:
                    await self.queue_manager.set_stored_cursor(subreddit, sort, new_cursor)
                if added > 0:
                    print(f"Refill: {subreddit} ({count} before) — added {added} assets")
            except Exception as e:
                print(f"Error fetching from {subreddit}: {e}")
        except Exception as e:
            print(f"Refresh job error: {e}")

    async def _cleanup_job(self):
        """Clean up old assets."""
        try:
            thirty_days_ago = int(time.time()) - (30 * 24 * 3600)
            async with get_db() as db:
                await db.execute(
                    "DELETE FROM media_queue WHERE added_at < ?",
                    (thirty_days_ago,)
                )
                await db.commit()
        except Exception as e:
            print(f"Cleanup job error: {e}")
