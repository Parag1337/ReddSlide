# Search Acquisition Architecture Audit & Migration Plan

## 1. Current Search Architecture

### High-Level Data Flow

```
┌──────────────────────────────────────────────────────────────────┐
│ Flutter SearchRepository.searchReddit()                          │
│   → HTTP GET /api/search/reddit?q=...&mode=...&subreddits=...   │
└──────────────────────────┬───────────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────────┐
│ search.py: search_reddit()  [FastAPI endpoint]                   │
│   • Parses query/mode/limit/after/subreddits from query params  │
│   • Creates SearchCoordinator(reddit_client, concurrency=5)     │
│   • Calls coordinator.execute()                                 │
│   • Returns FeedResponse(items, after, has_more)                │
└──────────────────────────┬───────────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────────┐
│ SearchCoordinator.execute()                                      │
│   • Wraps _execute_body() in asyncio.wait_for(timeout=60s)     │
└──────────────────────────┬───────────────────────────────────────┘
                           │
            ┌──────────────┴──────────────┐
            │                             │
            ▼                             ▼
┌───────────────────────┐   ┌───────────────────────────┐
│ LOCAL mode            │   │ GLOBAL mode               │
│ _run_workers()        │   │ _run_global_worker()      │
└───────────┬───────────┘   └───────────┬───────────────┘
            │                           │
            ▼                           ▼
┌───────────────────────┐   ┌───────────────────────────┐
│ asyncio.gather(       │   │ Single _accumulate_search│
│   [worker(sr) ...]    │   │   (no concurrency)       │
│ )                     │   │                           │
│ Semaphore(5)          │   │ SEARCH_TIME_BUDGET = 5s  │
│ per-worker:           │   │ SEARCH_MAX_PAGES = 20    │
│   _accumulate_search  │   │                           │
│ )                     │   │                           │
└───────────┬───────────┘   └───────────┬───────────────┘
            │                           │
            └──────────────┬────────────┘
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│ _accumulate_search()  [RedditClient method]                     │
│   Sequential page loop:                                          │
│   while True:                                                    │
│     if results >= target: break                                  │
│     if pages >= 20: break                                        │
│     if time budget exceeded: break                               │
│     page_items, next_after = _search_oauth(...)                  │
│     if not page_items: break                                     │
│     filter text posts                                            │
│     filter media posts with _is_media_post()                     │
│     extend results                                               │
│     if not next_after: break                                     │
│   return (results, after_cursor, audit)                          │
└──────────────────────────────────┬────────────────────────────────┘
                                   │
┌──────────────────────────────────▼────────────────────────────────┐
│ _search_oauth()  [RedditClient method]                           │
│   • Gets OAuth token from shared OAuthManager                    │
│   • Creates httpx.AsyncClient() per call (NO reuse)             │
│   • HTTP GET to Reddit search API                                │
│   • 401 retry: refresh token, retry with new AsyncClient        │
│   • Returns raw post_data dicts, after_cursor                   │
└──────────────────────────────────┬────────────────────────────────┘
                                   │
┌──────────────────────────────────▼────────────────────────────────┐
│ Back in SearchCoordinator._execute_body()                        │
│                                                                   │
│ • _aggregate_and_dedup(worker_results)                           │
│     → seen_ids set, sort by created_utc DESC                     │
│                                                                   │
│ • _parse_to_response(deduped)                                    │
│     → runs _parse_post_pipeline() on each item                   │
│     → builds MediaAssetResponse objects                          │
│                                                                   │
│ • Build new cursors dict per-subreddit                           │
│     → encode as JSON opaque after string                         │
│                                                                   │
│ • Return (all_assets, new_after, has_more, metrics)              │
└──────────────────────────────────────────────────────────────────┘
```

### Two Parallel Search Systems

| Aspect | Live Reddit Search | Cached SQLite Search |
|--------|-------------------|---------------------|
| Endpoint | `GET /api/search/reddit` | `GET /api/search` |
| Flutter caller | `SearchRepository.searchReddit()` | `SearchRepository.search()` |
| Backend handler | `search.py:search_reddit()` | `feed.py:search()` |
| Data source | Reddit OAuth API (live) | `media_assets` table via FTS5 |
| Parser | `_parse_post_pipeline()` per item | Already parsed on ingest |
| Parallelism | Semaphore(5) for local mode | N/A (single SQL query) |
| Pagination | Opaque JSON cursor per subreddit | `page` + `offset` |
| Target used by | Slideshow **search mode** | Feed/search screens |

This audit focuses on the **live Reddit search** path (`/api/search/reddit`), as it is the performance-critical path for slideshow search.

---

## 2. Responsibility Matrix

### SearchCoordinator — `search_coordinator.py:68-382`

| Attribute | Value |
|-----------|-------|
| **Responsibility** | Orchestrate parallel/multi-subreddit search, aggregate, deduplicate, parse to response |
| **Inputs** | `query`, `mode`, `limit`, `subreddits`, `after` (opaque cursor), `RedditClient` |
| **Outputs** | `list[MediaAssetResponse]`, `after` (opaque cursor), `has_more`, `SearchMetrics` |
| **Dependencies** | `RedditClient`, `ParserStats`, `MediaAssetResponse` |
| **Thread ownership** | Single asyncio task per `execute()` call; N sub-tasks spawned for local mode via `asyncio.gather` |
| **Concurrency control** | `asyncio.Semaphore(concurrency)` — defaults to 5 |
| **State** | Stateless (created per-request) |
| **Bottleneck potential** | HIGH — serializes after gather: aggregation, parsing, cursor construction |

### ProviderManager — `provider.py:7-68`

| Attribute | Value |
|-----------|-------|
| **Responsibility** | Track provider health, failover between OAuth and Redlib |
| **Inputs** | `record_provider_success(provider)`, `record_provider_failure(provider)` |
| **Outputs** | `get_healthy_provider()` → "reddit_oauth" or "redlib" |
| **Dependencies** | None |
| **Thread ownership** | Shared singleton; `asyncio.Lock()` guards mutable state |
| **State** | `_failure_count`, `_cooldown_until` |
| **Bottleneck potential** | LOW — lock held for microseconds |
| **Note** | `_fetch_redlib` is a stub returning `[], None`. Failover effectively means empty results. |

### OAuthManager — `oauth.py:9-247`

| Attribute | Value |
|-----------|-------|
| **Responsibility** | Acquire/refresh Reddit OAuth tokens; serialize refreshes |
| **Inputs** | `client_id`, `client_secret`, `user_agent` |
| **Outputs** | `get_valid_token()` → Bearer token string |
| **Dependencies** | `httpx`, `aiosqlite` (persists token in `oauth_tokens` table) |
| **Thread ownership** | Shared singleton; `_refresh_lock` (`asyncio.Lock()`) serializes refreshes |
| **State** | `_token`, `_refresh_token_value`, `_token_id` |
| **Bottleneck potential** | LOW — token refresh is rare (~hourly). `get_valid_token()` reads DB every call (minor overhead). |
| **Note** | `get_valid_token()` reads `oauth_tokens` table every call (line 51). Two DB round-trips per search request (one in `_search_oauth` line 434, one in `_fetch_oauth` line 119). |

### RedditClient — `reddit_client.py:77-705`

| Attribute | Value |
|-----------|-------|
| **Responsibility** | HTTP communication with Reddit APIs; post parsing and validation |
| **Inputs** | `OAuthManager`, `ProviderManager` |
| **Outputs** | Parsed `MediaAsset` objects; raw post dicts for search; `ParseResult` |
| **Dependencies** | `httpx`, `OAuthManager`, `ProviderManager` |
| **Thread ownership** | Methods called by coordinator workers; no internal concurrency |
| **State** | Stateless (delegates state to OAuth/Provider managers) |
| **Bottleneck potential** | HIGH — network I/O bound; no HTTP client reuse; `_accumulate_search` is strictly sequential |

### QueueManager — `queue_manager.py:13-458`

| Attribute | Value |
|-----------|-------|
| **Responsibility** | Database CRUD for media_assets, media_queue, gallery_items; FTS5 search |
| **Inputs** | SQL queries via `get_db()` |
| **Outputs** | Lists of dicts, counts |
| **Dependencies** | `aiosqlite`, `DATABASE_PATH` |
| **Thread ownership** | Single connection per `get_db()` context manager |
| **State** | Stateless (created per-request) |
| **Bottleneck potential** | MEDIUM — FTS5 search is fast but uncached COUNT queries duplicate the scan |

### Database — `database.py`

| Attribute | Value |
|-----------|-------|
| **Responsibility** | SQLite schema; connection factory (`get_db()`) |
| **Inputs** | Connection requests |
| **Outputs** | `aiosqlite.Connection` |
| **Thread ownership** | One connection per context manager — NOT a pool |
| **State** | File-based |
| **Bottleneck potential** | MEDIUM — no connection pooling; every `get_db()` opens a new file descriptor (around 1.2ms overhead in tests) |

### Parser — `reddit_client.py:546-661`

| Attribute | Value |
|-----------|-------|
| **Responsibility** | Convert raw Reddit post dict → `MediaAsset` with validation |
| **Inputs** | Raw post dict |
| **Outputs** | `ParseResult(asset or rejection_reason)` |
| **Dependencies** | `MediaAsset` model |
| **Thread ownership** | Called synchronously in `_parse_to_response()` (single-threaded after gather) |
| **State** | Stateless |
| **Bottleneck potential** | LOW — CPU-bound but fast (~0.0001s per post in tests). Memory allocations for gallery extraction are non-trivial for gallery posts. |

---

## 3. Search Flow Audit — Per-Stage Analysis

### Stage 1: HTTP Request — `search.py:20-70`

```
Lines 20-70, search.py
```

- **Parallelism**: Single HTTP request, single asyncio task.
- **Deserialization**: `FeedResponse` Pydantic model on response.
- **Overhead**: ~0.1ms for FastAPI routing + parameter parsing.

### Stage 2: Coordinator Dispatch — `search_coordinator.py:80-156`

```
Line 80:  async def execute(...)
Line 89:  return await asyncio.wait_for(self._execute_body(...), timeout=EXECUTE_TIMEOUT)
Line 112: if mode == "local" and subreddits:
Line 113:     worker_results = await self._run_workers(...)
Line 121:     worker_results = await self._run_global_worker(...)
```

- **Decision point**: `mode == "local"` branches to `_run_workers()` or `_run_global_worker()`.
- **Timeout**: 60s global timeout wraps everything.
- **Overhead**: ~0.01ms (pure Python dispatch).

### Stage 3: Worker Launch — `search_coordinator.py:157-218`

```python
Line 165: semaphore = asyncio.Semaphore(self._concurrency)  # defaults to 5
Line 170: async with semaphore:
Line 174:     items, after_cursor, audit = await self._client._accumulate_search(...)
Line 198: tasks = [worker(sr) for sr in subreddits]
Line 199: results = await asyncio.gather(*tasks, return_exceptions=True)
```

- **Concurrency model**: All N tasks created eagerly (line 198), semaphore limits concurrent execution to 5.
- **Key insight**: `asyncio.gather` with `return_exceptions=True` means ALL tasks start immediately. A slow subreddit blocks the semaphore slot but does NOT block other tasks from running when slots free up.
- **Problem**: When subreddit count > 5, subreddits 6+ wait until a slot opens. With 20 subreddits: first 5 run immediately, then as each finishes, the next starts. Total wall time = sum of slowest 5 / 5 + the rest, roughly bounded by max individual worker time × ceil(N/5).
- **Cancellation**: `asyncio.gather` does NOT cancel remaining tasks when one fails or when overall timeout hits. If the outer `wait_for` times out, tasks are cancelled, BUT Reddit HTTP requests in flight are NOT cancelled (httpx does not support per-request cancellation).

### Stage 4: Sequential Page Accumulation — `reddit_client.py:341-405`

```python
Line 357: while True:
Line 358:     if len(results) >= target_results: break
Line 360:     if pages_scanned >= SEARCH_MAX_PAGES: break       # 20 pages max
Line 362:     if time.monotonic() - start_time > SEARCH_TIME_BUDGET_SECONDS: break  # 5s budget
Line 365:     page_items, next_after = await self._search_oauth(...)
```

- **This is the critical bottleneck**: Each subreddit worker runs a **strictly sequential** page loop.
- Target results = `max(limit * 4, 100)` (line 109). At 25 items/page and 5s budget, typical workers fetch 1-4 pages before hitting time or target.
- **Time budget per worker**: 5 seconds shared across ALL pages for that worker. Workers that hit 5s early return partial results.
- **No per-page timeout**: `_search_oauth` has a 15s client timeout, but a single slow page within the 5s budget can starve remaining pages.

### Stage 5: HTTP Reddit Request — `reddit_client.py:425-510`

```python
Line 434: token = await self.oauth.get_valid_token()  # DB read every call
Line 453: async with httpx.AsyncClient(timeout=httpx.Timeout(15.0)) as client:
Line 454:     response = await client.get(url, headers={...}, params=params)
```

- **HTTP client**: NEW `httpx.AsyncClient` PER REQUEST. No connection pooling. TCP/TLS handshake every time.
- **Token acquisition**: Reads OAuth token from DB every call (line 434 via `get_valid_token()`). Two DB round trips per HTTP request — one here and one inside `get_valid_token()` for the stored token check.
- **Timeout**: 15s per request, no connect timeout separate from total timeout.
- **Error handling**: Timeout/connect errors caught (line 462), recorded to provider failure, returns empty.

### Stage 6: Response Parsing + Filtering — `reddit_client.py:372-382` (per-page)

```python
Line 378: text_items = [item for item in page_items if not self._extract_preview_url(item)]
Line 381: media_items = [item for item in page_items if self._is_media_post(item)]
```

- **Two passes** over the same list: one for text post detection, one for media post detection. These could be combined.
- `_extract_preview_url()` and `_is_media_post()` do overlapping work (both check URL, preview, gallery, video patterns).

### Stage 7: Aggregation + Deduplication — `search_coordinator.py:256-279`

```python
Line 261: seen_ids: set[str] = set()
Line 265: for wr in worker_results:
Line 266:     for item in wr.items:
Line 267:         pid = item.get("id")
Line 268:         if pid is None: deduped.append(item); continue
Line 271:         if pid in seen_ids: dupes_found += 1; continue
Line 274:         seen_ids.add(pid); deduped.append(item)
Line 278: deduped.sort(key=lambda x: x.get("created_utc", 0), reverse=True)
```

- `O(N)` in total items across all workers.
- Items without `id` bypass dedup — this is a correctness gap for some edge cases.
- Sort is `O(N log N)` but N is typically small (< 2000 items).
- **Bottleneck**: negligible (< 1ms for realistic N).

### Stage 8: Final Parsing to Response — `search_coordinator.py:281-348`

```python
Line 289: for raw in deduped:
Line 291:     parse_result = self._client._parse_post_pipeline(raw)
```

- Runs `_parse_post_pipeline()` on EVERY deduped item. The same items were already parsed once by `_search_oauth` → `_parse_reddit_response`. However, the `_accumulate_search` path returns RAW dicts (line 510), so parsing was NOT done during accumulation. Only `_search_oauth`'s final path parses; the accumulation path does NOT parse.
- Wait — let me re-read this. `_search_oauth` returns `raw_items` (lists of dicts from `child.get("data", {})` at line 489/508). These are **unparsed** raw post dicts. The actual `_parse_post_pipeline` happens only in `_parse_to_response` (line 291) and in `_parse_reddit_response` (line 187), which is only used by `fetch_subreddit_media` (feed path), NOT the search path.
- **So parsing happens only once** per item, in `_parse_to_response`. This is correct but means all parsing CPU time is in this single-threaded loop after all network I/O is done.

### Stage 9: Cursor Encoding — `search_coordinator.py:137-148`

```python
Line 137: new_cursors: dict[str, Optional[str]] = {}
Line 139: for wr in worker_results:
Line 140:     if wr.after_cursor is not None:
Line 141:         new_cursors[wr.subreddit] = wr.after_cursor
Line 142:     elif wr.had_more and wr.input_cursor is not None:
Line 143:         new_cursors[wr.subreddit] = wr.input_cursor
Line 147: new_after = _cursors_to_after(new_cursors)
```

- `had_more` is True when `after_cursor is not None` (line 192).
- If a worker returned 0 items and `after_cursor` is None, but `had_more` was set in the exception path (line 209: `had_more=True`), then the `input_cursor` is reused.
- `_cursors_to_after` JSON-encodes the dict → opaque string.
- **Bottleneck**: negligible.

### Stage 10: Response Serialization — `search.py:66-70`

```python
Line 66: return FeedResponse(items=items, after=new_after, has_more=has_more)
```

- Pydantic model serialization to JSON.
- `items` is `list[MediaAssetResponse]`. Serialization time scales with item count.
- **Bottleneck**: LOW (< 5ms for 100 items).

---

## 4. Worker Model Audit

### How many simultaneous Reddit requests?

- **Local mode**: Up to `concurrency` (default 5) simultaneous `_search_oauth` requests. Each worker acquires the semaphore once for its entire `_accumulate_search` duration (multiple sequential pages), then releases it. At any moment, at most 5 concurrent HTTP requests to Reddit.
- **Global mode**: Exactly 1 sequential `_accumulate_search`. No parallelism.
- **Total possible**: 5 concurrent requests.

### Task scheduling

- Tasks are created eagerly in a list comprehension (line 198) and passed to `asyncio.gather`.
- The semaphore gates entry to the `_accumulate_search` call inside each worker.
- Within each worker, pages are sequential — no further parallelism.

### Worker reuse

- **None**. Workers are one-shot: each is a single `_accumulate_search` call that fetches multiple pages for one subreddit. After the worker coroutine completes, the subreddit has no more worker activity for this request.

### Request cancellation

- **In the gather**: When `return_exceptions=True`, exceptions from one worker do NOT cancel others. A failing subreddit (network error, timeout) returns an exception result while others continue.
- **At the coordinator level**: The outer `asyncio.wait_for(timeout=60)` cancels the entire `_execute_body` coroutine, which cancels the gather. However, `httpx.AsyncClient` HTTP calls in flight are NOT pre-emptively cancelled — they continue until completion or their own 15s timeout.
- **No cancellation propagation**: There is no mechanism to cancel in-flight HTTP requests when results are already sufficient or when a worker's 5s budget is exhausted.

### Can slow subreddits block fast ones?

- **Yes, partially**. With semaphore(5) and 20 subreddits, the 5 fastest subreddits start immediately. Each holds the semaphore for its entire `_accumulate_search` duration (multiple pages). A subreddit with many pages or slow responses keeps a semaphore slot occupied. The 6th+ subreddit waits until any slot opens.
- **No head-of-line blocking**: Because all 5 slots can be used by any worker, a single slow worker doesn't block all others. It blocks one slot. The other 4 continue.
- **Total wall time with N subreddits**: `max(worker_time[0..N-1])` for the slowest worker in the batch that its slot executes. With semaphore(5), the expected wall time is roughly `max(worker_time[0..4]) + max(worker_time[5..9]) + ...` only if workers are perfectly serialized by the semaphore. In practice, if subreddits have similar response times, all 20 can complete in ~4 batches.

---

## 5. Pagination Audit

### Cursor Types

| Cursor Type | Format | Used By | Lifetime |
|-------------|--------|---------|----------|
| Single subreddit `after` | Reddit's opaque `t3_xxx` string | Reddit API response | Per-page, returned from `_search_oauth` |
| Multi-subreddit after | JSON dict: `{"subreddit1": "t3_xxx", "subreddit2": null}` | Opaque cursor returned to Flutter | Returns from `search_reddit` endpoint, consumed by next request |
| Legacy format | Reddit `t3_xxx` string directly | `_after_to_cursors` detects by `startswith("t")` | Read once, converted to dict internally |

### Local mode pagination

1. Flutter passes opaque `after` string from previous response.
2. `_after_to_cursors()` decodes JSON → `{subreddit: cursor}` dict.
3. Each worker looks up `after_cursors.get(subreddit)` for its initial cursor.
4. Worker calls `_accumulate_search(after=cursor)` → fetches pages starting from that cursor.
5. Each page updates the internal `current_after` cursor.
6. After all workers complete, `_execute_body()` builds `new_cursors` dict:
   - If worker returned a new `after_cursor`, use it.
   - Else if worker had_more and had an input_cursor, reuse input_cursor.
   - This means a worker that returned 0 new results but previously had a cursor gets the SAME cursor on the next request — it will re-fetch the same exhausted page.
7. `_cursors_to_after()` JSON-encodes → opaque string.

### Global mode pagination

1. Single `_run_global_worker()` with `__global__` key.
2. `_accumulate_search` fetches pages from Reddit's global `/search` endpoint.
3. Cursor is Reddit's native `after` parameter.
4. Stored in `__global__` key of the cursors dict.

### Page-one reload issue

- **Every new search** starts with `after=None` → no cursors → workers start from page 1.
- This is correct for new queries but wasteful for pagination *within the same query*.
- Currently, Flutter sends `after` from previous response. The backend correctly resumes.
- **No unnecessary page-one reload** when `after` is properly passed.
- **Edge case**: If a worker returns `0 items, after_cursor=None, input_cursor="t3_xxx"` and `had_more=True` (from exception path line 209), the next request will reuse `input_cursor`. This preserves the cursor for retry.

### Resume behavior

- Cursors are ephemeral — they exist only in the request/response cycle. No server-side cursor state.
- If Flutter loses the cursor (e.g., app restart), the search starts over from page 1. This is acceptable for a mobile app.

---

## 6. SearchCoordinator Audit — Responsibility Assessment

### Current responsibilities

| Responsibility | Belongs Here? | Notes |
|---------------|--------------|-------|
| Parse query/mode/limit params | No | Should be in endpoint handler (already is) |
| Dispatch local vs global workers | Yes | Natural orchestration point |
| Create worker tasks | Yes | Core coordination |
| Bound concurrency | Yes | Semaphore is appropriate |
| Aggregate worker results | Yes | Single point of merge |
| Deduplicate across subreddits | Yes | Cross-subreddit scope |
| Sort results | Debatable | Could be pushed to consumer |
| Parse raw posts → MediaAssetResponse | **No** | This should happen upstream (during accumulation) |
| Track per-subreddit latency | Marginal | Metrics concern, not orchestration |
| Build opaque cursor | Yes | Requires state from all workers |
| Log metrics | Marginal | Should be logging layer, not coordinator |
| Timeout enforcement | Yes | But should propagate cancellation to HTTP |
| Exception handling per worker | Yes | `return_exceptions=True` pattern is correct |

### Responsibilities that belong elsewhere

1. **`_parse_to_response`** — Post parsing should happen during `_accumulate_search`, not in a separate post-hoc loop. Currently `_search_oauth` returns raw dicts, and `_parse_to_response` re-parses them. Instead, `_search_oauth` (or better, `_accumulate_search`) should parse inline and return `MediaAsset` objects. This would:
   - Eliminate the second O(N) parse loop.
   - Allow early rejection of non-media posts during accumulation (already done with `_is_media_post`, but full parsing adds more rejection categories).
   - Reduce memory: raw dicts are larger than `MediaAsset` objects.

2. **Metrics logging** — The `_log_metrics` method (`search_coordinator.py:350-382`) mixes logging with orchestration. This is acceptable for now but should eventually use a structured logging system.

---

## 7. Bottleneck Report

### Bottleneck Rankings

| Rank | Bottleneck | Type | Evidence | Impact |
|------|-----------|------|----------|--------|
| **1** | **No HTTP client reuse** — NEW `httpx.AsyncClient()` per Reddit request | Network | `reddit_client.py:453`, `reddit_client.py:126`, `reddit_client.py:473` | ~2-5ms TCP+TLS handshake overhead per request. With 20 subreddits × 1-4 pages each = 20-80 requests, this adds 40-400ms of pure handshake overhead. |
| **2** | **Sequential page loop** — `_accumulate_search` fetches pages one at a time with no parallel page fetching | Synchronization | `reddit_client.py:357-405` | Each page is an HTTP round trip (~200-500ms). With 4 pages per worker, a subreddit takes 800-2000ms sequentially. Pages could be fetched in parallel within a subreddit. |
| **3** | **No HTTP request cancellation** — `httpx.AsyncClient` requests cannot be cancelled mid-flight | Synchronization | `search_coordinator.py:89-92`, httpx docs | When a worker's 5s budget expires, the current HTTP request continues until its 15s timeout. With 20 subreddits, this can waste significant server time. |
| **4** | **DB round-trips for token on every request** — `get_valid_token()` reads DB every call | Database | `oauth.py:51`, called from `reddit_client.py:434`, `reddit_client.py:119` | Two DB queries per HTTP request. With 80 requests, that's 160+ DB queries for token management alone. Token is cached in memory but `get_valid_token()` still queries DB to check expiry. |
| **5** | **Two-pass filtering in _accumulate_search** — separate loops for text removal and media filtering | CPU | `reddit_client.py:378-381` | Each item is visited twice with overlapping checks. Minor but unnecessary. |
| **6** | **Parsing happens in single-threaded loop after gather** | CPU | `search_coordinator.py:289` | All items parsed sequentially after all network I/O. This is the final step before response — it adds latency that cannot overlap with anything. |
| **7** | **workers_launched set to len(subreddits) before semaphore** | Measurement | `search_coordinator.py:166` | Metrics may be inaccurate for timed-out/cancelled scenarios, but not a performance bottleneck. |
| **8** | **FTS5 COUNT query duplicates the scan** | Database | `queue_manager.py:249-254` | The COUNT query in FTS5 search has the same WHERE clause as the main SELECT. SQLite scans the FTS index twice. Only applies to the cached search path (`/api/search`), NOT the live search path. |

### Network Bottlenecks (Rank 1, 2, 3)

The primary bottleneck is network I/O. Reddit's API latency dominates (200-500ms per request). The current architecture:
- Fetches pages sequentially per subreddit (can't overlap)
- Creates new TCP connections per request (can't reuse)
- Cannot cancel in-flight requests (wasteful on timeout)
- With 20 subreddits × 4 pages = 80 sequential HTTP requests, worst-case wall time = 80 × 500ms = 40s (before the 60s timeout).

### CPU Bottlenecks (Rank 5, 6)

CPU bottlenecks are secondary. `_parse_post_pipeline` is ~0.0001s per post. For 2000 items, that's ~0.2s — not significant but happens at the end when the user is already waiting.

### Synchronization Bottlenecks (Rank 2, 3)

The semaphore(5) limits concurrency, which is correct for rate limiting. The real issue is that each worker holds the semaphore for MULTIPLE sequential pages. A better model would acquire the semaphore per-page, allowing more interleaving.

### Database Bottlenecks (Rank 4)

OAuth token reads on every request are unnecessary. The token is in memory; expiry can be checked in-memory rather than with a DB query.

---

## 8. Resource Usage

### Concurrent Reddit Requests

- Maximum: 5 (semaphore bound).
- Typical: 1-5 depending on subreddit count and mode.

### HTTP Client Reuse

- **None**. `httpx.AsyncClient()` is created per-call in `_search_oauth` (line 453) and `_fetch_oauth` (line 126). Also for 401 retry (line 473, 139).
- Each `AsyncClient` creates a new connection pool (default pool_limits=100). These are garbage collected after the context manager exits.

### Memory During Search

- Raw post dicts: ~1-2KB per post. 2000 posts ≈ 2-4MB.
- Worker results list: ~8 bytes per reference overhead.
- `seen_ids` set: ~50 bytes per unique ID. 1000 IDs ≈ 50KB.
- `MediaAssetResponse` objects: ~500 bytes each. 100 items ≈ 50KB.
- **Total**: ~5-10MB per search request. Acceptable.

### Database Access During Search

- `get_valid_token()` reads `oauth_tokens` table (1 query).
- `_get_stored_token()` reads `oauth_tokens` table inside `get_valid_token()` (1 query — total 2 per request).
- Search path does NOT write to database during live search (writes happen via `fetch_and_store` in the feed/refresh path).

---

## 9. Scalability Review

### 1 subreddit

- **Local mode**: 1 worker, 1 semaphore slot. Sequential pages. Best case: 1-4 pages in 0.2-2s.
- **Global mode**: 1 worker, sequential pages. Same as local.
- **No issues**: Architecture is optimal for single subreddit.

### 5 subreddits

- All 5 workers start immediately (semaphore=5). Sequential pages per worker.
- At peak: 5 concurrent HTTP requests to Reddit.
- Reddit rate limit: ~60 req/min for OAuth apps. 5 concurrent × 4 pages = 20 requests in ~5s. Well within limits.
- **Acceptable**: Good utilization.

### 20 subreddits

- 5 run immediately, 15 wait in the semaphore queue.
- At peak: still 5 concurrent requests, but total wall time = ~4 batches of slowest subreddit.
- Each batch: workers hold semaphore for entire `_accumulate_search` (1-4 pages, ~0.5-2s each). Total wall time: 4 × 2s = 8s best case, 4 × 5s (time budget) = 20s worst case.
- HTTP connections: 20-80 total, each with new TCP handshake.
- **Degraded**: Linear scaling with batches. No benefit from having more than 5 subreddits — the extra ones just wait in the queue.

### 100 subreddits (stress scenario)

- 5 concurrent at a time, 95 in queue.
- 20 batches of ~5 subreddits each.
- Each batch takes ~0.5-5s → total wall time: 10-100s.
- Will hit the 60s coordinator timeout for many requests.
- HTTP connections: 100-400 with no reuse.
- **Unusable**: Architecture breaks down. The semaphore model does not scale beyond `concurrency` subreddits per batch. For 100 subreddits, the bottleneck is the sequential batching, not the network.

### Architectural Limit

The fundamental limit is the **semaphore-per-worker** pattern where one worker = one subreddit = multiple sequential pages. This means:
- Subreddit count > concurrency → requests are batched, increasing wall time linearly.
- Subreddit count is unbounded from the API perspective (frontend can request any number).
- There is no mechanism to prioritize or deduplicate subreddits.
- The only defense is the 60s coordinator timeout.

---

## 10. Cancellation Review

### Can searches be cancelled?

**At the coordinator level**: Yes, via `asyncio.wait_for(timeout=60)`. After 60 seconds, `_execute_body` is cancelled, which cancels the `asyncio.gather`.

**At the HTTP level**: **No**. `httpx.AsyncClient.get()` does not support cancellation by coroutine cancellation. The TCP connection remains open until the response is received or the 15s timeout expires.

**At the Flutter level**: No explicit cancellation mechanism. The `SearchRepository.searchReddit()` returns a Future; cancelling the Future does not cancel the backend request.

### Are cancelled Reddit requests stopped?

- When the coordinator timeout fires, the `asyncio.CancelledError` propagates through `_execute_body` → `_run_workers` → `worker()` → `_accumulate_search` → `_search_oauth`.
- At each `await` point, the coroutine is cancelled. But `httpx.AsyncClient.get()` is a synchronous-style await that does not check for cancellation mid-request.
- The HTTP request continues on the server side until Reddit responds or the 15s httpx timeout fires.
- The response, when received, is discarded because the coroutine is already cancelled.

### Is unnecessary work continued after cancellation?

- **Yes**. Workers that completed before the timeout have their results processed (aggregation, dedup, parsing). These results are discarded if the cancel fires before response serialization, but the CPU work was already done.
- **Yes at the HTTP level**: In-flight requests continue until response or 15s timeout.

---

## 11. Metrics Review

### Existing Metrics

| Metric | Location | Type | Persistence |
|--------|----------|------|-------------|
| `SearchMetrics.total_elapsed` | `search_coordinator.py:151` | Float (seconds) | Printed, not stored |
| `SearchMetrics.workers_launched` | `search_coordinator.py:166` | Int | Printed |
| `SearchMetrics.workers_completed` | `search_coordinator.py:214` | Int | Printed |
| `SearchMetrics.workers_failed` | `search_coordinator.py:205` | Int | Printed |
| `SearchMetrics.total_raw_items` | `search_coordinator.py:128` | Int | Printed |
| `SearchMetrics.duplicates_removed` | `search_coordinator.py:277` | Int | Printed |
| `SearchMetrics.filtered_out_after_parse` | `search_coordinator.py:346` | Int | Printed |
| `SearchMetrics.total_after_dedup` | `search_coordinator.py:133` | Int | Printed |
| `SearchMetrics.aggregation_elapsed` | `search_coordinator.py:132` | Float | Printed |
| `SearchMetrics.total_reddit_requests` | `search_coordinator.py:216` | Int | Printed |
| `SearchMetrics.overall_timed_out` | `search_coordinator.py:96` | Bool | Printed |
| `SearchMetrics.per_subreddit` | `search_coordinator.py:183` | Dict[str, float] | Printed |
| `ParserStats` (13 fields) | `search_coordinator.py:347` | Int counters | Printed |

### Missing Metrics

| Missing Metric | Why Needed |
|----------------|-----------|
| Per-page HTTP latency | To distinguish network latency from parsing overhead |
| Per-worker HTTP count | To know how many pages each subreddit consumed |
| HTTP connection reuse count | To verify the impact of missing connection pooling |
| Token acquisition latency | To quantify DB read overhead |
| Semaphore wait time | To measure contention when subreddit count > concurrency |
| Response serialization time | To measure Pydantic overhead |
| Time-to-first-result | To know when the first items are available (progressive rendering potential) |

---

## 12. Phased Migration Plan

### Phase 6.1.2 — SearchCoordinator Cleanup

**Goal**: No behavior changes. Improve code clarity, remove dead paths, fix metrics.

**Changes**:
1. Remove `workers_launched = len(subreddits)` before semaphore (move after gather for accuracy).
2. Combine `_extract_preview_url` + `_is_media_post` into a single pass.
3. Move `_parse_to_response` logic into `_accumulate_search` so parsing happens during accumulation (reduces memory and eliminates second O(N) loop).
4. Add per-page timing to `SearchAuditResult`.

**Rollback**: Revert each file individually. No dependency between changes.

### Phase 6.1.3 — HTTP Client Pool

**Goal**: Reuse HTTP connections across Reddit requests within the same search.

**Changes**:
1. Create a shared `httpx.AsyncClient` instance in `RedditClient` (or inject from coordinator).
2. Reuse it across all `_search_oauth` calls within a request.
3. Close on coordinator completion.

**Risks**: Connection pool limits could cause head-of-line blocking. Test with 20 subreddits.

**Rollback**: Revert `RedditClient.__init__` to create per-instance clients.

### Phase 6.1.4 — Bounded Concurrency (Per-Page)

**Goal**: Allow more interleaved concurrency by acquiring the semaphore per-page instead of per-worker.

**Changes**:
1. Move `async with semaphore` from wrapping `_accumulate_search` to wrapping `_search_oauth` inside the page loop.
2. Maintain an accounting of per-subreddit page budgets.

**Risks**: Could increase total concurrent HTTP requests to Reddit. Must verify Reddit rate limits (60 req/min, ~1 req/s sustained for OAuth client credentials; higher for app-only tokens).

**Rollback**: Revert to per-worker semaphore.

### Phase 6.1.5 — Pagination Improvements

**Goal**: Eliminate redundant page fetches and improve cursor stability.

**Changes**:
1. Fix the `had_more` edge case where empty result + stale cursor causes re-fetch of exhausted page.
2. Add a `reddit_id`-based dedup across pages within `_accumulate_search` (currently dedup only across subreddits, not across pages of the same subreddit).

**Rollback**: Revert cursor logic changes. Remove dedup extension.

### Phase 6.1.6 — Cancellation

**Goal**: Stop in-flight HTTP requests on timeout or when results are sufficient.

**Changes**:
1. Replace `httpx` with `aiohttp` (which supports per-request cancellation) or use `asyncio.timeout()` with `httpx.AsyncClient` (httpx 0.28+ supports `asyncio.timeout`).
2. Add result-sufficient check during `_accumulate_search` — if the total aggregated results across all workers already meet the target, cancel remaining workers.
3. Cancel in-flight HTTP requests when a worker's 5s budget or the coordinator's 60s timeout fires.

**Risks**: High — replaces HTTP library. Must be tested thoroughly.

**Rollback**: Switch back to `httpx`.

### Phase 6.1.7 — Metrics

**Goal**: Expose structured metrics for monitoring and tuning.

**Changes**:
1. Add `per_page_latency`, `per_page_items`, `semaphore_wait_time` fields to `SearchMetrics`.
2. Expose metrics via a new `/api/metrics/search` endpoint or log in structured JSON.
3. Add token acquisition latency and DB read count tracking.

**Rollback**: Revert metrics additions. Remove endpoint.

### Phase 6.1.8 — Benchmarks

**Goal**: Baseline performance numbers for the optimized pipeline.

**Changes**:
1. Add pytest benchmarks for:
   - 1 subreddit, 5 subreddits, 20 subreddits, 100 subreddits.
   - Global mode.
   - With and without HTTP mocking (respx).
   - Token acquisition overhead.
2. Track in CI.

**Rollback**: Revert test file additions.

---

## 13. Rollback Plan Summary

| Phase | Rollback Strategy |
|-------|-------------------|
| 6.1.2 | Revert individual file changes. Each is independent. |
| 6.1.3 | Revert `RedditClient.__init__` to create per-call `AsyncClient`. |
| 6.1.4 | Move `async with semaphore` back around `_accumulate_search`. |
| 6.1.5 | Revert `_accumulate_search` cursor logic. Remove per-page dedup. |
| 6.1.6 | Revert to `httpx`. Revert cancellation logic. |
| 6.1.7 | Revert metrics fields and endpoints. |
| 6.1.8 | Revert benchmark test files. |

Each phase is independently revertible. No phase depends on a previous phase for rollback safety.

---

## 14. Validation Report

### No production code behavior changed in this audit phase

| Concern | Status |
|---------|--------|
| API contracts modified? | No — this phase is read-only |
| Request/response formats changed? | No |
| SearchCoordinator behavior changed? | No |
| MergeEngine changed? | No |
| Frontend changed? | No |
| Pagination behavior changed? | No |
| Parallel workers implemented? | No |
| Streaming implemented? | No |
| Caching implemented? | No |
| Ranking changes? | No |
| Any code written? | No — this file is documentation only |

This phase produced zero code changes. All findings are observational and documented in this file.

---

## 15. Key Findings Summary

1. **No HTTP connection pooling** is the #1 bottleneck. Each Reddit request creates a new TCP/TLS connection.
2. **Sequential page fetching** per subreddit is #2. Pages for the same subreddit cannot overlap even though they are independent.
3. **No HTTP-level cancellation** wastes resources on timed-out requests.
4. **DB reads for token on every request** add unnecessary overhead (160+ queries for a 20-subreddit search).
5. **OAuth token is re-read from DB** in `get_valid_token()` even though it's cached in memory.
6. **Semaphore(5) is reasonable** for current Reddit rate limits but breaks down at 20+ subreddits.
7. **100 subreddits would be unusable** with the current architecture — the 60s timeout would fire before most workers complete.
8. **Parser CPU time is negligible** (0.2ms per 100 items) — not worth optimizing.
9. **Metrics are print-only** with no structured logging or persistence.
10. **Two search systems** coexist (live Reddit vs cached SQLite) with different endpoints and pagination models.
