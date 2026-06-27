import time
from fastapi import APIRouter, Query
from typing import Optional
from ..models.schemas import FeedResponse, MediaAssetResponse
from ..services.reddit_client import RedditClient
from ..managers.oauth import OAuthManager
from ..managers.provider import ProviderManager
import os

router = APIRouter()


def _get_reddit_client() -> RedditClient:
    oauth = OAuthManager(
        client_id=os.getenv("REDDIT_CLIENT_ID", ""),
        client_secret=os.getenv("REDDIT_CLIENT_SECRET", ""),
        user_agent=os.getenv("REDDIT_USER_AGENT", "RedSlide/1.0"),
    )
    provider = ProviderManager()
    return RedditClient(oauth_manager=oauth, provider_manager=provider)


def _asset_to_response(asset) -> MediaAssetResponse:
    """Convert a MediaAsset to MediaAssetResponse with gallery URLs."""
    gallery_urls = None
    if hasattr(asset, "_gallery_items") and asset._gallery_items:
        gallery_urls = [item["url"] for item in asset._gallery_items]

    return MediaAssetResponse(
        id=asset.id,
        title=asset.title,
        author=asset.author,
        score=asset.score,
        subreddit=asset.subreddit,
        media_url=asset.media_url,
        video_url=asset.video_url,
        thumbnail_url=asset.thumbnail_url,
        is_video=asset.is_video,
        is_gallery=asset.is_gallery,
        nsfw=asset.nsfw,
        quality_score=getattr(asset, "quality_score", 50),
        width=asset.width,
        height=asset.height,
        duration=asset.duration,
        created_utc=asset.created_utc,
        gallery_urls=gallery_urls,
    )


@router.get("/search/reddit", response_model=FeedResponse)
async def search_reddit(
    q: str = Query(..., min_length=1),
    mode: str = Query(default="global"),
    limit: int = Query(default=25, ge=1, le=100),
    after: Optional[str] = Query(default=None),
    subreddits: Optional[str] = Query(default=None),
):
    """Search Reddit directly, not from SQLite cache.

    Accumulates results across multiple Reddit pages until enough
    media-only results are found, a page limit is hit, or a time budget
    is exhausted. Results are NOT stored in the search_results table.

    Parameters:
        q: Search query string
        mode: 'global' for entire Reddit, 'local' for specific subreddits
        limit: Results target per page (backend will accumulate limit*4)
        after: Reddit pagination cursor (t3_xxxxx)
        subreddits: Comma-separated subreddit names (required when mode=local)
    """
    subreddit_list = None
    if subreddits and mode == "local":
        subreddit_list = [s.strip().lower() for s in subreddits.split(",") if s.strip()]

    client = _get_reddit_client()
    await client.oauth.initialize()

    try:
        items, new_after = await client.search_reddit(
            query=q,
            limit=limit,
            after=after,
            subreddits=subreddit_list,
            mode=mode,
        )
    except Exception as e:
        print(f"[SEARCH_ERROR] query={q} error={e}")
        return FeedResponse(items=[], after=None, has_more=False)

    parsed = []
    rejected = 0
    for raw in items:
        asset = client._parse_post(raw)
        if asset and client.validate_media(asset) and client._validate_search_asset(asset):
            parsed.append(asset)
        else:
            rejected += 1

    print(f"[Search] parse: kept={len(parsed)} rejected={rejected}")

    enriched_items = []
    for asset in parsed:
        item = _asset_to_response(asset)
        enriched_items.append(item)

    has_more = new_after is not None
    print(f"[SEARCH_LOAD_MORE] fetched={len(enriched_items)} has_more={has_more} after={new_after}")

    return FeedResponse(
        items=enriched_items,
        after=new_after,
        has_more=has_more,
    )
