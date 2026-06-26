import asyncio
import os
from fastapi import APIRouter, Depends, HTTPException, Query
from typing import Optional
from ..models.schemas import FeedResponse, QueueResponse, SearchResponse, MediaAssetResponse
from ..services.queue_manager import QueueManager
from ..core.database import get_db

# Rollback gate: set SLIDESHOW_SOURCE=queue to revert to queue-based slideshow.
# When "assets" (default), single-subreddit requests query media_assets directly.
SLIDESHOW_SOURCE = os.getenv("SLIDESHOW_SOURCE", "assets")

router = APIRouter()


async def get_queue_manager() -> QueueManager:
    """Get queue manager instance."""
    return QueueManager()


async def _enrich_with_gallery_urls(
    items: list[dict],
    queue_manager: QueueManager,
) -> list[MediaAssetResponse]:
    """Convert database items to response format with gallery URLs."""
    reddit_ids = [item.get("reddit_id", "") for item in items]
    gallery_map = await queue_manager.get_gallery_urls(reddit_ids)

    result = []
    for item in items:
        rid = item.get("reddit_id", "")
        gallery_urls = gallery_map.get(rid)
        result.append(MediaAssetResponse(
            id=item.get("id"),
            title=item.get("title"),
            author=item.get("author"),
            score=item.get("score"),
            subreddit=item.get("subreddit"),
            media_url=item.get("media_url"),
            video_url=item.get("video_url"),
            thumbnail_url=item.get("thumbnail_url"),
            is_video=item.get("is_video"),
            is_gallery=item.get("is_gallery"),
            nsfw=item.get("nsfw"),
            quality_score=item.get("quality_score"),
            width=item.get("width"),
            height=item.get("height"),
            duration=item.get("duration"),
            gallery_urls=gallery_urls,
        ))
    return result


def _parse_subreddits(subreddits: Optional[str]) -> Optional[list[str]]:
    """Parse comma-separated subreddit list, normalizing case."""
    if not subreddits:
        return None
    return [s.strip().lower() for s in subreddits.split(",") if s.strip()]


async def _ensure_subreddits_have_content(
    subreddit_list: Optional[list[str]],
    queue_manager: QueueManager,
    sort: str = "hot",
) -> None:
    """Trigger on-demand fetch for any subreddit that has no content yet."""
    if not subreddit_list:
        return
    for subreddit in subreddit_list:
        if await queue_manager.count_subreddit_items(subreddit) == 0:
            asyncio.create_task(queue_manager.ensure_subreddit_has_content(subreddit, sort=sort))


@router.get("/feed", response_model=FeedResponse)
async def get_feed(
    limit: int = Query(default=50, le=100),
    after: Optional[str] = Query(default=None),
    subreddits: Optional[str] = Query(default=None),
    sort: str = Query(default="hot"),
    queue_manager: QueueManager = Depends(get_queue_manager)
):
    """Get media feed.

    - Single subreddit (SLIDESHOW_SOURCE=assets, default):
      Cursor-based pagination on media_assets directly.
    - Multiple subreddits or SLIDESHOW_SOURCE=queue:
      Offset-based pagination on media_queue (original behavior).
    - No subreddits (global home feed):
      Offset-based pagination on media_queue.
    """
    subreddit_list = _parse_subreddits(subreddits)

    # Direct media_assets path: single subreddit, rollback flag not set
    if subreddit_list and len(subreddit_list) == 1 and SLIDESHOW_SOURCE != "queue":
        sub = subreddit_list[0]
        items, next_cursor, has_more = await queue_manager.get_subreddit_assets(
            subreddit=sub,
            limit=limit,
            after_cursor=after if after and "," in after else None,
        )
        enriched_items = await _enrich_with_gallery_urls(items, queue_manager)
        print(
            f"[API] direct_assets subreddit={sub} limit={limit} "
            f"returned={len(items)} hasMore={has_more} after={next_cursor} cursor={after}"
        )
        return FeedResponse(
            items=enriched_items,
            after=next_cursor,
            has_more=has_more,
        )

    # Queue-based path: global feed or multi-subreddit feed or rollback
    offset = int(after) if after and after.isdigit() else 0

    items, has_more = await queue_manager.get_queue_items(
        limit=limit, offset=offset, subreddits=subreddit_list
    )

    # If no items exist for requested subreddits on first page, fetch on-demand synchronously
    if not items and subreddit_list and offset == 0:
        print(f"[API] sync_fetch_trigger subreddits={subreddit_list}")
        for subreddit in subreddit_list:
            await queue_manager.ensure_subreddit_has_content(subreddit, sort=sort)
        # Re-query after fetch
        items, has_more = await queue_manager.get_queue_items(
            limit=limit, offset=offset, subreddits=subreddit_list
        )

    # For subreddit-scoped feeds, trigger async refill when queue runs low
    if subreddit_list:
        if not items or len(items) < limit:
            print(f"[API] async_bg_refill_trigger subreddit={subreddit_list[0]} "
                  f"items={len(items)} limit={limit}")
            asyncio.create_task(
                queue_manager.ensure_subreddit_has_content(subreddit_list[0], sort=sort)
            )
        if not items:
            has_more = False

    next_after = str(offset + len(items)) if has_more else None
    enriched_items = await _enrich_with_gallery_urls(items, queue_manager)
    print(
        f"[API] offset={offset} limit={limit} "
        f"returned={len(items)} hasMore={has_more} "
        f"subreddits={subreddits} after={next_after} "
        f"cursor={after}"
    )
    return FeedResponse(
        items=enriched_items,
        after=next_after,
        has_more=has_more
    )


@router.get("/feed/queue", response_model=QueueResponse)
async def get_queue(
    limit: int = Query(default=20, le=100),
    queue_manager: QueueManager = Depends(get_queue_manager)
):
    """Get queue items."""
    items, _ = await queue_manager.get_queue_items(limit=limit)
    total = await queue_manager.count_queue_items()
    enriched_items = await _enrich_with_gallery_urls(items, queue_manager)
    return QueueResponse(
        items=enriched_items,
        total=total,
        pending=0
    )


@router.get("/search", response_model=SearchResponse)
async def search(
    q: str = Query(..., min_length=1),
    limit: int = Query(default=20, le=100),
    page: int = Query(default=1, ge=1),
    subreddits: Optional[str] = Query(default=None),
    media_type: Optional[str] = Query(default=None),
    sort: str = Query(default="relevance"),
    queue_manager: QueueManager = Depends(get_queue_manager)
):
    """Search media assets with optional filters.

    Parameters:
        q: Search query string
        limit: Number of results per page
        page: Page number (1-indexed)
        subreddits: Optional comma-separated list of subreddits to filter by
        media_type: Optional filter - "images", "galleries", "videos"
        sort: Sort order - "relevance", "newest", "most_upvoted"
    """
    subreddit_list = _parse_subreddits(subreddits)
    offset = (page - 1) * limit
    items, total = await queue_manager.search(
        q, limit, offset,
        subreddits=subreddit_list,
        media_type=media_type,
        sort=sort,
    )
    enriched_items = await _enrich_with_gallery_urls(items, queue_manager)
    has_more = (offset + len(items)) < total
    next_after = str(offset + len(items)) if has_more else None
    return SearchResponse(
        items=enriched_items,
        page=page,
        limit=limit,
        total_results=total,
        has_more=has_more,
        after=next_after,
    )


@router.get("/search/debug")
async def search_debug(q: str = Query(..., min_length=1)):
    """Debug search without FTS5."""
    async with get_db() as db:
        cursor = await db.execute(
            "SELECT * FROM media_assets WHERE title LIKE ? OR subreddit LIKE ? LIMIT ?",
            (f"%{q}%", f"%{q}%", 20)
        )
        rows = await cursor.fetchall()
        items = [dict(r) for r in rows]
        return {"query": q, "items": items}


@router.get("/media/{id}")
async def get_media(id: str):
    """Get media asset by ID."""
    async with get_db() as db:
        cursor = await db.execute("SELECT * FROM media_assets WHERE id = ?", (id,))
        row = await cursor.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Media not found")
        return dict(row)


@router.post("/media/start/{id}")
async def start_slideshow(id: str):
    """Start slideshow from specific media item."""
    return {"status": "started", "from_id": id}


@router.post("/subreddits/sync")
async def sync_subreddits(
    body: dict,
    queue_manager: QueueManager = Depends(get_queue_manager)
):
    """Sync user's subreddit list to backend config.

    Replaces the current subreddit configuration with the provided list.
    - Adds newly configured subreddits
    - Disables removed subreddits (no more fetches)
    - Triggers immediate fetch for newly added subreddits
    """
    sub_list: list[str] = body.get("subreddits", [])

    incoming = {name.strip().lower() for name in sub_list if name.strip()}
    current_set = set(await queue_manager.get_enabled_subreddits())

    added: list[str] = []
    removed: list[str] = []

    for name in incoming:
        if name not in current_set:
            await queue_manager.add_or_update_subreddit_config(name)
            added.append(name)

    for name in current_set:
        if name not in incoming:
            await queue_manager.disable_subreddit(name)
            removed.append(name)

    # Trigger on-demand fetch for newly added subreddits
    for name in added:
        asyncio.create_task(queue_manager.ensure_subreddit_has_content(name))

    return {
        "synced": len(incoming),
        "added": added,
        "removed": removed,
        "total": len(incoming),
    }


@router.post("/subreddits/fetch")
async def fetch_subreddit(
    subreddit: str = Query(..., min_length=1),
    queue_manager: QueueManager = Depends(get_queue_manager)
):
    """Immediately fetch content from a subreddit and store it."""
    clean = subreddit.strip().lower()
    await queue_manager.add_or_update_subreddit_config(clean)
    added, _ = await queue_manager.fetch_and_store(clean)
    return {"subreddit": clean, "fetched": added}
