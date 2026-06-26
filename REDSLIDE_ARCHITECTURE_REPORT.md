# RedSlide Architecture Investigation Report

> **Status**: Investigation Complete — No code changes implemented (except pagination fix)
>
> **Date**: 2026-06-24

---

## Table of Contents

1. [Current Architecture](#1-current-architecture)
2. [Root Findings](#2-root-findings)
3. [Hidden Content Analysis](#3-hidden-content-analysis)
4. [Queue Capacity & Eviction Analysis](#4-queue-capacity--eviction-analysis)
5. [Fetch Failure Analysis](#5-fetch-failure-analysis)
6. [Search vs Feed Inconsistency](#6-search-vs-feed-inconsistency)
7. [Recommended Architecture](#7-recommended-architecture)
8. [Migration Plan](#8-migration-plan)

---

## 1. Current Architecture

### Data Flow Diagram

```
Reddit API
    │
    ▼
┌─────────────────────────────────────────────────────┐
│              RedditClient.fetch_subreddit_media()    │
│              (OAuth, 25-50 items per call)           │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│              QueueManager.fetch_and_store()          │
│                                                      │
│  1. Calls RedditClient.fetch_subreddit_media()       │
│  2. For each asset: QueueManager.add_to_queue()      │
│     ├── Checks dedup in media_queue                  │
│     ├── INSERT OR IGNORE into media_assets (always)  │
│     ├── INSERT into media_queue (position = MAX+1)   │
│     └── Returns True/False                           │
│  3. Returns (added_count, new_cursor)                │
└──────────────────────┬──────────────────────────────┘
                       │
          ┌────────────┼────────────┐
          ▼            ▼            ▼
┌──────────────┐ ┌──────────┐ ┌──────────┐
│ media_assets │ │ gallery  │ │ media_   │
│ (FTS5 index) │ │ _items   │ │ queue    │
│              │ │          │ │          │
│ 3,047 rows   │ │ 0 rows   │ │ 1,000    │
│ (all history)│ │          │ │ rows     │
│              │ │          │ │ (active) │
│ subreddit,   │ │ reddit_id│ │ position │
│ reddit_id,   │ │ item_url │ │ added_at │
│ media_url... │ │          │ │          │
└──────┬───────┘ └──────────┘ └────┬─────┘
       │                            │
       ▼                            │
┌──────────────────────┐            │
│  /api/search (FTS5)  │            │
│  SELECT FROM         │            │
│  media_assets        │            │
│  (all history,       │            │
│   3,047 items)       │            │
└──────────────────────┘            │
                                    ▼
                        ┌──────────────────────┐
                        │   /api/feed           │
                        │   SELECT FROM         │
                        │   media_assets        │
                        │   JOIN media_queue    │
                        │   (1,000 items max,   │
                        │    shared across all  │
                        │    subreddits)        │
                        └──────────────────────┘
                                    │
                                    ▼
                        ┌──────────────────────┐
                        │   Slideshow Screen    │
                        │   (sees only what     │
                        │    /api/feed returns) │
                        └──────────────────────┘
```

### Table Lifecycles

| Table | Purpose | Writer | Reader | Retention |
|-------|---------|--------|--------|-----------|
| `media_assets` | Permanent store of all fetched media | `add_to_queue()` — via `INSERT OR IGNORE` | `/api/feed` (via JOIN), `/api/search` (FTS5) | Never deleted (except 30d cleanup via `cleanup_old_assets`) |
| `media_queue` | Active playback queue (FIFO) | `add_to_queue()` — inserts at `MAX(position)+1` | `/api/feed` (via JOIN), `manage_queue()` → `_trim_queue()` | Trimmed to 1000 when exceeded; items older than 30d removed by `_cleanup_job` |
| `subreddit_configs` | Subreddit metadata & cursors | `sync_subreddits()`, `add_or_update_subreddit_config()`, `set_stored_cursor()` | `get_enabled_subreddits()`, `get_stored_cursor()`, `_get_subreddits_needing_refill()` | Permanent |
| `search_results` | (Currently unused) | Previously populated by search | `/api/search/debug` | N/A |
| `gallery_items` | Gallery image URLs | `add_to_queue()` | `get_gallery_urls()` | Same as `media_assets` |
| `oauth_tokens` | Reddit OAuth tokens | `OAuthManager` | `RedditClient._fetch_oauth()` | Replaced on refresh |

---

## 2. Root Findings

### Finding 1: Queue is a shared 1000-slot FIFO

`QUEUE_MAX = 1000` in `backend/app/services/queue_manager.py:10`

The queue uses monotonic positions (`MAX(position) + 1`) for ordering. All subreddits share the same queue. There is NO per-subreddit queue isolation.

### Finding 2: Disabled subreddits waste 54% of queue capacity

```
DISABLED subreddits occupying queue slots:
  art            : 346 items (34.6%)
  indiameme      : 147 items (14.7%)
  images         :  47 items ( 4.7%)
  saimansays     :   0 items (in media_assets only)
  TOTAL DISABLED : 540 items (54.0%)

ENABLED subreddits available slots:
  total queue    : 1000
  minus disabled :  540
  ─────────────────
  for 7 enabled  :  460
  average/sub    :   65
```

`disable_subreddit()` (`queue_manager.py:293-300`) only sets `enabled=0`. It does NOT remove the subreddit's items from `media_queue`. Those items remain permanently, occupying slots that enabled subreddits could use.

### Finding 3: Background refill uses wrong metric

`_get_subreddits_needing_refill()` (`background_service.py:90-99`) checks `count_subreddit_items()` which counts from `media_assets`:

```python
count = await self.queue_manager.count_subreddit_items(subreddit)
if count < QUEUE_REFILL:  # QUEUE_REFILL = 300
    needs_refill.append((subreddit, count))
```

`count_subreddit_items()` counts from `media_assets` (974 for navelnsfw), not from the queue JOIN (40 for navelnsfw). So navelnsfw at 974 assets NEVER qualifies for refill (974 > 300 threshold), even though only 40 are visible.

### Finding 4: New items get trimmed immediately

The `_trim_queue` mechanism position-orders items and deletes the HIGHEST positions when the queue exceeds 1000:

```sql
DELETE FROM media_queue WHERE id IN (
    SELECT id FROM media_queue 
    ORDER BY position DESC 
    LIMIT (SELECT COUNT(*) - 1000 FROM media_queue)
)
```

New items always get `position = MAX(position) + 1` (the highest position). When the queue exceeds 1000, these new items (at the highest positions) are the first to be deleted.

### Finding 5: Pagination bug was masking the problem

The previously-fixed bug in `feed.py:104-113` forced `has_more = True` for all subreddit feeds regardless of actual available items. This masked the "only 40 items" problem by:
1. Telling the frontend more items exist
2. Returning the same `after` cursor
3. Creating an infinite retry loop

After the fix, the slideshow correctly reports `has_more = False` at offset=40 and stops. But the underlying problem (only 40 items visible out of 974) remains.

---

## 3. Hidden Content Analysis

For every configured subreddit:

| Subreddit | Enabled | `media_assets` | Visible in Queue | Hidden | Visibility % |
|-----------|---------|---------------|-----------------|--------|-------------|
| navelnsfw | YES | 974 | 40 | 934 | 4.1% |
| supermodelindia | YES | 333 | 41 | 292 | 12.3% |
| fingmemes | YES | 233 | 214 | 19 | 91.8% |
| bollywooduhqonly | YES | 99 | 99 | 0 | 100.0% |
| indianbikes | YES | 41 | 25 | 16 | 61.0% |
| carsindia | YES | 40 | 40 | 0 | 100.0% |
| cars | YES | 1 | 1 | 0 | 100.0% |
| art | NO | 346 | 346 | 0 | 100.0% |
| indiameme | NO | 147 | 147 | 0 | 100.0% |
| saimansays | NO | 786 | 0 | 786 | 0.0% |
| images | NO | 47 | 47 | 0 | 100.0% |
| **TOTAL** | | **3,047** | **1,000** | **2,047** | **32.8%** |

**Key finding**: **2,047 out of 3,047 stored assets (67.2%) are invisible to slideshow users.**

navelnsfw is the worst case: 934 of 974 assets (95.9%) are hidden.

---

## 4. Queue Capacity & Eviction Analysis

### Queue Position Map

```
Positions 1-346:   art (DISABLED — will never be replaced)
Positions 347-688: fingmemes (ENABLED — 214 items) + carsindia (ENABLED — 40 items, scattered)
Positions 689-728: navelnsfw (ENABLED — 40 items)
Positions 729-769: supermodelindia (ENABLED — 41 items)
Positions 770-876: indiameme (DISABLED) + bollywooduhqonly (ENABLED)
Positions 877-975: bollywooduhqonly (ENABLED — 99 items)
Positions 976-1000: indianbikes (ENABLED — 25 items)
```

### Eviction Cycle

```
1. BackgroundRefreshService._refresh_job() runs every 60s
2. manage_queue() → _trim_queue(1000) if queue > 1000
3. Trims highest positions (1001+), deleting newly-added items
4. _get_subreddits_needing_refill() checks media_assets count
5. navelnsfw: 974 assets > 300 threshold → SKIPPED
6. navelnsfw never gets refilled by background service
7. Only manual feed requests can trigger ensure_subreddit_has_content
```

### Why 974 stored → 40 visible

1. `media_assets` accumulates everything (974 items) via `INSERT OR IGNORE`
2. `media_queue` is capped at 1000 items shared across ALL subreddits
3. New items enter at position 1001+ (always highest)
4. `_trim_queue` deletes from position 1001+ when queue exceeds 1000
5. Disabled subreddits consume 540 slots permanently (never cleaned up)
6. Navelnsfw's 40 items at positions 689-728 survive because they're below position 1000
7. Any NEW navelnsfw item enters at 1001+ and gets trimmed in the next cycle
8. The background service never triggers a refill for navelnsfw (wrong metric check)

---

## 5. Fetch Failure Analysis

### The Log Message

```
On-demand fetch failed for navelnsfw:
```

### Source Code

`backend/app/services/queue_manager.py:396-398`:
```python
except Exception as e:
    print(f"On-demand fetch failed for {subreddit}: {e}")
    return await self.count_subreddit_items(subreddit) > 0
```

### What Happens Inside fetch_and_store

`fetch_and_store()` (`queue_manager.py:333-367`) does:
1. **Creates NEW OAuthManager, ProviderManager, RedditClient** on every call
2. Calls `OAuthManager.initialize()` — HTTP call to Reddit for token
3. Calls `RedditClient.fetch_subreddit_media()` — HTTP call to Reddit API
4. Calls `add_to_queue()` for each asset — database operations

### Empty Exception Message

The empty `{e}` in the log means `str(e) == ""`. Testing confirms that only `Exception()` with no arguments produces an empty string in Python 3.14. Most real exceptions (httpx, aiosqlite, asyncio) have non-empty messages.

**In my live test, the fetch succeeded** — OAuth was valid (392 successes, 0 failures), Reddit returned 24 items, 20 were added to the queue, cursor advanced.

**Possible explanations for the empty failure log:**
- **Transient network error** that resolves quickly (e.g., DNS flapping, connection reset)
- **Reddit API rate limiting** returning a response that triggers an internal code path throwing `Exception()`
- **asyncio CANCELLED** — though in Python 3.14, `asyncio.CancelledError` is `BaseException` (not `Exception`) and would NOT be caught here, propagating instead
- **A bare `raise Exception()` somewhere in the dependency chain** (httpx, aiosqlite, etc.)

The `fetch_and_store` method's per-call object creation (`OAuthManager()`, `ProviderManager()`, `RedditClient()`) is inefficient and could contribute to timing-related failures.

### Confirmed Working State

- OAuth token: Valid, expires in ~8 hours
- Reddit API: Returns data (tested successfully)
- Queue insertion: Works (tested)
- Cursor management: Works (tested)

---

## 6. Search vs Feed Inconsistency

### Three Different Architectures

| Feature | `/api/feed` (Slideshow) | `/api/search` (FTS5) | `/api/search/reddit` (Live) |
|---------|----------------------|-------------------|--------------------------|
| Data source | `media_assets JOIN media_queue` | `media_assets` via FTS5 | Live Reddit API |
| Items accessible | ~40 per subreddit (1,000 shared) | ALL 3,047 items | MILLIONS (entire Reddit) |
| Pagination | Offset-based (position) | Offset-based (FTS5) | Cursor-based (Reddit `after`) |
| Speed | Fast | Fast | Slow (network) |
| Cached | Yes | Yes | No |

### The Inconsistency

A user searching "navel" via `/api/search` can find ALL 974 navelnsfw posts in `media_assets`, but starting a slideshow for navelnsfw shows only 40. This is architecturally inconsistent — both features operate on the same database but use different queries with different access to data.

### Search Architecture (Recommended Pattern)

The `/api/search/reddit` endpoint demonstrates the correct pattern: **fetch live from Reddit, return results directly**. It:
1. Does NOT use the queue
2. Does NOT cache results
3. Does NOT have a 1000-item limit
4. Supports proper cursor-based pagination

---

## 7. Recommended Architecture

### Design Comparison

| Aspect | **Design A** — Current Queue | **Design B** — Direct `media_assets` | **Design C** — Hybrid |
|--------|-----------------------------|-------------------------------------|----------------------|
| **Architecture** | `media_assets JOIN media_queue` | Direct `SELECT FROM media_assets WHERE subreddit=X` | Feed uses queue, slideshow uses `media_assets` |
| **Items per subreddit** | ~40-65 (capped by shared 1000) | ALL fetched items (e.g., 974 for navelnsfw) | Slideshow: ALL; Feed: queue |
| **Performance** | Fast (1k row JOIN) | Slower with many rows per subreddit | Per-context optimized |
| **Pagination** | Fragile (offset-based) | Cursor-by-position or cursor-by-`created_utc` | Per-context |
| **Staleness** | Items cycle out | Items remain until cleanup (30d) | Per-context |
| **Implementation Effort** | None (current) | Medium (change feed.py + queue_manager.py) | High (two parallel systems) |
| **User Experience** | Poor (sees 4% of content) | Good (sees all content) | Good |

### Recommendation: **Design B — Direct `media_assets`**

Change the `/api/feed` endpoint and `get_queue_items()` to query `media_assets` directly (via `subreddit` + `created_utc DESC`), instead of joining through `media_queue`.

**Rationale:**

1. **Eliminates the 1000-item global cap**: Each subreddit gets access to ALL its stored assets
2. **Eliminates per-subreddit starvation**: Navelnsfw with 974 items gets just as many visible as fingmemes with 233
3. **Eliminates the trim/capacity problem**: No more items entering and immediately getting evicted
4. **Consistent with search**: Both `/api/feed` and `/api/search` would access all of `media_assets`
5. **Simpler architecture**: Remove the `media_queue` dependency from the feed path entirely
6. **The `media_queue` table can remain** for background service refill tracking and potential future use

**Concerns addressed:**

- **Performance**: `media_assets` has an index on `(subreddit, created_utc DESC)`. Queries filtered by subreddit and ordered by `created_utc DESC` use this index efficiently regardless of table size (3k rows now, potentially 100k+).
- **Pagination**: Use cursor-based pagination on `(subreddit, created_utc, reddit_id)` instead of fragile offset-based pagination.
- **Queue purpose**: `media_queue` was originally intended as an "active feed cache" but has become the permanent source of slideshow content (see Phase 2). This was a design evolution that never accounted for the 1000-item shared cap.

---

## 8. Migration Plan

### Step 1 — Update `get_queue_items()` to bypass `media_queue`

In `backend/app/services/queue_manager.py`, add a new query path that reads directly from `media_assets` when a subreddit filter is provided:

**Current**:
```python
SELECT ma.* FROM media_assets ma
JOIN media_queue mq ON ma.reddit_id = mq.reddit_post_id
WHERE ma.subreddit IN (?)
ORDER BY mq.position ASC
LIMIT ? OFFSET ?
```

**Proposed**:
```python
SELECT ma.* FROM media_assets ma
WHERE ma.subreddit IN (?)
ORDER BY ma.created_utc DESC
LIMIT ? OFFSET ?
```

Or better, cursor-based:
```python
SELECT ma.* FROM media_assets ma
WHERE ma.subreddit IN (?)
  AND (ma.created_utc < ? OR (ma.created_utc = ? AND ma.reddit_id < ?))
ORDER BY ma.created_utc DESC, ma.reddit_id DESC
LIMIT ?
```

### Step 2 — Update `count_subreddit_items()` for the refill threshold

Change `_get_subreddits_needing_refill()` to count from `media_queue` (or the visible JOIN) instead of `media_assets`, so the background service actually refills subreddits whose queue share is low.

### Step 3 — Prune disabled subreddits from `media_queue`

Add a cleanup step in `disable_subreddit()` that removes the disabled subreddit's items from `media_queue`:

```python
async def disable_subreddit(self, subreddit: str) -> None:
    async with get_db() as db:
        await db.execute("UPDATE subreddit_configs SET enabled=0 WHERE subreddit=?", (subreddit,))
        await db.execute("""
            DELETE FROM media_queue WHERE reddit_post_id IN (
                SELECT reddit_id FROM media_assets WHERE subreddit = ?
            )
        """, (subreddit,))
        await db.commit()
```

### Step 4 — Reduce `fetch_and_store` overhead

Move the `OAuthManager`, `ProviderManager`, and `RedditClient` creation out of `fetch_and_store()` and into shared instances, to avoid per-call initialization overhead and reduce the chance of transient failures.

### Step 5 — Add reddit_id uniqueness to the cursor

Use `(created_utc, reddit_id)` as a composite cursor instead of fragile integer offsets, to prevent duplicates/skips if items are inserted between page loads.

---

## Appendix A: SQL Schema

```sql
-- media_assets — permanent store
CREATE TABLE media_assets (
    id TEXT PRIMARY KEY,
    reddit_id TEXT UNIQUE NOT NULL,
    permalink TEXT UNIQUE NOT NULL,
    media_url TEXT NOT NULL,
    title TEXT NOT NULL, author TEXT NOT NULL,
    score INTEGER NOT NULL, subreddit TEXT NOT NULL,
    video_url TEXT, thumbnail_url TEXT,
    created_utc INTEGER NOT NULL,
    is_video BOOLEAN NOT NULL, is_gallery BOOLEAN NOT NULL,
    nsfw BOOLEAN NOT NULL,
    quality_score INTEGER DEFAULT 50,
    source_provider TEXT NOT NULL DEFAULT 'reddit_oauth',
    width INTEGER, height INTEGER, duration INTEGER,
    created_at INTEGER NOT NULL, last_seen INTEGER NOT NULL,
    UNIQUE(reddit_id, media_url)
);
CREATE INDEX idx_subreddit_created ON media_assets(subreddit, created_utc DESC);

-- media_queue — active playback FIFO (capped at 1000)
CREATE TABLE media_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    reddit_post_id TEXT NOT NULL UNIQUE,
    position INTEGER NOT NULL,
    added_at INTEGER NOT NULL,
    group_id INTEGER,
    FOREIGN KEY (reddit_post_id) REFERENCES media_assets(id)
);
CREATE INDEX idx_position ON media_queue(position);

-- subreddit_configs — metadata + Reddit cursors
CREATE TABLE subreddit_configs (
    subreddit TEXT PRIMARY KEY,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    provider TEXT NOT NULL DEFAULT 'reddit_oauth',
    sort_mode TEXT NOT NULL DEFAULT 'hot',
    refresh_interval INTEGER NOT NULL DEFAULT 300,
    last_hot_after TEXT, last_new_after TEXT, last_top_after TEXT
);
```

## Appendix B: Key Code Locations

| File | Line(s) | Purpose |
|------|---------|---------|
| `backend/app/api/feed.py` | 69-125 | `/api/feed` endpoint — subreddit slideshow data source |
| `backend/app/api/feed.py` | 146-184 | `/api/search` endpoint — FTS5 search (uses `media_assets` directly) |
| `backend/app/services/queue_manager.py` | 106-146 | `get_queue_items()` — the JOIN query that limits visibility |
| `backend/app/services/queue_manager.py` | 161-170 | `manage_queue()` — trim/refill decision logic |
| `backend/app/services/queue_manager.py` | 177-188 | `_trim_queue()` — eviction by position DESC |
| `backend/app/services/queue_manager.py` | 262-270 | `count_subreddit_items()` — counts from `media_assets` (WRONG metric) |
| `backend/app/services/queue_manager.py` | 293-300 | `disable_subreddit()` — does NOT clean up queue |
| `backend/app/services/queue_manager.py` | 333-367 | `fetch_and_store()` — creates new OAuth/Provider per call |
| `backend/app/services/queue_manager.py` | 369-398 | `ensure_subreddit_has_content()` — catches exceptions silently |
| `backend/app/services/background_service.py` | 90-99 | `_get_subreddits_needing_refill()` — uses `media_assets` count |
| `backend/app/core/database.py` | 36-59 | `media_assets` table schema |
| `backend/app/core/database.py` | 82-92 | `media_queue` table schema |
| `lib/features/slideshow/providers/slideshow_provider.dart` | 274-318 | `loadMore()` — slideshow pagination logic |
| `lib/features/feed/data/feed_repository.dart` | 21-44 | `getFeed()` — frontend feed request |
