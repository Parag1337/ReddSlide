"""Progressive search session management.

Enables Time To First Result (TTFR) reduction by returning the first
batch of results immediately while the search continues in the background.
"""

import asyncio
import time
import uuid
from dataclasses import dataclass, field
from typing import Optional

from ..models.schemas import MediaAssetResponse

SESSION_TIMEOUT = 300  # 5 minutes without polling → auto-expire
FIRST_BATCH_MIN_ITEMS = 25
POLL_BATCH_MIN_ITEMS = 15
CLEANUP_INTERVAL = 60  # check for expired sessions every 60s


@dataclass
class ProgressiveBatch:
    """A batch of search results delivered progressively."""
    items: list[MediaAssetResponse]
    has_more: bool
    done: bool
    after: Optional[str] = None


@dataclass
class SearchSession:
    """In-memory search session.

    Created when a progressive search starts. Holds accumulated results,
    deduplication set, and background task handle. The session is
    reference-counted (poll_count) so we can drain new items since the
    last poll without re-sending.
    """
    session_id: str
    query: str
    created_at: float
    last_poll_at: float = 0.0
    poll_count: int = 0

    seen_ids: set[str] = field(default_factory=set)
    accumulated: list[MediaAssetResponse] = field(default_factory=list)
    delivered_count: int = 0

    cursors: dict[str, Optional[str]] = field(default_factory=dict)
    pending_subreddits: list[str] = field(default_factory=list)
    workers_completed: int = 0
    workers_failed: int = 0
    total_workers: int = 0

    done: bool = False
    cancelled: bool = False
    error: str = ""

    # Signalled when the first batch is ready

    # Signalled when the first batch is ready
    first_batch_event: asyncio.Event = field(default_factory=asyncio.Event)
    _lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    def drain_new_items(self) -> list[MediaAssetResponse]:
        """Return items not yet delivered, updating delivered_count."""
        start = self.delivered_count
        self.delivered_count = len(self.accumulated)
        return self.accumulated[start:]

    @property
    def expired(self) -> bool:
        return (time.monotonic() - self.last_poll_at) > SESSION_TIMEOUT


class SearchSessionManager:
    """Manages all active search sessions.

    Thread-safe (asyncio.Lock). Auto-cleans expired sessions.
    """

    def __init__(self):
        self._sessions: dict[str, SearchSession] = {}
        self._lock = asyncio.Lock()

    async def create_session(
        self,
        query: str,
        total_workers: int,
        pending_subreddits: list[str],
        cursors: dict[str, Optional[str]],
    ) -> SearchSession:
        session_id = uuid.uuid4().hex[:12]
        session = SearchSession(
            session_id=session_id,
            query=query,
            created_at=time.monotonic(),
            last_poll_at=time.monotonic(),
            total_workers=total_workers,
            pending_subreddits=list(pending_subreddits),
            cursors=dict(cursors),
        )
        async with self._lock:
            self._sessions[session_id] = session
        return session

    async def get_session(self, session_id: str) -> Optional[SearchSession]:
        async with self._lock:
            session = self._sessions.get(session_id)
            if session and not session.done:
                session.last_poll_at = time.monotonic()
                session.poll_count += 1
            return session

    async def remove_session(self, session_id: str):
        async with self._lock:
            self._sessions.pop(session_id, None)

    async def cancel_session(self, session_id: str):
        async with self._lock:
            session = self._sessions.get(session_id)
            if session:
                session.cancelled = True
                session.done = True

    async def cleanup_expired(self):
        now = time.monotonic()
        async with self._lock:
            expired = [
                sid for sid, s in self._sessions.items()
                if s.done or (now - s.created_at) > SESSION_TIMEOUT + 60
            ]
            for sid in expired:
                del self._sessions[sid]

    async def all_sessions(self) -> list[SearchSession]:
        async with self._lock:
            return list(self._sessions.values())


# Singleton — created at module level, injected into endpoints
session_manager = SearchSessionManager()
