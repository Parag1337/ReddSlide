import json
import time
import asyncio
from typing import Optional
from dataclasses import dataclass

import pytest

from app.services.search_coordinator import (
    SearchCoordinator,
    SubredditWorkerResult,
    SearchMetrics,
    _after_to_cursors,
    _cursors_to_after,
    EXECUTE_TIMEOUT,
    DEFAULT_CONCURRENCY,
)
from app.services.reddit_client import RedditClient, SearchAuditResult, ParseResult
from app.models.schemas import MediaAsset, MediaAssetResponse


def _make_post(post_id: str, subreddit: str, **kwargs) -> dict:
    return {
        "id": post_id,
        "subreddit": subreddit,
        "title": kwargs.get("title", f"Post {post_id}"),
        "author": kwargs.get("author", "testuser"),
        "score": kwargs.get("score", 100),
        "created_utc": kwargs.get("created_utc", int(time.time())),
        "is_video": False,
        "is_gallery": False,
        "over_18": False,
        "url": kwargs.get("url", f"https://i.redd.it/{post_id}.jpg"),
        "permalink": f"/r/{subreddit}/comments/{post_id}/",
        "preview": {"images": [{"source": {"url": f"https://preview.redd.it/{post_id}.jpg", "width": 800, "height": 600}}]},
        "thumbnail": f"https://preview.redd.it/{post_id}.jpg",
        "width": 800,
        "height": 600,
        "media": None,
        "media_metadata": None,
    }


def _make_media_asset(post: dict) -> Optional[MediaAsset]:
    pid = post.get("id", "")
    sub = post.get("subreddit", "unknown")
    return MediaAsset(
        id=f"{sub}_{pid}",
        reddit_id=pid,
        permalink=post.get("permalink", ""),
        media_url=post.get("url", ""),
        title=post.get("title", ""),
        author=post.get("author", ""),
        score=post.get("score", 0),
        subreddit=sub,
        video_url=None,
        thumbnail_url=post.get("thumbnail"),
        created_utc=post.get("created_utc", 0),
        is_video=False,
        is_gallery=False,
        nsfw=False,
        quality_score=80,
        width=post.get("width"),
        height=post.get("height"),
        duration=None,
        created_at=int(time.time()),
        last_seen=int(time.time()),
    )


class FakeRedditClient:
    """Mock RedditClient that returns controlled results per subreddit."""

    def __init__(self):
        self._subreddit_posts: dict[str, list[dict]] = {}
        self._page_size = 10
        self.call_count = 0
        self.fail_subreddits: set[str] = set()
        self.timeout_subreddits: set[str] = set()
        self.oauth = FakeOAuth()

    def set_posts(self, subreddit: str, posts: list[dict]):
        self._subreddit_posts[subreddit] = list(posts)

    def set_page_size(self, size: int):
        self._page_size = size

    async def _accumulate_search(
        self,
        query: str,
        subreddits: Optional[list[str]],
        mode: str,
        target_results: int,
        after: Optional[str] = None,
    ) -> tuple[list[dict], Optional[str], SearchAuditResult]:
        self.call_count += 1

        sr = subreddits[0] if subreddits else "__global__"

        if sr in self.timeout_subreddits:
            raise asyncio.TimeoutError(f"Simulated timeout for {sr}")

        if sr in self.fail_subreddits:
            raise Exception(f"Simulated failure for {sr}")

        all_posts = self._subreddit_posts.get(sr, [])
        audit = SearchAuditResult(query=query, mode=mode)

        if after:
            try:
                start_idx = int(after.split("_")[-1])
            except (ValueError, IndexError):
                start_idx = 0
        else:
            start_idx = 0

        results: list[dict] = []
        pages_scanned = 0

        while start_idx < len(all_posts) and len(results) < target_results:
            page = all_posts[start_idx:start_idx + self._page_size]
            if not page:
                break
            results.extend(page)
            pages_scanned += 1
            start_idx += self._page_size

        next_cursor = f"cursor_{start_idx}" if start_idx < len(all_posts) and len(results) >= target_results else None

        audit.pages_scanned = pages_scanned
        audit.raw_posts = len(results)
        audit.kept = len(results)
        return results, next_cursor, audit

    def _parse_post(self, post_data: dict) -> Optional[MediaAsset]:
        return _make_media_asset(post_data)

    def _parse_post_pipeline(self, post_data: dict) -> ParseResult:
        asset = _make_media_asset(post_data)
        return ParseResult(asset=asset)

    def validate_media(self, asset: MediaAsset) -> bool:
        return True


class FakeOAuth:
    async def initialize(self):
        pass


@pytest.fixture
def coordinator():
    return SearchCoordinator(reddit_client=FakeRedditClient(), concurrency=5)


class TestCursors:
    def test_after_to_cursors_empty(self):
        assert _after_to_cursors(None) == {}
        assert _after_to_cursors("") == {}

    def test_after_to_cursors_json(self):
        raw = '{"pics":"t3_abc","aww":"t3_def"}'
        result = _after_to_cursors(raw)
        assert result == {"pics": "t3_abc", "aww": "t3_def"}

    def test_after_to_cursors_legacy_format(self):
        result = _after_to_cursors("t3_abc123")
        assert result == {"__global__": "t3_abc123"}

    def test_cursors_to_after(self):
        result = _cursors_to_after({"pics": "t3_abc", "aww": None})
        assert json.loads(result) == {"pics": "t3_abc"}

    def test_cursors_to_after_all_none(self):
        assert _cursors_to_after({"pics": None}) is None

    def test_cursors_to_after_empty(self):
        assert _cursors_to_after({}) is None

    def test_roundtrip(self):
        cursors = {"pics": "t3_abc", "aww": "t3_def"}
        after = _cursors_to_after(cursors)
        decoded = _after_to_cursors(after)
        assert decoded == cursors


class TestDeduplication:
    @pytest.mark.asyncio
    async def test_no_duplicates(self):
        client = FakeRedditClient()
        client.set_posts("pics", [_make_post("1", "pics"), _make_post("2", "pics")])
        client.set_posts("aww", [_make_post("3", "aww"), _make_post("4", "aww")])

        coord = SearchCoordinator(reddit_client=client)
        items, after, has_more, _ = await coord.execute(
            query="cat", mode="local", limit=10,
            subreddits=["pics", "aww"],
        )
        assert len(items) == 4
        ids = [item.id for item in items]
        assert len(set(ids)) == 4, "All IDs should be unique"

    @pytest.mark.asyncio
    async def test_duplicates_across_subreddits_removed(self):
        """Same Reddit post appearing in two subreddits should be deduped."""
        shared_post = _make_post("999", "pics", title="Shared post")
        client = FakeRedditClient()
        client.set_posts("pics", [shared_post, _make_post("1", "pics")])
        client.set_posts("aww", [shared_post, _make_post("2", "aww")])

        coord = SearchCoordinator(reddit_client=client)
        items, after, has_more, metrics = await coord.execute(
            query="cat", mode="local", limit=10,
            subreddits=["pics", "aww"],
        )
        assert len(items) == 3
        assert metrics.duplicates_removed == 1

    @pytest.mark.asyncio
    async def test_large_duplicate_overlap(self):
        """Test 5: large duplicate overlap — each Reddit ID appears exactly once."""
        client = FakeRedditClient()
        shared_ids = [str(i) for i in range(50)]
        shared_posts = [_make_post(pid, "pics") for pid in shared_ids]

        client.set_posts("pics", shared_posts)
        client.set_posts("aww", list(shared_posts))
        client.set_posts("itookapicture", list(shared_posts))

        coord = SearchCoordinator(reddit_client=client)
        items, after, has_more, metrics = await coord.execute(
            query="cat", mode="local", limit=100,
            subreddits=["pics", "aww", "itookapicture"],
        )
        assert len(items) == 50, f"Expected 50 deduped items, got {len(items)}"
        assert metrics.duplicates_removed == 100


class TestPagination:
    @pytest.mark.asyncio
    async def test_pagination_continues_across_rounds(self):
        """Test 2: pagination continues indefinitely for a subreddit with many posts."""
        client = FakeRedditClient()
        # Need posts > target_per_subreddit (max(10*4, 100) = 100) so pagination spans rounds
        posts = [_make_post(str(i), "pics") for i in range(500)]
        client.set_posts("pics", posts)

        coord = SearchCoordinator(reddit_client=client)

        # Round 1 should return 100 items (target_per_subreddit)
        items1, after1, has_more1, _ = await coord.execute(
            query="cat", mode="local", limit=10,
            subreddits=["pics"],
        )
        assert len(items1) > 0
        assert has_more1 is True, "Should have more after first round"
        assert after1 is not None

        # Round 2 (loadMore)
        items2, after2, has_more2, _ = await coord.execute(
            query="cat", mode="local", limit=10,
            subreddits=["pics"], after=after1,
        )
        assert len(items2) > 0
        assert has_more2 is True
        ids1 = {item.id for item in items1}
        ids2 = {item.id for item in items2}
        assert ids1.isdisjoint(ids2), "No overlap between rounds"

        # Continue to exhaustion
        after = after2
        rounds = 0
        has_more_n = True
        while has_more_n and rounds < 10:
            items_n, after, has_more_n, _ = await coord.execute(
                query="cat", mode="local", limit=10,
                subreddits=["pics"], after=after,
            )
            rounds += 1

        assert has_more_n is False, "Should have exhausted after multiple rounds"

    @pytest.mark.asyncio
    async def test_per_subreddit_cursors_independent(self):
        """Each subreddit maintains its own cursor — one finishing doesn't affect others."""
        client = FakeRedditClient()
        # pics has only 5 items (exhausts in round 1)
        # aww has 300 items (needs 3 rounds of 100)
        client.set_posts("pics", [_make_post(str(i), "pics") for i in range(5)])
        client.set_posts("aww", [_make_post(str(i + 100), "aww") for i in range(300)])

        coord = SearchCoordinator(reddit_client=client)

        # Round 1: pics exhausts (5 items), aww returns 100 items
        items1, after1, has_more1, _ = await coord.execute(
            query="cat", mode="local", limit=15,
            subreddits=["pics", "aww"],
        )
        assert has_more1 is True, "aww still has more pages"

        # Round 2: pics exhausted (cursor omitted from after), aww continues
        items2, after2, has_more2, _ = await coord.execute(
            query="cat", mode="local", limit=15,
            subreddits=["pics", "aww"], after=after1,
        )
        assert has_more2 is True
        items2_subs = {item.subreddit for item in items2}
        assert "aww" in items2_subs, "aww should continue to produce items"


class TestWorkerFailure:
    @pytest.mark.asyncio
    async def test_one_subreddit_fails_others_succeed(self):
        """Test 4: one subreddit timing out doesn't block others."""
        client = FakeRedditClient()
        client.set_posts("pics", [_make_post(str(i), "pics") for i in range(10)])
        client.set_posts("aww", [_make_post(str(i + 100), "aww") for i in range(10)])
        client.set_posts("failing", [_make_post(str(i + 200), "failing") for i in range(10)])
        client.fail_subreddits.add("failing")

        coord = SearchCoordinator(reddit_client=client)
        items, after, has_more, metrics = await coord.execute(
            query="cat", mode="local", limit=30,
            subreddits=["pics", "aww", "failing"],
        )
        assert len(items) == 20, "Failing subreddit should be skipped, others return items"
        assert metrics.workers_failed == 1

    @pytest.mark.asyncio
    async def test_failed_worker_cursor_preserved(self):
        """Fix C: failed worker preserves cursor for next round."""
        client = FakeRedditClient()
        # Need enough posts so pagination spans multiple rounds
        client.set_posts("pics", [_make_post(str(i), "pics") for i in range(150)])
        client.set_posts("aww", [_make_post(str(i + 100), "aww") for i in range(150)])

        coord = SearchCoordinator(reddit_client=client)

        # Round 1: both succeed, get cursors
        items1, after1, _, _ = await coord.execute(
            query="cat", mode="local", limit=10,
            subreddits=["pics", "aww"],
        )
        assert after1 is not None, "Round 1 should produce cursors"

        # Now make aww fail on next round
        client.fail_subreddits.add("aww")

        # Round 2: pics succeeds, aww fails
        items2, after2, has_more2, metrics = await coord.execute(
            query="cat", mode="local", limit=10,
            subreddits=["pics", "aww"], after=after1,
        )

        # aww's original cursor should be preserved in the output
        decoded_after = _after_to_cursors(after2)
        assert "aww" in decoded_after, "aww cursor should be preserved after failure"
        assert metrics.workers_failed == 1

        # Round 3: aww succeeds again — should resume from preserved cursor
        client.fail_subreddits.discard("aww")
        items3, after3, _, _ = await coord.execute(
            query="cat", mode="local", limit=10,
            subreddits=["pics", "aww"], after=after2,
        )
        assert len(items3) > 0, "Should get new items after failure recovery"


class TestTimeout:
    @pytest.mark.asyncio
    async def test_overall_timeout_returns_empty(self):
        """Fix D: overall timeout returns empty results gracefully."""
        client = FakeRedditClient()
        original_timeout = EXECUTE_TIMEOUT

        try:
            import app.services.search_coordinator as sc
            sc.EXECUTE_TIMEOUT = 0.1

            async def slow_search(*args, **kwargs):
                await asyncio.sleep(10)
                return [], None, SearchAuditResult()

            client._accumulate_search = slow_search

            coord = SearchCoordinator(reddit_client=client)
            items, after, has_more, metrics = await coord.execute(
                query="cat", mode="local", limit=10,
                subreddits=["pics"],
            )
            assert len(items) == 0
            assert after is None
            assert has_more is False
            assert metrics.overall_timed_out is True
        finally:
            sc.EXECUTE_TIMEOUT = original_timeout


class TestCancellation:
    @pytest.mark.asyncio
    async def test_rapid_search_cancels_previous(self):
        """Test 3: rapid repeated searches — old search is cancelled, no stale results."""
        client = FakeRedditClient()
        client.set_posts("pics", [_make_post(str(i), "pics") for i in range(200)])

        coord = SearchCoordinator(reddit_client=client)

        async def slow_search(*args, **kwargs):
            await asyncio.sleep(10)
            return [], None, SearchAuditResult()

        client._accumulate_search = slow_search

        task1 = asyncio.create_task(
            coord.execute(query="old", mode="local", limit=10, subreddits=["pics"])
        )
        await asyncio.sleep(0.05)

        task1.cancel()

        client._accumulate_search = FakeRedditClient._accumulate_search.__get__(client, FakeRedditClient)

        items2, after2, has_more2, _ = await coord.execute(
            query="new", mode="local", limit=10, subreddits=["pics"],
        )
        assert len(items2) > 0
        assert has_more2 is True

        with pytest.raises(asyncio.CancelledError):
            await task1


class TestGlobalMode:
    @pytest.mark.asyncio
    async def test_global_mode_works(self):
        client = FakeRedditClient()
        # Need enough posts for pagination (target_per_subreddit=100)
        client.set_posts("__global__", [_make_post(str(i), "all") for i in range(200)])

        coord = SearchCoordinator(reddit_client=client)
        items, after, has_more, _ = await coord.execute(
            query="cat", mode="global", limit=10,
            subreddits=None,
        )
        assert len(items) > 0
        assert has_more is True

    @pytest.mark.asyncio
    async def test_global_mode_legacy_cursor(self):
        """Fix E: old t3_ format cursor works in global mode."""
        client = FakeRedditClient()
        # Need enough posts so first round returns cursor
        client.set_posts("__global__", [_make_post(str(i), "all") for i in range(200)])

        coord = SearchCoordinator(reddit_client=client)

        items1, after1, _, _ = await coord.execute(
            query="cat", mode="global", limit=10,
            subreddits=None,
        )
        assert after1 is not None, "Should get cursor in round 1"

        items2, after2, _, _ = await coord.execute(
            query="cat", mode="global", limit=10,
            subreddits=None, after=after1,
        )
        ids1 = {item.id for item in items1}
        ids2 = {item.id for item in items2}
        assert ids1.isdisjoint(ids2), "No overlap between global pages"


class TestMetrics:
    @pytest.mark.asyncio
    async def test_metrics_are_populated(self):
        client = FakeRedditClient()
        client.set_posts("pics", [_make_post(str(i), "pics") for i in range(10)])
        client.set_posts("aww", [_make_post(str(i + 100), "aww") for i in range(10)])

        coord = SearchCoordinator(reddit_client=client)
        _, _, _, metrics = await coord.execute(
            query="cat", mode="local", limit=10,
            subreddits=["pics", "aww"],
        )

        assert metrics.workers_launched == 2
        assert metrics.workers_completed == 2
        assert metrics.total_raw_items == 20
        assert metrics.total_reddit_requests == 2
        assert metrics.total_elapsed > 0
        assert "pics" in metrics.per_subreddit
        assert "aww" in metrics.per_subreddit


class TestStress:
    @pytest.mark.asyncio
    async def test_20_subreddits_no_duplicates(self):
        """Test 1: 20 subreddits, 100 pages — verify no duplicates."""
        client = FakeRedditClient()
        post_id = 0
        for i in range(20):
            sub = f"sub{i}"
            posts = [_make_post(str(post_id + j), sub) for j in range(100)]
            post_id += 100
            client.set_posts(sub, posts)

        coord = SearchCoordinator(reddit_client=client, concurrency=5)
        items, after, has_more, _ = await coord.execute(
            query="test", mode="local", limit=50,
            subreddits=[f"sub{i}" for i in range(20)],
        )
        ids = [item.id for item in items]
        assert len(ids) == len(set(ids)), "No duplicates in results from 20 subreddits"

    @pytest.mark.asyncio
    async def test_all_workers_fail_returns_empty(self):
        client = FakeRedditClient()
        client.set_posts("pics", [_make_post("1", "pics")])
        client.set_posts("aww", [_make_post("2", "aww")])
        client.fail_subreddits = {"pics", "aww"}

        coord = SearchCoordinator(reddit_client=client)
        items, after, has_more, metrics = await coord.execute(
            query="cat", mode="local", limit=10,
            subreddits=["pics", "aww"],
        )
        assert len(items) == 0
        assert after is None
        # Failed workers return had_more=True so frontend retries
        assert has_more is True
        assert metrics.workers_failed == 2

    @pytest.mark.asyncio
    async def test_no_subreddits_returns_empty(self):
        coord = SearchCoordinator(reddit_client=FakeRedditClient())
        items, after, has_more, _ = await coord.execute(
            query="cat", mode="local", limit=10,
            subreddits=[],
        )
        assert len(items) == 0
        assert after is None
        assert has_more is False


class TestParserValidation:
    """Test the unified _parse_post_pipeline on a real RedditClient instance."""

    @pytest.fixture
    def parser(self):
        """RedditClient instance with mocked dependencies for parser testing."""
        from unittest.mock import MagicMock
        oauth = MagicMock()
        oauth.get_valid_token = MagicMock(return_value="fake_token")
        oauth.initialize = MagicMock()
        provider = MagicMock()
        provider.get_healthy_provider = MagicMock(return_value="reddit_oauth")
        return RedditClient(oauth_manager=oauth, provider_manager=provider)

    def _make_raw_post(self, **overrides) -> dict:
        base = {
            "id": "abc123",
            "subreddit": "testsub",
            "title": "Test Post",
            "author": "testuser",
            "score": 100,
            "created_utc": int(time.time()),
            "is_video": False,
            "is_gallery": False,
            "over_18": False,
            "url": "https://i.redd.it/abc123.jpg",
            "permalink": "/r/testsub/comments/abc123/",
            "preview": {"images": [{"source": {"url": "https://preview.redd.it/abc123.jpg", "width": 800, "height": 600}}]},
            "thumbnail": "https://preview.redd.it/abc123.jpg",
            "width": 800,
            "height": 600,
            "media": None,
            "media_metadata": None,
        }
        base.update(overrides)
        return base

    def test_accepts_valid_image_post(self, parser):
        result = parser._parse_post_pipeline(self._make_raw_post())
        assert result.accepted
        assert result.asset is not None
        assert result.asset.media_url.endswith(".jpg")
        assert result.asset.quality_score > 0

    def test_rejects_deleted_post(self, parser):
        result = parser._parse_post_pipeline(self._make_raw_post(title="[deleted]"))
        assert not result.accepted
        assert result.rejection_reason == "deleted_or_removed_post"

    def test_rejects_removed_post(self, parser):
        result = parser._parse_post_pipeline(self._make_raw_post(title="[removed]"))
        assert not result.accepted
        assert result.rejection_reason == "deleted_or_removed_post"

    def test_rejects_deleted_author(self, parser):
        result = parser._parse_post_pipeline(self._make_raw_post(author="[deleted]"))
        assert not result.accepted

    def test_rejects_missing_media_url(self, parser):
        result = parser._parse_post_pipeline(self._make_raw_post(url="https://example.com/page", preview=None, thumbnail="https://example.com/thumb.jpg"))
        assert not result.accepted
        assert result.rejection_reason == "missing_media_url"

    def test_rejects_thumbnail_url(self, parser):
        result = parser._parse_post_pipeline(self._make_raw_post(url="https://reddit.com/thumbnail/abc123.jpg"))
        assert not result.accepted
        assert result.rejection_reason == "thumbnail_url"

    def test_rejects_small_width(self, parser):
        result = parser._parse_post_pipeline(self._make_raw_post(width=100, height=800))
        assert not result.accepted
        assert result.rejection_reason == "below_minimum_resolution"

    def test_rejects_small_height(self, parser):
        result = parser._parse_post_pipeline(self._make_raw_post(width=800, height=100))
        assert not result.accepted
        assert result.rejection_reason == "below_minimum_resolution"

    def test_accepts_unknown_dimension(self, parser):
        """If width/height are None/0, resolution check is skipped."""
        result = parser._parse_post_pipeline(self._make_raw_post(width=0, height=0))
        assert result.accepted

    def test_accepts_video_with_mp4(self, parser):
        result = parser._parse_post_pipeline(self._make_raw_post(
            is_video=True,
            url="https://v.redd.it/abc123",
            media={"reddit_video": {
                "fallback_url": "https://v.redd.it/abc123/DASH_480.mp4?source=fallback",
                "duration": 15,
                "width": 640,
                "height": 480,
            }},
        ))
        assert result.accepted
        assert result.asset.is_video
        assert ".mp4" in result.asset.video_url

    def test_rejects_video_without_reddit_video_data(self, parser):
        """Video post missing reddit_video dict is rejected."""
        result = parser._parse_post_pipeline(self._make_raw_post(
            is_video=True,
            url="https://v.redd.it/abc123",
            media={},
        ))
        assert not result.accepted
        assert result.rejection_reason == "missing_media_url"

    def test_accepts_gallery_with_items(self, parser):
        result = parser._parse_post_pipeline(self._make_raw_post(
            is_gallery=True,
            url=None,
            preview=None,
            thumbnail="https://preview.redd.it/abc123.jpg",
            media_metadata={
                "img1": {"e": "Image", "s": {"u": "https://i.redd.it/img1.jpg", "x": 800, "y": 600}},
                "img2": {"e": "Image", "s": {"u": "https://i.redd.it/img2.jpg", "x": 800, "y": 600}},
            },
        ))
        assert result.accepted
        assert result.asset.is_gallery
        assert len(result.asset._gallery_items) == 2

    def test_gallery_ordering_via_gallery_data(self, parser):
        """Gallery items should be ordered by gallery_data.items, not dict order."""
        result = parser._parse_post_pipeline(self._make_raw_post(
            is_gallery=True,
            url=None,
            preview=None,
            media_metadata={
                "img_b": {"e": "Image", "s": {"u": "https://i.redd.it/b.jpg", "x": 800, "y": 600}},
                "img_a": {"e": "Image", "s": {"u": "https://i.redd.it/a.jpg", "x": 800, "y": 600}},
            },
            gallery_data={
                "items": [
                    {"media_id": "img_a", "id": 0},
                    {"media_id": "img_b", "id": 1},
                ]
            },
        ))
        assert result.accepted
        urls = [item["url"] for item in result.asset._gallery_items]
        assert urls == ["https://i.redd.it/a.jpg", "https://i.redd.it/b.jpg"]

    def test_rejects_empty_gallery(self, parser):
        result = parser._parse_post_pipeline(self._make_raw_post(
            is_gallery=True,
            media_metadata={},
            url=None,
            preview=None,
        ))
        assert not result.accepted
        # Gallery with no items → missing_media_url (since no media_url was extracted)
        assert result.rejection_reason is not None

    def test_crosspost_unwrapping(self, parser):
        """Crosspost without own media should use parent data."""
        result = parser._parse_post_pipeline(self._make_raw_post(
            crosspost_parent="t3_xyz789",
            url="https://www.reddit.com/r/testsub/comments/abc123/",
            preview=None,
            crosspost_parent_data={
                "url": "https://i.redd.it/parent.jpg",
                "preview": {"images": [{"source": {"url": "https://preview.redd.it/parent.jpg", "width": 800, "height": 600}}]},
            },
        ))
        assert result.accepted
        assert "parent" in result.asset.media_url

    @pytest.mark.asyncio
    async def test_parser_stats_collected(self):
        """Parser statistics are populated when parsing through search coordinator."""
        client = FakeRedditClient()
        client.set_posts("pics", [
            _make_post("1", "pics"),
            _make_post("2", "pics"),
        ])
        coord = SearchCoordinator(reddit_client=client)

        items, after, has_more, metrics = await coord.execute(
            query="cat", mode="local", limit=10,
            subreddits=["pics"],
        )
        assert metrics.parser.total == 2
        assert metrics.parser.accepted == 2
        assert metrics.parser.images == 2
