import asyncio
import json
import time
from dataclasses import dataclass, field
from typing import Optional

from .reddit_client import RedditClient, ParserStats
from ..models.schemas import MediaAssetResponse

EXECUTE_TIMEOUT = 60.0


@dataclass
class SubredditWorkerResult:
    subreddit: str
    items: list[dict]
    after_cursor: Optional[str]
    had_more: bool
    elapsed: float
    pages_scanned: int
    input_cursor: Optional[str] = None


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


DEFAULT_CONCURRENCY = 5


def _after_to_cursors(after: Optional[str]) -> dict[str, Optional[str]]:
    if not after:
        return {}
    if isinstance(after, str) and after.startswith("t"):
        return {"__global__": after}
    try:
        return json.loads(after)
    except (json.JSONDecodeError, TypeError):
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
        try:
            return await asyncio.wait_for(
                self._execute_body(query, mode, limit, subreddits, after),
                timeout=EXECUTE_TIMEOUT,
            )
        except asyncio.TimeoutError:
            metrics = SearchMetrics(start_time=0.0, end_time=time.monotonic(),
                                     overall_timed_out=True)
            print(f"[COORDINATOR_TIMEOUT] query='{query}' timeout={EXECUTE_TIMEOUT}s")
            return [], None, False, metrics

    async def _execute_body(
        self,
        query: str,
        mode: str,
        limit: int,
        subreddits: Optional[list[str]],
        after: Optional[str] = None,
    ) -> tuple[list[MediaAssetResponse], Optional[str], bool, SearchMetrics]:
        metrics = SearchMetrics(start_time=time.monotonic())

        target_per_subreddit = max(limit * 4, 100)
        after_cursors = _after_to_cursors(after)

        if mode == "local" and subreddits:
            worker_results = await self._run_workers(
                query=query,
                subreddits=subreddits,
                target=target_per_subreddit,
                after_cursors=after_cursors,
                metrics=metrics,
            )
        else:
            worker_results = await self._run_global_worker(
                query=query,
                target=target_per_subreddit,
                after_cursors=after_cursors,
                metrics=metrics,
            )

        metrics.total_raw_items = sum(len(wr.items) for wr in worker_results)

        agg_start = time.monotonic()
        deduped = self._aggregate_and_dedup(worker_results, metrics)
        metrics.aggregation_elapsed = time.monotonic() - agg_start
        metrics.total_after_dedup = len(deduped)

        all_assets = self._parse_to_response(deduped, metrics)

        new_cursors: dict[str, Optional[str]] = {}
        any_had_more = False
        for wr in worker_results:
            if wr.after_cursor is not None:
                new_cursors[wr.subreddit] = wr.after_cursor
            elif wr.had_more and wr.input_cursor is not None:
                new_cursors[wr.subreddit] = wr.input_cursor
            if wr.had_more:
                any_had_more = True

        new_after = _cursors_to_after(new_cursors)
        has_more = any_had_more

        metrics.end_time = time.monotonic()
        metrics.total_elapsed = metrics.end_time - metrics.start_time

        self._log_metrics(metrics, query)

        return all_assets, new_after, has_more, metrics

    async def _run_workers(
        self,
        query: str,
        subreddits: list[str],
        target: int,
        after_cursors: dict[str, Optional[str]],
        metrics: SearchMetrics,
    ) -> list[SubredditWorkerResult]:
        semaphore = asyncio.Semaphore(self._concurrency)
        metrics.workers_launched = len(subreddits)

        async def worker(subreddit: str) -> SubredditWorkerResult:
            w_start = time.monotonic()
            async with semaphore:
                cursor = after_cursors.get(subreddit)
                print(f"[WORKER_START] subreddit={subreddit} cursor={cursor}")

                items, after_cursor, audit = await self._client._accumulate_search(
                    query=query,
                    subreddits=[subreddit],
                    mode="local",
                    target_results=target,
                    after=cursor,
                )

                elapsed = time.monotonic() - w_start
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
                metrics.total_reddit_requests += res.pages_scanned

        return final_results

    async def _run_global_worker(
        self,
        query: str,
        target: int,
        after_cursors: dict[str, Optional[str]],
        metrics: SearchMetrics,
    ) -> list[SubredditWorkerResult]:
        cursor = after_cursors.get("__global__")
        print(f"[GLOBAL_WORKER_START] query={query} cursor={cursor}")

        items, after_cursor, audit = await self._client._accumulate_search(
            query=query,
            subreddits=None,
            mode="global",
            target_results=target,
            after=cursor,
        )

        metrics.workers_launched = 1
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
    ) -> list[dict]:
        seen_ids: set[str] = set()
        deduped: list[dict] = []
        dupes_found = 0

        for wr in worker_results:
            for item in wr.items:
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
    ) -> list[MediaAssetResponse]:
        result: list[MediaAssetResponse] = []
        parser_stats = ParserStats()

        for raw in deduped:
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

    def _log_metrics(self, metrics: SearchMetrics, query: str):
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
            f"agg_elapsed={metrics.aggregation_elapsed:.3f}s"
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
