from fastapi import APIRouter, Depends, Query
from typing import Optional
from ..models.schemas import FeedResponse
from ..services.reddit_client import RedditClient
from ..services.search_coordinator import SearchCoordinator
from ..managers.oauth import OAuthManager
from ..managers.provider import ProviderManager
from .dependencies import get_oauth_manager, get_provider_manager

router = APIRouter()


async def _get_reddit_client(
    oauth: OAuthManager = Depends(get_oauth_manager),
    provider: ProviderManager = Depends(get_provider_manager),
) -> RedditClient:
    return RedditClient(oauth_manager=oauth, provider_manager=provider)


@router.get("/search/reddit", response_model=FeedResponse)
async def search_reddit(
    q: str = Query(..., min_length=1),
    mode: str = Query(default="global"),
    limit: int = Query(default=25, ge=1, le=100),
    after: Optional[str] = Query(default=None),
    subreddits: Optional[str] = Query(default=None),
    reddit_client: RedditClient = Depends(_get_reddit_client),
):
    """Search Reddit directly, not from SQLite cache.

    Uses parallel workers (bounded concurrency) to search subreddits
    simultaneously, then aggregates, deduplicates, and returns results.
    Per-subreddit pagination cursors are encoded in the opaque `after`
    field.

    Parameters:
        q: Search query string
        mode: 'global' for entire Reddit, 'local' for specific subreddits
        limit: Results target per page (backend will accumulate limit*4)
        after: Opaque pagination cursor (JSON-encoded per-subreddit cursors)
        subreddits: Comma-separated subreddit names (required when mode=local)
    """
    subreddit_list = None
    if subreddits and mode == "local":
        subreddit_list = [s.strip().lower() for s in subreddits.split(",") if s.strip()]

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

    return FeedResponse(
        items=items,
        after=new_after,
        has_more=has_more,
    )
