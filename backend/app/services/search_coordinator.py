import asyncio
import json
import time
import uuid
from dataclasses import dataclass, field
from typing import Optional

from .reddit_client import RedditClient, ParserStats
from ..models.schemas import MediaAssetResponse

EXECUTE_TIMEOUT = 60.0
EXHAUSTED_SENTINEL = "__EXHAUSTED__"


@dataclass
class SearchContext:
    """Lightweight search lifecycle context.

    Created per execute() call, passed through the entire search pipeline.
    Workers and pipeline stages check `cancelled` before starting new work.
    After cancellation, in-flight operations continue to their next safe
    point and then exit without processing results.
    """
    search_id: str = field(default_factory=lambda: uuid.uuid4().hex[:8])
    cancelled: bool = False
    _cancel_time: float = 0.0

    def cancel(self):
        self.cancelled = True
        self._cancel_time = time.monotonic()

    @property
    def cancellation_latency_ms(self) -> float:
        if self._cancel_time == 0.0:
            return 0.0
        return (time.monotonic() - self._cancel_time) * 1000


@dataclass
class SubredditWorkerResult:
    subreddit: str
    items: list[dict]
    after_cursor: Optional[str]
    had_more: bool
    elapsed: float
    pages_scanned: int
    input_cursor: Optional[str] = None
    cancelled: bool = False


@dataclass
class SearchMetrics:
    start_time: float = 0.0
    end_time: float = 0.0
    total_elapsed: float = 0.0
    workers_launched: int = 0
    workers_completed: int = 0
    workers_failed: int = 0
    worker_timeouts: int = 0
    total_raw_items: int = 0
    duplicates_removed: int = 0
    posts_lost_in_aggregation: int = 0
    total_after_dedup: int = 0
    aggregation_elapsed: float = 0.0
    filtered_out_after_parse: int = 0
    per_subreddit: dict[str, float] = field(default_factory=dict)
    total_reddit_requests: int = 0
    overall_timed_out: bool = False
    parser: ParserStats = field(default_factory=ParserStats)
    semaphore_wait_ms: float = 0.0
    workers_exhausted: int = 0
    workers_skipped: int = 0
    cancelled: bool = False
    workers_cancelled: int = 0
    abandoned_responses: int = 0
    abandoned_parses: int = 0
    abandoned_merges: int = 0
    cancellation_latency_ms: float = 0.0
    # HTTP-level instrumentation (copied from RedditClient)
    http_request_count: int = 0
    http_failure_count: int = 0
    http_latency_sum_ms: float = 0.0
    http_latency_min_ms: float = 0.0
    http_latency_max_ms: float = 0.0
    json_parse_sum_ms: float = 0.0
    oauth_lookup_sum_ms: float = 0.0
    # Pipeline-stage timing
    response_serialization_elapsed: float = 0.0
    pagination_elapsed: float = 0.0


DEFAULT_CONCURRENCY = 5


def _after_to_cursors(after: Optional[str]) -> dict[str, Optional[str]]:
    if not after:
        return {}
    # Try JSON decode first — covers dict and rejects primitives/arrays
    try:
        decoded = json.loads(after)
        if isinstance(decoded, dict):
            validated: dict[str, Optional[str]] = {}
            for k, v in decoded.items():
                if isinstance(k, str) and (v is None or isinstance(v, str)):
                    validated[k] = v
            return validated
        return {}
    except (json.JSONDecodeError, TypeError):
        pass
    # Fall back to legacy Reddit base36 cursor format
    if after.startswith("t"):
        return {"__global__": after}
    return {}


def _cursors_to_after(cursors: dict[str, Optional[str]]) -> Optional[str]:
    if not cursors:
        return None
    cleaned = {k: v for k, v in cursors.items() if v is not None}
    if not cleaned:
        return None
    return json.dumps(cleaned)


class SearchCoordinator:
    """Orchestrates parallel Reddit search with bounded concurrency,
    centralized aggregation, deduplication, and per-subreddit pagination."""

    def __init__(
        self,
        reddit_client: RedditClient,
        concurrency: int = DEFAULT_CONCURRENCY,
    ):
        self._client = reddit_client
        self._concurrency = concurrency

    async def execute(
        self,
        query: str,
        mode: str,
        limit: int,
        subreddits: Optional[list[str]],
        after: Optional[str] = None,
    ) -> tuple[list[MediaAssetResponse], Optional[str], bool, SearchMetrics]:
        ctx = SearchContext()
        try:
            return await asyncio.wait_for(
                self._execute_body(ctx, query, mode, limit, subreddits, after),
                timeout=EXECUTE_TIMEOUT,
            )
        except asyncio.CancelledError:
            ctx.cancel()
            metrics = self._build_cancelled_metrics(ctx, query)
            print(f"[COORDINATOR_CANCEL] query='{query}' id={ctx.search_id} "
                  f"latency={metrics.cancellation_latency_ms:.1f}ms "
                  f"cancelled_workers={metrics.workers_cancelled}")
            return [], None, False, metrics
        except asyncio.TimeoutError:
            ctx.cancel()
            metrics = self._build_cancelled_metrics(ctx, query)
            metrics.overall_timed_out = True
            print(f"[COORDINATOR_TIMEOUT] query='{query}' timeout={EXECUTE_TIMEOUT}s "
                  f"id={ctx.search_id}")
            return [], None, False, metrics

    def _build_cancelled_metrics(
        self, ctx: SearchContext, query: str
    ) -> SearchMetrics:
        metrics = SearchMetrics(
            start_time=0.0,
            end_time=time.monotonic(),
            cancelled=True,
            cancellation_latency_ms=ctx.cancellation_latency_ms,
        )
        return metrics

    async def _execute_body(
        self,
        ctx: SearchContext,
        query: str,
        mode: str,
        limit: int,
        subreddits: Optional[list[str]],
        after: Optional[str] = None,
    ) -> tuple[list[MediaAssetResponse], Optional[str], bool, SearchMetrics]:
        metrics = SearchMetrics(start_time=time.monotonic())

        if ctx.cancelled:
            return self._empty_result(ctx, metrics, query)

        target_per_subreddit = max(limit * 4, 100)
        after_cursors = _after_to_cursors(after)
        # Reset client-level instrumentation
        self._client._semaphore_wait_ms = 0.0
        self._client._http_request_count = 0
        self._client._http_failure_count = 0
        self._client._http_latency_sum = 0.0
        self._client._http_latency_min = 0.0
        self._client._http_latency_max = 0.0
        self._client._json_parse_sum = 0.0
        self._client._oauth_lookup_sum = 0.0

        if mode == "local" and subreddits:
            worker_results = await self._run_workers(
                ctx=ctx,
                query=query,
                subreddits=subreddits,
                target=target_per_subreddit,
                after_cursors=after_cursors,
                metrics=metrics,
            )
        else:
            worker_results = await self._run_global_worker(
                ctx=ctx,
                query=query,
                target=target_per_subreddit,
                after_cursors=after_cursors,
                metrics=metrics,
            )

        metrics.total_raw_items = sum(len(wr.items) for wr in worker_results)
        metrics.semaphore_wait_ms = self._client._semaphore_wait_ms
        # Copy HTTP instrumentation from client
        metrics.http_request_count = self._client._http_request_count
        metrics.http_failure_count = self._client._http_failure_count
        metrics.http_latency_sum_ms = self._client._http_latency_sum * 1000
        metrics.http_latency_min_ms = self._client._http_latency_min * 1000
        metrics.http_latency_max_ms = self._client._http_latency_max * 1000
        metrics.json_parse_sum_ms = self._client._json_parse_sum * 1000
        metrics.oauth_lookup_sum_ms = self._client._oauth_lookup_sum * 1000

        if ctx.cancelled:
            metrics.cancelled = True
            metrics.end_time = time.monotonic()
            metrics.total_elapsed = metrics.end_time - metrics.start_time
            if ctx._cancel_time > 0:
                metrics.cancellation_latency_ms = (time.monotonic() - ctx._cancel_time) * 1000
            self._log_metrics(metrics, query)
            return [], None, False, metrics

        agg_start = time.monotonic()
        deduped = self._aggregate_and_dedup(worker_results, metrics, ctx)
        metrics.aggregation_elapsed = time.monotonic() - agg_start
        metrics.total_after_dedup = len(deduped)

        ser_start = time.monotonic()
        all_assets = self._parse_to_response(deduped, metrics, ctx)
        metrics.response_serialization_elapsed = time.monotonic() - ser_start

        pag_start = time.monotonic()
        new_cursors: dict[str, Optional[str]] = {}
        any_had_more = False
        for wr in worker_results:
            if wr.after_cursor is not None:
                new_cursors[wr.subreddit] = wr.after_cursor
            elif wr.had_more and wr.input_cursor is not None:
                new_cursors[wr.subreddit] = wr.input_cursor
            elif wr.pages_scanned > 0:
                new_cursors[wr.subreddit] = EXHAUSTED_SENTINEL
                metrics.workers_exhausted += 1
            elif wr.input_cursor == EXHAUSTED_SENTINEL:
                new_cursors[wr.subreddit] = EXHAUSTED_SENTINEL
            if wr.had_more:
                any_had_more = True

        new_after = _cursors_to_after(new_cursors)
        has_more = any_had_more
        metrics.pagination_elapsed = time.monotonic() - pag_start

        metrics.end_time = time.monotonic()
        metrics.total_elapsed = metrics.end_time - metrics.start_time

        self._log_metrics(metrics, query)

        return all_assets, new_after, has_more, metrics

    def _empty_result(
        self, ctx: SearchContext, metrics: SearchMetrics, query: str
    ) -> tuple[list[MediaAssetResponse], Optional[str], bool, SearchMetrics]:
        metrics.end_time = time.monotonic()
        metrics.total_elapsed = 0.0
        metrics.cancelled = True
        metrics.cancellation_latency_ms = ctx.cancellation_latency_ms
        self._log_metrics(metrics, query)
        return [], None, False, metrics

    async def _run_workers(
        self,
        ctx: SearchContext,
        query: str,
        subreddits: list[str],
        target: int,
        after_cursors: dict[str, Optional[str]],
        metrics: SearchMetrics,
    ) -> list[SubredditWorkerResult]:
        """Launch per-subreddit workers.

        Cancellation (6.1.5):
          Each worker checks ctx.cancelled before starting work and after
          _accumulate_search returns. If cancelled mid-flight, stale results
          from _accumulate_search are discarded. Workers exit cleanly without
          waiting for new pages.
        """
        metrics.workers_launched = len(subreddits)

        async def worker(subreddit: str) -> SubredditWorkerResult:
            w_start = time.monotonic()
            cursor = after_cursors.get(subreddit)

            if cursor == EXHAUSTED_SENTINEL:
                metrics.workers_skipped += 1
                metrics.per_subreddit[subreddit] = 0.0
                return SubredditWorkerResult(
                    subreddit=subreddit, items=[], after_cursor=None,
                    had_more=False, elapsed=0.0, pages_scanned=0,
                    input_cursor=EXHAUSTED_SENTINEL,
                )

            if ctx.cancelled:
                metrics.workers_cancelled += 1
                metrics.per_subreddit[subreddit] = 0.0
                return SubredditWorkerResult(
                    subreddit=subreddit, items=[], after_cursor=None,
                    had_more=False, elapsed=0.0, pages_scanned=0,
                    input_cursor=cursor, cancelled=True,
                )

            print(f"[WORKER_START] subreddit={subreddit} cursor={cursor}")

            items, after_cursor, audit = await self._client._accumulate_search(
                query=query,
                subreddits=[subreddit],
                mode="local",
                target_results=target,
                after=cursor,
                ctx=ctx,
            )

            elapsed = time.monotonic() - w_start

            # If cancelled during accumulation, discard stale results
            if ctx.cancelled:
                metrics.workers_cancelled += 1
                metrics.abandoned_responses += audit.pages_scanned
                print(f"[WORKER_CANCEL] subreddit={subreddit} "
                      f"items_discarded={len(items)} pages={audit.pages_scanned}")
                return SubredditWorkerResult(
                    subreddit=subreddit, items=[], after_cursor=None,
                    had_more=False, elapsed=elapsed, pages_scanned=0,
                    input_cursor=cursor, cancelled=True,
                )

            metrics.per_subreddit[subreddit] = elapsed

            print(f"[WORKER_FINISH] subreddit={subreddit} items={len(items)} "
                  f"cursor={after_cursor} elapsed={elapsed:.2f}s")

            return SubredditWorkerResult(
                subreddit=subreddit,
                items=items,
                after_cursor=after_cursor,
                had_more=after_cursor is not None,
                elapsed=elapsed,
                pages_scanned=audit.pages_scanned,
                input_cursor=cursor,
            )

        tasks = [worker(sr) for sr in subreddits]
        results = await asyncio.gather(*tasks, return_exceptions=True)

        final_results: list[SubredditWorkerResult] = []
        for sr, res in zip(subreddits, results):
            if isinstance(res, Exception):
                print(f"[WORKER_FAIL] subreddit={sr} error={res}")
                metrics.workers_failed += 1
                cursor = after_cursors.get(sr)
                final_results.append(
                    SubredditWorkerResult(
                        subreddit=sr, items=[], after_cursor=None, had_more=True,
                        elapsed=0.0, pages_scanned=0, input_cursor=cursor,
                    )
                )
            else:
                metrics.workers_completed += 1
                final_results.append(res)
                if not res.cancelled:
                    metrics.total_reddit_requests += res.pages_scanned

        return final_results

    async def _run_global_worker(
        self,
        ctx: SearchContext,
        query: str,
        target: int,
        after_cursors: dict[str, Optional[str]],
        metrics: SearchMetrics,
    ) -> list[SubredditWorkerResult]:
        cursor = after_cursors.get("__global__")

        if ctx.cancelled:
            metrics.workers_launched = 1
            metrics.workers_cancelled = 1
            return [
                SubredditWorkerResult(
                    subreddit="__global__", items=[], after_cursor=None,
                    had_more=False, elapsed=0.0, pages_scanned=0,
                    input_cursor=cursor, cancelled=True,
                )
            ]

        print(f"[GLOBAL_WORKER_START] query={query} cursor={cursor}")

        items, after_cursor, audit = await self._client._accumulate_search(
            query=query,
            subreddits=None,
            mode="global",
            target_results=target,
            after=cursor,
            ctx=ctx,
        )

        metrics.workers_launched = 1

        if ctx.cancelled:
            metrics.workers_cancelled = 1
            metrics.abandoned_responses += audit.pages_scanned
            print(f"[GLOBAL_WORKER_CANCEL] query={query} items_discarded={len(items)}")
            return [
                SubredditWorkerResult(
                    subreddit="__global__", items=[], after_cursor=None,
                    had_more=False, elapsed=0.0, pages_scanned=0,
                    input_cursor=cursor, cancelled=True,
                )
            ]

        metrics.workers_completed = 1
        metrics.total_reddit_requests = audit.pages_scanned

        print(f"[GLOBAL_WORKER_FINISH] items={len(items)} cursor={after_cursor}")

        return [
            SubredditWorkerResult(
                subreddit="__global__",
                items=items,
                after_cursor=after_cursor,
                had_more=after_cursor is not None,
                elapsed=0.0,
                pages_scanned=audit.pages_scanned,
                input_cursor=cursor,
            )
        ]

    def _aggregate_and_dedup(
        self,
        worker_results: list[SubredditWorkerResult],
        metrics: SearchMetrics,
        ctx: Optional[SearchContext] = None,
    ) -> list[dict]:
        seen_ids: set[str] = set()
        deduped: list[dict] = []
        dupes_found = 0
        stopped = False

        for wr in worker_results:
            if stopped:
                break
            if wr.cancelled:
                continue
            for item in wr.items:
                if ctx and ctx.cancelled:
                    metrics.abandoned_merges += 1
                    stopped = True
                    break
                pid = item.get("id")
                if pid is None:
                    deduped.append(item)
                    continue
                if pid in seen_ids:
                    dupes_found += 1
                    continue
                seen_ids.add(pid)
                deduped.append(item)

        metrics.duplicates_removed = dupes_found
        deduped.sort(key=lambda x: x.get("created_utc", 0), reverse=True)
        return deduped

    def _parse_to_response(
        self,
        deduped: list[dict],
        metrics: SearchMetrics,
        ctx: Optional[SearchContext] = None,
    ) -> list[MediaAssetResponse]:
        result: list[MediaAssetResponse] = []
        parser_stats = ParserStats()

        for raw in deduped:
            if ctx and ctx.cancelled:
                metrics.abandoned_parses += 1
                break
            parser_stats.total += 1
            parse_result = self._client._parse_post_pipeline(raw)
            if parse_result.accepted:
                asset = parse_result.asset
                parser_stats.accepted += 1
                if asset.is_gallery:
                    parser_stats.galleries += 1
                elif asset.is_video:
                    parser_stats.videos += 1
                else:
                    parser_stats.images += 1
                if raw.get("crosspost_parent"):
                    parser_stats.crossposts += 1

                gallery_urls = None
                if hasattr(asset, "_gallery_items") and asset._gallery_items:
                    gallery_urls = [item["url"] for item in asset._gallery_items]
                result.append(
                    MediaAssetResponse(
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
                        quality_score=asset.quality_score,
                        width=asset.width,
                        height=asset.height,
                        duration=asset.duration,
                        created_utc=asset.created_utc,
                        gallery_urls=gallery_urls,
                    )
                )
            else:
                parser_stats.rejected += 1
                reason = parse_result.rejection_reason
                if reason == "deleted_or_removed_post":
                    parser_stats.deleted += 1
                elif reason == "missing_media_url":
                    parser_stats.missing_url += 1
                elif reason == "thumbnail_url":
                    parser_stats.thumbnail_url += 1
                elif reason == "below_minimum_resolution":
                    parser_stats.small_resolution += 1
                elif reason == "gallery_has_no_valid_items" or reason == "gallery_missing_media_metadata":
                    parser_stats.broken_gallery += 1
                elif reason == "video_post_missing_reddit_video_data":
                    parser_stats.missing_video_data += 1
                else:
                    parser_stats.unsupported += 1

        metrics.filtered_out_after_parse = parser_stats.rejected
        metrics.parser = parser_stats
        return result

    def _raw_to_response(self, raw: dict) -> Optional[MediaAssetResponse]:
        """Convert a single raw Reddit post dict to MediaAssetResponse."""
        parse_result = self._client._parse_post_pipeline(raw)
        if not parse_result.accepted:
            return None
        asset = parse_result.asset
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
            quality_score=asset.quality_score,
            width=asset.width,
            height=asset.height,
            duration=asset.duration,
            created_utc=asset.created_utc,
            gallery_urls=gallery_urls,
        )

    @staticmethod
    def _build_context(query: str) -> SearchContext:
        """Build a SearchContext for progressive search coordination."""
        return SearchContext()

    def _log_metrics(self, metrics: SearchMetrics, query: str):
        cancellation = ""
        if metrics.cancelled:
            cancellation = (f" CANCELLED latency={metrics.cancellation_latency_ms:.1f}ms "
                           f"cancelled_w={metrics.workers_cancelled} "
                           f"abandoned_resp={metrics.abandoned_responses} "
                           f"abandoned_parse={metrics.abandoned_parses} "
                           f"abandoned_merge={metrics.abandoned_merges}")
        http_pct = ""
        if metrics.http_latency_sum_ms > 0 and metrics.total_elapsed > 0:
            http_pct = f" http_pct={metrics.http_latency_sum_ms / (metrics.total_elapsed * 1000) * 100:.0f}%"
        print(
            f"[COORDINATOR] query='{query}' "
            f"workers={metrics.workers_completed}/{metrics.workers_launched} "
            f"failures={metrics.workers_failed} "
            f"raw={metrics.total_raw_items} "
            f"dupes_removed={metrics.duplicates_removed} "
            f"filtered_after_parse={metrics.filtered_out_after_parse} "
            f"final={metrics.total_after_dedup - metrics.filtered_out_after_parse} "
            f"reddit_requests={metrics.total_reddit_requests} "
            f"elapsed={metrics.total_elapsed:.2f}s "
            f"agg_elapsed={metrics.aggregation_elapsed:.3f}s "
            f"sem_wait={metrics.semaphore_wait_ms:.1f}ms "
            f"exhausted={metrics.workers_exhausted} "
            f"skipped={metrics.workers_skipped}"
            f"{http_pct}"
            f"{cancellation}"
            f"{' TIMED_OUT' if metrics.overall_timed_out else ''}"
        )
        p = metrics.parser
        if p.total > 0:
            print(
                f"[PARSER] total={p.total} accepted={p.accepted} rejected={p.rejected} "
                f"images={p.images} galleries={p.galleries} videos={p.videos} "
                f"crossposts={p.crossposts} avg={p.avg_parse_time:.4f}s"
            )
            reasons = []
            if p.deleted: reasons.append(f"deleted={p.deleted}")
            if p.missing_url: reasons.append(f"missing_url={p.missing_url}")
            if p.thumbnail_url: reasons.append(f"thumbnail={p.thumbnail_url}")
            if p.small_resolution: reasons.append(f"small_res={p.small_resolution}")
            if p.broken_gallery: reasons.append(f"broken_gallery={p.broken_gallery}")
            if p.missing_video_data: reasons.append(f"missing_video={p.missing_video_data}")
            if p.unsupported: reasons.append(f"unsupported={p.unsupported}")
            if reasons:
                print(f"[REJECTION] {' '.join(reasons)}")
        for sr, el in metrics.per_subreddit.items():
            print(f"  [{sr}] elapsed={el:.2f}s")
        if metrics.http_request_count > 0:
            avg_ms = metrics.http_latency_sum_ms / metrics.http_request_count
            print(f"[HTTP] requests={metrics.http_request_count} "
                  f"failures={metrics.http_failure_count} "
                  f"latency_avg={avg_ms:.1f}ms "
                  f"latency_min={metrics.http_latency_min_ms:.1f}ms "
                  f"latency_max={metrics.http_latency_max_ms:.1f}ms "
                  f"json_parse={metrics.json_parse_sum_ms:.1f}ms "
                  f"oauth_lookup={metrics.oauth_lookup_sum_ms:.1f}ms")
        if metrics.response_serialization_elapsed > 0:
            print(f"[SERIALIZE] elapsed={metrics.response_serialization_elapsed:.4f}s")
        if metrics.pagination_elapsed > 0:
            print(f"[PAGINATION] elapsed={metrics.pagination_elapsed:.4f}s")
