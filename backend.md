# RedSlide Backend Architecture

## Table of Contents
1. [Overview](#overview)
2. [System Architecture](#system-architecture)
3. [Directory Structure](#directory-structure)
4. [Application Startup](#application-startup)
5. [API Layer](#api-layer)
6. [Services Layer](#services-layer)
7. [Managers Layer](#managers-layer)
8. [Database Layer](#database-layer)
9. [Data Models](#data-models)
10. [Background Service](#background-service)
11. [Frontend Integration](#frontend-integration)
12. [Configuration](#configuration)
13. [Deployment](#deployment)

---

## Overview

**RedSlide** is a media discovery application with a Python FastAPI backend and Flutter frontend. The backend fetches media from Reddit via OAuth, stores it in SQLite, and serves it to the Flutter client through REST APIs.

### Key Design Principles
- **Client-driven subreddit management**: Backend starts with zero subreddits. The Flutter client syncs subscribed subreddits via `/api/subreddits/sync`.
- **On-demand + background fetching**: Subreddit content is fetched immediately on first request and refilled in the background every 60 seconds.
- **Cursor-based pagination**: All feed pagination is cursor-based on `media_assets` using `(created_utc DESC, reddit_id DESC)` composite cursor. No offset-based pagination is used for feeds.
- **Flutter-side multi-subreddit merging**: The backend does NOT merge multiple subreddits — it returns 400 if asked to. The Flutter Merge Engine handles multi-subreddit merging client-side.
- **Provider failover**: Primary provider (Reddit OAuth) falls back to Redlib if failures exceed threshold (circuit breaker pattern).
- **Quality filtering**: Media assets must meet minimum resolution (400x300) to be stored.

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          FLUTTER FRONTEND                               │
│                                                                         │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌──────────────┐    │
│  │ Feed Screen│  │Search Screen│  │Slideshow   │  │ Settings     │    │
│  │ (Riverpod) │  │ (Riverpod) │  │ (Riverpod) │  │ (SharedPrefs)│    │
│  └─────┬──────┘  └─────┬──────┘  └─────┬──────┘  └──────────────┘    │
│        │               │               │                               │
│  ┌─────┴───────────────┴───────────────┴──────────────────────────┐  │
│  │                    ApiClient (Dio/HTTP)                         │  │
│  │  FeedRepository · SearchRepository · SettingsRepository       │  │
│  └─────────────────────────────┬──────────────────────────────────┘  │
│                                │                                      │
│  ┌─────────────────────────────▼──────────────────────────────────┐  │
│  │  MediaSource abstraction (loadNext / hasMore / dispose)        │  │
│  │  ┌──────────────────┐ ┌──────────────────┐                    │  │
│  │  │ SubredditMediaSrc│ │ SearchMediaSource│                    │  │
│  │  │ (FeedRepository) │ │ (SearchRepo)     │                    │  │
│  │  └────────┬─────────┘ └────────┬─────────┘                    │  │
│  │           │                    │                               │  │
│  │  ┌────────▼────────────────────▼──────────────────────────┐  │  │
│  │  │  MergeEngine (Flutter-side multi-subreddit merger)      │  │  │
│  │  │  · SourceBuffer per MediaSource (loadNext calls)        │  │  │
│  │  │  · Round-robin selection with freshness + diversity    │  │  │
│  │  │  · Auto-refill at low watermark (8 remaining)           │  │  │
│  │  └─────────────────────────────────────────────────────────┘  │  │
│  └─────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────┼──────────────────────────────────────┘
                                 │ HTTP REST
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          BACKEND (FastAPI)                              │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  FastAPI App (app/main.py)                                       │  │
│  │  Routers: feed (/api/feed), search (/api/search*),              │  │
│  │           debug  (/api/health, /api/debug*)                      │  │
│  │           /api/media*, /api/subreddits*                          │  │
│  └──────────────────────────┬───────────────────────────────────────┘  │
│                             │                                           │
│  ┌──────────────────────────▼───────────────────────────────────────┐  │
│  │  Services Layer                                                  │  │
│  │  ┌─────────────────────┐  ┌────────────────────────────────┐   │  │
│  │  │   QueueManager      │  │   RedditClient                 │   │  │
│  │  │   · Queue CRUD      │  │   · fetch_subreddit_media()   │   │  │
│  │  │   · FTS5 search     │  │   · search_reddit()           │   │  │
│  │  │   · Cursor/pagination│  │   · _fetch_oauth()            │   │  │
│  │  │   · Gallery URLs     │  │   · _fetch_redlib() (stub)   │   │  │
│  │  │   · Subreddit config │  │   · _parse_reddit_response()  │   │  │
│  │  │   · fetch_and_store()│  │   · validate_media()         │   │  │
│  │  │   · get_subreddit_assets() (PRIMARY)                     │   │  │
│  │  └─────────────────────┘  └──────────┬─────────────────────┘   │  │
│  │                                       │                           │
│  │  ┌────────────────────────────────────▼────────────────────────┐ │  │
│  │  │   BackgroundRefreshService (APScheduler)                    │ │  │
│  │  │   · Refresh job (every 60s): picks subreddit with lowest   │ │  │
│  │  │     asset count (< 300), fetches next page via cursor,     │ │  │
│  │  │     stores in queue, updates cursor                        │ │  │
│  │  │   · Cleanup job (every 24h): removes queue items >30 days  │ │  │
│  │  └─────────────────────────────────────────────────────────────┘ │  │
│  └────────────────────────────────┬──────────────────────────────────┘  │
│                                   │                                     │
│  ┌────────────────────────────────▼──────────────────────────────────┐  │
│  │  Managers Layer                                                  │  │
│  │  ┌─────────────────────┐  ┌────────────────────────────────┐   │  │
│  │  │   OAuthManager      │  │   ProviderManager              │   │  │
│  │  │   · Token lifecycle  │  │   · Circuit breaker           │   │  │
│  │  │   · Client cred flow │  │   · Failure threshold: 5     │   │  │
│  │  │   · Refresh flow     │  │   · Cooldown: 300s           │   │  │
│  │  │   · Retry/backoff    │  │   · Provider health check    │   │  │
│  │  └─────────────────────┘  └────────────────────────────────┘   │  │
│  └────────────────────────────────┬──────────────────────────────────┘  │
│                                   │                                     │
│  ┌────────────────────────────────▼──────────────────────────────────┐  │
│  │  Database (SQLite via aiosqlite)                                  │  │
│  │  Tables: oauth_tokens · media_assets · gallery_items             │  │
│  │          media_queue · subreddit_configs · search_results │  │
│  │          media_search (FTS5)                                      │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Directory Structure

```
backend/
├── main.py                          # Server entry point (uvicorn)
├── app/
│   ├── __init__.py                  # Empty
│   ├── main.py                      # FastAPI app + lifespan (DB init, OAuth, background svc)
│   ├── core/
│   │   ├── database.py              # SQLite schema, migrations, connection helper
│   │   └── (no __init__.py)         # Core is a namespace package
│   ├── models/
│   │   └── schemas.py               # Pydantic models (MediaAsset, response schemas, OAuthToken)
│   ├── managers/
│   │   ├── __init__.py              # Re-exports OAuthManager, ProviderManager
│   │   ├── oauth.py                 # OAuthManager — token lifecycle
│   │   └── provider.py              # ProviderManager — circuit breaker failover
│   ├── services/
│   │   ├── __init__.py              # Re-exports RedditClient, QueueManager
│   │   ├── queue_manager.py         # QueueManager — queue CRUD, search, subreddit config, cursors
│   │   ├── reddit_client.py         # RedditClient — fetch/parse media from Reddit API
│   │   └── background_service.py    # BackgroundRefreshService — APScheduler jobs
│   └── api/
│       ├── __init__.py              # Imports feed, debug, search routers
│       ├── feed.py                  # /api/feed, /api/media*, /api/subreddits*, /api/search*
│       ├── search.py                # /api/search/reddit (direct Reddit search)
│       └── debug.py                 # /api/health, /api/debug/*
├── data/
│   └── redslide.db                  # SQLite database (auto-created)
├── .env                             # Environment variables (not committed)
├── .env.example
├── requirements.txt
├── Dockerfile
└── validate.py / benchmark.py / etc.  # Test/validation scripts
```

---

## Application Startup

The server starts via `backend/main.py`, which runs `uvicorn` on `app.main:app`.

### Startup Sequence

```
1. backend/main.py
   └── uvicorn.run(app, host="0.0.0.0", port=8000)

2. FastAPI lifespan (app/main.py:lifespan)
   │
   ├── Load .env (python-dotenv)
   ├── Ensure data/ directory exists
   ├── await init_db()
   │   ├── Create tables (oauth_tokens, media_assets, gallery_items,
   │   │                 media_queue, subreddit_configs, search_results)
   │   ├── Create FTS5 virtual table (media_search)
   │   ├── Create triggers (after_media_insert/update/delete → sync FTS5)
   │   └── Apply migrations (add last_hot_after, last_new_after, last_top_after columns)
   │
   ├── OAuthManager.initialize()
   │   ├── Load existing token from oauth_tokens table
   │   ├── If token exists & not expired → use it
   │   └── If no token → acquire via client_credentials grant
   │
   ├── BackgroundRefreshService.start()
   │   ├── QueueManager.initialize()
   │   ├── OAuthManager.initialize()
   │   ├── scheduler.add_job(refresh_job, IntervalTrigger(60s))
   │   └── scheduler.add_job(cleanup_job, IntervalTrigger(86400s))
   │
   └── Yield → Server ready, accepts requests

3. Cleanup on shutdown
   └── BackgroundRefreshService.stop() → scheduler.shutdown()
```

**Critical startup behavior**: The backend does NOT seed any default subreddits. It does NOT fetch any Reddit content on startup. It waits for the Flutter client to call `POST /api/subreddits/sync` with the user's subscribed subreddits. This is the **client-driven subreddit management** model.

---

## API Layer

### Endpoint Summary

| Method | Endpoint | Description | Query Params |
|--------|----------|-------------|--------------|
| GET | `/api/feed` | Paginated media feed (single subreddit or all) | `limit` (max 100), `after` (cursor), `subreddits` (single only), `sort` |
| GET | `/api/feed/queue` | Queue status (deprecated) | `limit` |
| GET | `/api/search` | FTS5 full-text search | `q` (required), `limit`, `page`, `subreddits`, `media_type`, `sort` |
| GET | `/api/search/debug` | LIKE-based search fallback | `q` (required) |
| GET | `/api/search/reddit` | Live Reddit search (no cache) | `q`, `mode` (global/local), `limit`, `after`, `subreddits` |
| GET | `/api/media/{id}` | Get single media asset | — |
| POST | `/api/media/start/{id}` | Start slideshow placeholder | — |
| POST | `/api/subreddits/sync` | Sync subreddit list | Body: `{"subreddits": [...]}` |
| POST | `/api/subreddits/fetch` | Fetch one subreddit now | `subreddit` (query param) |
| GET | `/api/health` | System health | — |
| GET | `/api/debug/providers` | Provider status | — |
| GET | `/api/debug/queue` | Queue diagnostics | — |

### Detailed Endpoint Logic

#### GET /api/feed

The feed endpoint uses cursor-based pagination on `media_assets` table. Multi-subreddit requests are rejected.

```
1. Parse query params (limit, after/cursor, subreddits, sort)
2. Reject multi-subreddit requests with 400:
     "Multi subreddit handled by Flutter Merge Engine."
3. Single subreddit or no subreddits:
   → Call QueueManager.get_subreddit_assets(subreddit, limit, after_cursor)
     → SELECT from media_assets WHERE subreddit=? (or all if subreddit is None)
       ORDER BY created_utc DESC, reddit_id DESC LIMIT ?+1
     → Cursor format: "created_utc,reddit_id"
     → Returns (items, has_more, new_cursor)
4. If no items AND single subreddit AND first page:
   → Synchronous on-demand fetch via ensure_subreddit_has_content()
   → Re-query after fetch
5. Enrich items with gallery URLs via get_gallery_urls()
6. Return FeedResponse(items, after=cursor, has_more)
```

**Key design decision**: Multiple subreddits are NOT merged server-side. The Flutter Merge Engine fires N parallel requests (one per subreddit) and merges them client-side with round-robin, freshness scoring, and deduplication.

#### POST /api/subreddits/sync

```
1. Receive subreddit list from Flutter client
2. Compute diff: added = incoming - current, removed = current - incoming
3. Insert/update subreddit_configs for added subreddits (enabled=1)
4. Disable removed subreddits (enabled=0) — also deletes their queue items
5. Fire async ensure_subreddit_has_content() for each added subreddit
6. Return sync summary {synced, added, removed, total}
```

#### POST /api/subreddits/fetch

```
1. Clean and lower subreddit name
2. Add/update subreddit_configs (enabled=1)
3. Call QueueManager.fetch_and_store(subreddit)
4. Return {subreddit, fetched}
```

#### GET /api/search/reddit

```
1. Create RedditClient with fresh OAuthManager + ProviderManager
2. OAuthManager.initialize() — loads/acquires token
3. Call RedditClient.search_reddit(query, limit, after, subreddits, mode)
   │
   ├── Global mode: Calls _accumulate_search() — scans Reddit up to 20 pages
   │   or until target_results (limit × 4, min 100) media items are found,
   │   within SEARCH_TIME_BUDGET_SECONDS (5s). Uses single Reddit OAuth
   │   search request per page, passes restrict_sr=on if subreddits given.
   │
   └── Local mode: Calls _search_local_multi(query, subreddits, target_results)
       — searches EACH selected subreddit individually via _accumulate_search()
       (accepts after parameter but cursor is always returned as None in local
       mode, preventing incremental pagination), then merges and deduplicates
       by post id. Bypasses Reddit's multi-subreddit search bug
       (r/sub1+sub2/search returns 0 results for many queries).
       Passes include_over_18=on for NSFW content.

4. _parse_post() converts raw dicts → MediaAsset objects
5. validate_media() + _validate_search_asset() filter low-quality items
6. _asset_to_response() enriches with gallery URLs
7. Return FeedResponse (NO storage in search_results table)
```

**Error handling**: The entire `search_reddit()` call is wrapped in try/except. On any exception, returns `FeedResponse(items=[], after=None, has_more=False)`.

#### GET /api/search (FTS5)

```
1. Parse params (q, limit, page, subreddits, media_type, sort)
2. Call QueueManager.search()
   → MATCH query against media_search FTS5 table
   → JOIN with media_assets
   → Optional filters: subreddits, media_type (images/galleries/videos)
   → Optional sort: relevance (default), newest, most_upvoted
3. Enrich with gallery URLs
4. Return SearchResponse
```

### Response Schemas

```json
// MediaAssetResponse
{
  "id": "string",
  "title": "string",
  "author": "string",
  "score": "integer",
  "subreddit": "string",
  "media_url": "string",
  "video_url": "string|null",
  "thumbnail_url": "string|null",
  "is_video": "boolean",
  "is_gallery": "boolean",
  "nsfw": "boolean",
  "quality_score": "integer",
  "width": "integer|null",
  "height": "integer|null",
  "duration": "integer|null",
  "created_utc": "integer|null",
  "gallery_urls": "string[]|null"
}

// FeedResponse
{
  "items": "MediaAssetResponse[]",
  "after": "string|null",
  "has_more": "boolean"
}

// SearchResponse
{
  "items": "MediaAssetResponse[]",
  "page": "integer",
  "limit": "integer",
  "total_results": "integer",
  "has_more": "boolean",
  "after": "string|null"
}

// HealthResponse
{
  "status": "ok|degraded",
  "database": "boolean",
  "oauth_valid": "boolean",
  "queue_size": "integer",
  "providers": { "primary": "string", "fallback": "string" }
}
```

---

## Services Layer

### QueueManager (`app/services/queue_manager.py`)

The central service for queue and subreddit management.

**Note on deprecation**: The `media_queue`-based approach (slide show sourced from queue) is deprecated. The primary feed path uses cursor-based pagination directly on `media_assets` via `get_subreddit_assets()`. Queue methods (`get_queue_items()`, `manage_queue()`, `_refill_queue()`) are marked as deprecated and no longer used by the slideshow.

**Queue thresholds (used only by background service for per-subreddit refill):**
| Threshold | Value | Action |
|-----------|-------|--------|
| MAX | 1000 | Trim excess (deprecated) |
| MIN | 500 | — |
| REFILL | 300 | Refill when below |
| EMERGENCY | 100 | Emergency refill (200 items) (deprecated) |

**Key methods:**

| Method | Purpose |
|--------|---------|
| `get_subreddit_assets(subreddit, limit, after_cursor)` | **PRIMARY** — Cursor-based pagination on `media_assets` by `(created_utc DESC, reddit_id DESC)`. If `subreddit` is None, returns assets from all subreddits. Returns `(items, next_cursor, has_more)` with cursor format `"created_utc,reddit_id"` |
| `get_queue_items(limit, offset, subreddits)` | DEPRECATED — Queue-based pagination. Returns `(items, has_more)` |
| `add_to_queue(asset)` | Insert asset into `media_assets` + `media_queue` + `gallery_items`. Dedup by `reddit_post_id` |
| `remove_from_queue(reddit_post_id)` | Delete from queue |
| `clear_queue()` | Truncate queue |
| `search(query, limit, offset, ...)` | FTS5 search with filters (subreddits, media_type, sort) |
| `get_gallery_urls(reddit_ids)` | Fetch gallery item URLs for given IDs |
| `fetch_and_store(subreddit, limit, sort, after)` | Create RedditClient, fetch media, store in queue, register subreddit |
| `ensure_subreddit_has_content(subreddit, sort)` | Cursor-based paginated fetch — reads stored cursor, fetches next page, stores new cursor. Resets cursor on empty response |
| `manage_queue()` | DEPRECATED — No longer used by slideshow |
| `_refill_queue(count)` | DEPRECATED — Stub |
| `_trim_queue(max_size)` | Trim excess queue items |
| `add_or_update_subreddit_config(subreddit)` | Insert/update with `enabled=1` |
| `get_enabled_subreddits()` | List all enabled subreddits |
| `disable_subreddit(subreddit)` | Set `enabled=0`, delete all queue items for this subreddit |
| `get_stored_cursor / set_stored_cursor` | Persist Reddit pagination cursors per subreddit+sort |
| `count_subreddit_items(subreddit)` | Count assets for a subreddit |
| `cleanup_old_assets(days)` | DELETE media_assets older than N days |

**URL sanitization:** `QueueManager._sanitize_url()` replaces `external-preview.redd.it` → `preview.redd.it` and `external-i.redd.it` → `i.redd.it` on all URLs.

### RedditClient (`app/services/reddit_client.py`)

Fetches and validates media from Reddit. Contains two independent pipelines:
one for **feed fetching** (`fetch_subreddit_media` → `_fetch_oauth`) and one
for **live search** (`search_reddit` → `_accumulate_search` / `_search_local_multi`).

#### Feed Fetching

**`fetch_subreddit_media(subreddit, limit, after, sort)`** — Fetches media
from a single subreddit for the queue/background refresh pipeline, using
`_fetch_oauth` (Reddit OAuth) or `_fetch_redlib` (stub fallback).

**`_fetch_oauth` failure handling:**
- **401**: Refresh token, record failure, fallback to Redlib
- **Non-200**: Record failure, fallback to Redlib
- **Success**: Record success for OAuth + provider

`_fetch_redlib` is a **stub** — returns `[], None`.

#### Live Reddit Search (v4.1)

Three-tier architecture that replaced the original single-page search:

```
search_reddit()
  │
  ├── Local mode + subreddits present:
  │     └── _search_local_multi(query, subreddits, target_results, after)
  │           ├── for each subreddit:
  │           │     └── _accumulate_search(query, [subreddit], mode="local")
  │           │           └── _search_oauth() → page loop up to 20 pages
  │           ├── merge all results
  │           └── deduplicate by post "id"
  │
  └── Global mode (or no subreddits):
        └── _accumulate_search(query, subreddits, mode="global")
              └── _search_oauth() → page loop up to 20 pages
```

**Constants:**
| Constant | Value | Purpose |
|----------|-------|---------|
| `SEARCH_MAX_PAGES` | 20 | Max Reddit pages scanned per accumulation |
| `SEARCH_TIME_BUDGET_SECONDS` | 5.0 | Max wall-clock time per accumulation |
| `target_results` | `max(limit * 4, 100)` | Stop accumulating when enough media found |

**Key methods:**

| Method | Purpose |
|--------|---------|
| `search_reddit(query, limit, after, subreddits, mode)` | Entry point. Delegates to `_search_local_multi` (local) or `_accumulate_search` (global). Returns `(list[dict], cursor)` |
| `_search_local_multi(query, subreddits, target_results, after)` | Iterates subreddits individually, calls `_accumulate_search` per subreddit, merges, deduplicates by `id`. Accepts `after` parameter but cursor is always returned as `None`, preventing incremental pagination. Budget: `SEARCH_TIME_BUDGET_SECONDS × 1.5`. Returns `(merged_list, None)` |
| `_accumulate_search(query, subreddits, mode, target_results)` | Accumulation loop: fetches pages of 25 via `_search_oauth` until target reached, pages exhausted, or time budget exceeded. Returns `(results, last_cursor, SearchAuditResult)` |
| `_search_oauth(query, limit, after, subreddits, mode)` | Single Reddit OAuth search HTTP request. Builds URL (`r/sub/search` for local, `search` for global). Adds `restrict_sr=on` + `include_over_18=on` for local mode. Returns raw post dicts |

**Why per-subreddit search for local mode?** Reddit's OAuth API returns 0
children for multi-subreddit restricted searches
(`r/sub1+sub2/search?restrict_sr=on&q=...`) even when individual subreddits
contain many matching posts. `_search_local_multi` works around this by
searching each subreddit separately and deduplicating the merged results.

**`SearchAuditResult`** — Dataclass used during accumulation to track:
`raw_posts`, `text_posts_removed`, `non_media_removed`,
`subreddit_filtered`, `kept`, `images`, `galleries`, `videos`.

#### Media URL Extraction Logic

1. **Gallery posts**: Extract all images from `media_metadata`, use first as primary `media_url`, store all as `gallery_items`
2. **Video posts**: Extract `reddit_video.fallback_url` as both `media_url` and `video_url`
3. **Direct image**: If URL ends with `.jpg/.jpeg/.png/.gif/.webp`, use as-is
4. **Preview fallback**: Use `preview.images[0].source.url`
5. **Thumbnail**: From `preview.images[0].source.url` (fallback to smallest resolution)

#### Quality validation (`validate_media`):
- Reject if `"thumbnail"` is in the media_url path
- Reject if `width < 400` or `height < 300`
- Calculate quality score (base: 50, resolution bonus up to +20, video: +10, score bonus: +5/+10)

#### Quality scoring:
| Condition | Bonus |
|-----------|-------|
| Base score | 50 |
| 1MP+ (pixels > 1,000,000) | +5 |
| 2MP+ (pixels > 2,000,000) | +10 |
| 4MP+ (pixels > 4,000,000) | +20 |
| Is video | +10 |
| Score > 500 | +5 |
| Score > 1000 | +10 |
| Maximum | 100 |

#### Search-specific validation (`_validate_search_asset`):
- Reject deleted/removed posts (checking title and author)
- Reject if `"thumbnail"` is in any URL path
- Reject if `width < 400` or `height < 300`
- Reject gallery posts missing gallery items

### BackgroundRefreshService (`app/services/background_service.py`)

Runs on APScheduler with two periodic jobs. Creates its own `OAuthManager`,
`ProviderManager`, and `RedditClient` instances (not shared with API routers).

| Job | Interval | Logic |
|-----|----------|-------|
| `_refresh_job` | 60 seconds | 1. Get all enabled subreddits from subreddit_configs. 2. Find subreddits with asset count < QUEUE_REFILL (300). 3. Sort by count ascending. 4. Pick the lowest-count subreddit. 5. Read stored cursor. 6. Fetch next page from Reddit OAuth (limit=50). 7. Store assets in queue. 8. Update cursor (reset to None if no items returned). |
| `_cleanup_job` | 86400 seconds (24h) | DELETE from `media_queue` where `added_at < 30 days ago` |

**Note**: The background service no longer calls `manage_queue()` for global queue thresholds. Each tick checks per-subreddit counts and refills the lowest-count subreddit that falls below the threshold.

---

## Managers Layer

### OAuthManager (`app/managers/oauth.py`)

Manages Reddit OAuth token lifecycle.

**Note on instance sharing:** The `OAuthManager` instance created during startup in `app/main.py` is not shared with API routers or the background service. Each endpoint that needs OAuth (e.g., `/api/search/reddit` in `search.py`, `QueueManager.fetch_and_store()` in `feed.py`, `BackgroundRefreshService` in `background_service.py`) creates its own fresh instances, loading the token from the database again.

**Token acquisition flow:**
1. On `initialize()`: Load token from `oauth_tokens` table
2. If no token: `_acquire_initial_token()` via `client_credentials` grant → POST to `reddit.com/api/v1/access_token`
3. Token storage: upsert into `oauth_tokens` with `expires_at`, `success_count`, `failure_count`
4. Before API calls (`get_valid_token()`): Check if `expires_at <= now + 300s` → refresh
5. `refresh_token()`: If refresh_token stored → `_refresh_with_token()`, else → `_acquire_initial_token()`
6. Exponential backoff: `1s, 2s, 4s` (3 max retries)
7. Health tracking via `record_success()` / `record_failure()` updates `oauth_tokens` table

### ProviderManager (`app/managers/provider.py`)

Circuit breaker for provider failover.

| Setting | Value |
|---------|-------|
| FAILURE_THRESHOLD | 5 failures |
| COOLDOWN_SECONDS | 300 (5 minutes) |
| Primary provider | `reddit_oauth` |
| Fallback provider | `redlib` |

**State machine:**
```
HEALTHY ──┐
  ▲       │ 1-4 failures
  │       ▼
  │     WARNING (still returns primary)
  │       │
  │       │ 5th failure
  │       ▼
  │     COOLDOWN ──300s──▶ FALLBACK (returns redlib)
  │                              │
  └────── success resets ────────┘
```

---

## Database Layer

### Schema

#### oauth_tokens
| Column | Type | Notes |
|--------|------|-------|
| id | INTEGER PK | AUTOINCREMENT |
| access_token | TEXT NOT NULL | Bearer token |
| refresh_token | TEXT | Nullable |
| token_type | TEXT | Default: 'bearer' |
| expires_at | INTEGER | Unix timestamp |
| created_at | INTEGER | |
| last_refreshed | INTEGER | |
| success_count | INTEGER | Default 0 |
| failure_count | INTEGER | Default 0 |
| last_success | INTEGER | Nullable |
| last_failure | INTEGER | Nullable |

Index: `idx_expires` on `expires_at`

#### media_assets
| Column | Type | Notes |
|--------|------|-------|
| id | TEXT PK | `{subreddit}_{reddit_id}` |
| reddit_id | TEXT UNIQUE | Reddit post ID |
| permalink | TEXT UNIQUE | Reddit permalink |
| media_url | TEXT NOT NULL | Resolved media URL |
| title | TEXT | |
| author | TEXT | |
| score | INTEGER | Reddit score |
| subreddit | TEXT | Lowercase |
| video_url | TEXT | Nullable |
| thumbnail_url | TEXT | Nullable |
| created_utc | INTEGER | Reddit creation time |
| is_video | BOOLEAN | |
| is_gallery | BOOLEAN | |
| nsfw | BOOLEAN | |
| quality_score | INTEGER | Default 50 |
| source_provider | TEXT | Default 'reddit_oauth' |
| width | INTEGER | Nullable |
| height | INTEGER | Nullable |
| duration | INTEGER | Nullable (videos) |
| created_at | INTEGER | When inserted |
| last_seen | INTEGER | |

Unique constraint: `(reddit_id, media_url)`
Indexes: `idx_subreddit_created`, `idx_created_utc`, `idx_source_provider`, `idx_quality`

#### gallery_items
| Column | Type | Notes |
|--------|------|-------|
| id | INTEGER PK | AUTOINCREMENT |
| reddit_id | TEXT NOT NULL | FK → media_assets(reddit_id) |
| item_url | TEXT NOT NULL | Gallery image URL |
| item_order | INTEGER | Position in gallery |
| width | INTEGER | Nullable |
| height | INTEGER | Nullable |
| created_at | INTEGER | |

Unique: `(reddit_id, item_order)`
Indexes: `idx_gallery_reddit_id`, `idx_gallery_order`

#### media_queue
| Column | Type | Notes |
|--------|------|-------|
| id | INTEGER PK | AUTOINCREMENT |
| reddit_post_id | TEXT UNIQUE | FK → media_assets(id) |
| position | INTEGER | Queue ordering |
| added_at | INTEGER | |
| group_id | INTEGER | Nullable (future groups feature) |

Indexes: `idx_position`, `idx_added`

#### subreddit_configs
| Column | Type | Notes |
|--------|------|-------|
| subreddit | TEXT PK | Lowercase |
| enabled | BOOLEAN | Default TRUE |
| provider | TEXT | Default 'reddit_oauth' |
| sort_mode | TEXT | Default 'hot' |
| refresh_interval | INTEGER | Default 300 |
| last_hot_after | TEXT | Cursor (migration added) |
| last_new_after | TEXT | Cursor (migration added) |
| last_top_after | TEXT | Cursor (migration added) |

Index: `idx_enabled`

#### search_results (currently unused by search endpoint)
| Column | Type | Notes |
|--------|------|-------|
| id | INTEGER PK | AUTOINCREMENT |
| search_query | TEXT |
| reddit_id | TEXT |
| title | TEXT |
| author | TEXT |
| subreddit | TEXT |
| media_url | TEXT |
| video_url | TEXT | Nullable |
| thumbnail_url | TEXT | Nullable |
| is_video | BOOLEAN |
| is_gallery | BOOLEAN |
| nsfw | BOOLEAN |
| width | INTEGER | Nullable |
| height | INTEGER | Nullable |
| duration | INTEGER | Nullable |
| score | INTEGER |
| permalink | TEXT |
| created_utc | INTEGER |
| cached_at | INTEGER |
| hide_from_results | BOOLEAN | Default FALSE |

Unique: `(reddit_id, search_query)`
Indexes: `idx_search_query`, `idx_search_cached`

**Note:** The `search_results` table was previously used to cache search
results returned by `/api/search/reddit`. As of Search v3, results are no
longer stored in this table — they are returned live from Reddit and
discarded after the API response. The table schema remains for backward
compatibility but is not populated by any active code path.

#### media_search (FTS5 virtual table)
| Column | Type |
|--------|------|
| reddit_post_id | TEXT |
| title | TEXT |
| subreddit | TEXT |
| author | TEXT |

**Triggers** (on `media_assets`):
- `after_media_insert` → INSERT into media_search
- `after_media_update` → DELETE old + INSERT new (on reddit_id/title/subreddit change)
- `after_media_delete` → DELETE from media_search

### Key SQL Queries

```sql
-- Get subreddit assets (cursor-based — PRIMARY feed path)
SELECT ma.* FROM media_assets ma
WHERE ma.subreddit = ?                     -- optional (None = all subreddits)
  AND (ma.created_utc < ? OR (ma.created_utc = ? AND ma.reddit_id < ?))  -- cursor
ORDER BY ma.created_utc DESC, ma.reddit_id DESC
LIMIT ?;

-- Get queue items (paginated, optionally filtered by subreddits — DEPRECATED)
SELECT ma.* FROM media_assets ma
JOIN media_queue mq ON ma.reddit_id = mq.reddit_post_id
ORDER BY mq.position ASC
LIMIT ? OFFSET ?;

-- FTS5 search with filters
SELECT ma.* FROM media_assets ma
WHERE ma.reddit_id IN (
    SELECT reddit_post_id FROM media_search 
    WHERE media_search MATCH ?
)
AND ma.subreddit IN (?, ?, ...)         -- optional
AND ma.is_video = 0 AND ma.is_gallery = 0  -- optional (media_type filter)
ORDER BY ma.quality_score DESC, ma.score DESC
LIMIT ? OFFSET ?;

-- Add to queue (asset + gallery items + queue entry)
INSERT OR IGNORE INTO media_assets (...) VALUES (...);
INSERT OR IGNORE INTO gallery_items (...) VALUES (...);
INSERT INTO media_queue (reddit_post_id, position, added_at) VALUES (?, ?, ?);
```

---

## Data Models (Pydantic)

All models in `app/models/schemas.py`:

| Model | Purpose |
|-------|---------|
| `MediaAsset` | Internal model for representing a Reddit post's media |
| `MediaAssetResponse` | API response model (adds `gallery_urls`, `created_utc` fields) |
| `FeedResponse` | Wrapper for feed/search results (`items`, `after`, `has_more`) |
| `QueueResponse` | Queue status (`items`, `total`, `pending`) |
| `SearchResponse` | Search results with `page`, `limit`, `total_results` |
| `SubredditConfig` | Subreddit configuration model |
| `OAuthToken` | Token storage model |
| `HealthResponse` | Health check response |
| `ProviderStatus` | Provider health status |

---

## Background Service

### Refresh Job Detailed Flow

```
_refresh_job()  (every 60s)
  │
  └── _get_subreddits_needing_refill()
      │ Query enabled subreddits from subreddit_configs
      │ For each: count_subreddit_items() < 300
      │ Sort ascending by count
      │ Pick the first (lowest-count) subreddit
      │
      └── QueueManager.fetch_and_store() via RedditClient.fetch_subreddit_media()
          ├── Read stored cursor for this subreddit+sort
          ├── Fetch next page from Reddit OAuth (limit=50)
          ├── Parse & validate media assets
          ├── add_to_queue() for each valid asset
          └── Update stored cursor
              (reset to None if no items returned → end of pagination)
```

### Cleanup Job

```
_cleanup_job()  (every 24h)
  │
  └── DELETE FROM media_queue WHERE added_at < (now - 30 days)
```

Note: `media_assets` are not auto-cleaned. Only `media_queue` entries are pruned.

---

## Frontend Integration

### Flutter Merge Engine

The backend rejects multi-subreddit requests. The Flutter Merge Engine
(`lib/features/slideshow/domain/merge_engine.dart`) handles this client-side
using the `MediaSource` abstraction:

```
User selects multiple subreddits for slideshow
  │
  └── SlideshowNotifier._buildMediaSources()
      ├── Maps SlideshowSource → List<MediaSource>
      │     SubredditSource → [SubredditMediaSource]
      │     MultiSubredditSource → [SubredditMediaSource × N]
      │     GlobalFeedSource → [SubredditMediaSource × allConfigured]
      │     SearchSource → [SearchMediaSource]
      │     GroupSource → [SubredditMediaSource × groupSubreddits]
      │
      └── MergeEngine.initialize()
          ├── Creates N SourceBuffers (one per MediaSource)
          ├── Fires N parallel loadNext() calls
          ├── Each buffer fetches cursor-based pages
          └── generateBatch() → round-robin merge with freshness+diversity scoring
              │
              ├── Freshness: 35% weight based on post age (max 7 days)
              ├── Diversity: 20% weight (penalizes consecutive same-buffer,
              │     same-author, same-domain)
              └── Randomness: 45% weight for variety
```

For architecture details on the Merge Engine, slideshow, and preloading, see `frontend.md`.

---

## Configuration

### Environment Variables (.env)

```
REDDIT_CLIENT_ID=your_client_id
REDDIT_CLIENT_SECRET=your_client_secret
REDDIT_USER_AGENT=RedSlide/1.0 by u/your_username
DATABASE_PATH=./data/redslide.db
```

**Note:** `praw` (Reddit Python wrapper) is listed in `requirements.txt` but is **not used** anywhere in the codebase. All Reddit API calls use raw `httpx` requests.

### Reddit OAuth Setup
1. Go to https://www.reddit.com/prefs/apps
2. Create a "script" app
3. Use the `client_id` (under the app name) and `client_secret`
4. Token is auto-acquired on startup via `client_credentials` grant

---

## Deployment

### Docker

```bash
docker build -t redslide-backend ./backend
docker run -p 8000:8000 --env-file ./backend/.env redslide-backend
```

### Manual

```bash
cd backend
pip install -r requirements.txt
python main.py  # uvicorn on 0.0.0.0:8000
```

---

## Error Handling Patterns

### Multi-Subreddit Rejection
`feed.py` — Explicit 400 to force Flutter-side merging:
```python
if subreddit_list and len(subreddit_list) > 1:
    raise HTTPException(
        status_code=400,
        detail="Multi subreddit handled by Flutter Merge Engine.",
    )
```

### Media Not Found
`feed.py` — Single endpoint with explicit 404:
```python
if not row:
    raise HTTPException(status_code=404, detail="Media not found")
```

### Queue Insert Failure
`queue_manager.py` — Silently returns `False`:
```python
try:
    await db.execute(...)
    await db.commit()
    return True
except Exception:
    return False  # Duplicate or constraint violation
```

### OAuth Provider 401
`reddit_client.py` — Auto-refresh + fallback:
```python
if response.status_code == 401:
    await self.oauth.refresh_token()
    await self.provider_manager.record_provider_failure("reddit_oauth")
    return await self._fetch_redlib(subreddit, limit, after, sort)  # Fallback
```

### Background Job Errors
`background_service.py` — Caught and logged, job continues:
```python
except Exception as e:
    print(f"Error fetching from {subreddit}: {e}")
```

### Pagination Cursor Reset
`queue_manager.py` — On empty response, cursor resets to None:
```python
if added == 0 and new_cursor is None:
    await self.set_stored_cursor(subreddit, sort, None)
```

### Search Error Handling
`search.py` — Entire search wrapped in try/except:
```python
try:
    items, new_after = await client.search_reddit(...)
except Exception as e:
    print(f"[SEARCH_ERROR] query={q} error={e}")
    return FeedResponse(items=[], after=None, has_more=False)
```

---

## Known Limitations

1. **Redlib fallback is a stub** — `_fetch_redlib()` returns `[], None`
2. **No rate limiting** — API is unprotected against abuse
3. **SQLite single-instance** — not suitable for horizontal scaling (use PostgreSQL for production)
4. **FTS5 token-level matching** — "city" won't match "cityscape" (use `/api/search/debug` for substring LIKE fallback)
5. **No CASCADE DELETE** — `media_queue` and `gallery_items` rows for deleted `media_assets` must be cleaned up manually
6. **Cleanup only prunes `media_queue`** — `media_assets` and `gallery_items` are not auto-cleaned beyond 30 days
7. **OAuth token has no public setup endpoint** — must be configured via `.env` before first startup
8. **Local search budget is 1.5× global budget** — `_search_local_multi` uses `SEARCH_TIME_BUDGET_SECONDS × 1.5` to accommodate N subreddits, which may still time out if many subreddits are selected
9. **`_search_local_multi` ignores incoming `after` cursor** — each call starts fresh; cursor is always returned as `None`, preventing incremental pagination for local search
10. **OAuth initialized multiple times** — startup lifespan, BackgroundRefreshService, and every API call all create separate `OAuthManager` instances calling `initialize()`
11. **Global instances not shared with routers** — the `oauth_manager` and `background_service` globals in `app/main.py` are never passed to API endpoints; each request creates fresh instances
12. **`praw` dependency unused** — `praw>=7.8.0` is in `requirements.txt` but no code imports it
13. **`media_queue`-based feed is deprecated** — `get_queue_items()`, `manage_queue()`, `_refill_queue()` are stubs marked for future removal. The slideshow exclusively uses `get_subreddit_assets()` cursor-based pagination
14. **Multi-subreddit merging is Flutter-only** — the backend returns 400 for multi-subreddit requests, putting all merge complexity on the client
