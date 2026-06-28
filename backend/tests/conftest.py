"""Test fixtures for RedSlide backend tests."""

import asyncio
import os
import shutil
import tempfile
from unittest.mock import MagicMock

import pytest

from app.core.database import init_db
from app.services.queue_manager import QueueManager
from app.services.background_service import BackgroundRefreshService


@pytest.fixture(autouse=True)
def test_db(monkeypatch):
    """Create a temporary database for each test."""
    tmp_dir = tempfile.mkdtemp()
    db_path = os.path.join(tmp_dir, "redslide_test.db")
    monkeypatch.setattr("app.core.database.DATABASE_PATH", db_path)
    asyncio.run(init_db())
    yield
    shutil.rmtree(tmp_dir, ignore_errors=True)


@pytest.fixture
def queue_manager() -> QueueManager:
    """Return a QueueManager instance backed by the test database."""
    return QueueManager()


@pytest.fixture
def background_service(queue_manager) -> BackgroundRefreshService:
    """Return a BackgroundRefreshService with mocked Reddit dependencies.

    The real queue_manager is replaced with the test-backed instance so
    cleanup and queue operations use the test database.
    """
    mock_oauth = MagicMock()
    mock_oauth.initialize = MagicMock()
    mock_provider = MagicMock()
    service = BackgroundRefreshService(
        oauth_manager=mock_oauth,
        provider_manager=mock_provider,
    )
    service.queue_manager = queue_manager
    return service
