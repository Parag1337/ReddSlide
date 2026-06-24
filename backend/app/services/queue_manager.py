import os
import time
from typing import Optional
from dotenv import load_dotenv
from ..core.database import get_db, DATABASE_PATH
from ..models.schemas import MediaAsset

load_dotenv()

QUEUE_MAX = 1000
QUEUE_MIN = 500
QUEUE_REFILL = 300
QUEUE_EMERGENCY = 100


class QueueManager:
    """Persistent queue for slideshow playback."""
    
    def __init__(self):
        self._initialized = False
    
    async def initialize(self):
        """Load queue state on startup."""
        self._initialized = True
    
    async def count_queue_items(self) -> int:
        """Count items in queue."""
        async with get_db() as db:
            cursor = await db.execute("SELECT COUNT(*) as count FROM media_queue")
            row = await cursor.fetchone()
            return row["count"] if row else 0
    
    async def add_to_queue(self, asset: MediaAsset) -> bool:
        """Add media asset to queue."""
        asset.media_url = self._sanitize_url(asset.media_url)
        if asset.video_url:
            asset.video_url = self._sanitize_url(asset.video_url)
        if asset.thumbnail_url:
            asset.thumbnail_url = self._sanitize_url(asset.thumbnail_url)

        async with get_db() as db:
            cursor = await db.execute(
                "SELECT id FROM media_queue WHERE reddit_post_id = ?",
                (asset.reddit_id,)
            )
            if await cursor.fetchone():
                return False
            
            try:
                await db.execute(
                    """INSERT OR IGNORE INTO media_assets 
                       (id, reddit_id, permalink, media_url, title, author, score, subreddit,
                        video_url, thumbnail_url, created_utc, is_video, is_gallery, nsfw, quality_score,
                        source_provider, width, height, duration, created_at, last_seen)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        asset.id, asset.reddit_id, asset.permalink, asset.media_url,
                        asset.title, asset.author, asset.score, asset.subreddit,
                        asset.video_url, asset.thumbnail_url, asset.created_utc, asset.is_video,
                        asset.is_gallery, asset.nsfw, asset.quality_score,
                        asset.source_provider, asset.width, asset.height, asset.duration,
                        asset.created_at, asset.last_seen
                    )
                )
                
                # Store gallery items if this is a gallery
                if asset.is_gallery and hasattr(asset, '_gallery_items'):
                    gallery_items = getattr(asset, '_gallery_items', [])
                    for item in gallery_items:
                        item_url = item["url"]
                        await db.execute(
                            """INSERT OR IGNORE INTO gallery_items 
                               (reddit_id, item_url, item_order, width, height, created_at)
                               VALUES (?, ?, ?, ?, ?, ?)""",
                            (
                                asset.reddit_id, item_url, item["order"],
                                item.get("width"), item.get("height"), int(time.time())
                            )
                        )
                
                position = await self._get_next_position(db)
                await db.execute(
                    "INSERT INTO media_queue (reddit_post_id, position, added_at) VALUES (?, ?, ?)",
                    (asset.reddit_id, position, int(time.time()))
                )
                
                await db.commit()
                return True
            except Exception:
                return False
    
    @staticmethod
    def _sanitize_url(url: str) -> str:
        """Sanitize a media URL by replacing problematic Reddit CDN hostnames."""
        return (
            url.replace("external-preview.redd.it", "preview.redd.it")
            .replace("external-i.redd.it", "i.redd.it")
        )

    async def _get_next_position(self, db) -> int:
        """Get next position for queue item."""
        cursor = await db.execute("SELECT MAX(position) as max_pos FROM media_queue")
        row = await cursor.fetchone()
        return (row["max_pos"] or 0) + 1
    
    async def get_queue_items(self, limit: int = 20, offset: int = 0, subreddits: Optional[list[str]] = None) -> tuple[list[dict], bool]:
        """Get items from queue, optionally filtered by subreddits. Returns (items, has_more)."""
        async with get_db() as db:
            if subreddits:
                placeholders = ",".join("?" * len(subreddits))
                cursor = await db.execute(
                    f"""SELECT ma.* FROM media_assets ma
                       JOIN media_queue mq ON ma.reddit_id = mq.reddit_post_id
                       WHERE ma.subreddit IN ({placeholders})
                       ORDER BY mq.position ASC
                       LIMIT ? OFFSET ?""",
                    (*subreddits, limit, offset)
                )
                rows = await cursor.fetchall()
                total_cursor = await db.execute(
                    f"""SELECT COUNT(*) as cnt FROM media_assets ma
                       JOIN media_queue mq ON ma.reddit_id = mq.reddit_post_id
                       WHERE ma.subreddit IN ({placeholders})""",
                    (*subreddits,)
                )
            else:
                cursor = await db.execute(
                    """SELECT ma.* FROM media_assets ma
                       JOIN media_queue mq ON ma.reddit_id = mq.reddit_post_id
                       ORDER BY mq.position ASC
                       LIMIT ? OFFSET ?""",
                    (limit, offset)
                )
                rows = await cursor.fetchall()
                total_cursor = await db.execute(
                    "SELECT COUNT(*) as cnt FROM media_queue"
                )
            total_row = await total_cursor.fetchone()
            total = total_row["cnt"] if total_row else 0
            has_more = (len(rows) == limit) or (offset + len(rows) < total)
            print(
                f"[DATABASE] get_queue_items limit={limit} offset={offset} "
                f"returned={len(rows)} total={total} has_more={has_more} "
                f"subreddits={subreddits}"
            )
            return [dict(row) for row in rows], has_more
    
    async def remove_from_queue(self, reddit_post_id: str) -> bool:
        """Remove item from queue."""
        async with get_db() as db:
            await db.execute("DELETE FROM media_queue WHERE reddit_post_id = ?", (reddit_post_id,))
            await db.commit()
            return True
    
    async def clear_queue(self) -> None:
        """Clear all queue items."""
        async with get_db() as db:
            await db.execute("DELETE FROM media_queue")
            await db.commit()
    
    async def manage_queue(self) -> None:
        """Ensure queue stays in optimal range."""
        current = await self.count_queue_items()
        
        if current < QUEUE_EMERGENCY:
            await self._refill_queue(200)
        elif current < QUEUE_REFILL:
            await self._refill_queue(100)
        elif current > QUEUE_MAX:
            await self._trim_queue(QUEUE_MAX)
    
    async def _refill_queue(self, count: int) -> None:
        """Refill queue with media."""
        # This would be called by background service with RedditClient
        pass
    
    async def _trim_queue(self, max_size: int) -> None:
        """Trim queue to max size."""
        async with get_db() as db:
            await db.execute(
                """DELETE FROM media_queue WHERE id IN (
                    SELECT id FROM media_queue 
                    ORDER BY position DESC 
                    LIMIT (SELECT COUNT(*) - ? FROM media_queue)
                )""",
                (max_size,)
            )
            await db.commit()
    
    async def search(
        self,
        query: str,
        limit: int = 20,
        offset: int = 0,
        subreddits: Optional[list[str]] = None,
        media_type: Optional[str] = None,
        sort: str = "relevance",
    ) -> tuple[list[dict], int]:
        """Search media using FTS5 with optional filters."""
        async with get_db() as db:
            base_where = "ma.reddit_id IN (SELECT reddit_post_id FROM media_search WHERE media_search MATCH ?)"
            params: list = [query]

            if subreddits:
                placeholders = ",".join("?" * len(subreddits))
                base_where += f" AND ma.subreddit IN ({placeholders})"
                params.extend(subreddits)

            if media_type == "images":
                base_where += " AND ma.is_video = 0 AND ma.is_gallery = 0"
            elif media_type == "galleries":
                base_where += " AND ma.is_gallery = 1"
            elif media_type == "videos":
                base_where += " AND ma.is_video = 1"

            order_clause = "ORDER BY ma.score DESC"
            if sort == "newest":
                order_clause = "ORDER BY ma.created_utc DESC"
            elif sort == "relevance":
                order_clause = "ORDER BY ma.quality_score DESC, ma.score DESC"

            cursor = await db.execute(
                f"""SELECT ma.* FROM media_assets ma
                   WHERE {base_where}
                   {order_clause}
                   LIMIT ? OFFSET ?""",
                [*params, limit, offset]
            )
            rows = await cursor.fetchall()

            count_cursor = await db.execute(
                f"""SELECT COUNT(*) as count FROM media_assets ma
                   WHERE {base_where}""",
                params
            )
            count_row = await count_cursor.fetchone()
            total = count_row["count"] if count_row else 0

            return [dict(row) for row in rows], total
    
    async def get_gallery_urls(self, reddit_ids: list[str]) -> dict[str, list[str]]:
        """Get gallery URLs for a list of reddit IDs. Returns dict mapping reddit_id -> list of URLs."""
        if not reddit_ids:
            return {}
        async with get_db() as db:
            placeholders = ",".join("?" * len(reddit_ids))
            cursor = await db.execute(
                f"""SELECT reddit_id, item_url FROM gallery_items
                   WHERE reddit_id IN ({placeholders})
                   ORDER BY reddit_id, item_order ASC""",
                reddit_ids
            )
            rows = await cursor.fetchall()
            result: dict[str, list[str]] = {}
            for row in rows:
                rid = row["reddit_id"]
                if rid not in result:
                    result[rid] = []
                result[rid].append(row["item_url"])
            return result

    async def count_subreddit_items(self, subreddit: str) -> int:
        """Count media assets for a given subreddit."""
        async with get_db() as db:
            cursor = await db.execute(
                "SELECT COUNT(*) as cnt FROM media_assets WHERE subreddit = ?",
                (subreddit,)
            )
            row = await cursor.fetchone()
            return row["cnt"] if row else 0

    async def add_or_update_subreddit_config(self, subreddit: str) -> None:
        """Add or update subreddit configuration so background service picks it up."""
        async with get_db() as db:
            await db.execute(
                """INSERT INTO subreddit_configs 
                   (subreddit, enabled, provider, sort_mode, refresh_interval)
                   VALUES (?, 1, 'reddit_oauth', 'hot', 300)
                   ON CONFLICT(subreddit) DO UPDATE SET enabled=1""",
                (subreddit,)
            )
            await db.commit()

    async def get_enabled_subreddits(self) -> list[str]:
        """Get list of enabled subreddits from config."""
        async with get_db() as db:
            cursor = await db.execute(
                "SELECT subreddit FROM subreddit_configs WHERE enabled=1"
            )
            rows = await cursor.fetchall()
            return [row["subreddit"] for row in rows]

    async def disable_subreddit(self, subreddit: str) -> None:
        """Disable a subreddit so background service stops fetching it."""
        async with get_db() as db:
            await db.execute(
                "UPDATE subreddit_configs SET enabled=0 WHERE subreddit=?",
                (subreddit,)
            )
            await db.commit()

    @staticmethod
    def _cursor_column_for_sort(sort: str) -> str:
        """Map sort mode to the cursor column name in subreddit_configs."""
        mapping = {
            "hot": "last_hot_after",
            "new": "last_new_after",
            "top": "last_top_after",
        }
        return mapping.get(sort, "last_hot_after")

    async def get_stored_cursor(self, subreddit: str, sort: str = "hot") -> Optional[str]:
        """Get stored Reddit pagination cursor for a subreddit+sort combination."""
        column = self._cursor_column_for_sort(sort)
        async with get_db() as db:
            cursor = await db.execute(
                f"SELECT {column} FROM subreddit_configs WHERE subreddit = ?",
                (subreddit,)
            )
            row = await cursor.fetchone()
            return row[column] if row else None

    async def set_stored_cursor(self, subreddit: str, sort: str, after: Optional[str]) -> None:
        """Store Reddit pagination cursor for a subreddit+sort combination."""
        column = self._cursor_column_for_sort(sort)
        async with get_db() as db:
            await db.execute(
                f"UPDATE subreddit_configs SET {column} = ? WHERE subreddit = ?",
                (after, subreddit)
            )
            await db.commit()

    async def fetch_and_store(self, subreddit: str, limit: int = 25, sort: str = "hot", after: Optional[str] = None) -> tuple[int, Optional[str]]:
        """Fetch content from a subreddit on-demand and store in queue.
        Returns (added_count, new_cursor_from_reddit)."""
        before_count = await self.count_subreddit_items(subreddit)
        print(f"[QUEUE] fetch_and_store start subreddit={subreddit} limit={limit} sort={sort} after={after}")
        from .reddit_client import RedditClient
        from ..managers.oauth import OAuthManager
        from ..managers.provider import ProviderManager

        oauth = OAuthManager(
            client_id=os.getenv("REDDIT_CLIENT_ID", ""),
            client_secret=os.getenv("REDDIT_CLIENT_SECRET", ""),
            user_agent=os.getenv("REDDIT_USER_AGENT", "RedSlide/1.0")
        )
        await oauth.initialize()

        provider = ProviderManager()
        client = RedditClient(oauth_manager=oauth, provider_manager=provider)

        assets, new_cursor = await client.fetch_subreddit_media(subreddit, limit=limit, after=after, sort=sort)
        added = 0
        for asset in assets:
            if await self.add_to_queue(asset):
                added += 1

        # Ensure subreddit is registered so background service picks it up
        await self.add_or_update_subreddit_config(subreddit)

        after_count = await self.count_subreddit_items(subreddit)
        print(
            f"[QUEUE_GROWTH] subreddit={subreddit} sort={sort} "
            f"beforeCount={before_count} added={added} afterCount={after_count}"
        )

        return added, new_cursor

    async def ensure_subreddit_has_content(self, subreddit: str, sort: str = "hot") -> bool:
        """Refill subreddit queue with cursor-based pagination.
        Reads stored cursor, fetches next page from Reddit, stores new cursor.
        If Reddit returns no items (end of pagination), resets cursor so next
        fetch starts fresh from the top of the listing."""
        stored_after = await self.get_stored_cursor(subreddit, sort)
        print(
            f"[REDDIT_CURSOR] subreddit={subreddit} sort={sort} "
            f"before={stored_after}"
        )
        try:
            added, new_cursor = await self.fetch_and_store(subreddit, limit=50, sort=sort, after=stored_after)

            # Cursor recovery: if Reddit returned no items, cursor is stale or
            # we reached end of pagination.  Reset to None so the next fetch
            # starts from the top of the listing.
            if added == 0 and new_cursor is None:
                print(f"[REDDIT_CURSOR] reset subreddit={subreddit} sort={sort} reason=end_of_pagination")
                await self.set_stored_cursor(subreddit, sort, None)
            else:
                await self.set_stored_cursor(subreddit, sort, new_cursor)

            print(
                f"[REDDIT_CURSOR] subreddit={subreddit} sort={sort} "
                f"before={stored_after} after={new_cursor}"
            )
            return added > 0 or await self.count_subreddit_items(subreddit) > 0
        except Exception as e:
            print(f"On-demand fetch failed for {subreddit}: {e}")
            return await self.count_subreddit_items(subreddit) > 0

    async def cleanup_old_assets(self, days: int = 30) -> None:
        """Clean up assets older than specified days."""
        cutoff = int(time.time()) - (days * 24 * 60 * 60)
        async with get_db() as db:
            await db.execute("DELETE FROM media_assets WHERE created_at < ?", (cutoff,))
            await db.commit()