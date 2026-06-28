import asyncio
import html
import time
from dataclasses import dataclass, field
from typing import Optional
import httpx
from ..managers.oauth import OAuthManager
from ..managers.provider import ProviderManager
from ..models.schemas import MediaAsset

SEARCH_MAX_PAGES = 20
SEARCH_TIME_BUDGET_SECONDS = 5.0

REJECTION_DELETED = "deleted_or_removed_post"
REJECTION_MISSING_SUBREDDIT = "missing_subreddit"
REJECTION_MISSING_MEDIA_URL = "missing_media_url"
REJECTION_THUMBNAIL_URL = "thumbnail_url"
REJECTION_SMALL_RESOLUTION = "below_minimum_resolution"
REJECTION_EMPTY_GALLERY = "gallery_has_no_valid_items"
REJECTION_MISSING_GALLERY_METADATA = "gallery_missing_media_metadata"
REJECTION_MISSING_VIDEO_DATA = "video_post_missing_reddit_video_data"
REJECTION_CROSSPOST_NO_MEDIA = "crosspost_has_no_extractable_media"
REJECTION_UNSUPPORTED_MEDIA = "unsupported_media_type"


@dataclass
class ParseResult:
    asset: Optional[MediaAsset] = None
    rejection_reason: Optional[str] = None

    @property
    def accepted(self) -> bool:
        return self.asset is not None


@dataclass
class ParserStats:
    total: int = 0
    accepted: int = 0
    rejected: int = 0
    images: int = 0
    videos: int = 0
    galleries: int = 0
    crossposts: int = 0
    missing_url: int = 0
    deleted: int = 0
    thumbnail_url: int = 0
    small_resolution: int = 0
    broken_gallery: int = 0
    missing_video_data: int = 0
    unsupported: int = 0
    total_parse_time: float = 0.0

    @property
    def avg_parse_time(self) -> float:
        if self.total == 0:
            return 0.0
        return self.total_parse_time / self.total


@dataclass
class SearchAuditResult:
    query: str = ""
    mode: str = "global"
    pages_scanned: int = 0
    raw_posts: int = 0
    text_posts_removed: int = 0
    non_media_removed: int = 0
    subreddit_filtered: int = 0
    deleted_removed: int = 0
    kept: int = 0
    images: int = 0
    galleries: int = 0
    videos: int = 0


class RedditClient:
    """Reddit API client with quality validation and deduplication."""
    
    QUALITY_MIN_WIDTH = 400
    QUALITY_MIN_HEIGHT = 300
    
    def __init__(self, oauth_manager: OAuthManager, provider_manager: ProviderManager):
        self.oauth = oauth_manager
        self.provider_manager = provider_manager
    
    async def fetch_subreddit_media(
        self,
        subreddit: str,
        limit: int = 25,
        after: Optional[str] = None,
        sort: str = "hot"
    ) -> tuple[list[MediaAsset], Optional[str]]:
        """Fetch media from subreddit using available provider."""
        provider = await self.provider_manager.get_healthy_provider()
        print(
            f"[REDDIT] fetch subreddit={subreddit} limit={limit} after={after} "
            f"sort={sort} provider={provider}"
        )
        if provider == "reddit_oauth":
            result = await self._fetch_oauth(subreddit, limit, after, sort)
        else:
            result = await self._fetch_redlib(subreddit, limit, after, sort)
        assets, after_cursor = result
        print(
            f"[REDDIT] result subreddit={subreddit} items={len(assets)} "
            f"after={after_cursor}"
        )
        return result
    
    async def _fetch_oauth(
        self,
        subreddit: str,
        limit: int,
        after: Optional[str],
        sort: str
    ) -> tuple[list[MediaAsset], Optional[str]]:
        """Fetch using Reddit OAuth."""
        token = await self.oauth.get_valid_token()
        
        url = f"https://oauth.reddit.com/r/{subreddit}/{sort}"
        params = {"limit": limit}
        if after:
            params["after"] = after
        
        async with httpx.AsyncClient() as client:
            response = await client.get(
                url,
                headers={
                    "Authorization": f"bearer {token}",
                    "User-Agent": "RedSlide/1.0 by u/redslide_dev"
                },
                params=params
            )

            if response.status_code == 401:
                await self.oauth.refresh_token()
                token = await self.oauth.get_valid_token()
                async with httpx.AsyncClient() as retry_client:
                    retry_response = await retry_client.get(
                        url,
                        headers={
                            "Authorization": f"bearer {token}",
                            "User-Agent": "RedSlide/1.0 by u/redslide_dev"
                        },
                        params=params
                    )
                    if retry_response.status_code == 200:
                        await self.oauth.record_success()
                        await self.provider_manager.record_provider_success("reddit_oauth")
                        data = retry_response.json()
                        return self._parse_reddit_response(data, subreddit)
                    else:
                        await self.provider_manager.record_provider_failure("reddit_oauth")
                        return await self._fetch_redlib(subreddit, limit, after, sort)

            if response.status_code != 200:
                await self.provider_manager.record_provider_failure("reddit_oauth")
                return await self._fetch_redlib(subreddit, limit, after, sort)
            
            await self.oauth.record_success()
            await self.provider_manager.record_provider_success("reddit_oauth")
            
            data = response.json()
            return self._parse_reddit_response(data, subreddit)
    
    async def _fetch_redlib(
        self,
        subreddit: str,
        limit: int,
        after: Optional[str],
        sort: str
    ) -> tuple[list[MediaAsset], Optional[str]]:
        """Fetch using Redlib fallback (implementation placeholder)."""
        # Redlib fallback - would use HTTP calls to Redlib instance
        # For now, return empty
        return [], None
    
    def _parse_reddit_response(self, data: dict, subreddit: str) -> tuple[list[MediaAsset], Optional[str]]:
        """Parse Reddit API response into MediaAsset list."""
        assets = []
        after = data.get("data", {}).get("after")
        
        for post in data.get("data", {}).get("children", []):
            post_data = post.get("data", {})

            result = self._parse_post_pipeline(post_data)
            if result.accepted:
                assets.append(result.asset)
        
        return assets, after
    
    def _extract_media_details(self, post_data: dict) -> tuple:
        """Extract all media details from post data. Returns (media_url, video_url, thumbnail_url, width, height, duration, gallery_items)."""
        media_url = None
        video_url = None
        thumbnail_url = None
        width = post_data.get("width")
        height = post_data.get("height")
        duration = None
        gallery_items = []
        
        if post_data.get("is_gallery"):
            gallery_items = self._extract_gallery_items(post_data)
            if gallery_items:
                media_url = gallery_items[0]["url"]
                width = gallery_items[0].get("width") or width
                height = gallery_items[0].get("height") or height
        
        elif post_data.get("is_video"):
            media = post_data.get("media", {})
            reddit_video = media.get("reddit_video", {})
            if reddit_video:
                video_url = reddit_video.get("fallback_url")
                if video_url:
                    video_url = html.unescape(video_url)
                    # Strip query params before checking extension
                    clean_url = video_url.split("?")[0]
                    if clean_url.endswith(".mp4"):
                        media_url = video_url
                duration = reddit_video.get("duration")
                width = reddit_video.get("width") or width
                height = reddit_video.get("height") or height
        
        elif post_data.get("url", "").endswith((".jpg", ".jpeg", ".png", ".gif", ".webp")):
            media_url = post_data.get("url")
            if media_url:
                media_url = html.unescape(media_url)
        
        else:
            preview = post_data.get("preview")
            if preview and isinstance(preview, dict):
                images = preview.get("images", [])
                if images:
                    source = images[0].get("source", {})
                    media_url = source.get("url", "")
                    if media_url:
                        media_url = html.unescape(media_url)
                    width = source.get("width") or width
                    height = source.get("height") or height
        
        # Extract thumbnail from preview, falling back to Reddit's thumbnail field
        if post_data.get("preview"):
            preview_images = post_data.get("preview", {}).get("images", [])
            if preview_images:
                thumbnail_data = preview_images[0]
                if "source" in thumbnail_data:
                    thumbnail_url = thumbnail_data["source"].get("url")
                elif "resolutions" in thumbnail_data:
                    resolutions = thumbnail_data["resolutions"]
                    if resolutions:
                        thumbnail_url = resolutions[0].get("url")
                if thumbnail_url:
                    thumbnail_url = html.unescape(thumbnail_url)

        # Fallback: use Reddit's own thumbnail field when preview extraction fails
        if not thumbnail_url:
            raw_thumb = post_data.get("thumbnail")
            if raw_thumb and raw_thumb.startswith(("http://", "https://")):
                thumbnail_url = raw_thumb
        
        # Final sanitization: ensure no external-*.redd.it URLs slip through
        if media_url:
            media_url = media_url.replace("external-preview.redd.it", "preview.redd.it")
            media_url = media_url.replace("external-i.redd.it", "i.redd.it")
        if video_url:
            video_url = video_url.replace("external-preview.redd.it", "preview.redd.it")
            video_url = video_url.replace("external-i.redd.it", "i.redd.it")
        if thumbnail_url:
            thumbnail_url = thumbnail_url.replace("external-preview.redd.it", "preview.redd.it")
            thumbnail_url = thumbnail_url.replace("external-i.redd.it", "i.redd.it")
        gallery_items = [
            {**item, "url": item["url"].replace("external-preview.redd.it", "preview.redd.it").replace("external-i.redd.it", "i.redd.it")}
            if "url" in item else item
            for item in gallery_items
        ]

        return media_url, video_url, thumbnail_url, width, height, duration, gallery_items

    def _extract_gallery_items(self, post_data: dict) -> list[dict]:
        """Extract gallery items from post data, preserving Reddit's display order."""
        media_metadata = post_data.get("media_metadata", {})
        if not media_metadata:
            return []

        # Build media_id -> metadata lookup
        metadata_map: dict[str, dict] = {}
        for gid, item in media_metadata.items():
            if item.get("e") == "Image":
                u = item.get("s", {}).get("u", "")
                if u:
                    u = html.unescape(u)
                    metadata_map[gid] = {
                        "url": u,
                        "width": item["s"].get("x"),
                        "height": item["s"].get("y"),
                    }

        if not metadata_map:
            return []

        # Try gallery_data.items for official ordering
        gallery_data = post_data.get("gallery_data", {})
        order_items = gallery_data.get("items", []) if isinstance(gallery_data, dict) else []

        items_list: list[dict] = []
        if order_items:
            seen = set()
            for entry in order_items:
                media_id = entry.get("media_id")
                if media_id and media_id in metadata_map and media_id not in seen:
                    item = metadata_map[media_id]
                    items_list.append({
                        "url": item["url"],
                        "width": item["width"],
                        "height": item["height"],
                        "order": len(items_list),
                    })
                    seen.add(media_id)
            # Append any remaining items not in the order list
            for gid, item in metadata_map.items():
                if gid not in seen:
                    items_list.append({
                        "url": item["url"],
                        "width": item["width"],
                        "height": item["height"],
                        "order": len(items_list),
                    })
        else:
            # Fallback: use dict iteration order
            for gid, item in metadata_map.items():
                items_list.append({
                    "url": item["url"],
                    "width": item["width"],
                    "height": item["height"],
                    "order": len(items_list),
                })

        return items_list
    
    async def _accumulate_search(
        self,
        query: str,
        subreddits: Optional[list[str]],
        mode: str,
        target_results: int,
        after: Optional[str] = None,
    ) -> tuple[list[dict], Optional[str], SearchAuditResult]:
        """Accumulate search results across pages for a given query/subreddit/mode combination."""
        results: list[dict] = []
        current_after = after
        pages_scanned = 0
        start_time = time.monotonic()

        audit = SearchAuditResult(query=query, mode=mode)

        while True:
            if len(results) >= target_results:
                break
            if pages_scanned >= SEARCH_MAX_PAGES:
                break
            if time.monotonic() - start_time > SEARCH_TIME_BUDGET_SECONDS:
                break

            page_items, next_after = await self._search_oauth(
                query=query,
                limit=25,
                after=current_after,
                subreddits=subreddits,
                mode=mode,
            )

            audit.raw_posts += len(page_items)

            if not page_items:
                break

            text_items = [item for item in page_items if not self._extract_preview_url(item)]
            audit.text_posts_removed += len(text_items)

            media_items = [item for item in page_items if self._is_media_post(item)]
            audit.non_media_removed += len(page_items) - len(text_items) - len(media_items)
            print(f"[SEARCH_MEDIA] page_items={len(page_items)} text_removed={len(text_items)} media_kept={len(media_items)}")

            for item in media_items:
                if item.get("is_gallery"):
                    audit.galleries += 1
                elif item.get("is_video"):
                    audit.videos += 1
                else:
                    audit.images += 1

            results.extend(media_items)
            audit.kept = len(results)

            current_after = next_after
            pages_scanned += 1
            audit.pages_scanned = pages_scanned

            print(f"[Search] page={pages_scanned} fetched={len(page_items)} media={len(media_items)} total={len(results)} after={current_after}")

            if not next_after:
                break

        return results, current_after, audit

    def _extract_preview_url(self, post_data: dict) -> Optional[str]:
        """Check if a raw post dict has any extractable media URL (without fully parsing)."""
        if post_data.get("is_gallery") and post_data.get("media_metadata"):
            return "gallery"
        if post_data.get("is_video") and post_data.get("media", {}).get("reddit_video"):
            return "video"
        if post_data.get("crosspost_parent") and (
            post_data.get("crosspost_parent_data") or post_data.get("crosspost_parent_media")
        ):
            return "crosspost"
        url = post_data.get("url", "")
        if any(url.lower().endswith(ext) for ext in [".jpg", ".jpeg", ".png", ".gif", ".webp"]):
            return url
        preview = post_data.get("preview", {})
        if preview.get("images"):
            return preview["images"][0].get("source", {}).get("url", "preview")
        return None

    async def _search_oauth(
        self,
        query: str,
        limit: int,
        after: Optional[str],
        subreddits: Optional[list[str]],
        mode: str = "global",
    ) -> tuple[list[dict], Optional[str]]:
        """Search Reddit via OAuth. Returns raw post_data dicts (not parsed MediaAsset objects)."""
        token = await self.oauth.get_valid_token()

        if subreddits and mode == "local":
            subreddit_str = "+".join(s.strip().lower() for s in subreddits if s.strip())
            url = f"https://oauth.reddit.com/r/{subreddit_str}/search"
        else:
            url = "https://oauth.reddit.com/search"

        params: dict = {"q": query, "limit": limit}
        if after:
            params["after"] = after
        if subreddits and mode == "local":
            params["restrict_sr"] = "on"
            params["include_over_18"] = "on"

        print(f"[SEARCH_CURSOR] before={after}")
        print(f"[SEARCH_REQUEST] q={query} after={after} url={url} params={params}")

        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(15.0)) as client:
                response = await client.get(
                    url,
                    headers={
                        "Authorization": f"bearer {token}",
                        "User-Agent": "RedSlide/1.0 by u/redslide_dev",
                    },
                    params=params,
                )
        except (httpx.TimeoutException, httpx.ConnectError) as e:
            print(f"[SEARCH_TIMEOUT] url={url} error={e}")
            await self.provider_manager.record_provider_failure("reddit_oauth")
            return [], None

        print(f"[SEARCH_RESPONSE] status={response.status_code}")

        if response.status_code == 401:
            await self.oauth.refresh_token()
            token = await self.oauth.get_valid_token()
            try:
                async with httpx.AsyncClient(timeout=httpx.Timeout(15.0)) as retry_client:
                    retry_response = await retry_client.get(
                        url,
                        headers={
                            "Authorization": f"bearer {token}",
                            "User-Agent": "RedSlide/1.0 by u/redslide_dev",
                        },
                        params=params,
                    )
                    if retry_response.status_code == 200:
                        await self.oauth.record_success()
                        await self.provider_manager.record_provider_success("reddit_oauth")
                        data = retry_response.json()
                        after_cursor = data.get("data", {}).get("after")
                        raw_items = []
                        for child in data.get("data", {}).get("children", []):
                            raw_items.append(child.get("data", {}))
                        print(f"[SEARCH_RAW] count={len(raw_items)} after_cursor={after_cursor}")
                        return raw_items, after_cursor
            except (httpx.TimeoutException, httpx.ConnectError) as e:
                print(f"[SEARCH_TIMEOUT_RETRY] url={url} error={e}")
            await self.provider_manager.record_provider_failure("reddit_oauth")
            return [], None

        if response.status_code != 200:
            await self.provider_manager.record_provider_failure("reddit_oauth")
            return [], None

        await self.oauth.record_success()
        await self.provider_manager.record_provider_success("reddit_oauth")

        data = response.json()
        after_cursor = data.get("data", {}).get("after")
        raw_items = []
        for child in data.get("data", {}).get("children", []):
            raw_items.append(child.get("data", {}))
        print(f"[SEARCH_RAW] count={len(raw_items)} after_cursor={after_cursor}")
        return raw_items, after_cursor

    def _unwrap_crosspost(self, post_data: dict) -> dict:
        """Detect and unwrap crossposted Reddit posts.

        If a post is a crosspost (has crosspost_parent) and lacks its own
        media, try to extract media from the crosspost's parent data that
        Reddit may include inline.
        """
        if not post_data.get("crosspost_parent"):
            return post_data

        # Check if this crosspost has its own media
        has_own_media = (
            post_data.get("is_gallery") or
            post_data.get("is_video") or
            self._has_direct_media_url(post_data)
        )
        if has_own_media:
            return post_data

        # Try to get parent post data provided inline by Reddit
        parent_data = post_data.get("crosspost_parent_data")
        if parent_data and isinstance(parent_data, dict):
            merged = dict(post_data)
            for key in ("media", "media_metadata", "preview", "url",
                        "is_gallery", "is_video", "gallery_data",
                        "thumbnail", "width", "height", "title",
                        "author", "score", "permalink", "over_18",
                        "created_utc"):
                if key not in merged or not merged.get(key):
                    if key in parent_data:
                        merged[key] = parent_data[key]
            return merged

        crosspost_media = post_data.get("crosspost_parent_media")
        if crosspost_media and isinstance(crosspost_media, dict):
            merged = dict(post_data)
            merged["media"] = crosspost_media
            merged["is_video"] = True
            return merged

        return post_data

    def _has_direct_media_url(self, post_data: dict) -> bool:
        """Check if the post has a direct media URL without full parsing."""
        url = post_data.get("url", "")
        if any(url.lower().endswith(ext) for ext in (".jpg", ".jpeg", ".png", ".gif", ".webp")):
            return True
        preview = post_data.get("preview")
        if preview and isinstance(preview, dict):
            if preview.get("images"):
                return True
        return False

    def _is_media_post(self, post_data: dict) -> bool:
        """Returns True only if the Reddit post contains usable media."""
        data = post_data.get("data", post_data)

        if data.get("is_gallery") and data.get("media_metadata"):
            return True
        if data.get("is_video") and data.get("media", {}).get("reddit_video"):
            return True
        if data.get("crosspost_parent") and (
            data.get("crosspost_parent_data") or data.get("crosspost_parent_media")
        ):
            return True
        url = data.get("url", "")
        if any(url.lower().endswith(ext) for ext in [".jpg", ".jpeg", ".png", ".gif", ".webp"]):
            return True
        preview = data.get("preview", {})
        if preview.get("images"):
            return True
        return False

    def _parse_post_pipeline(self, post_data: dict) -> ParseResult:
        """Single authoritative parser for all Reddit post data -> MediaAsset.

        Used by Search, Home feed, and all future media sources. Validates
        every post and returns a ParseResult with either the asset or a
        rejection reason.
        """
        start = time.monotonic()

        # 1. Check for deleted/removed posts
        title = post_data.get("title", "").lower()
        author = post_data.get("author", "").lower()
        if title in ("[deleted]", "[removed]") or author in ("[deleted]",):
            return ParseResult(rejection_reason=REJECTION_DELETED)

        # 2. Check subreddit exists
        subreddit = post_data.get("subreddit", "").lower()
        if not subreddit:
            return ParseResult(rejection_reason=REJECTION_MISSING_SUBREDDIT)

        # 3. Unwrap crossposts that lack their own media
        resolved = self._unwrap_crosspost(post_data)

        # 4. Extract media details
        media_url, video_url, thumbnail_url, width, height, duration, gallery_items = self._extract_media_details(resolved)

        # 5. Check media URL exists
        if not media_url:
            return ParseResult(rejection_reason=REJECTION_MISSING_MEDIA_URL)

        # 6. Reject thumbnail URLs
        if "thumbnail" in media_url:
            return ParseResult(rejection_reason=REJECTION_THUMBNAIL_URL)

        # 7. Gallery must have items
        is_gallery = bool(resolved.get("is_gallery"))
        is_video = bool(resolved.get("is_video"))
        if is_gallery and not gallery_items:
            return ParseResult(rejection_reason=REJECTION_EMPTY_GALLERY)

        # 8. Resolution validation
        known_width = width or 0
        known_height = height or 0
        if known_width > 0 and known_width < self.QUALITY_MIN_WIDTH:
            return ParseResult(rejection_reason=REJECTION_SMALL_RESOLUTION)
        if known_height > 0 and known_height < self.QUALITY_MIN_HEIGHT:
            return ParseResult(rejection_reason=REJECTION_SMALL_RESOLUTION)

        # 9. Build MediaAsset
        reddit_id = resolved.get("id", "")
        asset = MediaAsset(
            id=f"{subreddit}_{reddit_id}",
            reddit_id=reddit_id,
            permalink=resolved.get("permalink", ""),
            media_url=media_url,
            title=resolved.get("title", ""),
            author=resolved.get("author", ""),
            score=resolved.get("score", 0),
            subreddit=subreddit,
            video_url=video_url,
            thumbnail_url=thumbnail_url,
            created_utc=resolved.get("created_utc", 0),
            is_video=is_video,
            is_gallery=is_gallery,
            nsfw=resolved.get("over_18", False),
            width=width,
            height=height,
            duration=duration,
            created_at=int(time.time()),
            last_seen=int(time.time()),
        )
        asset._gallery_items = gallery_items  # type: ignore

        # 10. Calculate quality score (sets asset.quality_score)
        asset.quality_score = self._calculate_quality_score(asset)

        return ParseResult(asset=asset)

    def _parse_post(self, post_data: dict) -> Optional[MediaAsset]:
        """Legacy wrapper — parses Reddit post data into MediaAsset.

        Delegates to the unified _parse_post_pipeline. Returns None if
        the post is rejected.
        """
        return self._parse_post_pipeline(post_data).asset

    def validate_media(self, asset: MediaAsset) -> bool:
        """Validate media quality before queue insertion.

        Quality score is now computed during _parse_post_pipeline.
        This method only recalculates if needed (e.g. for queue insertion).
        """
        if asset.quality_score == 0:
            asset.quality_score = self._calculate_quality_score(asset)
        return True
    
    def _calculate_quality_score(self, asset: MediaAsset) -> int:
        """Calculate quality score for media asset."""
        score = 50
        
        # Resolution bonus
        if asset.width and asset.height:
            pixels = asset.width * asset.height
            if pixels > 4000000:  # 4MP+
                score += 20
            elif pixels > 2000000:  # 2MP+
                score += 10
            elif pixels > 1000000:  # 1MP+
                score += 5
        
        # Video bonus
        if asset.is_video:
            score += 10
        
        # Score bonus
        if asset.score > 1000:
            score += 10
        elif asset.score > 500:
            score += 5
        
        return min(100, score)