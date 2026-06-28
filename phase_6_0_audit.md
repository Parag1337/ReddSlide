# Phase 6.0 — Backend Search Architecture Audit (Pre-Optimization Blueprint)

## Objective

This is an **engineering audit only**. No code changes were made during the audit.

The frontend slideshow architecture is frozen after Phase 5.7I. Future gains come from backend acquisition speed.

The audit was conducted before Phase 6.0 stability fixes (see `backend.md` Phase 6.0 section for stability changes). This document contains only the architectural analysis and optimization roadmap for later phases.

## Deliverable 1: Current Architecture Diagram

```
User Request
    │
    ▼
┌──────────────────────────────────────────────────────────────────────┐
│  FastAPI Router Layer                                                 │
│                                                                       │
│  /api/search/reddit            /api/feed               /api/search    │
│  (live Reddit search)          (SQLite cache)          (FTS5 cache)  │
│                                                                       │
│  search_coordinator.py:        feed.py:                feed.py:       │
│  SearchCoordinator.execute()   get_feed()              search()       │
└──────────────────┬──────────────────────┬──────────────────────┬───────┘
                   │                      │                      │
                   ▼                      ▼                      │
┌─────────────────────────────┐  ┌─────────────────────┐        │
│  SearchCoordinator           │  │  QueueManager        │        │
│                             │  │                      │        │
│  _run_workers()             │  │  get_subreddit_      │        │
│    asyncio.gather(5 max)    │  │  assets()            │        │
│    ┌───┐ ┌───┐ ┌───┐       │  │  (cursor pagination) │        │
│    │ w1│ │ w2│ │ w3│...    │  │                      │        │
│    └─┬─┘ └─┬─┘ └─┬─┘       │  │  ensure_subreddit_   │        │
│      │     │     │          │  │  has_content()       │        │
│      ▼     ▼     ▼          │  │  (on-demand Reddit) │        │
│  ┌─────────────────────┐    │  └────────┬─────────────┘        │
│  │  RedditClient        │    │           │                      │
│  │                     │    │           ▼                      ▼
│  │  _accumulate_search()│    │  ┌──────────────────────────────────┐
│  │  (sequential loop)  │    │  │  QueueManager.search()            │
│  │                     │    │  │                                   │
│  │  _search_oauth()    │    │  │  FTS5 MATCH query                 │
│  │  (httpx per page)   │    │  │  (SQLite, no Reddit calls)        │
│  └─────────────────────┘    │  └──────────────────────────────────┘
│                             │
│  _aggregate_and_dedup()     │
│  (seen_ids set, sort utc)   │
│                             │
│  _parse_to_response()       │
│  (parse_post_pipeline)      │
└─────────────────────────────┘
```

### Request Lifecycle: `/api/search/reddit` (Live Search)

```
search_reddit() handler
  ├── _get_reddit_client()       → OAuthManager + ProviderManager + RedditClient
  ├── coordinator = SearchCoordinator(client, concurrency=5)
  ├── coordinator._client.oauth.initialize()   → load token from SQLite
  └── coordinator.execute(query, mode, limit, subreddits, after)
        ├── wrapped in asyncio.wait_for(EXECUTE_TIMEOUT=60s)
        │
        ├── Local mode + subreddits:
        │     └── _run_workers()
        │           ├── asyncio.Semaphore(5)
        │           ├── Per-subreddit worker → _accumulate_search()
        │           │     └── Sequential page loop (up to 20 pages, 5s budget)
        │           │           └── _search_oauth() → httpx.AsyncClient().get()
        │           │                 timeout=15.0s, no connection pooling
        │           └── asyncio.gather(return_exceptions=True)
        │
        ├── _aggregate_and_dedup()  → seen_ids set, sort by created_utc DESC
        │
        └── _parse_to_response()
              └── _parse_post_pipeline() → 10-step validation pipeline
```

### Request Lifecycle: `/api/feed` (SQLite Cache)

```
get_feed() handler
  ├── Reject if multiple subreddits (HTTP 400)
  ├── QueueManager.get_subreddit_assets(subreddit, limit, after_cursor)
  │     └── SQL: SELECT ... WHERE subreddit=? AND (created_utc < ? OR ...)
  │           ORDER BY created_utc DESC, reddit_id DESC LIMIT ?
  │
  ├── If empty AND first page AND single subreddit:
  │     └── ensure_subreddit_has_content() → on-demand Reddit fetch (blocks response)
  │           └── RedditClient.fetch_subreddit_media() → OAuth → store → re-query
  │
  ├── _enrich_with_gallery_urls()
  └── Return FeedResponse
```

### Request Lifecycle: `/api/search` (FTS5 Local)

```
search() handler
  └── QueueManager.search(q, limit, offset, subreddits, media_type, sort)
        └── SQL: SELECT FROM media_assets WHERE reddit_id IN (
              SELECT reddit_post_id FROM media_search WHERE media_search MATCH ?
            ) [filters] ORDER BY quality_score DESC LIMIT ? OFFSET ?
```

---

## Deliverable 2: Bottleneck Ranking

Ranked from highest impact to lowest:

### #1 — Sequential page accumulation within workers (HIGHEST IMPACT)

**What:** Each worker calls `_accumulate_search()` which loops page-by-page: fetch one page (25 results), validate, filter, check if enough media found, then fetch next page. This is inherently sequential within a single subreddit.

**Why it hurts:** If subreddit A has many text posts, the accumulation loop may need 10-20 pages to find 100 media items. Each page takes ~500-1500ms. The frontend waits for ALL workers to finish before getting ANY results.

**Impact:** 5-15 seconds added to every multi-subreddit search.

**File:** `reddit_client.py` `_accumulate_search()` lines 485+, `_search_oauth()` line 569+

### #2 — No streaming response

**What:** Results are accumulated entirely in memory before returning. The frontend waits for the slowest worker to complete before seeing any results.

**Why it hurts:** If 4 subreddits finish in 3 seconds and a 5th takes 12 seconds, the user sees a 12-second blank loading state.

**Impact:** Perceived latency = max(worker times), not min or p50.

### #3 — No request-level cache for live search

**What:** Every `/api/search/reddit` call makes fresh HTTP requests to Reddit. Identical queries in quick succession hit Reddit N times instead of being served from a TTL cache.

**Why it hurts:** The FTS5 `/api/search` endpoint is cached but `/api/search/reddit` is not. Users often search the same query multiple times while browsing results.

**Impact:** 100% Reddit request redundancy for repeated queries.

**File:** `search.py` — no cache layer exists.

### #4 — No connection pooling

**What:** `_search_oauth()` creates a new `httpx.AsyncClient()` for every single Reddit API call. DNS resolution and TLS handshake are repeated each time.

**Why it hurts:** Each new client ≈ 100-300ms overhead for DNS + TLS before any data is transferred. With up to 100 Reddit requests per search (5 workers × 20 pages), this overhead adds up to 10-30 seconds of wasted time.

**Impact:** 100-300ms per request × up to 100 requests = 10-30s cumulative overhead.

**File:** `reddit_client.py:597` — `async with httpx.AsyncClient(timeout=httpx.Timeout(15.0)) as client:`

### #5 — Background refill fetches one subreddit per 60s

**What:** `BackgroundRefreshService._refresh_job()` runs every 60 seconds, queries all subreddits below 300 assets, sorts by count ascending, and fetches **only the lowest** subreddit. With 20 subreddits below threshold, the lowest one gets refilled every 60s, meaning each subreddit is refreshed every ~20 minutes on average.

**Why it hurts:** Users browsing a specific subreddit may hit the end of cached content and trigger the synchronous `ensure_subreddit_has_content()` path, blocking the feed response for seconds.

**Impact:** O(n) refill rate instead of O(1) — scales poorly with subreddit count.

**File:** `background_service.py` — single subreddit per tick.

### #6 — `return_exceptions=True` silences errors completely

**What:** Worker exceptions are caught, logged, and replaced with empty results. The frontend receives no indication that a subreddit failed. The user sees empty results for that subreddit.

**Why it hurts:** A transient network error or rate limit on one subreddit silently produces no results for that subreddit. The user cannot distinguish "no content exists" from "temporarily unavailable."

**Impact:** User confusion on partial failures. No retry mechanism for failed workers.

**File:** `search_coordinator.py:199` — `results = await asyncio.gather(*tasks, return_exceptions=True)`

### #7 — `_fetch_redlib` is a stub

**What:** When OAuth fails, the fallback provider `redlib` calls `_fetch_redlib()` which returns `([], None)` — a hardcoded empty response.

**Why it hurts:** Any provider failure (rate limit, token expiry, network issue) becomes a total data loss for that request. There is no real fallback.

**Impact:** Any Reddit OAuth issue = zero search results.

**File:** `reddit_client.py` — `_fetch_redlib()` stub.

### #8 — No rate limiting protection

**What:** A single search request can generate up to 100+ Reddit API calls in a few seconds (5 workers × up to 20 pages each). There is no client-side rate limiting or Reddit API rate limit awareness.

**Why it hurts:** Exceeding Reddit's rate limit (600 requests per 10 minutes for OAuth) causes subsequent requests (from other users or the background service) to fail.

**Impact:** Cascading rate-limit failures affecting all users after one aggressive search.

**Files:** `search_coordinator.py:157` — semaphore bounds concurrency but not total requests.

### #9 — Duplicate `_search_local_multi` dedup code path

**What:** `reddit_client.py` line 470 has a second `_search_local_multi()` method with its own local dedup loop. This method is **not called** by the coordinator (which calls `_accumulate_search` directly), but is retained for backward compatibility. Dead code that adds maintenance burden.

**Impact:** None currently, but dead code is a maintenance risk.

**File:** `reddit_client.py` line 470.

### #10 — OAuthManager initialized per request, not shared

**What:** Each API request that needs Reddit access creates its own `OAuthManager`, loads the token from SQLite, and checks expiry. This duplicates the token-load query on every request.

**Impact:** Small (~5ms per request) but unnecessary SQLite load.

**Files:** `search.py:14`, `queue_manager.py:391`, `background_service.py`.

---

## Deliverable 3: Concurrency Analysis

### Current Model

| Aspect | Detail |
|--------|--------|
| **Server** | Single `uvicorn` process, async event loop |
| **Search parallelism** | `asyncio.Semaphore(5)` + `asyncio.gather()` — 5 workers max |
| **Within-worker parallelism** | None — sequential page-by-page accumulation |
| **Background refill** | 1 subreddit per 60s, no parallelism |
| **Async client** | `httpx.AsyncClient()` — created per-request, not pooled |
| **Database** | `aiosqlite` — single async connection per `get_db()` context |

### Strengths

- Worker-level parallelism is genuine async concurrency (5 requests in flight)
- Failed workers do not block healthy workers (`return_exceptions=True`)
- Semaphore prevents overwhelming Reddit with >5 simultaneous connections
- Per-subreddit cursor tracking enables resumption across pagination boundaries

### Weaknesses

- Within-worker sequential page accumulation is the #1 latency driver
- No partial result streaming — all workers must finish before any response
- No connection pooling (new client per request = DNS + TLS overhead)
- Background refill is fundamentally O(n) per subreddit count
- No cancellation propagation — if the user navigates away, the coordinator continues fetching

### Recommended Model

```
┌─────────────────────────────────────────────────┐
│  SearchCoordinator                                │
│                                                   │
│  1. Fan-out: launch all subreddit workers         │
│     concurrently (semaphore-bounded)              │
│                                                   │
│  2. Within each worker:                           │
│     ┌─────────────────────────────────────────┐   │
│     │  Stream results back as they arrive     │   │
│     │  (SSE or WebSocket, or buffered batches)│   │
│     └─────────────────────────────────────────┘   │
│                                                   │
│  3. Aggregator:                                   │
│     ├── Dedup in real-time as items arrive        │
│     ├── Push deduped items downstream             │
│     └── No sorting requirement (frontend handles) │
│                                                   │
│  4. Background:                                   │
│     └── Parallel refill with per-subreddit rate   │
│         limiting instead of single-subreddit      │
│         sequential sweep                          │
└─────────────────────────────────────────────────┘
```

Key changes:
- **Stream results** instead of batch-accumulate
- **Shared httpx client** with connection pooling
- **Parallel background refill** with subreddit concurrency limit
- **Optional cancellation** via `asyncio.CancelledError` propagation

---

## Deliverable 4: Pagination Review

### Current Pagination Mechanisms

| Endpoint | Method | Format | Strength | Weakness |
|----------|--------|--------|----------|----------|
| `/api/feed` | Cursor-based on `(created_utc, reddit_id)` | `"<utc>,<id>"` | Keyset pagination is stable (no phantom rows), fast on indexed columns | Single-subreddit only; multi-sub rejected |
| `/api/search/reddit` | JSON-encoded per-subreddit Reddit cursors | `'{"pics":"t3_abc","aww":"t3_def"}'` | Each subreddit resumes independently; opaque to frontend | Reddit cursors can expire; JSON encoding is hacky |
| `/api/search` (FTS5) | Offset-based `(page, limit)` | integer offset | Simple implementation | Offset-based pagination is unstable on large datasets; `total` count query is expensive on SQLite |

### Strengths
- Feed cursor is deterministic and stable (no row shift issues)
- Per-subreddit cursors enable independent worker resumption
- Frontend treats `after` as opaque, so encoding format changes are non-breaking

### Weaknesses
- No cursor for multi-subreddit feed (frontend must manage per-subreddit cursors itself via MergeEngine)
- FTS5 offset pagination queries `COUNT(*)` on every request (expensive on large tables)
- Search Reddit cursors are opaque Reddit-format strings that can go stale
- No pagination timeout — if a worker stalls mid-pagination, the cursor is lost

---

## Deliverable 5: Search Pipeline Review

### Stage-by-Stage Timing (estimate)

| Stage | Est. Time | % of Total | Notes |
|-------|-----------|-----------|-------|
| **OAuth initialize** | ~5ms | <1% | SQLite read, token check — negligible |
| **Subreddit worker creation** | ~1ms | <1% | Task creation + semaphore acquire |
| **Reddit API call (per page)** | ~500-1500ms | 50-70% | HTTP request to oauth.reddit.com. Dominant cost. 5 workers × 10 pages = 50 calls × 1s = 50s wall-clock (parallelized to ~10s with semaphore) |
| **Within-worker page accumulation** | ~5-50ms per page | 5-10% | JSON parsing, media extraction, validation |
| **Aggregation + dedup** | ~1-5ms | <1% | Hash set insertion, sort — negligible |
| **Parse to response** | ~10-50ms per item | 5-10% | `_parse_post_pipeline()` for each accepted item |
| **Serialization** | ~5-10ms | <1% | Pydantic model construction + JSON serialization |

### Key Findings

1. **Reddit API latency dominates** (50-70% of total time). A single page fetch takes 500-1500ms depending on Reddit's server response time, network, and result complexity.

2. **Within-worker accumulation is sequential** — each page must complete before the next begins. With 10 pages per subreddit, each worker takes 5-15 seconds.

3. **Parsing overhead scales with results**, not with pages. Most of the "parse" time is spent in `_parse_post_pipeline()` which applies 10 validation rules per post. With 100-400 posts parsed per search, this adds 10-50ms.

4. **The search pipeline is CPU-light, I/O-heavy**. There is almost no local computation cost — the bottleneck is exclusively Reddit API response time.

---

## Deliverable 6: Future Architecture (Target)

```
┌──────────────────────────────────────────────────────────────────┐
│                    TARGET BACKEND ARCHITECTURE                     │
│                                                                   │
│  ┌──────────────┐                                                 │
│  │  API Router   │                                                 │
│  └──────┬───────┘                                                 │
│         │                                                          │
│         ▼                                                          │
│  ┌──────────────────────────────────────────────────┐             │
│  │  SearchCoordinator                                 │             │
│  │                                                    │             │
│  │  ┌──────────────────┐    ┌──────────────────┐     │             │
│  │  │  Query Router    │───▶│  Worker Pool     │     │             │
│  │  │  (parse params,  │    │  (bounded async  │     │             │
│  │  │   decode cursors)│    │   workers)       │     │             │
│  │  └──────────────────┘    └────────┬─────────┘     │             │
│  │                                    │                │             │
│  │                                    ▼                │             │
│  │  ┌──────────────────┐    ┌──────────────────┐     │             │
│  │  │  Rate Limiter    │◀───│  Streaming        │     │             │
│  │  │  (respect Reddit │    │  Aggregator       │     │             │
│  │  │   limits)        │    │  (dedup in real-  │     │             │
│  │  └──────────────────┘    │   time, push as   │     │             │
│  │                           │   they arrive)    │     │             │
│  │                           └────────┬─────────┘     │             │
│  │                                    │                │             │
│  │                                    ▼                │             │
│  │  ┌──────────────────────────────────────────────┐  │             │
│  │  │  Response Builder                             │  │             │
│  │  │  (parse + validate + build MediaAssetResponse)│  │             │
│  │  └──────────────────────────────────────────────┘  │             │
│  └──────────────────────────────────────────────────┘             │
│                                                                   │
│  ┌──────────────────────────────────────────────────┐             │
│  │  Cache Layer (in-memory TTL)                      │             │
│  │  ┌────────────┐ ┌──────────┐ ┌────────────────┐  │             │
│  │  │ Reddit API │ │ Subreddit│ │  Search        │  │             │
│  │  │ Response   │ │ Feed     │ │  Results       │  │             │
│  │  │ Cache (30s)│ │ Cache    │ │  Cache (120s)  │  │             │
│  │  └────────────┘ └──────────┘ └────────────────┘  │             │
│  └──────────────────────────────────────────────────┘             │
│                                                                   │
│  ┌──────────────────────────────────────────────────┐             │
│  │  Background Refill Service                        │             │
│  │  ┌─────────────────────────────────────────────┐ │             │
│  │  │  Parallel per-subreddit refill (max 3       │ │             │
│  │  │  concurrent) with TTL-aware scheduling      │ │             │
│  │  │  instead of round-robin sweep               │ │             │
│  │  └─────────────────────────────────────────────┘ │             │
│  └──────────────────────────────────────────────────┘             │
│                                                                   │
│  ┌──────────────────────────────────────────────────┐             │
│  │  Shared httpx.AsyncClient (connection pool)       │             │
│  │  ┌─────────────────────────────────────────────┐ │             │
│  │  │  Single client instance for all API calls   │ │             │
│  │  │  → connection reuse, DNS cache, TLS reuse  │ │             │
│  │  │  → ~200ms saved per request                 │ │             │
│  │  └─────────────────────────────────────────────┘ │             │
│  └──────────────────────────────────────────────────┘             │
└──────────────────────────────────────────────────────────────────┘
```

### Key Changes from Current Architecture

| Component | Current | Target |
|-----------|---------|--------|
| **httpx client** | Created per-request, no pooling | Single shared `httpx.AsyncClient` with connection pooling |
| **Worker model** | Sequential page accumulation within each worker | Streaming accumulation — push results per page (or per item) instead of batch |
| **Streaming** | None — all results buffered until all workers finish | SSE or buffered batch response — push results as they arrive |
| **Cache** | No live-search cache | In-memory TTL cache for Reddit API responses (30s-120s TTL) |
| **Background refill** | One subreddit per 60s (sequential sweep) | Parallel per-subreddit refill (max 3 concurrent) with TTL-aware scheduling |
| **Rate limiting** | None | Client-side rate limiter respecting Reddit OAuth limits (600/10min) |
| **OAuthManager** | Created per-request | Singleton shared instance with in-memory token cache |
| **Error reporting** | Silent failures (empty results) | Partial success indicator for failed subreddits |

---

## Deliverable 7: Migration Plan

### Phase 6.2 — Connection Pooling & Shared Clients (Post-6.0, LOW RISK, HIGH IMPACT)

**Changes:**
- Share a single `httpx.AsyncClient` instance across the application (app lifespan)
- Pass it to `RedditClient`, `SearchCoordinator`, `QueueManager`, `BackgroundRefreshService`
- Set reasonable timeouts on the shared client defaults
- Remove per-call `async with httpx.AsyncClient()` blocks

**Estimated latency reduction:** 10-30s per search (eliminating per-request DNS + TLS overhead)

**Risk:** Low — purely mechanical refactor, no logic changes.

---

### Phase 6.3 — Query-Level Response Cache (Post-6.0, LOW RISK, MEDIUM IMPACT)

**Changes:**
- Add an in-memory TTL cache (`cachetools.TTLCache` or similar) for Reddit API responses
- Short TTL (30s) for live search results to avoid serving stale data
- Longer TTL (120s) for subreddit feeds
- Cache key = `(subreddit, sort, after_cursor)` for feeds, `(query, subreddit, after)` for search
- Respect cache invalidation on explicit user refresh

**Estimated latency reduction:** Eliminates 100% of Reddit API calls for repeated queries within cache window.

**Risk:** Low — cache miss falls through to normal request.

---

### Phase 6.4 — Parallel Background Refill (Post-6.0, MEDIUM RISK, MEDIUM IMPACT)

**Changes:**
- Replace single-subreddit-per-tick with concurrent refill
- Use `asyncio.Semaphore(3)` to bound concurrent fetches
- Schedule refill workers for all subreddits below threshold, not just the lowest
- Add per-subreddit rate limiting to avoid flooding Reddit

**Risk:** Medium — must ensure per-subreddit cursor consistency under concurrent writes.

---

### Phase 6.5 — Streaming Search Results (Post-6.0, HIGH RISK, HIGH IMPACT)

**Changes:**
- Replace `FeedResponse` batch response with SSE (Server-Sent Events) or chunked transfer
- Frontend renders items incrementally as they arrive from the backend
- Each worker pushes results to a shared queue; the response iterates the queue
- First paint in ~2-3s instead of 10-15s

**Risk:** High — requires coordinated frontend changes to consume streaming response. The frontend `ApiClient` must switch from `Dio` HTTP JSON to SSE parsing.

---

### Phase 6.6 — Cancellation & Rate Limiting (Post-6.0, MEDIUM RISK, MEDIUM IMPACT)

**Changes:**
- Pass `asyncio.CancelledError` propagation from router through coordinator to workers
- On new search with same query, cancel in-flight request automatically
- Add client-side rate limiter (`asyncio.Semaphore` at app level, not per-request)
- Track `X-Ratelimit-*` headers from Reddit API to dynamically adjust rate

**Risk:** Medium — cancellation propagation requires careful cleanup; must not leave dangling SQLite transactions.

---

## Deliverable 8: Risk Assessment

### Compatibility

| Change | Backward Compatible? | Migration Notes |
|--------|---------------------|-----------------|
| Phase 6.2 — Connection pooling | ✅ Fully | No API contract changes |
| Phase 6.3 — Response cache | ✅ Fully | Cache miss → existing behavior |
| Phase 6.4 — Parallel refill | ✅ Fully | Background-only, no API change |
| Phase 6.5 — Streaming results | ❌ Breaking | Requires frontend `ApiClient` rewrite for SSE; old non-streaming path must be maintained as fallback |
| Phase 6.6 — Cancellation | ✅ Fully | No API contract changes |

### Regression Risk

| Phase | Risk Level | Mitigation |
|-------|-----------|------------|
| 6.2 Connection pooling | **Low** | Existing tests validate functional behavior. Pooling is a replace-the-client refactor. |
| 6.3 Response cache | **Low** | TTLCache with miss → fallthrough. Add cache-hit test. |
| 6.4 Parallel refill | **Medium** | SQLite concurrent write risk. Add row-level locking or use a dedicated write queue. |
| 6.5 Streaming | **High** | Requires dual code paths (streaming + legacy). Must test both. Frontend integration is the primary risk. |
| 6.6 Cancellation | **Medium** | Must ensure no resource leaks. Add timeout + cleanup tests. |

### Expected Performance Gains

| Phase | Metric | Before | After | Gain |
|-------|--------|--------|-------|------|
| 6.2 | Search latency (5 subreddits) | 10-15s | 8-12s | ~20% reduction |
| 6.3 | Repeated search latency | 10-15s | 0-2s | 100% (within cache window) |
| 6.4 | Background refill coverage | 1/20 sub per 60s | 3/20 per 60s | 3x coverage rate |
| 6.5 | Time to first result | 10-15s | 2-5s | ~60-70% reduction in perceived latency |
| 6.6 | Rate-limit errors | Cascading failures | Graceful backoff | Eliminates cascading failures |

### Overall Assessment

The single highest-impact change is **Phase 6.5 (Streaming)** because it converts perceived latency from "max worker time" to "min worker time." However, it requires coordinated frontend changes and is architecturally the most invasive.

The safest high-impact change is **Phase 6.2 (Connection Pooling)** + **Phase 6.3 (Response Cache)** — two low-risk, fully backward-compatible changes that together eliminate 10-30s of per-search overhead. These should be done first.

Phase 6.4 (Parallel Refill) can be done independently and improves the feed cold-start experience significantly.

Phase 6.6 (Cancellation) is important for robust multi-user deployment but should be done last.
