# RedSlide Application Documentation

## Table of Contents
1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Backend System](#backend-system)
4. [Frontend System](#frontend-system)
5. [Data Flow](#data-flow)
6. [API Endpoints](#api-endpoints)
7. [Database Schema](#database-schema)
8. [Configuration](#configuration)
9. [Deployment](#deployment)
10. [Development Setup](#development-setup)
11. [Known Limitations](#known-limitations)
12. [Future Improvements](#future-improvements)
13. [Detailed Working](#detailed-working)
14. [Appendix](#appendix)

---

## Overview

**RedSlide** is a media discovery application designed to provide a slideshow experience for Reddit content. The application consists of:

- **Backend**: A Python FastAPI server that handles media discovery, queue management, and API endpoints
- **Frontend**: A Flutter mobile application for Android (with potential for iOS and web)

### Purpose
RedSlide aggregates media content from Reddit subreddits and presents it in a slideshow format, allowing users to browse images and videos from their favorite communities.

### Key Features
- Media feed from Reddit subreddits
- Queue-based slideshow management
- Full-text search across media assets
- OAuth-based authentication with Reddit
- Provider failover (Reddit OAuth → Redlib fallback)
- Background queue management
- Quality filtering for media assets

---

## Architecture

### High-Level Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        FLUTTER FRONTEND                          │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    Mobile Application                     │  │
│  │  - Material Design UI                                      │  │
│  │  - API Client (HTTP requests to backend)                   │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────┐
│                          BACKEND API                              │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                   FastAPI Application                     │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐    │  │
│  │  │  Feed   │  │ Debug   │  │ OAuth   │  │ Reddit  │    │  │
│  │  │ Router  │  │ Router  │  │Manager  │  │ Client  │    │  │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘    │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────┐
│                        SERVICE LAYER                            │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              Queue Manager & Background Service            │  │
│  │  - Queue management (add/remove/refill)                  │  │
│  │  - Background scheduling (APScheduler)                   │  │
│  │  - Media cleanup (old assets)                            │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────┐
│                       DATA LAYER                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              SQLite Database (AIOSQLITE)                 │  │
│  │  Tables:                                                 │  │
│  │  - oauth_tokens     (OAuth token storage)                │  │
│  │  - media_assets     (Media metadata)                     │  │
│  │  - media_queue      (Slideshow queue)                    │  │
│  │  - subreddit_configs (Subreddit settings)               │  │
│  │  - media_search     (FTS5 full-text search)              │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Technology Stack

#### Backend
- **Framework**: FastAPI (Python 3.11+)
- **ASGI Server**: Uvicorn
- **Database**: SQLite with aiosqlite (async)
- **Search**: FTS5 (Full-Text Search)
- **Scheduling**: APScheduler
- **HTTP Client**: httpx
- **Validation**: Pydantic
- **Configuration**: python-dotenv

#### Frontend
- **Framework**: Flutter (Dart)
- **UI**: Material Design
- **Platform**: Android (primary), with support for iOS and web

---

## Backend System

### Application Entry Point

The backend application starts from `backend/app/main.py`, which:
1. Loads environment variables from `.env` file
2. Initializes the database connection
3. Creates the FastAPI application instance
4. Registers API routers (feed, debug)
5. Initializes the OAuth manager for Reddit authentication

### Component Breakdown

#### 1. Core Database (`app/core/database.py`)

**Purpose**: Manages SQLite database connections and schema initialization.

**Key Functions**:
- `init_db()`: Creates all database tables and indexes on startup
- `get_db()`: Provides async database connection context manager

**Tables Created**:
| Table | Purpose |
|-------|---------|
| `oauth_tokens` | Stores Reddit OAuth tokens with expiration tracking |
| `media_assets` | Stores media metadata (images, videos, galleries) |
| `media_queue` | Manages slideshow queue with position ordering |
| `subreddit_configs` | Stores per-subreddit configuration |
| `media_search` | FTS5 virtual table for full-text search |

**Database Features**:
- UNIQUE constraints for deduplication
- Automatic FTS5 index synchronization via triggers
- Indexes for performance optimization

#### 2. API Layer (`app/api/`)

##### Feed Router (`feed.py`)
Handles media feed and search endpoints:
- `GET /api/feed` - Returns paginated media feed
- `GET /api/feed/queue` - Returns queue status
- `GET /api/search` - Full-text search with pagination
- `GET /api/search/debug` - Debug search without FTS5
- `GET /api/media/{id}` - Get specific media item
- `POST /api/media/start/{id}` - Start slideshow from item

##### Debug Router (`debug.py`)
Internal debugging endpoints:
- `GET /api/health` - System health check
- `GET /api/debug/providers` - Provider status
- `GET /api/debug/queue` - Queue diagnostics

#### 3. Managers Layer (`app/managers/`)

##### OAuth Manager (`oauth.py`)
**Purpose**: Handles Reddit OAuth authentication and token management.

**Features**:
- Token storage in SQLite with expiration tracking
- Automatic token refresh before expiry
- Success/failure tracking for health monitoring
- Internal (non-public) endpoint design

**Flow**:
1. On startup: Load existing token from database
2. Before API call: Check if token needs refresh
3. On 401 error: Trigger token refresh automatically
4. Record success/failure for monitoring

##### Provider Manager (`provider.py`)
**Purpose**: Manages API provider health and failover.

**Features**:
- Circuit breaker pattern (5 failures → 5 min cooldown)
- Primary provider: Reddit OAuth
- Fallback provider: Redlib (alternative Reddit API)
- Exponential backoff for retries

**Health Logic**:
- Tracks failure count per provider
- Triggers cooldown when threshold exceeded
- Automatically switches to fallback during cooldown

#### 4. Services Layer (`app/services/`)

##### Queue Manager (`queue_manager.py`)
**Purpose**: Manages the slideshow queue persistently.

**Key Operations**:
- `add_to_queue()`: Add media to queue with deduplication
- `get_queue_items()`: Retrieve items ordered by position
- `remove_from_queue()`: Remove specific item
- `clear_queue()`: Clear entire queue
- `manage_queue()`: Auto-refill/trim based on thresholds
- `search()`: FTS5-powered search

**Queue Thresholds**:
| Metric | Value |
|--------|-------|
| Max Size | 1000 items |
| Min Size | 500 items |
| Refill Threshold | 300 items |
| Emergency Threshold | 100 items |

##### Reddit Client (`reddit_client.py`)
**Purpose**: Fetches media from Reddit with quality validation.

**Features**:
- Dual-provider support (OAuth + Redlib fallback)
- Media URL extraction for images, videos, galleries
- Quality validation (minimum 800x600 pixels)
- Quality scoring algorithm
- Automatic failover on API errors

**Quality Scoring**:
- Base score: 50
- Resolution bonus: +5 (1MP+) / +10 (2MP+) / +20 (4MP+)
- Video bonus: +10
- Score bonus: +5 (500+) / +10 (1000+)
- Maximum score: 100

##### Background Service (`background_service.py`)
**Purpose**: Scheduled jobs for queue management.

**Jobs**:
- Refresh Job (every 5 minutes): Queue maintenance
- Cleanup Job (every 24 hours): Remove assets older than 30 days

**Service Architecture:**
```
BackgroundRefreshService
├── Scheduler (APScheduler)
│   ├── Refresh Job (every 5 min)
│   │   └── QueueManager.manage_queue()
│   └── Cleanup Job (every 24 hours)
│       └── QueueManager.cleanup_old_assets()
├── RedditClient
│   ├── OAuthManager
│   └── ProviderManager
└── QueueManager
```

**Refresh Job Details:**
1. Calls `QueueManager.manage_queue()`
2. Checks current queue size against thresholds
3. Emergency (< 100 items): Refill with 200 items
4. Low (< 300 items): Refill with 100 items
5. High (> 1000 items): Trim to max size
6. Uses `RedditClient` to fetch new media from configured subreddits

**Cleanup Job Details:**
1. Calculates cutoff: `now - 30 days`
2. Executes: `DELETE FROM media_queue WHERE added_at < cutoff`
3. Note: `media_assets` are not auto-cleaned; only `media_queue` entries are pruned

**Note:** There are no CASCADE DELETE constraints. Queue entries and gallery items must be deleted explicitly.

**Scheduler Configuration:**
```python
scheduler = AsyncIOScheduler()
scheduler.add_job(
    self._refresh_job,
    IntervalTrigger(seconds=300),
    id="refresh_job"
)
scheduler.add_job(
    self._cleanup_job,
    IntervalTrigger(seconds=86400),
    id="cleanup_job"
)
scheduler.start()
```

---

## Frontend System

### Current State

The Flutter frontend (`lib/main.dart`) is currently in a **boilerplate state** with the default Flutter counter application. It has NOT been implemented yet.

### Expected Architecture (Planned)

```
lib/
├── main.dart              # Entry point
├── models/
│   └── media_asset.dart   # MediaAsset model
├── services/
│   └── api_service.dart   # HTTP client for backend API
├── providers/
│   └── feed_provider.dart # State management
├── screens/
│   ├── home_screen.dart   # Main feed/slideshow
│   └── search_screen.dart # Search interface
└── widgets/
    ├── media_card.dart    # Media display widget
    └── queue_indicator.dart # Queue status
```

### Planned Features
- Media feed display
- Slideshow mode
- Search interface
- Queue management UI
- Reddit authentication flow

---

## Data Flow

### Media Discovery Flow

```
1. User opens app → App calls /api/feed
2. Backend checks queue size
3. If queue < threshold → Background service fetches new media
4. RedditClient calls Reddit API (OAuth)
5. Media parsed and validated
6. Assets stored in media_assets table
7. Assets added to media_queue table
8. Response returned to client
```

### Search Flow

```
1. User searches → App calls /api/search?q=query
2. Backend queries FTS5 media_search table
3. Results joined with media_assets
4. Pagination applied
5. Results returned to client
```

### OAuth Flow

```
1. App starts → OAuthManager.initialize()
2. Check for stored token in database
3. If no valid token → Cannot fetch media
4. Token auto-refreshes before expiry
5. Failed tokens trigger provider failover
```

#### Error Handling in OAuth Flow

| Error Code | Action |
|------------|--------|
| 401 (Unauthorized) | Refresh token, record provider failure, switch to fallback |
| 403 (Forbidden) | Record provider failure, switch to fallback |
| 500 (Server Error) | Record provider failure, switch to fallback |
| Network Error | Record provider failure, switch to fallback |

#### Token Expiration Handling

Tokens are considered expired when:
```python
expires_at <= current_time + 300  # 5 minute buffer
```

This ensures tokens are refreshed before they actually expire, preventing failed API calls.

---

## API Endpoints

### Production Endpoints

| Method | Endpoint | Description | Auth Required |
|--------|----------|-------------|---------------|
| GET | `/api/feed` | Get media feed | No |
| GET | `/api/feed/queue` | Get queue status | No |
| GET | `/api/search` | Search media (FTS5) | No |
| GET | `/api/search/debug` | Debug search (LIKE, no FTS5) | No |
| GET | `/api/media/{id}` | Get media details | No |
| POST | `/api/media/start/{id}` | Start slideshow | No |

### Query Parameters

#### GET /api/feed
| Parameter | Type | Default | Max | Description |
|-----------|------|---------|-----|-------------|
| limit | int | 20 | 100 | Number of items |
| after | string | null | - | Pagination cursor |
| subreddits | string | null | - | Comma-separated list |
| sort | string | "hot" | - | Sort mode (hot/new/top) |

#### GET /api/search
| Parameter | Type | Default | Min | Description |
|-----------|------|---------|-----|-------------|
| q | string | required | 1 | Search query |
| limit | int | 20 | 1 | Items per page |
| page | int | 1 | 1 | Page number |

### Response Schemas

#### MediaAssetResponse
```json
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
  "duration": "integer|null"
}
```

#### FeedResponse
```json
{
  "items": "MediaAssetResponse[]",
  "after": "string|null",
  "has_more": "boolean"
}
```

#### HealthResponse
```json
{
  "status": "ok|degraded",
  "database": "boolean",
  "oauth_valid": "boolean",
  "queue_size": "integer",
  "providers": "{primary, fallback}"
}
```

---

## Database Schema

### Entity Relationship Diagram

```
oauth_tokens
┌─────────────────────────────────────────────────────┐
│ id (PK)      │ INTEGER PRIMARY KEY AUTOINCREMENT   │
│ access_token    │ TEXT NOT NULL                       │
│ refresh_token   │ TEXT                               │
│ token_type      │ TEXT DEFAULT 'bearer'               │
│ expires_at      │ INTEGER NOT NULL                      │
│ created_at   │ INTEGER NOT NULL                      │
│ last_refreshed│ INTEGER NOT NULL                     │
│ success_count│ INTEGER DEFAULT 0                    │
│ failure_count│ INTEGER DEFAULT 0                    │
│ last_success │ INTEGER                            │
│ last_failure │ INTEGER                            │
└─────────────────────────────────────────────────────┘

media_assets
┌─────────────────────────────────────────────────────┐
│ id              │ TEXT PRIMARY KEY                 │
│ reddit_id       │ TEXT UNIQUE NOT NULL             │
│ permalink       │ TEXT UNIQUE NOT NULL             │
│ media_url       │ TEXT NOT NULL                    │
│ title           │ TEXT NOT NULL                    │
│ author          │ TEXT NOT NULL                    │
│ score           │ INTEGER NOT NULL                 │
│ subreddit       │ TEXT NOT NULL                    │
│ video_url       │ TEXT                             │
│ thumbnail_url   │ TEXT                             │
│ created_utc     │ INTEGER NOT NULL                 │
│ duration        │ INTEGER                          │
│ is_video        │ BOOLEAN NOT NULL                 │
│ is_gallery      │ BOOLEAN NOT NULL                 │
│ nsfw            │ BOOLEAN NOT NULL                 │
│ quality_score   │ INTEGER DEFAULT 50               │
│ source_provider │ TEXT DEFAULT 'reddit_oauth'      │
│ width           │ INTEGER                        │
│ height          │ INTEGER                        │
│ created_at      │ INTEGER NOT NULL                 │
│ last_seen       │ INTEGER NOT NULL                 │
└─────────────────────────────────────────────────────┘

media_queue
┌─────────────────────────────────────────────────────┐
│ id            │ INTEGER PRIMARY KEY AUTOINCREMENT │
│ reddit_post_id│ TEXT UNIQUE NOT NULL              │
│ position      │ INTEGER NOT NULL                  │
│ added_at      │ INTEGER NOT NULL                  │
│ group_id      │ INTEGER                           │
└─────────────────────────────────────────────────────┘

subreddit_configs
┌─────────────────────────────────────────────────────┐
│ subreddit       │ TEXT PRIMARY KEY                 │
│ enabled         │ BOOLEAN DEFAULT TRUE             │
│ provider        │ TEXT DEFAULT 'reddit_oauth'      │
│ sort_mode       │ TEXT DEFAULT 'hot'               │
│ refresh_interval│ INTEGER DEFAULT 300              │
└─────────────────────────────────────────────────────┘

media_search (FTS5 Virtual Table)
┌─────────────────────────────────────────────────────┐
│ reddit_post_id  │ TEXT                           │
│ title           │ TEXT                           │
│ subreddit       │ TEXT                           │
│ author          │ TEXT                           │
└─────────────────────────────────────────────────────┘
```

### Indexes

| Index | Table | Purpose |
|-------|-------|---------|
| `idx_expires` | oauth_tokens | Token expiration queries |
| `idx_subreddit_created` | media_assets | Subreddit feed queries |
| `idx_created_utc` | media_assets | Recent media queries |
| `idx_source_provider` | media_assets | Provider filtering |
| `idx_quality` | media_assets | Quality sorting |
| `idx_position` | media_queue | Queue ordering |
| `idx_added` | media_queue | Queue management |
| `idx_enabled` | subreddit_configs | Active subreddit queries |

### Triggers

| Trigger | Table | Action | Purpose |
|---------|-------|--------|---------|
| `after_media_insert` | media_assets | INSERT | Sync to FTS5 search index |
| `after_media_update` | media_assets | UPDATE | Update FTS5 index on changes |
| `after_media_delete` | media_assets | DELETE | Remove from FTS5 index |

### FTS5 Search Implementation

**FTS5 Virtual Table Schema:**
```sql
CREATE VIRTUAL TABLE media_search USING fts5(
    reddit_post_id,
    title,
    subreddit,
    author
);
```

**Search Query:**
```sql
SELECT ma.* FROM media_assets ma
JOIN media_search ON ma.reddit_id = media_search.reddit_post_id
WHERE media_search MATCH 'query terms'
LIMIT 20 OFFSET 0;
```

**FTS5 Behavior Notes:**
- Token-level matching (not substring) — "city" does not match "cityscape"
- No prefix matching or ranking configured
- For substring search, use the `/api/search/debug` endpoint with `LIKE` queries
- Consider trigram tokenizer if substring search is needed

---

## Configuration

### Environment Variables

Create a `.env` file in the backend directory:

```bash
# Reddit OAuth Configuration
REDDIT_CLIENT_ID=your_client_id_here
REDDIT_CLIENT_SECRET=your_client_secret_here
REDDIT_USER_AGENT=RedSlide/1.0 by u/your_username

# Database Configuration
DATABASE_PATH=./data/redslide.db

# Optional: Server Configuration
HOST=0.0.0.0
PORT=8000
```

### Reddit OAuth Setup

1. Go to https://www.reddit.com/prefs/apps
2. Create a new "script" app
3. Note the `client_id` (under the app name) and `client_secret`
4. Set these in `.env`

### Initial OAuth Token

The application requires an initial OAuth token to function. This is typically obtained through:
1. Manual authorization flow (for development)
2. A setup endpoint (not currently exposed for security)

#### Token Storage and Management

OAuth tokens are stored in the `oauth_tokens` table:
- `access_token`: The current bearer token
- `refresh_token`: Optional refresh token for token refresh flow
- `expires_at`: Unix timestamp of expiration
- `created_at`: Token creation timestamp
- `last_refreshed`: Last refresh attempt timestamp
- `success_count`: Number of successful API calls
- `failure_count`: Number of failed API calls

#### Token Refresh Process

When `OAuthManager.refresh_token()` is called:
1. Retrieve stored token from database
2. Extract refresh token from access token (format: `bearer_{refresh_token}`)
3. POST to `https://www.reddit.com/api/v1/access_token`:
   ```python
   auth=(client_id, client_secret)
   data={"grant_type": "refresh_token", "refresh_token": refresh_token}
   headers={"User-Agent": user_agent}
   ```
4. On success: Store new token with new expiration
5. On failure: Record failure and raise exception

If no refresh token is available (client credentials grant), a new token is acquired directly via `https://www.reddit.com/api/v1/access_token` with `grant_type=client_credentials`.

#### Token Health Tracking

Each successful API call updates:
- `success_count += 1`
- `last_success = current_time`

Each failed API call updates:
- `failure_count += 1`
- `last_failure = current_time`

---

## Deployment

### Docker Deployment

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000/api/health || exit 1
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### Manual Deployment

```bash
# Install dependencies
pip install -r requirements.txt

# Run server
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

### Production Considerations

1. **Database**: Consider PostgreSQL for production
2. **Authentication**: Implement JWT or API keys
3. **Rate Limiting**: Add rate limiting middleware
4. **Caching**: Implement Redis for caching
5. **Logging**: Add structured logging
6. **Monitoring**: Add Prometheus metrics

#### Health Check Endpoints

The `/api/health` endpoint provides comprehensive system status:
- Database connectivity check
- Queue size monitoring
- Provider health status
- OAuth token validity

#### Container Orchestration

Docker configuration includes:
- Health check with 30s interval
- 5s startup grace period
- Automatic restart on failure

---

## Development Setup

### Backend Setup

```bash
# Navigate to backend
cd backend

# Create virtual environment
python -m venv venv
source venv/bin/activate  # Linux/Mac
# or
venv\Scripts\activate     # Windows

# Install dependencies
pip install -r requirements.txt

# Create .env file
cp .env.example .env
# Edit with your credentials

# Run development server
uvicorn app.main:app --reload
```

### Frontend Setup

```bash
# Navigate to project root
cd /home/parag/Projects/Application/redslide

# Install Flutter dependencies
flutter pub get

# Run development
flutter run
```

### Testing

The backend has validation tests in `validate.py` and `validate_real.py`. Run with:

```bash
python validate.py
```

### Performance Metrics

From validation report:
| Metric | Target | Actual |
|--------|--------|--------|
| Feed Response (20 items) | <500ms | 0.55ms ✅ |
| Queue Response | <100ms | 0.17ms ✅ |
| FTS5 Search | <10ms | 0.56ms ✅ |
| Memory Usage | <500MB | 732KB ✅ |
| Startup Time | <30s | <1s ✅ |

### Request Lifecycle

When a client makes an API request:

```
Client Request
      │
      ▼
┌─────────────────────────────────┐
│  FastAPI Router (feed.py)      │
│  - Parse query parameters      │
│  - Validate input              │
│  - Call QueueManager           │
└─────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────┐
│  QueueManager.get_queue_items()│
│  - Get DB connection             │
│  - Execute JOIN query          │
│  - Convert to response model   │
└─────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────┐
│  Response Serialization        │
│  - Pydantic validation         │
│  - JSON encoding               │
└─────────────────────────────────┘
      │
      ▼
Client Response
```

### Dependency Injection

FastAPI's dependency injection is used for service access:

```python
async def get_queue_manager() -> QueueManager:
    return QueueManager()

@router.get("/feed")
async def get_feed(queue_manager: QueueManager = Depends(get_queue_manager)):
    # Use queue_manager
```

This pattern allows for:
- Easy testing with mock dependencies
- Centralized service configuration
- Clean separation of concerns

### Async Architecture

The application uses Python's async/await for concurrent operations:

```python
async def get_queue_items(limit: int, offset: int) -> list[dict]:
    async with get_db() as db:  # Async context
        cursor = await db.execute(query, params)  # Async execution
        rows = await cursor.fetchall()  # Async fetch
        return [dict(row) for row in rows]
```

Benefits:
- Non-blocking database operations
- Concurrent HTTP requests (httpx)
- Efficient background job scheduling

---

## Known Limitations

### Backend
1. Redlib fallback not fully implemented
2. No public OAuth setup endpoint
3. No rate limiting
4. SQLite for single-instance deployment only
5. `QueueManager._refill_queue()` is an empty stub — actual refill happens in `BackgroundRefreshService._refresh_job()`
6. FTS5 performs token-level matching only (no substring search) — use `/api/search/debug` for LIKE-based fallback
7. No CASCADE DELETE constraints on `media_queue` or `gallery_items` — orphaned rows must be cleaned up manually
8. Gallery URL extraction previously had a bug where `preview.redd.it` was incorrectly stripped to `.redd.it` (invalid hostname) — fixed

### Frontend
1. UI is in boilerplate state (not implemented)
2. No API integration
3. No state management

---

## Future Improvements

1. **Frontend**: Full implementation with slideshow mode
2. **Backend**: 
   - Redis caching layer
   - User preferences
   - Push notifications
   - Analytics
3. **Infrastructure**:
   - Kubernetes deployment
   - CI/CD pipeline
   - Monitoring and alerting

---

## Appendix

### File Structure

```
redslide/
├── backend/
│   ├── app/
│   │   ├── __init__.py
│   │   ├── main.py              # FastAPI app entry
│   │   ├── core/
│   │   │   └── database.py      # SQLite + FTS5 setup
│   │   ├── models/
│   │   │   └── schemas.py       # Pydantic models
│   │   ├── managers/
│   │   │   ├── __init__.py
│   │   │   ├── oauth.py         # OAuth token management
│   │   │   └── provider.py      # Provider failover
│   │   ├── services/
│   │   │   ├── __init__.py
│   │   │   ├── reddit_client.py # Reddit API client
│   │   │   ├── queue_manager.py # Queue operations
│   │   │   └── background_service.py # Scheduled jobs
│   │   └── api/
│   │       ├── __init__.py
│   │       ├── feed.py          # Feed/search endpoints
│   │       └── debug.py         # Health/debug endpoints
│   ├── data/
│   │   └── redslide.db          # SQLite database
│   ├── main.py                  # Server entry point
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── benchmark.py             # Functional benchmark suite
│   ├── validate.py
│   ├── validate_real.py
│   ├── final_validation.py
│   ├── VALIDATION.md
│   ├── FINAL_REPORT.md          # Investigation findings
│   ├── .env.example
│   └── .env
├── lib/
│   └── main.dart                # Flutter entry (boilerplate)
├── web/                         # Web assets
├── android/                     # Android native
├── ios/                         # iOS native
├── linux/                       # Linux native
├── windows/                     # Windows native
├── test/
│   └── widget_test.dart
├── pubspec.yaml                 # Flutter dependencies
├── analysis_options.yaml
└── README.md

### Dependencies

**Backend** (`requirements.txt`):
- fastapi>=0.110.0 - Modern web framework
- uvicorn[standard]>=0.29.0 - ASGI server
- httpx>=0.27.0 - Async HTTP client
- aiosqlite>=0.20.0 - Async SQLite driver
- apscheduler>=3.10.0 - Job scheduler
- python-dotenv>=1.0.0 - Environment loading
- pydantic>=2.6.0 - Data validation
- python-multipart>=0.0.9 - Form parsing
- praw>=7.8.0 - Reddit API wrapper (used in validation/test scripts only)

**Frontend** (`pubspec.yaml`):
- flutter - UI framework
- cupertino_icons - Platform-aware icons

### Common Issues and Solutions

| Issue | Cause | Solution |
|-------|-------|----------|
| Empty feed | No OAuth token | Set up Reddit OAuth credentials |
| Slow responses | Large database | Run cleanup job, add indexes |
| 401 errors | Expired token | Check token refresh logic |
| Empty queue | No media fetched | Check provider health |

### API Versioning

Currently v1.0.0. Future versions may include:
- `/api/v2/feed` - Enhanced filtering
- `/api/v2/search` - Improved search

### Security Considerations

1. **OAuth tokens**: Stored encrypted in SQLite
2. **API keys**: Environment variables only
3. **Rate limiting**: Not implemented (add middleware)
4. **CORS**: Configure for production domains

### Monitoring Endpoints

- `GET /api/health` - System health
- `GET /api/debug/providers` - Provider status
- `GET /api/debug/queue` - Queue diagnostics

These endpoints are intended for internal monitoring and should be protected in production.

---

## Detailed Working

### Application Startup Sequence

```
1. Server Entry Point (main.py)
   │
   ├── Import uvicorn
   ├── Import app from app.main
   └── Run uvicorn server

2. FastAPI Lifespan (app/main.py)
   │
   ├── Load environment variables (.env)
   ├── Create data directory if needed
   ├── Initialize database (init_db)
   │   ├── Create oauth_tokens table
   │   ├── Create media_assets table
   │   ├── Create media_queue table
   │   ├── Create subreddit_configs table
   │   └── Create media_search FTS5 table
   ├── Initialize OAuthManager
   │   ├── Load existing token from DB
   │   └── Validate token not expired
   └── Yield to start server

3. Ready State
   │
   └── Health endpoint returns: {"status": "ok", ...}
```

### Request Processing Pipeline

#### GET /api/feed Processing

```
Client Request
      │
      ▼
┌─────────────────────────────────────┐
│  FastAPI Router                    │
│  - Validate query params           │
│    • limit: 1-100                 │
│    • after: optional string       │
│  - Inject QueueManager dependency │
└─────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────┐
│  QueueManager.get_queue_items()    │
│  - Get async DB connection         │
│  - Execute SQL:                  │
│    SELECT ma.* FROM media_assets ma│
│    JOIN media_queue mq ON...       │
│  - Fetch all rows                  │
│  - Convert to dict                 │
└─────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────┐
│  Response Building                 │
│  - Map dict to MediaAssetResponse  │
│  - Wrap in FeedResponse            │
│  - Serialize to JSON               │
└─────────────────────────────────────┘
      │
      ▼
Client Response (JSON)
```

#### SQL Queries Used

**Get Queue Items:**
```sql
SELECT ma.* FROM media_assets ma
JOIN media_queue mq ON ma.reddit_id = mq.reddit_post_id
ORDER BY mq.position ASC
LIMIT ? OFFSET ?
```

**Count Queue:**
```sql
SELECT COUNT(*) as count FROM media_queue
```

**Search (FTS5):**
```sql
SELECT ma.* FROM media_assets ma
WHERE ma.reddit_id IN (
    SELECT reddit_post_id FROM media_search 
    WHERE media_search MATCH ?
)
LIMIT ? OFFSET ?
```

**Add to Queue:**
```sql
-- Insert or ignore asset
INSERT OR IGNORE INTO media_assets (...) VALUES (...)

-- Get next position
SELECT MAX(position) as max_pos FROM media_queue

-- Add to queue
INSERT INTO media_queue (reddit_post_id, position, added_at) VALUES (?, ?, ?)
```

### Media Asset Processing

#### Media URL Extraction Algorithm

```python
def _extract_media_details(post_data):
    # Step 1: Gallery posts
    if post_data.get("is_gallery"):
        for gallery_id, item in media_metadata.items():
            if item.e == "Image":
                # Reddit returns preview.redd.it URLs
                # Fixed: replaced "preview" stripping with proper domain
                item_url = item.s.u.replace("preview.redd.it", "i.redd.it")
                gallery_items.append(item_url)
        media_url = gallery_items[0]  # First image as primary
    
    # Step 2: Video posts (reddit_video.fallback_url)
    elif post_data.get("is_video"):
        video_url = media.reddit_video.fallback_url  # MP4 URL
        media_url = video_url  # Same URL for both
    
    # Step 3: Direct image URL (ends with .jpg, .png, etc.)
    elif post_data.url ends with image extension:
        media_url = post_data.url
    
    # Step 4: Preview fallback
    else:
        media_url = preview.images[0].source.url
    
    # Thumbnail from preview images
    thumbnail_url = preview.images[0].source.url
    
    return (media_url, video_url, thumbnail_url, width, height, duration, gallery_items)
```

**Important**: Gallery URLs from Reddit's API use `preview.redd.it` domain. The backend fixes these to `i.redd.it` (the direct image CDN) to avoid invalid hostname errors.

#### Quality Validation Pipeline

```
MediaAsset
    │
    ▼
┌─────────────────────────────────┐
│  Check: preview/thumbnail in URL│
│  If yes → REJECT                 │
└─────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────┐
│  Check: width < 800 or height < 600
│  If yes → REJECT                 │
└─────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────┐
│  Calculate Quality Score         │
│  - Base: 50                    │
│  - Resolution bonus            │
│  - Video bonus (+10)           │
│  - Reddit score bonus          │
└─────────────────────────────────┘
    │
    ▼
ACCEPT (with quality_score)
```

### Background Service Working

#### APScheduler Integration

```python
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.interval import IntervalTrigger

class BackgroundRefreshService:
    def __init__(self):
        self.scheduler = AsyncIOScheduler()
        
    async def start(self):
        self.scheduler.add_job(
            self._refresh_job,
            IntervalTrigger(seconds=300),
            id="refresh_job"
        )
        self.scheduler.start()
        
    async def _refresh_job(self):
        await self.queue_manager.manage_queue()
```

#### Queue Management Logic

```
manage_queue()
    │
    ├── count_queue_items()
    │
    ├── if count < 100:
    │       _refill_queue(200)  # Emergency refill
    │
    ├── elif count < 300:
    │       _refill_queue(100)  # Normal refill
    │
    ├── elif count > 1000:
    │       _trim_queue(1000)   # Trim excess
    │
    └── else:
            # Queue is healthy, no action
```

#### Refill Queue Process (Stub — Not Fully Implemented)

```python
async def _refill_queue(self, count: int) -> None:
    """Refill queue with media."""
    # NOTE: This method is a stub. Actual refill logic
    # is handled by the BackgroundRefreshService _refresh_job,
    # which calls RedditClient.fetch_subreddit_media() directly
    # and adds assets via QueueManager.add_to_queue().
    pass
```

The actual media fetching happens in `BackgroundRefreshService._refresh_job()`, which:
1. Calls `QueueManager.manage_queue()` to check thresholds
2. Gets enabled subreddits from `subreddit_configs` table
3. Fetches fresh content via `RedditClient.fetch_subreddit_media()`
4. Adds unique assets via `QueueManager.add_to_queue()`

### Provider Failover Working

#### Circuit Breaker Implementation

```
State Machine:
                    
HEALTHY ──failure──▶ OPEN(1-4) ──failure──▶ OPEN(5+) ──timeout──▶ COOLDOWN
   │                                                   │
   │success                                            │
   ▼                                                   ▼
success              ┌──────────────────┐       success
   │                 │ Cooldown Period  │         │
   ▼                 │ (5 minutes)      │         ▼
HALF-OPEN ◀─────────┤                  ├─────────▶ FALLBACK
                      └──────────────────┘
```

#### get_healthy_provider() Logic

```python
async def get_healthy_provider():
    # Check cooldown
    if now < cooldown_until:
        return fallback
    
    # Check failure threshold
    if failure_count >= 5:
        cooldown_until = now + 300  # 5 minutes
        return fallback
    
    return primary
```

### Error Handling Patterns

#### Database Errors

```python
try:
    async with get_db() as db:
        await db.execute(query, params)
        await db.commit()
except aiosqlite.Error as e:
    await db.rollback()
    raise HTTPException(500, "Database error")
```

#### API Errors

```python
if response.status_code == 401:
    await oauth_manager.refresh_token()
    await provider_manager.record_provider_failure("reddit_oauth")
    return await fetch_redlib(...)  # Fallback
elif response.status_code != 200:
    await provider_manager.record_provider_failure("reddit_oauth")
    raise HTTPException(response.status_code, "API error")
```

### Performance Characteristics

#### Response Times (from validation)
- Feed (20 items): ~0.55ms
- Queue status: ~0.17ms
- Search: ~0.56ms
- Health check: <1ms

#### Memory Usage
- 1000 media assets: ~732KB
- Database: <10MB for 10,000 assets
- Cache: Minimal (SQLite-based)

#### Concurrency
- Async/await for all I/O operations
- Connection pooling via aiosqlite
- Non-blocking HTTP requests via httpx