"""Tests for BackgroundRefreshService scheduler lifecycle and error handling.

Verifies the cleanup job is properly registered, the scheduler starts/stops
correctly, and exceptions in cleanup do not terminate the scheduler.
"""

import time
from unittest.mock import MagicMock, patch

import pytest

from app.core.database import get_db
from app.services.background_service import BackgroundRefreshService


class TestSchedulerLifecycle:
    """Verify scheduler starts, stops, and registers jobs correctly."""

    @pytest.mark.asyncio
    async def test_start_registers_both_jobs(self, background_service):
        """start() should register refresh_job and cleanup_job."""
        assert not background_service._is_running
        await background_service.start()

        assert background_service._is_running
        refresh_job = background_service.scheduler.get_job("refresh_job")
        cleanup_job = background_service.scheduler.get_job("cleanup_job")
        assert refresh_job is not None, "refresh_job should be registered"
        assert cleanup_job is not None, "cleanup_job should be registered"

        await background_service.stop()

    @pytest.mark.asyncio
    async def test_stop_shuts_down_scheduler(self, background_service):
        """stop() should shut down the scheduler."""
        import asyncio
        await background_service.start()
        assert background_service.scheduler.running

        await background_service.stop()
        # Yield to let the event loop process the APScheduler shutdown callback
        await asyncio.sleep(0)

        assert not background_service._is_running
        assert not background_service.scheduler.running

    @pytest.mark.asyncio
    async def test_start_is_idempotent(self, background_service):
        """Calling start() twice should not register duplicate jobs."""
        await background_service.start()
        await background_service.start()  # second call should be no-op

        refresh_job = background_service.scheduler.get_job("refresh_job")
        cleanup_job = background_service.scheduler.get_job("cleanup_job")
        assert refresh_job is not None
        assert cleanup_job is not None
        # Scheduler should be running once
        assert background_service.scheduler.running

        await background_service.stop()

    @pytest.mark.asyncio
    async def test_stop_is_idempotent(self, background_service):
        """Calling stop() twice should not raise."""
        await background_service.start()
        await background_service.stop()
        await background_service.stop()  # second call should be no-op
        assert not background_service._is_running


class TestCleanupJobRegistration:
    """Verify the cleanup job has correct configuration."""

    @pytest.mark.asyncio
    async def test_cleanup_job_interval(self, background_service):
        """Cleanup job should have a 24-hour interval."""
        await background_service.start()
        job = background_service.scheduler.get_job("cleanup_job")
        assert job is not None
        # APScheduler stores the trigger with its interval
        trigger = job.trigger
        assert trigger.interval_length >= 82800  # ~23 hours (allowing minor delta)
        assert trigger.interval_length <= 90000  # ~25 hours
        await background_service.stop()

    @pytest.mark.asyncio
    async def test_cleanup_job_calls_cleanup_old_assets(self, background_service):
        """Cleanup job should invoke queue_manager.cleanup_old_assets(days=30)."""
        with patch.object(background_service.queue_manager, "cleanup_old_assets") as mock_cleanup:
            mock_cleanup.return_value = None
            await background_service._cleanup_job()
            mock_cleanup.assert_called_once_with(days=30)


class TestCleanupErrorHandling:
    """Verify cleanup failures don't crash the scheduler."""

    @pytest.mark.asyncio
    async def test_cleanup_exception_does_not_crash_scheduler(self, background_service):
        """If cleanup_old_assets raises, the scheduler should continue running."""
        await background_service.start()
        assert background_service.scheduler.running

        with patch.object(
            background_service.queue_manager, "cleanup_old_assets",
            side_effect=ValueError("Simulated cleanup failure")
        ):
            # This should not propagate — the job catches the exception
            await background_service._cleanup_job()

        # Scheduler should still be running after the failure
        assert background_service.scheduler.running

        await background_service.stop()

    @pytest.mark.asyncio
    async def test_cleanup_exception_logs_traceback(self, background_service, caplog):
        """Cleanup failure should log the exception traceback."""
        import logging
        caplog.set_level(logging.ERROR)

        with patch.object(
            background_service.queue_manager, "cleanup_old_assets",
            side_effect=ValueError("Simulated cleanup failure")
        ):
            await background_service._cleanup_job()

        assert len(caplog.records) >= 1
        assert any("Cleanup job failed" in rec.message for rec in caplog.records)
        assert any("Simulated cleanup failure" in rec.message for rec in caplog.records)

    @pytest.mark.asyncio
    async def test_future_cleanup_still_executes_after_failure(self, background_service):
        """After a failed cleanup, the next cleanup should still execute."""
        call_count = 0

        async def failing_then_succeeding(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                raise ValueError("First failure")
            # Second call succeeds

        with patch.object(
            background_service.queue_manager, "cleanup_old_assets",
            side_effect=failing_then_succeeding
        ):
            await background_service._cleanup_job()  # first call fails
            await background_service._cleanup_job()  # second call succeeds

        assert call_count == 2


class TestCleanupJobIntegration:
    """Verify the cleanup job works end-to-end with the real queue_manager."""

    @pytest.mark.asyncio
    async def test_cleanup_job_removes_old_assets(self, background_service):
        """Running _cleanup_job should remove old assets via queue_manager."""
        old_time = int(time.time()) - (31 * 24 * 60 * 60)
        async with get_db() as db:
            await db.execute(
                """INSERT INTO media_assets
                   (id, reddit_id, permalink, media_url, title, author, score,
                    subreddit, created_utc, is_video, is_gallery, nsfw,
                    quality_score, source_provider, created_at, last_seen)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                ("job_test_1", "job_reddit_old", "/r/test/comments/job_old/",
                 "https://i.redd.it/jobold.jpg", "Job Old", "author",
                 100, "testsub", old_time, 0, 0, 0, 50, "reddit_oauth",
                 old_time, old_time)
            )
            await db.commit()

        await background_service._cleanup_job()

        async with get_db() as db:
            cursor = await db.execute(
                "SELECT COUNT(*) as cnt FROM media_assets WHERE reddit_id = ?",
                ("job_reddit_old",)
            )
            row = await cursor.fetchone()
            assert row["cnt"] == 0
