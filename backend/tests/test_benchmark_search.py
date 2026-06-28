"""Benchmark: SearchCoordinator multi-subreddit performance.

Tests 1, 5, 10, 20 subreddits with simulated page latencies.
Measures total search latency, worker utilization, semaphore wait, etc.

Results are printed to stdout for comparison.
"""

import asyncio
import time
from typing import Optional

import pytest

from app.services.search_coordinator import EXHAUSTED_SENTINEL, SearchCoordinator
from app.services.reddit_client import SearchAuditResult, ParseResult
from app.models.schemas import MediaAsset


class LatencyFakeRedditClient:
    """Fake RedditClient that simulates per-page network latency.

    Each page fetch via _search_oauth (called from _accumulate_search's page
    loop) waits page_latency seconds to simulate real Reddit API latency.
    Results are returned from pre-staged per-subreddit post lists.
    """

    def __init__(self, page_latency: float = 0.05):
        self._subreddit_posts: dict[str, list[dict]] = {}
        self._page_size = 25
        self._page_latency = page_latency
        self.oauth = None
        self._semaphore_wait_ms = 0.0
        self._http_request_count = 0
        self._http_failure_count = 0
        self._http_latency_sum = 0.0
        self._http_latency_min = 0.0
        self._http_latency_max = 0.0
        self._json_parse_sum = 0.0
        self._oauth_lookup_sum = 0.0

    def set_posts(self, subreddit: str, posts: list[dict]):
        self._subreddit_posts[subreddit] = list(posts)

    async def _accumulate_search(
        self,
        query: str,
        subreddits: Optional[list[str]],
        mode: str,
        target_results: int,
        after: Optional[str] = None,
        ctx: Optional[object] = None,
    ) -> tuple[list[dict], Optional[str], SearchAuditResult]:
        """Simulates _accumulate_search with per-page latency.

        The page loop calls _search_oauth for each page, which adds
        the simulated latency. This mimics the real code path where
        each page involves an HTTP request to Reddit.
        """
        audit = SearchAuditResult(query=query, mode=mode)
        sr = subreddits[0] if subreddits else "__global__"
        all_posts = self._subreddit_posts.get(sr, [])

        results: list[dict] = []
        current_after = after
        pages_scanned = 0

        while True:
            if ctx and getattr(ctx, "cancelled", False):
                break
            if len(results) >= target_results:
                break

            start_idx = 0
            if current_after:
                try:
                    start_idx = int(current_after.split("_")[-1])
                except (ValueError, IndexError):
                    start_idx = 0

            if start_idx >= len(all_posts):
                break
            if pages_scanned >= 20:
                break

            page_items, next_after = await self._search_oauth(
                query=query, limit=self._page_size,
                after=current_after, subreddits=subreddits, mode=mode,
            )
            audit.raw_posts += len(page_items)
            results.extend(page_items)
            audit.kept = len(results)
            current_after = next_after
            pages_scanned += 1

            if not next_after:
                break

        audit.pages_scanned = pages_scanned
        return results, current_after, audit

    async def _search_oauth(
        self,
        query: str,
        limit: int,
        after: Optional[str],
        subreddits: Optional[list[str]],
        mode: str = "global",
    ) -> tuple[list[dict], Optional[str]]:
        """Simulate a single page request with network latency."""
        t0 = time.monotonic()
        # Simulate HTTP round-trip
        await asyncio.sleep(self._page_latency)
        elapsed = time.monotonic() - t0
        self._semaphore_wait_ms += elapsed * 1000
        self._http_request_count += 1
        self._http_latency_sum += elapsed
        if self._http_latency_min == 0.0 or elapsed < self._http_latency_min:
            self._http_latency_min = elapsed
        if elapsed > self._http_latency_max:
            self._http_latency_max = elapsed

        sr = subreddits[0] if subreddits else "__global__"
        all_posts = self._subreddit_posts.get(sr, [])
        start_idx = 0
        if after:
            try:
                start_idx = int(after.split("_")[-1])
            except (ValueError, IndexError):
                start_idx = 0

        page = all_posts[start_idx:start_idx + limit]
        if not page:
            return [], None

        next_idx = start_idx + len(page)
        next_after = f"cursor_{next_idx}" if next_idx < len(all_posts) else None
        return page, next_after

    def _parse_post(self, post_data: dict) -> Optional[MediaAsset]:
        pid = post_data.get("id", "")
        sub = post_data.get("subreddit", "unknown")
        return MediaAsset(
            id=f"{sub}_{pid}", reddit_id=pid,
            permalink=post_data.get("permalink", ""),
            media_url=post_data.get("url", ""),
            title=post_data.get("title", ""),
            author=post_data.get("author", ""),
            score=post_data.get("score", 0),
            subreddit=sub, video_url=None,
            thumbnail_url=post_data.get("thumbnail"),
            created_utc=post_data.get("created_utc", 0),
            is_video=False, is_gallery=False,
            nsfw=False, quality_score=80,
            width=post_data.get("width"),
            height=post_data.get("height"),
            duration=None, created_at=int(time.time()),
            last_seen=int(time.time()),
        )

    def _parse_post_pipeline(self, post_data: dict) -> ParseResult:
        asset = self._parse_post(post_data)
        if asset:
            return ParseResult(asset=asset)
        return ParseResult(rejection_reason="unknown")

    def validate_media(self, asset) -> bool:
        return True


def _make_post(post_id: str, subreddit: str) -> dict:
    return {
        "id": post_id,
        "subreddit": subreddit,
        "title": f"Post {post_id}",
        "author": "testuser",
        "score": 100,
        "created_utc": int(time.time()),
        "is_video": False,
        "is_gallery": False,
        "over_18": False,
        "url": f"https://i.redd.it/{post_id}.jpg",
        "permalink": f"/r/{subreddit}/comments/{post_id}/",
        "preview": {"images": [{"source": {"url": f"https://preview.redd.it/{post_id}.jpg", "width": 800, "height": 600}}]},
        "thumbnail": f"https://preview.redd.it/{post_id}.jpg",
        "width": 800,
        "height": 600,
        "media": None,
        "media_metadata": None,
    }


async def benchmark_search(
    subreddit_count: int,
    posts_per_subreddit: int = 100,
    page_latency: float = 0.05,
    label: str = "",
) -> dict:
    """Run a search benchmark and return metrics."""
    client = LatencyFakeRedditClient(page_latency=page_latency)
    subs = []
    for i in range(subreddit_count):
        sub = f"sub{i}"
        subs.append(sub)
        posts = [_make_post(f"{i}_{j}", sub) for j in range(posts_per_subreddit)]
        client.set_posts(sub, posts)

    coord = SearchCoordinator(reddit_client=client)

    t0 = time.monotonic()
    items, after, has_more, metrics = await coord.execute(
        query="test", mode="local", limit=25,
        subreddits=subs,
    )
    elapsed = time.monotonic() - t0

    result = {
        "label": label or f"{subreddit_count} subs",
        "subreddits": subreddit_count,
        "total_elapsed_s": round(metrics.total_elapsed, 3),
        "wall_clock_s": round(elapsed, 3),
        "workers_completed": metrics.workers_completed,
        "workers_failed": metrics.workers_failed,
        "total_reddit_requests": metrics.total_reddit_requests,
        "total_raw_items": metrics.total_raw_items,
        "total_after_dedup": metrics.total_after_dedup,
        "semaphore_wait_ms": round(metrics.semaphore_wait_ms, 1),
        "max_per_subreddit_s": round(max(metrics.per_subreddit.values()), 3) if metrics.per_subreddit else 0,
        "min_per_subreddit_s": round(min(metrics.per_subreddit.values()), 3) if metrics.per_subreddit else 0,
        "avg_per_subreddit_s": round(
            sum(metrics.per_subreddit.values()) / len(metrics.per_subreddit), 3
        ) if metrics.per_subreddit else 0,
    }

    title = f"[BENCHMARK] {result['label']}"
    sep = "=" * len(title)
    print(f"\n{sep}\n{title}\n{sep}")
    print(f"  Wall clock:     {result['wall_clock_s']:.3f}s")
    print(f"  Coordinator:    {result['total_elapsed_s']:.3f}s")
    print(f"  Workers:        {result['workers_completed']}/{result['workers_failed']} (ok/fail)")
    print(f"  Reddit reqs:    {result['total_reddit_requests']}")
    print(f"  Raw items:      {result['total_raw_items']}")
    print(f"  Final items:    {result['total_after_dedup']}")
    print(f"  Semaphore wait: {result['semaphore_wait_ms']:.1f}ms")
    print(f"  Per-subreddit:")
    print(f"    max:  {result['max_per_subreddit_s']:.3f}s")
    print(f"    min:  {result['min_per_subreddit_s']:.3f}s")
    print(f"    avg:  {result['avg_per_subreddit_s']:.3f}s")
    if metrics.http_request_count > 0:
        avg_http = metrics.http_latency_sum_ms / metrics.http_request_count
        print(f"  HTTP latency (avg/min/max): {avg_http:.1f}/{metrics.http_latency_min_ms:.1f}/{metrics.http_latency_max_ms:.1f}ms")
        print(f"  JSON parse: {metrics.json_parse_sum_ms:.1f}ms  OAuth: {metrics.oauth_lookup_sum_ms:.1f}ms")
    if metrics.response_serialization_elapsed > 0:
        print(f"  Serialization: {metrics.response_serialization_elapsed:.4f}s")
    if metrics.pagination_elapsed > 0:
        print(f"  Pagination cursor: {metrics.pagination_elapsed:.4f}s")

    return result


class TestBenchmark:
    """Benchmark tests — run with: pytest tests/test_benchmark_search.py -v -s"""

    @pytest.mark.asyncio
    async def test_benchmark_1_sub(self):
        """1 subreddit baseline."""
        r = await benchmark_search(1, page_latency=0.05, label="1 sub")
        assert r["workers_completed"] == 1
        assert r["total_reddit_requests"] >= 1

    @pytest.mark.asyncio
    async def test_benchmark_5_subs(self):
        """5 subreddits — typical small search."""
        r = await benchmark_search(5, page_latency=0.05, label="5 subs")
        assert r["workers_completed"] == 5

    @pytest.mark.asyncio
    async def test_benchmark_10_subs(self):
        """10 subreddits — medium search."""
        r = await benchmark_search(10, page_latency=0.05, label="10 subs")
        assert r["workers_completed"] == 10

    @pytest.mark.asyncio
    async def test_benchmark_20_subs(self):
        """20 subreddits — large search, stress test."""
        r = await benchmark_search(20, page_latency=0.05, label="20 subs")
        assert r["workers_completed"] == 20

    @pytest.mark.asyncio
    async def test_benchmark_mixed_latency(self):
        """10 subs with one slow sub (200ms pages) to test fairness."""
        client = LatencyFakeRedditClient(page_latency=0.05)

        subs = []
        for i in range(10):
            sub = f"sub{i}"
            subs.append(sub)
            posts = [_make_post(f"{i}_{j}", sub) for j in range(100)]
            client.set_posts(sub, posts)

        # Make sub0 slow (4x latency)
        slow_sub = "sub0"
        original_search = client._search_oauth

        async def slow_search_oauth(*args, **kwargs):
            t0 = time.monotonic()
            await asyncio.sleep(0.2)
            elapsed = time.monotonic() - t0
            client._semaphore_wait_ms += elapsed * 1000
            client._http_request_count += 1
            client._http_latency_sum += elapsed
            if client._http_latency_min == 0.0 or elapsed < client._http_latency_min:
                client._http_latency_min = elapsed
            if elapsed > client._http_latency_max:
                client._http_latency_max = elapsed

            sr = kwargs.get("subreddits", args[3] if len(args) > 3 else None)
            sr = sr[0] if sr else "__global__"
            all_posts = client._subreddit_posts.get(sr, [])
            after_param = kwargs.get("after", args[2] if len(args) > 2 else None)
            start_idx = 0
            if after_param:
                try:
                    start_idx = int(after_param.split("_")[-1])
                except (ValueError, IndexError):
                    start_idx = 0
            page = all_posts[start_idx:start_idx + 25]
            if not page:
                return [], None
            next_idx = start_idx + len(page)
            next_after = f"cursor_{next_idx}" if next_idx < len(all_posts) else None
            return page, next_after

        # Override _search_oauth to be slow for sub0 only
        original_search_oauth = client._search_oauth

        async def conditional_slow_search(query, limit, after, subreddits, mode="global"):
            if subreddits and subreddits[0] == slow_sub:
                return await slow_search_oauth(query=query, limit=limit, after=after, subreddits=subreddits, mode=mode)
            return await original_search_oauth(query=query, limit=limit, after=after, subreddits=subreddits, mode=mode)

        client._search_oauth = conditional_slow_search

        coord = SearchCoordinator(reddit_client=client)
        t0 = time.monotonic()
        items, after, has_more, metrics = await coord.execute(
            query="test", mode="local", limit=25,
            subreddits=subs,
        )
        total = time.monotonic() - t0

        print(f"\n{'='*50}")
        print(f"[BENCHMARK] 10 subs (1 slow, 200ms/pg)")
        print(f"{'='*50}")
        print(f"  Wall clock:     {total:.3f}s")
        print(f"  Coordinator:    {metrics.total_elapsed:.3f}s")
        print(f"  Workers:        {metrics.workers_completed}/{metrics.workers_failed} (ok/fail)")
        print(f"  Reddit reqs:    {metrics.total_reddit_requests}")
        print(f"  Semaphore wait: {metrics.semaphore_wait_ms:.1f}ms")
        fast_times = {k: v for k, v in metrics.per_subreddit.items() if k != slow_sub}
        if fast_times:
            print(f"  Fast subs avg:  {sum(fast_times.values())/len(fast_times):.3f}s")
        if slow_sub in metrics.per_subreddit:
            print(f"  Slow sub:       {metrics.per_subreddit[slow_sub]:.3f}s")

        assert metrics.workers_completed == 10
        assert len(items) > 0


class TestPaginationBenchmark:
    """Pagination benchmark tests — validates multi-round cursor behavior.

    Run with: pytest tests/test_benchmark_search.py::TestPaginationBenchmark -v -s
    """

    @pytest.mark.asyncio
    async def test_benchmark_pagination_two_rounds(self):
        """Two pagination rounds: round 2 skips exhausted sub, has_more correct."""
        client = LatencyFakeRedditClient(page_latency=0.01)
        client.set_posts("pics", [_make_post(str(i), "pics") for i in range(100)])
        client.set_posts("aww", [_make_post(str(i + 200), "aww") for i in range(500)])

        coord = SearchCoordinator(reddit_client=client)

        items1, after1, has_more1, m1 = await coord.execute(
            query="cat", mode="local", limit=25,
            subreddits=["pics", "aww"],
        )
        assert has_more1 is True
        reqs_round1 = m1.total_reddit_requests
        print(f"\n  Round 1: {len(items1)} items, {reqs_round1} reqs, has_more={has_more1}, "
              f"exhausted={m1.workers_exhausted}, skipped={m1.workers_skipped}")

        items2, after2, has_more2, m2 = await coord.execute(
            query="cat", mode="local", limit=25,
            subreddits=["pics", "aww"], after=after1,
        )
        print(f"  Round 2: {len(items2)} items, {m2.total_reddit_requests} reqs, "
              f"has_more={has_more2}, exhausted={m2.workers_exhausted}, skipped={m2.workers_skipped}")

        assert m2.workers_skipped == 1  # pics exhausted → skipped
        assert m2.workers_exhausted == 0  # aww still has more
        assert has_more2 is True  # aww still going
        assert len(items2) > 0
        assert reqs_round1 > m2.total_reddit_requests  # fewer reqs in round 2 (pics skipped)

    @pytest.mark.asyncio
    async def test_benchmark_pagination_until_exhausted(self):
        """Subreddits exhausted over N rounds, final round has_more=False."""
        client = LatencyFakeRedditClient(page_latency=0.01)
        # 250 posts = 10 pages × 25 per page = 10 pages, target=100
        # Round 1: pages 0-3 (100 items), rounds 2: pages 4-9 (150 items), then exhausted
        client.set_posts("fishtank", [_make_post(str(i), "fishtank") for i in range(250)])

        coord = SearchCoordinator(reddit_client=client)

        after = None
        round_num = 0
        total_items = 0
        total_reqs = 0
        final_has_more = True
        had_skip = False

        while final_has_more and round_num < 10:
            round_num += 1
            items, after, final_has_more, m = await coord.execute(
                query="fish", mode="local", limit=25,
                subreddits=["fishtank"], after=after,
            )
            total_items += len(items)
            total_reqs += m.total_reddit_requests
            if m.workers_skipped > 0:
                had_skip = True
            print(f"  Round {round_num}: {len(items)} items, {m.total_reddit_requests} reqs, "
                  f"has_more={final_has_more}, exhausted={m.workers_exhausted}, "
                  f"skipped={m.workers_skipped}")

        assert round_num == 3  # round 1: 100 items, round 2: 100 items, round 3: 50 items+exhausted
        assert final_has_more is False  # exhausted in round 3
        assert total_items == 250
        print(f"  Total: {total_items} items, {total_reqs} reqs across {round_num} rounds")

    @pytest.mark.asyncio
    async def test_benchmark_pagination_cursor_persistence(self):
        """Sentinel persists in after; frontend retry is handled safely."""
        client = LatencyFakeRedditClient(page_latency=0.01)
        client.set_posts("exhaustible", [_make_post(str(i), "exhaustible") for i in range(100)])

        coord = SearchCoordinator(reddit_client=client)

        items1, after1, has_more1, m1 = await coord.execute(
            query="test", mode="local", limit=25,
            subreddits=["exhaustible"],
        )
        print(f"  Round 1: exhausted={m1.workers_exhausted}, skipped={m1.workers_skipped}, "
              f"has_more={has_more1}, items={len(items1)}")

        # Round 2: sub exhausted since after1 has __EXHAUSTED__ sentinel
        items2, after2, has_more2, m2 = await coord.execute(
            query="test", mode="local", limit=25,
            subreddits=["exhaustible"], after=after1,
        )
        print(f"  Round 2: exhausted={m2.workers_exhausted}, skipped={m2.workers_skipped}, "
              f"has_more={has_more2}, items={len(items2)}")
        assert has_more2 is False
        assert len(items2) == 0
        assert m2.workers_skipped == 1

        # after2 persists sentinel for defensive retry handling
        assert EXHAUSTED_SENTINEL in after2

        print(f"  Total across 2 rounds: {len(items1 + items2)} items, "
              f"{m1.total_reddit_requests + m2.total_reddit_requests} reqs")

    @pytest.mark.asyncio
    async def test_benchmark_pagination_mixed_exhaustion(self):
        """Mixed subreddits: some exhaust early, some continue across rounds."""
        client = LatencyFakeRedditClient(page_latency=0.01)
        # small sub (100 posts = exhaust after 4 pages × 25 = 100 items, target=100)
        client.set_posts("small", [_make_post(str(i), "small") for i in range(100)])
        # large sub (500 posts = continues for many rounds)
        client.set_posts("large", [_make_post(str(i + 1000), "large") for i in range(500)])

        coord = SearchCoordinator(reddit_client=client)
        after = None
        round_num = 0
        results = []

        while True:
            round_num += 1
            items, after, has_more, m = await coord.execute(
                query="test", mode="local", limit=25,
                subreddits=["small", "large"], after=after,
            )
            results.append((len(items), has_more, m))
            print(f"  Round {round_num}: {len(items)} items, has_more={has_more}, "
                  f"exhausted={m.workers_exhausted}, skipped={m.workers_skipped}")
            if not has_more:
                break
            if round_num >= 10:
                break

        total = sum(r[0] for r in results)
        reqs = sum(r[2].total_reddit_requests for r in results)
        print(f"  Total: {total} items, {reqs} reqs across {round_num} rounds")

        # small exhausted in round 1 → skipped in round 2+
        assert results[0][2].workers_exhausted == 1
        assert results[1][2].workers_skipped == 1  # small skipped
        # large continues until all 500 exhausted
        final_round = results[-1]
        assert final_round[1] is False
        # total items should be ~600 (but dedup removes none since all IDs unique)
        assert total >= 500


class TestCancellationBenchmark:
    """Cancellation benchmark tests.

    Measures how quickly the coordinator stops work after cancellation,
    and how many Reddit requests are avoided.

    Run with: pytest tests/test_benchmark_search.py::TestCancellationBenchmark -v -s
    """

    @pytest.mark.asyncio
    async def test_cancel_immediate(self):
        """Scenario A: cancelled before any work starts — 0 requests."""
        from app.services.search_coordinator import SearchContext

        client = LatencyFakeRedditClient(page_latency=0.05)
        client.set_posts("pics", [_make_post(str(i), "pics") for i in range(500)])

        coord = SearchCoordinator(reddit_client=client)
        ctx = SearchContext()
        ctx.cancel()

        t0 = time.monotonic()
        items, after, has_more, metrics = await coord._execute_body(
            ctx=ctx, query="test", mode="local", limit=25,
            subreddits=["pics"],
        )
        elapsed = time.monotonic() - t0

        print(f"\n{'='*50}")
        print("[BENCHMARK] Cancel Immediate")
        print(f"{'='*50}")
        print(f"  Wall clock:      {elapsed:.4f}s")
        print(f"  Reddit requests: {metrics.total_reddit_requests}")
        print(f"  Workers cancelled: {metrics.workers_cancelled}")
        print(f"  Cancellation latency: {metrics.cancellation_latency_ms:.1f}ms")

        assert metrics.cancelled is True
        assert metrics.total_reddit_requests == 0
        assert len(items) == 0

    @pytest.mark.asyncio
    async def test_cancel_halfway(self):
        """Scenario B: cancelled mid-flight — partial requests discarded."""
        from app.services.search_coordinator import SearchContext

        client = LatencyFakeRedditClient(page_latency=0.05)
        client.set_posts("pics", [_make_post(str(i), "pics") for i in range(500)])

        coord = SearchCoordinator(reddit_client=client)
        ctx = SearchContext()

        async def run_and_cancel():
            return await coord._execute_body(
                ctx=ctx, query="test", mode="local", limit=25,
                subreddits=["pics"],
            )

        task = asyncio.create_task(run_and_cancel())
        await asyncio.sleep(0.15)  # let ~3 pages complete
        t_cancel = time.monotonic()
        ctx.cancel()
        items, after, has_more, metrics = await task
        total_elapsed = time.monotonic() - t_cancel

        print(f"\n{'='*50}")
        print("[BENCHMARK] Cancel Halfway")
        print(f"{'='*50}")
        print(f"  Wall clock:      {metrics.total_elapsed:.3f}s")
        print(f"  Workers cancelled: {metrics.workers_cancelled}")
        print(f"  Abandoned responses: {metrics.abandoned_responses}")
        print(f"  Abandoned parses: {metrics.abandoned_parses}")
        print(f"  Abandoned merges: {metrics.abandoned_merges}")
        print(f"  Cancellation latency: {metrics.cancellation_latency_ms:.1f}ms")
        print(f"  Time from cancel to return: {total_elapsed:.4f}s")

        assert metrics.cancelled is True
        assert metrics.abandoned_responses > 0
        assert len(items) == 0

    @pytest.mark.asyncio
    async def test_rapid_sequential_searches(self):
        """Scenario C: rapid search changes — only last search completes."""
        from app.services.search_coordinator import SearchContext

        client = LatencyFakeRedditClient(page_latency=0.03)
        client.set_posts("test", [_make_post(str(i), "test") for i in range(500)])

        coord = SearchCoordinator(reddit_client=client)

        # Launch 4 searches rapidly, only the last should reach completion
        tasks = []
        for i, q in enumerate(["query_a", "query_b", "query_c", "query_d"]):
            ctx = SearchContext()
            # Cancel all previous searches
            for prev_ctx, prev_task, _ in tasks:
                prev_ctx.cancel()
            task = asyncio.create_task(
                coord._execute_body(
                    ctx=ctx, query=q, mode="local", limit=25,
                    subreddits=["test"],
                )
            )
            tasks.append((ctx, task, q))
            await asyncio.sleep(0.01)

        # Let the last search complete
        last_ctx, last_task, last_q = tasks[-1]
        items, after, has_more, last_metrics = await last_task
        await asyncio.sleep(0.05)

        print(f"\n{'='*50}")
        print("[BENCHMARK] Rapid Sequential Searches")
        print(f"{'='*50}")
        for i, (ctx, task, q) in enumerate(tasks):
            cancelled = "CANCELLED" if ctx.cancelled else "COMPLETED"
            print(f"  {i}. {q}: {cancelled}")

        # Verify only the last completed (or was last to be cancelled)
        assert last_metrics.cancelled is False or last_metrics.total_raw_items > 0
        print(f"  Last search items: {len(items)}")
        print(f"  Last search requests: {last_metrics.total_reddit_requests}")

        # Verify cancelled tasks returned empty
        for ctx, task, _ in tasks[:-1]:
            if ctx.cancelled:
                try:
                    result = await asyncio.wait_for(task, timeout=1.0)
                    if result:
                        i, a, h, m = result
                        assert m.cancelled is True
                        assert len(i) == 0
                except (asyncio.TimeoutError, asyncio.CancelledError):
                    pass  # Task may have been genuinely cancelled

        print(f"  All cancelled tasks produced no final items")


class TestBenchmarkScenarioG:
    """Scenario G: Large pagination — 1 sub with 5000 posts over many rounds."""

    @pytest.mark.asyncio
    async def test_benchmark_large_pagination(self):
        """1 sub, 5000 posts, 4 pages/round (100 items), ~50 rounds to exhaust."""
        client = LatencyFakeRedditClient(page_latency=0.01)
        client.set_posts("gallery", [_make_post(str(i), "gallery") for i in range(5000)])

        coord = SearchCoordinator(reddit_client=client)
        after = None
        round_num = 0
        total_items = 0
        total_reqs = 0
        total_elapsed = 0.0

        while round_num < 60:
            round_num += 1
            t0 = time.monotonic()
            items, after, has_more, m = await coord.execute(
                query="cat", mode="local", limit=25,
                subreddits=["gallery"], after=after,
            )
            elapsed = time.monotonic() - t0
            total_items += len(items)
            total_reqs += m.total_reddit_requests
            total_elapsed += elapsed

            if round_num <= 3 or round_num % 10 == 0:
                print(f"  Round {round_num}: {len(items)} items, {m.total_reddit_requests} reqs, "
                      f"{elapsed:.3f}s, exhausted={m.workers_exhausted}, skipped={m.workers_skipped}")

            if not has_more:
                print(f"  Round {round_num}: FINAL {len(items)} items, exhausted={m.workers_exhausted}")
                break

        print(f"\n{'='*50}")
        print("[BENCHMARK] Scenario G — Large Pagination")
        print(f"{'='*50}")
        print(f"  Rounds:         {round_num}")
        print(f"  Total items:    {total_items}")
        print(f"  Total reqs:     {total_reqs}")
        print(f"  Total elapsed:  {total_elapsed:.3f}s")
        print(f"  Avg/round:      {total_elapsed/round_num:.3f}s")

        assert total_items == 5000
        assert total_reqs == 200  # 5000 posts / 25 per page = 200 page requests


class TestStressBenchmark:
    """Stress tests — boundary conditions and failure modes."""

    @pytest.mark.asyncio
    async def test_50_subreddits(self):
        """50 subreddits — concurrency boundary stress test."""
        client = LatencyFakeRedditClient(page_latency=0.02)
        subs = []
        for i in range(50):
            sub = f"sub{i}"
            subs.append(sub)
            client.set_posts(sub, [_make_post(f"{i}_{j}", sub) for j in range(50)])

        coord = SearchCoordinator(reddit_client=client)
        t0 = time.monotonic()
        items, after, has_more, metrics = await coord.execute(
            query="test", mode="local", limit=10,
            subreddits=subs,
        )
        wall = time.monotonic() - t0

        print(f"\n{'='*50}")
        print("[STRESS] 50 subreddits")
        print(f"{'='*50}")
        print(f"  Wall clock:     {wall:.3f}s")
        print(f"  Workers:        {metrics.workers_completed}/{metrics.workers_launched}")
        print(f"  Failures:       {metrics.workers_failed}")
        print(f"  Raw items:      {metrics.total_raw_items}")
        print(f"  Final items:    {metrics.total_after_dedup}")
        print(f"  Reddit reqs:    {metrics.total_reddit_requests}")
        print(f"  Semaphore wait: {metrics.semaphore_wait_ms:.1f}ms")
        print(f"  HTTP requests:  {metrics.http_request_count}")
        print(f"  HTTP latency:   avg={metrics.http_latency_sum_ms/max(metrics.http_request_count,1):.1f}ms "
              f"min={metrics.http_latency_min_ms:.1f}ms max={metrics.http_latency_max_ms:.1f}ms")

        assert metrics.workers_completed == 50
        assert metrics.total_raw_items > 0
        # Each sub with 50 posts at limit=10 → target_per_subreddit=40, so 40 per sub = 2000 raw
        assert metrics.total_raw_items >= 50 * 40

    @pytest.mark.asyncio
    async def test_empty_subreddit(self):
        """Empty subreddit — no posts, no crash, clean metrics."""
        client = LatencyFakeRedditClient(page_latency=0.01)
        client.set_posts("empty", [])
        client.set_posts("pics", [_make_post(str(i), "pics") for i in range(100)])

        coord = SearchCoordinator(reddit_client=client)
        items, after, has_more, metrics = await coord.execute(
            query="test", mode="local", limit=25,
            subreddits=["empty", "pics"],
        )

        print(f"\n{'='*50}")
        print("[STRESS] Empty subreddit + normal sub")
        print(f"{'='*50}")
        print(f"  Items:          {len(items)}")
        print(f"  Workers ok/fail: {metrics.workers_completed}/{metrics.workers_failed}")
        print(f"  Exhausted:      {metrics.workers_exhausted}")
        print(f"  Skipped:        {metrics.workers_skipped}")
        print(f"  Reddit reqs:    {metrics.total_reddit_requests}")
        print(f"  Sub times:      {metrics.per_subreddit}")

        assert len(items) >= 25  # pics has 100 posts, target=100, at least 25 items returned
        assert "empty" in metrics.per_subreddit
        assert metrics.workers_completed == 2

    @pytest.mark.asyncio
    async def test_high_latency_all_subs(self):
        """All subs have high latency (200ms/page) — simulates rate limiting."""
        client = LatencyFakeRedditClient(page_latency=0.2)
        for i in range(5):
            sub = f"sub{i}"
            client.set_posts(sub, [_make_post(f"{i}_{j}", sub) for j in range(100)])

        coord = SearchCoordinator(reddit_client=client)
        t0 = time.monotonic()
        items, after, has_more, metrics = await coord.execute(
            query="test", mode="local", limit=25,
            subreddits=[f"sub{i}" for i in range(5)],
        )
        wall = time.monotonic() - t0

        print(f"\n{'='*50}")
        print("[STRESS] High latency (200ms/pg) — rate limit simulation")
        print(f"{'='*50}")
        print(f"  Wall clock:     {wall:.3f}s")
        print(f"  Workers:        {metrics.workers_completed}/5")
        print(f"  Reddit reqs:    {metrics.total_reddit_requests}")
        print(f"  HTTP requests:  {metrics.http_request_count}")
        print(f"  HTTP latency:   avg={metrics.http_latency_sum_ms/max(metrics.http_request_count,1):.1f}ms")
        print(f"  Semaphore wait: {metrics.semaphore_wait_ms:.1f}ms")
        print(f"  Raw items:      {metrics.total_raw_items}")

        assert metrics.workers_completed == 5
        assert metrics.http_request_count > 0
        # With 5 subs and 4 pages each (target=100, 25 per page), 20 reqs total
        expected_reqs = 5 * 4
        assert metrics.total_reddit_requests == expected_reqs
        # With concurrency=5 and 200ms/pg, wall clock should be ~800ms (4 serial pages at 200ms each)
        assert wall >= expected_reqs / 5 * 0.2 * 0.5  # loose lower bound
        print(f"  Expected min:   {expected_reqs / 5 * 0.2:.1f}s (4 pages × 200ms serialized)")
