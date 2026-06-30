"""Tests for QueueManager.cleanup_old_assets.

Verifies the cleanup job correctly removes expired assets while
preserving recent ones and maintaining referential integrity.
"""

import time

import pytest

from app.core.database import get_db
from app.services.queue_manager import QueueManager


def _insert_test_asset(
    reddit_id: str,
    subreddit: str = "testsub",
    created_at: int = None,
    is_video: bool = False,
    is_gallery: bool = False,
):
    """Insert a minimal media_asset row and corresponding media_queue entry.

    Returns the generated UUID-style id.
    """
    if created_at is None:
        created_at = int(time.time())

    asset_id = f"test_{reddit_id}_{int(time.time() * 1000000)}"
    permalink = f"/r/{subreddit}/comments/{reddit_id}/"

    return asset_id, reddit_id, created_at, permalink


class TestCleanupBasic:
    """Verify basic cleanup behaviour: old removed, new kept."""

    @pytest.mark.asyncio
    async def test_cleanup_removes_old_assets(self, queue_manager: QueueManager):
        """Assets older than 30 days should be deleted."""
        old_time = int(time.time()) - (31 * 24 * 60 * 60)
        async with get_db() as db:
            await db.execute(
                """INSERT INTO media_assets
                   (id, reddit_id, permalink, media_url, title, author, score,
                    subreddit, created_utc, is_video, is_gallery, nsfw,
                    quality_score, source_provider, created_at, last_seen)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                ("old_1", "old_reddit_1", "/r/test/comments/old_1/",
                 "https://i.redd.it/old1.jpg", "Old Post", "author1",
                 100, "testsub", old_time, 0, 0, 0, 50, "reddit_oauth",
                 old_time, old_time)
            )
            await db.commit()

        await queue_manager.cleanup_old_assets(days=30)

        async with get_db() as db:
            cursor = await db.execute(
                "SELECT COUNT(*) as cnt FROM media_assets WHERE reddit_id = ?",
                ("old_reddit_1",)
            )
            row = await cursor.fetchone()
            assert row["cnt"] == 0, "Old asset should be removed"

    @pytest.mark.asyncio
    async def test_cleanup_preserves_recent_assets(self, queue_manager: QueueManager):
        """Assets newer than 30 days should be kept."""
        recent_time = int(time.time()) - (1 * 24 * 60 * 60)
        async with get_db() as db:
            await db.execute(
                """INSERT INTO media_assets
                   (id, reddit_id, permalink, media_url, title, author, score,
                    subreddit, created_utc, is_video, is_gallery, nsfw,
                    quality_score, source_provider, created_at, last_seen)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                ("recent_1", "recent_reddit_1", "/r/test/comments/recent_1/",
                 "https://i.redd.it/recent1.jpg", "Recent Post", "author2",
                 200, "testsub", recent_time, 0, 0, 0, 60, "reddit_oauth",
                 recent_time, recent_time)
            )
            await db.commit()

        await queue_manager.cleanup_old_assets(days=30)

        async with get_db() as db:
            cursor = await db.execute(
                "SELECT COUNT(*) as cnt FROM media_assets WHERE reddit_id = ?",
                ("recent_reddit_1",)
            )
            row = await cursor.fetchone()
            assert row["cnt"] == 1, "Recent asset should be preserved"

    @pytest.mark.asyncio
    async def test_cleanup_mixed_old_and_new(self, queue_manager: QueueManager):
        """Old assets removed, new assets kept in same run."""
        now = int(time.time())
        old_time = now - (31 * 24 * 60 * 60)
        recent_time = now - (1 * 24 * 60 * 60)

        async with get_db() as db:
            for asset_id, rid, ctime in [
                ("old_2", "old_reddit_2", old_time),
                ("recent_2", "recent_reddit_2", recent_time),
                ("old_3", "old_reddit_3", old_time),
            ]:
                await db.execute(
                    """INSERT INTO media_assets
                       (id, reddit_id, permalink, media_url, title, author, score,
                        subreddit, created_utc, is_video, is_gallery, nsfw,
                        quality_score, source_provider, created_at, last_seen)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (asset_id, rid, f"/r/test/comments/{rid}/",
                     f"https://i.redd.it/{rid}.jpg", f"Post {rid}", "author",
                     100, "testsub", ctime, 0, 0, 0, 50, "reddit_oauth",
                     ctime, ctime)
                )
            await db.commit()

        await queue_manager.cleanup_old_assets(days=30)

        async with get_db() as db:
            cursor = await db.execute(
                "SELECT reddit_id FROM media_assets ORDER BY reddit_id"
            )
            rows = await cursor.fetchall()
            remaining = [r["reddit_id"] for r in rows]
            assert "old_reddit_2" not in remaining
            assert "old_reddit_3" not in remaining
            assert "recent_reddit_2" in remaining


class TestCleanupRelatedTables:
    """Verify gallery_items and media_queue are cleaned up correctly."""

    @pytest.mark.asyncio
    async def test_cleanup_removes_gallery_items(self, queue_manager: QueueManager):
        """gallery_items referencing old assets should be removed."""
        old_time = int(time.time()) - (31 * 24 * 60 * 60)
        async with get_db() as db:
            await db.execute(
                """INSERT INTO media_assets
                   (id, reddit_id, permalink, media_url, title, author, score,
                    subreddit, created_utc, is_video, is_gallery, nsfw,
                    quality_score, source_provider, created_at, last_seen)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                ("gallery_old_1", "gallery_reddit_old", "/r/test/comments/g_old/",
                 "https://i.redd.it/gold.jpg", "Old Gallery", "author3",
                 150, "testsub", old_time, 0, 1, 0, 60, "reddit_oauth",
                 old_time, old_time)
            )
            await db.execute(
                """INSERT INTO gallery_items (reddit_id, item_url, item_order, created_at)
                   VALUES (?, ?, ?, ?)""",
                ("gallery_reddit_old", "https://i.redd.it/gold_item1.jpg", 0, old_time)
            )
            await db.commit()

        await queue_manager.cleanup_old_assets(days=30)

        async with get_db() as db:
            cursor = await db.execute(
                "SELECT COUNT(*) as cnt FROM gallery_items WHERE reddit_id = ?",
                ("gallery_reddit_old",)
            )
            row = await cursor.fetchone()
            assert row["cnt"] == 0, "Gallery items for old asset should be removed"

    @pytest.mark.asyncio
    async def test_cleanup_removes_media_queue(self, queue_manager: QueueManager):
        """media_queue entries referencing old assets should be removed."""
        old_time = int(time.time()) - (31 * 24 * 60 * 60)
        async with get_db() as db:
            await db.execute(
                """INSERT INTO media_assets
                   (id, reddit_id, permalink, media_url, title, author, score,
                    subreddit, created_utc, is_video, is_gallery, nsfw,
                    quality_score, source_provider, created_at, last_seen)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                ("queue_old_1", "queue_reddit_old", "/r/test/comments/q_old/",
                 "https://i.redd.it/qold.jpg", "Old Queue", "author4",
                 120, "testsub", old_time, 0, 0, 0, 55, "reddit_oauth",
                 old_time, old_time)
            )
            await db.execute(
                """INSERT INTO media_queue (reddit_post_id, position, added_at)
                   VALUES (?, ?, ?)""",
                ("queue_reddit_old", 1, old_time)
            )
            await db.commit()

        await queue_manager.cleanup_old_assets(days=30)

        async with get_db() as db:
            cursor = await db.execute(
                "SELECT COUNT(*) as cnt FROM media_queue WHERE reddit_post_id = ?",
                ("queue_reddit_old",)
            )
            row = await cursor.fetchone()
            assert row["cnt"] == 0, "Media queue entry for old asset should be removed"

    @pytest.mark.asyncio
    async def test_no_orphaned_rows_after_cleanup(self, queue_manager: QueueManager):
        """No gallery_items or media_queue rows referencing deleted assets."""
        old_time = int(time.time()) - (31 * 24 * 60 * 60)
        async with get_db() as db:
            await db.execute(
                """INSERT INTO media_assets
                   (id, reddit_id, permalink, media_url, title, author, score,
                    subreddit, created_utc, is_video, is_gallery, nsfw,
                    quality_score, source_provider, created_at, last_seen)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                ("orphan_test_1", "orphan_reddit", "/r/test/comments/orphan/",
                 "https://i.redd.it/orphan.jpg", "Orphan Test", "author5",
                 80, "testsub", old_time, 0, 1, 0, 50, "reddit_oauth",
                 old_time, old_time)
            )
            await db.execute(
                "INSERT INTO gallery_items (reddit_id, item_url, item_order, created_at) VALUES (?, ?, ?, ?)",
                ("orphan_reddit", "https://i.redd.it/orphan_item1.jpg", 0, old_time)
            )
            await db.execute(
                "INSERT INTO media_queue (reddit_post_id, position, added_at) VALUES (?, ?, ?)",
                ("orphan_reddit", 5, old_time)
            )
            await db.commit()

        await queue_manager.cleanup_old_assets(days=30)

        async with get_db() as db:
            # Check no gallery_items reference deleted assets
            cursor = await db.execute(
                """SELECT COUNT(*) as cnt FROM gallery_items gi
                   WHERE gi.reddit_id NOT IN (SELECT reddit_id FROM media_assets)"""
            )
            row = await cursor.fetchone()
            assert row["cnt"] == 0, "No orphaned gallery_items after cleanup"

            cursor = await db.execute(
                """SELECT COUNT(*) as cnt FROM media_queue mq
                   WHERE mq.reddit_post_id NOT IN (SELECT reddit_id FROM media_assets)"""
            )
            row = await cursor.fetchone()
            assert row["cnt"] == 0, "No orphaned media_queue after cleanup"


class TestCleanupEdgeCases:
    """Verify cleanup handles edge cases correctly."""

    @pytest.mark.asyncio
    async def test_cleanup_empty_database(self, queue_manager: QueueManager):
        """Cleanup on an empty database should not raise."""
        await queue_manager.cleanup_old_assets(days=30)
        # No exception = success

    @pytest.mark.asyncio
    async def test_cleanup_all_recent(self, queue_manager: QueueManager):
        """Cleanup with only recent assets should not delete anything."""
        now = int(time.time())
        async with get_db() as db:
            for i in range(3):
                rid = f"recent_only_{i}"
                await db.execute(
                    """INSERT INTO media_assets
                       (id, reddit_id, permalink, media_url, title, author, score,
                        subreddit, created_utc, is_video, is_gallery, nsfw,
                        quality_score, source_provider, created_at, last_seen)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (f"recent_only_id_{i}", rid, f"/r/test/comments/{rid}/",
                     f"https://i.redd.it/{rid}.jpg", f"Post {rid}", "author",
                     100, "testsub", now, 0, 0, 0, 50, "reddit_oauth",
                     now, now)
                )
            await db.commit()

        await queue_manager.cleanup_old_assets(days=30)

        async with get_db() as db:
            cursor = await db.execute("SELECT COUNT(*) as cnt FROM media_assets")
            row = await cursor.fetchone()
            assert row["cnt"] == 3, "All recent assets should remain"

    @pytest.mark.asyncio
    async def test_cleanup_at_boundary(self, queue_manager: QueueManager):
        """Asset exactly 30 days old should be preserved (exclusive cutoff)."""
        boundary_time = int(time.time()) - (30 * 24 * 60 * 60)
        async with get_db() as db:
            await db.execute(
                """INSERT INTO media_assets
                   (id, reddit_id, permalink, media_url, title, author, score,
                    subreddit, created_utc, is_video, is_gallery, nsfw,
                    quality_score, source_provider, created_at, last_seen)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                ("boundary_1", "boundary_reddit", "/r/test/comments/boundary/",
                 "https://i.redd.it/boundary.jpg", "Boundary Post", "author",
                 90, "testsub", boundary_time, 0, 0, 0, 55, "reddit_oauth",
                 boundary_time, boundary_time)
            )
            await db.commit()

        await queue_manager.cleanup_old_assets(days=30)

        async with get_db() as db:
            cursor = await db.execute(
                "SELECT COUNT(*) as cnt FROM media_assets WHERE reddit_id = ?",
                ("boundary_reddit",)
            )
            row = await cursor.fetchone()
            # cutoff = now - 30 days; created_at < cutoff means strictly older
            # boundary_time = now - 30 days exactly → not strictly older → preserved
            assert row["cnt"] == 1, "Asset exactly at boundary should be preserved"
