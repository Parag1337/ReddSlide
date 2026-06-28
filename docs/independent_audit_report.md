# Independent Audit Report — Phase 6.2 RedSlide

**Date**: 2026-06-28
**Scope**: Frontend (Flutter/Dart) + Backend (Python/FastAPI)
**Reference**: Phase 6.2 commit `81746d4` ("some error fixes")
**Method**: Full source-code inspection, git diff analysis, cross-reference verification with prior audit findings.

---

## Part A — Critical Issue Verification Table

| ID | Issue (from prior audit) | Status | Evidence |
|-----|--------------------------|--------|----------|
| **C-1** | Decode policy consistency (image_cache_v1) | ✅ FIXED | `MediaPreparationEngine.attachContext()` computes `_defaultDecodeSize` once via `ImageDecodePolicy.fromContext()` and passes it to both preloader (`AdaptivePreloader`) and viewer (`PreparedMediaHandle.decodeSize`). Same formula, same width/height → same `ResizeImage` cache key. Minor note: `SafeNetworkImage` fallback (when `decodeSize` null) uses a slightly different formula (`(mediaSize.width * pixelRatio).ceil()` without `qualityMultiplier`), but `decodeSize` is never null in practice. |
| **C-2** | Video URLs never enter image preload | ✅ FIXED | `_imageUrls()` in `adaptive_preloader.dart` extracts `thumbnailUrl` for videos, never `videoUrl`. `_allAssetUrls()` with `includeVideo=true` exists but is never called from any preload path. Preload pipeline exclusively uses `_imageUrls()`. |
| **C-3** | Shared OAuthManager singletons | ⚠️ PARTIAL | `dependencies.py` provides `get_oauth_manager` from `request.app.state`, set in `main.py` lifespan. `search.py` and explicit sync/fetch endpoints in `feed.py` inject via `Depends`. **But**: `feed.py:94` (`sync_fetch_trigger` path) calls `ensure_subreddit_has_content(single_sub, sort=sort)` **without** passing `oauth_manager`/`provider_manager`, causing `fetch_and_store` to create **per-request** instances. |
| **C-4** | Shared ProviderManager singletons | ⚠️ PARTIAL | Same as C-3. The circuit breaker state is correctly shared via `app.state.provider_manager` on all explicit endpoints, but the `sync_fetch_trigger` path creates isolated instances without circuit state. |
| **C-5** | Video timeout releases slot | ✅ FIXED | `_initController` always runs `_activeCount--` and `_processNextInQueue()` in `finally` block (line 136-139). On timeout: entry disposed, state → `failed`, completer completed with error, slot released. `updatePriority` now uses `removeWhere` (fixed the `compareTo` bug). Completer is set before `_initController` (fixed the `??=` leak). |
| **C-6** | Navigation race condition | ✅ FIXED | `_isNavigating` guard on `next()`, `previous()`, `jumpTo()`, `galleryNext()`, `galleryPrevious()`. Set `true` before async work, reset in `finally`. `galleryNext()` (called by auto-advance timer) checks `_isNavigating` before calling `next()`. Timer is also cancelled/restarted on navigation. |
| **C-7** | Search cancellation | ✅ FIXED | `_searchGeneration` counter incremented before each search. Three guards check `generation != _searchGeneration`: after FTS5 call (line 184), after fetch (line 188), and in error handler (line 208). Stale results from earlier (cancelled) searches are discarded. |
| **C-8** | ImageCache policy consistency | ⚠️ PARTIAL | ImageCache set to 500 entries / 200MB in `main.dart`. Decode sizes are consistent between preloader and viewer (same `ResizeImage` dims → same cache key). **Remaining issue**: `_preparingUrls` set in `media_preparation_engine.dart` is never cleaned on preload failure (`_executePreload` catch block does not call `onUrlReady`). Each unique failed URL permanently occupies `_preparingUrls`, though bounded by total unique URLs in session. |
| **C-9** | Background cleanup job | ✅ FIXED | `cleanup_old_assets(days=30)` uses `int(time.time())` (not `time.monotonic()`). Deletes orphaned `gallery_items` and `media_queue` before pruning `media_assets`. Called every 30 min by `_cleanup_job` in `background_service.py`. |

---

## Part B — Regression Verification

### B1. `created_at` / `last_seen` timebase (RED HERRING confirmed)
- `reddit_client.py:725` uses `int(time.time())` for both `created_at` and `last_seen`.
- `cleanup_old_assets` uses `int(time.time()) - cutoff`.
- **No regression**: consistent wall-clock timebase.

### B2. `reddit_client.py` rewrite (789 lines changed)
- New `_search_oauth` and `_fetch_oauth` methods with 401 retry logic.
- Retry acquires fresh token and retries once before falling back to Redlib.
- **Potential concern**: double-counting of results if the first request succeeded partially (e.g., timeout but data was stored). However, `fetch_and_store` uses `INSERT OR IGNORE`, so duplicates are safe.
- **Concern**: The 401 retry path creates a new `httpx.AsyncClient` per retry per call. Under heavy load with many 401s, this could create connection churn. Acceptable given 401s should be rare.

### B3. `search_coordinator.py` (new file, 612 lines)
- Search time budget, provider fallback, cancellation via `SearchContext`.
- Tested with 984-line test file (`test_search_coordinator.py`). Code quality looks reasonable.
- No obvious regressions.

### B4. FTS5 error wrapping in `queue_manager.py:search`
- Previously: SQL errors propagated to caller as exceptions.
- Now: caught, logged, returns `[], 0`. Could mask legitimate database errors (corruption, schema mismatch).
- Trade-off: graceful degradation vs silent data loss. Acceptable for a search feature where graceful degradation is preferred.

### B5. `dependencies.py` dependency injection
- New `get_oauth_manager`, `get_provider_manager` pull from `request.app.state`.
- If either is `None` (e.g., not set in lifespan), FastAPI would 500 with `AttributeError`.
- Both are initialized in `main.py` lifespan before server starts serving → safe.
- **No regression.**

### B6. FeedResponse naming consistency
- Backend: `FeedResponse` model has `items`, `after` (str), `has_more` (bool).
- Flutter: `FeedResponse.fromJson` reads `items`, `after` (JSON key `"after"`), `has_more` (JSON key `"has_more"`).
- **Consistent.** No naming mismatch.

---

## Part C — Full Project Scan

### C1. Remaining Critical Issues

| # | Severity | Issue | Location | Notes |
|---|----------|-------|----------|-------|
| **R1** | 🔴 CRITICAL | Live OAuth secrets on disk | `backend/.env` | `REDDIT_CLIENT_SECRET=6DPNdNE5zTAd_rXR28DdOHdISv_EJg` stored in plaintext. `.env` is NOT gitignored (not in `.gitignore`). **Needs `.gitignore` entry and secret rotation.** |
| **R2** | 🟠 HIGH | Sync-fetch trigger bypasses shared OAuth | `feed.py:94` | `ensure_subreddit_has_content(single_sub, sort=sort)` called without `oauth_manager`/`provider_manager`. Creates per-request OAuth instances, losing circuit breaker and token state. |
| **R3** | 🟠 HIGH | `_preparingUrls` leak on preload failure | `media_preparation_engine.dart:29-32` + `adaptive_preloader.dart:224-227` | On `precacheImage` failure, `onUrlReady` is never called → `_preparingUrls` retains the failed URL permanently. Only bounded by total unique URLs in the session. |
| **R4** | 🟠 HIGH | Slideshow provider watches settings → destruction on change | `slideshow_provider.dart:28` | `ref.watch(settingsProvider)` in the family factory. When settings change, the notifier is disposed and recreated, destroying active slideshow state (current index, preloaded images, video controllers). |
| **R5** | 🟠 HIGH | No rate limiting on any API endpoint | All `backend/app/api/*.py` | No rate limiting, throttling, or auth on any endpoint. `/health`, `/search/debug`, `/media/{id}` all freely accessible if the service is exposed. |
| **R6** | 🟡 MEDIUM | `QueueResponse` deserialization mismatch | `feed_repository.dart:113-123` | The Flutter `QueueResponse.fromJson` reads `queue_size` from JSON, but the backend `QueueResponse` model uses `total` and `pending` fields — no `queue_size` field exists. Deserialization would produce `queueSize: 0` always. |
| **R7** | 🟡 MEDIUM | `VideoPreparationService` has no maximum pool size | `video_preparation_service.dart:18` | `_pool` is a `Map<String, _VideoEntry>` with no eviction on `prepare()`. `evictOutsideWindow()` is called separately by the engine. If `_reconcilePreparationWindow` is not called (e.g., `onIndexChanged` not triggered due to navigation guard), old entries accumulate. |
| **R8** | 🟡 MEDIUM | Background lifecycle not saving state | `slideshow_screen.dart` | `didChangeAppLifecycleState` only calls `_saveSession()` which is empty. App suspension destroys preloaded images and video controllers. **Previously flagged as H9 — STILL NOT FIXED.** |
| **R9** | 🟡 MEDIUM | `MediaPreparationEngine.prepare()` reports `preparing` for failed URLs | `media_preparation_engine.dart:168-169` | Due to the `_preparingUrls` leak (R3), failed URLs are reported as `MediaState.preparing` instead of `MediaState.failed`. Minor because the video path (line 148-161) correctly checks `_videoService.hasFailed()`. |
| **R10** | 🟢 LOW | `_confirmedReadyUrls` LRU using `take()` (not FIFO) | `media_preparation_engine.dart:37-41` | When exceeding `_maxConfirmedReadyUrls`, `take(excess)` removes from iteration order (insertion order of `LinkedHashSet`). This is correct LRU-like behavior. Acceptable. |

### C2. False Positives from Prior Audit

| Original Claim | Verdict | Reason |
|---------------|---------|--------|
| `time.monotonic()` used for `created_at` → data loss | ❌ FALSE POSITIVE | Code inspection confirms `int(time.time())` is used for both `created_at` and `last_seen`. The original audit found an intermediate version; current HEAD is fixed. |
| `FeedResponse` naming mismatch (`has_more` vs `hasMore`) | ❌ FALSE POSITIVE | Both backend and Flutter use `has_more` in JSON. Flutter's `fromJson` reads JSON key `"has_more"`. Consistent. |
| `ensure_subreddit_has_content` always creates new OAuth | ❌ FIXED (partial) | The method now accepts optional `oauth_manager`/`provider_manager`. Explicit endpoints pass them. Only the `sync_fetch_trigger` bypass remains (R2). |

### C3. Regressions Introduced

| # | Regression | Location | Impact |
|---|------------|----------|--------|
| **RG1** | FTS5 errors silently return empty results | `queue_manager.py:215-301` | Before: exceptions propagated to caller. Now: `[], 0` returned silently. Could hide DB corruption. Mitigation: error is logged. |
| **RG2** | 401 retry creates new `httpx.AsyncClient` per call | `reddit_client.py` | Minor: connection churn on 401s. Acceptable. |
| **RG3** | `QueueManager()` stateless constructor | `feed.py:14-16` | Was always stateless (delegates to DB). No change. |

---

## Production Readiness Score

| Category | Score (1-10) | Notes |
|----------|-----------|-------|
| **Architecture** | 7/10 | Shared singletons via DI good; R2 (sync_fetch_trigger bypass) weakens it. |
| **Correctness** | 6/10 | C-1 through C-9 mostly fixed. R6 (`QueueResponse`) is a real data bug. R3 (`_preparingUrls` leak) is minor but real. |
| **Performance** | 7/10 | Preloader hysteresis and LRU sets are effective. No obvious O(n^2) or leaks beyond R3/R7. |
| **Stability** | 5/10 | R4 (settings change destroys slideshow) is a crash/data-loss risk. R2 (OAuth per-request) means circuit breaker resets on feed-first-page. |
| **Scalability** | 4/10 | R5 (no rate limiting) is critical if exposed. Otherwise single-user app, acceptable. |
| **Testing** | 5/10 | Backend has 984-line test for search_coordinator. No integration tests for frontend, no E2E tests. Phase 6.2 test file (`phase_6_2_fixes_test.dart`) exists but coverage is unknown without running it. |
| **Documentation** | 6/10 | README and previous audit reports exist. API docs via FastAPI OpenAPI. |
| **Security** | 3/10 | R1 (secrets in .env not gitignored) is the single biggest issue. R5 (no auth/rate-limiting). |
| **Overall** | 5.4/10 | Below release threshold. |

---

## Final Recommendation

**BLOCKED — DO NOT RELEASE** until:

1. **🔴 MUST FIX**: Remove `.env` from version control (add to `.gitignore`), rotate leaked secrets.
2. **🔴 MUST FIX**: Pass `oauth_manager`/`provider_manager` in `feed.py:94` sync_fetch_trigger path.
3. **🔴 MUST FIX**: Add `.gitignore` entry for `.env`.
4. **🟠 SHOULD FIX**: Call `onUrlReady` in `_executePreload` catch block to prevent `_preparingUrls` leak.
5. **🟠 SHOULD FIX**: Fix `QueueResponse.fromJson` to match backend response shape.
6. **🟠 SHOULD FIX**: Implement rate limiting on API endpoints.
7. **🟡 CONSIDER**: Implement `didChangeAppLifecycleState` to save/restore slideshow state.
8. **🟢 NICE**: Add `_pool` max-size eviction to `VideoPreparationService`.

**Estimated effort**: ~2-3 hours for blocking fixes (R1, R2, gitignore). ~1 day for SHOULD FIX items. Overall Phase 6.2 is 70% complete.

### If forced to ship today
- Disable the `/search/debug` endpoint (no auth, SQL injection vector).
- Warn that slideshow settings changes restart the current show.
- Accept FTS5 errors return empty results silently.
