import asyncio
import time

from fastapi import APIRouter, Depends, Query
from typing import Optional

from ..models.schemas import FeedResponse, ProgressiveSearchResponse
from ..services.reddit_client import RedditClient
from ..services.search_coordinator import SearchCoordinator
from ..services.search_session import (
    SearchSession,
    SearchSessionManager,
    session_manager,
    FIRST_BATCH_MIN_ITEMS,
)
from ..managers.oauth import OAuthManager
from ..managers.provider import ProviderManager
from .dependencies import get_oauth_manager, get_provider_manager

router = APIRouter()


async def _get_reddit_client(
    oauth: OAuthManager = Depends(get_oauth_manager),
    provider: ProviderManager = Depends(get_provider_manager),
) -> RedditClient:
    return RedditClient(oauth_manager=oauth, provider_manager=provider)


def _parse_subreddits(subreddits: Optional[str]) -> Optional[list[str]]:
    if not subreddits:
        return None
    return [s.strip().lower() for s in subreddits.split(",") if s.strip()]


@router.get("/search/reddit", response_model=FeedResponse)
async def search_reddit(
    q: str = Query(..., min_length=1),
    mode: str = Query(default="global"),
    limit: int = Query(default=25, ge=1, le=100),
    after: Optional[str] = Query(default=None),
    subreddits: Optional[str] = Query(default=None),
    reddit_client: RedditClient = Depends(_get_reddit_client),
):
    """Search Reddit directly (non-progressive / legacy endpoint).

    Waits for all workers to complete before returning.
    """
    subreddit_list = _parse_subreddits(subreddits) if mode == "local" else None

    coordinator = SearchCoordinator(
        reddit_client=reddit_client,
        concurrency=5,
    )

    try:
        items, new_after, has_more, metrics = await coordinator.execute(
            query=q,
            mode=mode,
            limit=limit,
            subreddits=subreddit_list,
            after=after,
        )
    except Exception as e:
        print(f"[SEARCH_ERROR] query={q} error={e}")
        return FeedResponse(items=[], after=None, has_more=False)

    print(f"[SEARCH_RESULT] query={q} items={len(items)} has_more={has_more} after={new_after}")
    return FeedResponse(items=items, after=new_after, has_more=has_more)


@router.get("/search/reddit/progressive", response_model=ProgressiveSearchResponse)
async def search_reddit_progressive(
    q: str = Query(..., min_length=1),
    mode: str = Query(default="global"),
    limit: int = Query(default=25, ge=1, le=100),
    after: Optional[str] = Query(default=None),
    subreddits: Optional[str] = Query(default=None),
    reddit_client: RedditClient = Depends(_get_reddit_client),
):
    """Search Reddit progressively.

    Returns the first batch of results as soon as enough items have
    accumulated (FIRST_BATCH_MIN_ITEMS). A session_id is returned when
    there are additional results still being fetched in the background.

    The frontend should poll /api/search/reddit/poll with the session_id
    to receive subsequent batches.
    """
    subreddit_list = _parse_subreddits(subreddits) if mode == "local" else None

    coordinator = SearchCoordinator(
        reddit_client=reddit_client,
        concurrency=5,
    )

    ctx = coordinator._build_context(q)

    if mode == "local" and subreddit_list:
        session = await session_manager.create_session(
            query=q,
            total_workers=len(subreddit_list),
            pending_subreddits=list(subreddit_list),
            cursors={},
        )
        asyncio.create_task(
            _run_progressive_local(
                coordinator=coordinator,
                session=session,
                query=q,
                subreddits=subreddit_list,
                target=max(limit * 4, 100),
            )
        )
    else:
        session = await session_manager.create_session(
            query=q,
            total_workers=1,
            pending_subreddits=["__global__"],
            cursors={},
        )
        asyncio.create_task(
            _run_progressive_global(
                coordinator=coordinator,
                session=session,
                query=q,
                target=max(limit * 4, 100),
            )
        )

    # Wait for first batch with a timeout
    try:
        await asyncio.wait_for(session.first_batch_event.wait(), timeout=60.0)
    except (asyncio.TimeoutError, asyncio.CancelledError):
        pass

    items = session.drain_new_items()
    print(f"[PROGRESSIVE] query={q} first_batch={len(items)} session={session.session_id}")

    return ProgressiveSearchResponse(
        items=items,
        has_more=not session.done,
        after=None,
        session_id=session.session_id if not session.done else None,
        done=session.done,
    )


async def _run_progressive_local(
    coordinator: SearchCoordinator,
    session: SearchSession,
    query: str,
    subreddits: list[str],
    target: int,
):
    """Run local-mode search progressively.

    As workers finish, results are accumulated into the session.
    The first_batch_event is signalled once enough items are ready.
    """
    from ..services.search_coordinator import EXHAUSTED_SENTINEL

    try:
        async def worker(subreddit: str):
            if session.cancelled:
                return
            try:
                items, after_cursor, audit = await coordinator._client._accumulate_search(
                    query=query,
                    subreddits=[subreddit],
                    mode="local",
                    target_results=target,
                    after=None,
                )
                async with session._lock:
                    for item in items:
                        pid = item.get("id")
                        if pid and pid not in session.seen_ids:
                            session.seen_ids.add(pid)
                            response = coordinator._raw_to_response(item)
                            if response is not None:
                                session.accumulated.append(response)
                    session.workers_completed += 1
                    session.cursors[subreddit] = after_cursor or EXHAUSTED_SENTINEL
                    if not session.first_batch_event.is_set() and len(session.accumulated) >= FIRST_BATCH_MIN_ITEMS:
                        session.first_batch_event.set()
            except Exception as e:
                print(f"[PROGRESSIVE_WORKER_FAIL] subreddit={subreddit} error={e}")
                async with session._lock:
                    session.workers_failed += 1
                    session.workers_completed += 1

        tasks = [worker(sr) for sr in subreddits]
        await asyncio.gather(*tasks)

        async with session._lock:
            session.done = True
            if not session.first_batch_event.is_set():
                session.first_batch_event.set()
            session.accumulated.sort(
                key=lambda x: x.created_utc or 0, reverse=True
            )
    except Exception as e:
        print(f"[PROGRESSIVE_ERROR] query={query} error={e}")
        async with session._lock:
            session.done = True
            session.error = str(e)
            if not session.first_batch_event.is_set():
                session.first_batch_event.set()


async def _run_progressive_global(
    coordinator: SearchCoordinator,
    session: SearchSession,
    query: str,
    target: int,
):
    """Run global-mode search progressively."""
    from ..services.search_coordinator import EXHAUSTED_SENTINEL

    try:
        items, after_cursor, audit = await coordinator._client._accumulate_search(
            query=query,
            subreddits=None,
            mode="global",
            target_results=target,
            after=None,
        )
        async with session._lock:
            session.workers_completed = 1
            for item in items:
                pid = item.get("id")
                if pid and pid not in session.seen_ids:
                    session.seen_ids.add(pid)
                    response = coordinator._raw_to_response(item)
                    if response is not None:
                        session.accumulated.append(response)
            session.cursors["__global__"] = after_cursor or EXHAUSTED_SENTINEL
            session.done = True
            if not session.first_batch_event.is_set():
                session.first_batch_event.set()
            session.accumulated.sort(
                key=lambda x: x.created_utc or 0, reverse=True
            )
    except Exception as e:
        print(f"[PROGRESSIVE_GLOBAL_ERROR] query={query} error={e}")
        async with session._lock:
            session.done = True
            if not session.first_batch_event.is_set():
                session.first_batch_event.set()


@router.get("/search/reddit/poll", response_model=ProgressiveSearchResponse)
async def search_poll(
    session: str = Query(..., min_length=1),
):
    """Poll a progressive search session for the next batch of results.

    Returns accumulated items since the last poll. When done=True,
    the session is complete and the frontend should stop polling.

    If the session is not found (expired or invalid), returns an
    empty response with done=True.
    """
    s = await session_manager.get_session(session)
    if not s:
        return ProgressiveSearchResponse(items=[], has_more=False, done=True)

    items = s.drain_new_items()
    done = s.done

    if done and not items:
        await session_manager.remove_session(session)
    elif done:
        # Return final batch, will remove on next poll
        pass

    print(f"[PROGRESSIVE_POLL] session={session} new_items={len(items)} done={done}")

    return ProgressiveSearchResponse(
        items=items,
        has_more=not done,
        after=None,
        session_id=session if not done else None,
        done=done,
    )
