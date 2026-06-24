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
            
            # Extract media URL and gallery items
            media_url, video_url, thumbnail_url, width, height, duration, gallery_items = self._extract_media_details(post_data)
            if not media_url:
                continue
            
            asset = MediaAsset(
                id=f"{subreddit}_{post_data.get('id')}",
                reddit_id=post_data.get("id", ""),
                permalink=post_data.get("permalink", ""),
                media_url=media_url,
                title=post_data.get("title", ""),
                author=post_data.get("author", ""),
                score=post_data.get("score", 0),
                subreddit=subreddit,
                video_url=video_url,
                thumbnail_url=thumbnail_url,
                created_utc=post_data.get("created_utc", 0),
                is_video=bool(post_data.get("is_video")),
                is_gallery=bool(post_data.get("is_gallery")),
                nsfw=post_data.get("over_18", False),
                width=width,
                height=height,
                duration=duration,
                created_at=int(time.time()),
                last_seen=int(time.time())
            )
            
            if self.validate_media(asset):
                # Store gallery items info in asset for later database insertion
                asset._gallery_items = gallery_items  # type: ignore
                assets.append(asset)
        
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
            # Gallery: extract all images in order
            gallery_data = post_data.get("media_metadata", {})
            # Sort by gallery order if available
            items_list = []
            for gallery_id, item in gallery_data.items():
                if item.get("e") == "Image":
                    u = item.get("s", {}).get("u", "")
                    if u:
                        u = html.unescape(u)
                        item_url = u
                        item_width = item["s"].get("x")
                        item_height = item["s"].get("y")
                        # Try to get position from gallery_id (format: "abc123" where position might be in order)
                        items_list.append({
                            "url": item_url,
                            "width": item_width,
                            "height": item_height,
                            "order": len(items_list)  # Use order of iteration
                        })
            
            # Use first image as main media_url
            if items_list:
                media_url = items_list[0]["url"]
                width = items_list[0].get("width") or width
                height = items_list[0].get("height") or height
                gallery_items = items_list
        
        elif post_data.get("is_video"):
            # Video: extract playable video URL
            media = post_data.get("media", {})
            reddit_video = media.get("reddit_video", {})
            if reddit_video:
                # Use fallback_url as the playable video URL (MP4 format)
                video_url = reddit_video.get("fallback_url")
                if video_url:
                    video_url = html.unescape(video_url)
                duration = reddit_video.get("duration")
                width = reddit_video.get("width") or width
                height = reddit_video.get("height") or height
                # For compatibility, set media_url to the fallback_url for playback
                media_url = video_url
        
        elif post_data.get("url", "").endswith((".jpg", ".jpeg", ".png", ".gif", ".webp")):
            media_url = post_data.get("url")
            if media_url:
                media_url = html.unescape(media_url)
        
        else:
            preview = post_data.get("preview", {})
            images = preview.get("images", [])
            if images:
                source = images[0].get("source", {})
                media_url = source.get("url", "")
                if media_url:
                    media_url = html.unescape(media_url)
                width = source.get("width") or width
                height = source.get("height") or height
        
        # Extract thumbnail from preview
        if post_data.get("preview"):
            preview_images = post_data.get("preview", {}).get("images", [])
            if preview_images:
                thumbnail_data = preview_images[0]
                if "source" in thumbnail_data:
                    thumbnail_url = thumbnail_data["source"].get("url")
                elif "resolutions" in thumbnail_data:
                    # Use the smallest resolution as thumbnail
                    resolutions = thumbnail_data["resolutions"]
                    if resolutions:
                        thumbnail_url = resolutions[0].get("url")
                if thumbnail_url:
                    thumbnail_url = html.unescape(thumbnail_url)
        
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
    
    async def search_reddit(
        self,
        query: str,
        limit: int = 25,
        after: Optional[str] = None,
        subreddits: Optional[list[str]] = None,
        mode: str = "global"
    ) -> tuple[list[dict], Optional[str]]:
        """Accumulation-based Reddit search.

        Scans multiple Reddit pages until enough media-only results are found,
        a page limit is hit, or a time budget is exhausted.

        Returns raw post data dicts (not parsed MediaAsset objects).
        """
        provider = await self.provider_manager.get_healthy_provider()
        if provider != "reddit_oauth":
            return [], None

        target_results = max(limit * 4, 100)
        results: list[dict] = []
        current_after = after
        pages_scanned = 0
        start_time = time.monotonic()

        audit = SearchAuditResult(
            query=query,
            mode=mode,
        )

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
                mode=mode
            )

            audit.raw_posts += len(page_items)

            if not page_items:
                break

            text_items = []
            for item in page_items:
                media_url = self._extract_preview_url(item)
                if not media_url:
                    text_items.append(item)

            audit.text_posts_removed += len(text_items)

            media_items = [item for item in page_items if self._is_media_post(item)]

            audit.non_media_removed += len(page_items) - len(text_items) - len(media_items)

            if mode == "local" and subreddits:
                subreddits_lower = {s.lower() for s in subreddits}
                before = len(media_items)
                media_items = [
                    item for item in media_items
                    if item.get("subreddit", "").lower() in subreddits_lower
                ]
                audit.subreddit_filtered += before - len(media_items)

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

        print(f"[Search] DONE query='{query}' pages={pages_scanned} returned={len(results)} elapsed={time.monotonic() - start_time:.2f}s")
        print(f"[Search] Audit: raw={audit.raw_posts} text_removed={audit.text_posts_removed} non_media_removed={audit.non_media_removed} sub_filtered={audit.subreddit_filtered} kept={audit.kept} images={audit.images} galleries={audit.galleries} videos={audit.videos}")

        return results, current_after

    def _extract_preview_url(self, post_data: dict) -> Optional[str]:
        """Check if a raw post dict has any extractable media URL (without fully parsing)."""
        if post_data.get("is_gallery") and post_data.get("media_metadata"):
            return "gallery"
        if post_data.get("is_video") and post_data.get("media", {}).get("reddit_video"):
            return "video"
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

        print(f"[SEARCH_CURSOR] before={after}")

        async with httpx.AsyncClient() as client:
            response = await client.get(
                url,
                headers={
                    "Authorization": f"bearer {token}",
                    "User-Agent": "RedSlide/1.0 by u/redslide_dev",
                },
                params=params,
            )

            if response.status_code == 401:
                await self.oauth.refresh_token()
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
            return raw_items, after_cursor

    def _is_media_post(self, post_data: dict) -> bool:
        """Returns True only if the Reddit post contains usable media."""
        data = post_data.get("data", post_data)

        if data.get("is_gallery") and data.get("media_metadata"):
            return True
        if data.get("is_video") and data.get("media", {}).get("reddit_video"):
            return True
        url = data.get("url", "")
        if any(url.lower().endswith(ext) for ext in [".jpg", ".jpeg", ".png", ".gif", ".webp"]):
            return True
        preview = data.get("preview", {})
        if preview.get("images"):
            return True
        return False

    def _parse_post(self, post_data: dict) -> Optional[MediaAsset]:
        """Parse a single Reddit post data dict into a MediaAsset."""
        media_url, video_url, thumbnail_url, width, height, duration, gallery_items = self._extract_media_details(post_data)
        if not media_url:
            return None

        subreddit = post_data.get("subreddit", "").lower()
        asset = MediaAsset(
            id=f"{subreddit}_{post_data.get('id')}",
            reddit_id=post_data.get("id", ""),
            permalink=post_data.get("permalink", ""),
            media_url=media_url,
            title=post_data.get("title", ""),
            author=post_data.get("author", ""),
            score=post_data.get("score", 0),
            subreddit=subreddit,
            video_url=video_url,
            thumbnail_url=thumbnail_url,
            created_utc=post_data.get("created_utc", 0),
            is_video=bool(post_data.get("is_video")),
            is_gallery=bool(post_data.get("is_gallery")),
            nsfw=post_data.get("over_18", False),
            width=width,
            height=height,
            duration=duration,
            created_at=int(time.time()),
            last_seen=int(time.time()),
        )
        asset._gallery_items = gallery_items  # type: ignore
        return asset

    def _validate_search_asset(self, asset: MediaAsset) -> bool:
        """Final quality gate for search results."""
        if not asset.reddit_id:
            return False
        if not asset.media_url:
            return False
        if not asset.subreddit:
            return False

        title = asset.title.lower()
        author = asset.author.lower()
        if title in ("[deleted]", "[removed]"):
            return False
        if author in ("[deleted]", "automoderator"):
            return False

        media_url = asset.media_url
        if "thumbnail" in media_url:
            return False

        if asset.is_gallery:
            gallery_items = getattr(asset, "_gallery_items", None)
            if not gallery_items:
                return False

        width = asset.width or 0
        height = asset.height or 0
        if width > 0 and height > 0:
            if width < 400 or height < 300:
                return False

        return True

    def validate_media(self, asset: MediaAsset) -> bool:
        """Validate media quality before queue insertion."""
        # Reject known thumbnail paths (not preview.redd.it CDN URLs)
        if "thumbnail" in asset.media_url:
            return False
        
        # Reject small images
        if asset.width and asset.width < self.QUALITY_MIN_WIDTH:
            return False
        if asset.height and asset.height < self.QUALITY_MIN_HEIGHT:
            return False
        
        # Calculate quality score
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