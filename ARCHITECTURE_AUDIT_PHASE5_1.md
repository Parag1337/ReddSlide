# RedSlide Architecture Audit & Migration Plan — Phase 5.1

> **Status**: Phase 5.2 Complete — MediaPreparationEngine created
> **Date**: 2026-06-27
> **Phase Progress**: Phase 1 (MPE Foundation) ✅ → Phase 2 (Video Pre-init) ⬜ → Phase 3 (Decouple Notifier) 🟡 → Phase 4 (Strip Widget Prep) ⬜ → Phase 5 (Cancellation/Memory) ⬜ → Phase 6 (Metrics) ⬜
> **Auditor**: Architecture analysis agent

---

## Table of Contents

1. [Current Architecture](#1-current-architecture)
2. [Current vs Target Comparison](#2-current-vs-target-comparison)
3. [File-by-File Audit](#3-file-by-file-audit)
4. [Dependency Graph](#4-dependency-graph)
5. [Migration Plan](#5-migration-plan)
6. [Risks](#6-risks)
7. [Validation Plan](#7-validation-plan)
8. [Rollback Strategy](#8-rollback-strategy)
9. [Documentation Plan](#9-documentation-plan)
10. [Final Recommendation](#10-final-recommendation)

---

## 1. Current Architecture

### 1.1 High-Level Data Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           FLUTTER FRONTEND                                   │
│                                                                              │
│  ┌────────────┐   ┌──────────────────┐   ┌───────────────────────────────┐  │
│  │ Backend API │──▶│  MediaSource     │──▶│  MergeEngine                  │  │
│  │ (Dio/HTTP)  │   │  (MediaPage)     │   │  ┌────────────────────────┐  │  │
│  └────────────┘   │  SubredditMediaSrc│   │  │ SourceBuffer × N       │  │  │
│                   │  SearchMediaSource│   │  │ Round-robin merge      │  │  │
│                   └──────────────────┘   │  │ Freshness + Diversity   │  │  │
│                                           │  │ Auto-refill (WM: 8)    │  │  │
│                                           │  └────────────────────────┘  │  │
│                                           └──────────────┬───────────────┘  │
│                                                          │                   │
│                                                          ▼                   │
│                              ┌─────────────────────────────────────────┐    │
│                              │         SlideshowNotifier              │    │
│                              │  ┌──────────────────────────────────┐  │    │
│                              │  │ PlaylistManager (items + index) │  │    │
│                              │  │ AdaptivePreloader               │  │    │
│                              │  │   └── precacheImage (images)    │  │    │
│                              │  │ Navigation + auto-advance        │  │    │
│                              │  │ Overlay timer                    │  │    │
│                              │  │ Pagination (loadMore)            │  │    │
│                              │  └──────────────────────────────────┘  │    │
│                              └──────────────────┬──────────────────────┘    │
│                                                  │                          │
│                                                  ▼                          │
│                              ┌─────────────────────────────────────────┐    │
│                              │         SlideshowScreen                │    │
│                              │  ┌──────────────────────────────────┐  │    │
│                              │  │ PageView → MediaViewer           │  │    │
│                              │  │   ├── ImageViewer                │  │    │
│                              │  │   │   └── CachedNetworkImage     │  │    │
│                              │  │   └── VideoViewer                │  │    │
│                              │  │       └── VideoPlayerController  │  │    │
│                              │  │          (created in initState)  │  │    │
│                              │  └──────────────────────────────────┘  │    │
│                              └─────────────────────────────────────────┘    │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────┐     │
│  │                         Flutter ImageCache                         │     │
│  │               (500 entries, 200MB — only bitmap cache)             │     │
│  └────────────────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Current Component Map

| Component | File Path | Role | Lines |
|-----------|-----------|------|-------|
| MediaSource | `lib/core/media/media_source.dart` | Abstract paginated media loader | 21 |
| SubredditMediaSource | `lib/features/slideshow/data/subreddit_media_source.dart` | Feed as MediaSource | 48 |
| SearchMediaSource | `lib/features/slideshow/data/search_media_source.dart` | Search as MediaSource | 53 |
| MergeEngine | `lib/features/slideshow/domain/merge_engine.dart` | Multi-source merge + SourceBuffer | 248 |
| PlaylistManager | `lib/features/slideshow/domain/playlist_manager.dart` | Flat list + index | 67 |
| AdaptivePreloader | `lib/features/slideshow/domain/adaptive_preloader.dart` | Priority image preloader | 243 |
| SlideshowNotifier | `lib/features/slideshow/providers/slideshow_provider.dart` | Central slideshow orchestrator | 371 |
| SlideshowState | `lib/features/slideshow/domain/slideshow_state.dart` | Immutable state | 53 |
| SlideshowSource | `lib/features/slideshow/domain/slideshow_source.dart` | Sealed source types | 111 |
| SlideshowScreen | `lib/features/slideshow/presentation/slideshow_screen.dart` | Fullscreen slideshow UI | 380 |
| MediaViewer | `lib/features/slideshow/presentation/widgets/media_viewer.dart` | Dispatches image/video | 47 |
| ImageViewer | `lib/features/slideshow/presentation/widgets/image_viewer.dart` | Zoomable image with logging | 185 |
| VideoViewer | `lib/features/slideshow/presentation/widgets/video_viewer.dart` | Video player with fallback | 179 |
| SlideshowOverlay | `lib/features/slideshow/presentation/widgets/slideshow_overlay.dart` | Gradient overlay UI | 188 |
| SlideshowControls | `lib/features/slideshow/presentation/widgets/slideshow_controls.dart` | Nav + action buttons | 97 |
| QueueIndicator | `lib/features/slideshow/presentation/widgets/queue_indicator.dart` | ±25 item chip bar | 56 |
| MediaAsset | `lib/features/feed/domain/media_asset.dart` | Domain model | 127 |
| SafeNetworkImage | `lib/core/media/safe_network_image.dart` | Safe image with fallback | 31 |
| MediaError | `lib/core/media/media_error.dart` | Error type enum + logger | 45 |
| AppConstants | `lib/core/constants/app_constants.dart` | Global constants | 30 |

### 1.3 Component Responsibility (Current)

```
SlideshowNotifier
├── Creates MediaSources (via _buildMediaSources)
├── Creates MergeEngine (via _buildMergeEngine)
├── Creates PlaylistManager (owns it)
├── Creates AdaptivePreloader (via attachPreloaderContext)
├── Owns slideshow state (via SlideshowState)
├── Manages navigation (next/previous/jumpTo)
├── Manages auto-advance timer
├── Manages overlay auto-hide timer
├── Manages pagination (loadMore → autoRefill → drainMerged)
├── Notifies preloader on index change
└── syncState (playlist → state copy)

MergeEngine
├── Creates N SourceBuffers
├── Manages parallel page loading
├── Round-robin merge with freshness + diversity
├── Auto-refill at low watermark (8)
├── Deduplication
└── Tracks per-source consumption

AdaptivePreloader
├── Priority queue (urgent/high/medium/background)
├── LRU tracking set (max 500)
├── Concurrent download limit (3)
├── Adaptive window sizing (wide/normal/tight)
├── Triggers loadMore when playlist low (30 remaining)
├── Image-only preloading (via CachedNetworkImageProvider)
├── Checks ImageCache before enqueueing
└── NO cancellation of in-flight preloads

ImageViewer
├── Creates CachedNetworkImageProvider
├── Async disk cache check
├── InteractiveViewer (pinch-to-zoom)
├── Performance logging pipeline
└── Error classification

VideoViewer
├── Creates VideoPlayerController.networkUrl()
├── Initializes controller (network fetch)
├── 1 retry on failure
├── Thumbnail fallback
├── Mute support
└── Performance logging pipeline
```

### 1.4 Current Ownership — Violations

| Violation | Location | Why It's Wrong |
|-----------|----------|---------------|
| Widgets perform network work | `VideoViewer._initController()` line 72-117 | Creates `VideoPlayerController.networkUrl()` and calls `initialize()` which fetches video data over network. Widgets should consume already-prepared media. |
| Widgets perform async disk checks | `ImageViewer.initState()` line 38-43 | Fires `DefaultCacheManager().getFileFromCache()` — disk I/O during widget creation |
| SlideshowNotifier manages preloader lifecycle | `slideshow_provider.dart` lines 57-65 | `attachPreloaderContext()` creates AdaptivePreloader inside the notifier. Preloading should be the domain of MediaPreparationEngine. |
| SlideshowNotifier manages pagination directly | `slideshow_provider.dart` lines 288-313 | `loadMore()` calls `engine.autoRefill()` + `drainMerged()` directly. Pagination should be managed by a PaginationManager. |
| No video pre-initialization | `adaptive_preloader.dart` only preloads images | `AppConstants.videoPreloadWindow = 2` is defined but never used. Videos are created on-demand in widgets. |
| No preload cancellation | `adaptive_preloader.dart` no cancel method | When user jumps to a distant index, in-flight preloads for irrelevant items continue consuming bandwidth. |

---

## 2. Current vs Target Comparison

### 2.1 Component Responsibility Table

| Component | Current Responsibility | Target Responsibility | Required Changes | Complexity | Risk |
|-----------|----------------------|----------------------|-----------------|------------|------|
| **MediaSource** | Supplies paginated media | Same | None | None | None |
| **MergeEngine** | Orders media from sources | Same | None | None | None |
| **PlaylistManager** | Items + index management | Same | None | None | None |
| **SlideshowNotifier** | Everything: prep, nav, state, timers, pagination | Slideshow state, navigation, playback state, Riverpod UI coordination | Strip preloading concerns to MediaPreparationEngine; strip pagination to PaginationManager | **Medium** | **Medium** — tight coupling makes separation delicate |
| **SlideshowState** | Immutable state model | Same. Add `preparedItems` or keep as-is | None if MediaPreparationEngine is a separate service | None | None |
| **AdaptivePreloader** | Image priority preloader | Evolve into MediaPreparationEngine | Add video pre-init, cancellation, memory mgmt, metrics | **Medium** | **Low** — evolution, not replacement |
| **MediaPreparationEngine** | Does not exist | Owns ALL preparation: download, decode, cache, cancel, pagination trigger | **New component** | **High** | **Medium** — risk of over-engineering |
| **PreparationCoordinator** | Does not exist | Orchestrate download + decode | **New sub-component** | Low | Low |
| **PreparationPolicy** | Does not exist | Decide WHAT to prepare and WHEN | Part of MPE | Low | Low |
| **DownloadScheduler** | Does not exist | Concurrent download management | Evolution of AdaptivePreloader's _processQueue | Low | Low |
| **DecodeScheduler** | Does not exist | Manage decode pipeline (images + videos) | **New** — video pre-init is the main new capability | **Medium** | **Medium** |
| **CancellationManager** | Does not exist | Cancel in-flight prep for items no longer relevant | **New** | Low | Low |
| **MemoryManager** | Does not exist | Respond to memory pressure, evict distant items | **New** | Low | Low |
| **PaginationManager** | Not a separate component | Trigger loadMore when playlist runs low | Extract from AdaptivePreloader _checkLoadMore | Low | Low |
| **MetricsCollector** | Does not exist (except log statements) | Track preload hit rates, decode times | **New** | Low | Low |
| **ImageViewer** | Creates image provider, disk cache check | Consume already-prepared image from ImageCache | Remove disk cache check; remove prep work | **Low** | **Low** |
| **VideoViewer** | Creates controller, initializes, 1 retry | Consume already-prepared video controller | Receive pre-initialized controller; remove init logic | **Medium** | **Medium** |

### 2.2 Architectural Comparison

| Aspect | Current | Target | Delta |
|--------|---------|--------|-------|
| Ownership model | SlideshowNotifier owns everything | Clear ownership boundaries per component | **Major improvement** |
| Preloading | Image-only via AdaptivePreloader | Image + video via MediaPreparationEngine | **Major gain** |
| Widget prep work | VideoViewer creates controllers | Widgets consume prepared media only | **Major improvement** |
| Cancellation | None | CancellationManager | **Medium gain** |
| Memory management | Flutter ImageCache only | MemoryManager + Flutter ImageCache | **Minor gain** |
| Metrics | Debug log statements | MetricsCollector | **Minor gain** |
| Pagination trigger | In AdaptivePreloader._checkLoadMore | PaginationManager | **Minor refactor** |
| Video pre-init | None (defined in constants, unused) | DecodeScheduler pre-initializes videos | **Major gain** |
| Complexity | Moderate (monolithic notifier) | Higher (more components, clear boundaries) | Acceptable |
| Testability | Hard (notifier has many concerns) | Easy (components have single concern) | **Major improvement** |
| Extensibility | Hard (adding features requires modifying notifier) | Easy (add new source types via new components) | **Major improvement** |

---

## 3. File-by-File Audit

### 3.1 Files Requiring Modification

| # | File | Current Responsibility | Target Responsibility | Reason | Complexity | Regression Risk |
|---|------|----------------------|---------------------|--------|------------|-----------------|
| 1 | `lib/features/slideshow/domain/adaptive_preloader.dart` | Image priority preloader | **Evolve into MediaPreparationEngine** | Add video pre-init, cancellation, memory mgmt, metrics | **High** — core refactor | **Medium** — preloader logic must remain correct |
| 2 | `lib/features/slideshow/providers/slideshow_provider.dart` | Central orchestrator | Strip preloading/pagination concerns; keep state/navigation/UI | Clear ownership boundaries | **Medium** | **Medium** — notifier is tightly coupled |
| 3 | `lib/features/slideshow/presentation/widgets/video_viewer.dart` | Creates + initializes video player | Consume pre-initialized VideoPlayerController | Remove prep work from widget | **Medium** | **Medium** — video playback path changes |
| 4 | `lib/features/slideshow/presentation/widgets/image_viewer.dart` | Creates image provider + disk check | Consume already-cached image; remove disk check | Remove prep work from widget | **Low** | **Low** |
| 5 | `lib/features/slideshow/presentation/slideshow_screen.dart` | Initialization sequence | Create MediaPreparationEngine; attach to notifier | Integration point | **Low** | **Low** |
| 6 | `lib/core/constants/app_constants.dart` | Global constants | Add MediaPreparationEngine config values | Configuration | **Low** | **None** |
| 7 | `lib/features/slideshow/presentation/widgets/media_viewer.dart` | Dispatch to image/video | Pass prepared video controllers | Interface change | **Low** | **Low** |
| 8 | `lib/features/slideshow/domain/slideshow_state.dart` | Immutable state | Possibly add prepared item tracking | Optional | **Low** | **Low** |

### 3.2 New Files to Create

| # | File | Purpose | Complexity |
|---|------|---------|------------|
| 1 | `lib/core/media/media_preparation_engine.dart` | Main MPE class — orchestrates all preparation | **High** |
| 2 | `lib/core/media/preparation_coordinator.dart` | Coordinates download → decode pipeline | **Medium** |
| 3 | `lib/core/media/preparation_policy.dart` | Decides WHAT to prepare and WHEN | **Low** |
| 4 | `lib/core/media/download_scheduler.dart` | Manages concurrent downloads | **Low** |
| 5 | `lib/core/media/decode_scheduler.dart` | Pre-initializes video controllers, decodes images | **Medium** |
| 6 | `lib/core/media/memory_manager.dart` | Responds to memory pressure notifications | **Low** |
| 7 | `lib/core/media/cancellation_manager.dart` | Cancels in-flight preparation | **Low** |
| 8 | `lib/core/media/pagination_manager.dart` | Triggers loadMore when playlist runs low | **Low** |
| 9 | `lib/core/media/metrics_collector.dart` | Tracks preload hit rates, decode times | **Low** |

### 3.3 Files That Should Remain Untouched

| File | Reason |
|------|--------|
| `lib/core/media/media_source.dart` | Correct abstraction, no changes needed |
| `lib/features/slideshow/domain/merge_engine.dart` | Correct implementation, no changes needed |
| `lib/features/slideshow/domain/playlist_manager.dart` | Correct abstraction, no changes needed |
| `lib/features/slideshow/domain/slideshow_source.dart` | Correct sealed hierarchy, no changes needed |
| `lib/features/slideshow/data/subreddit_media_source.dart` | Correct implementation, no changes needed |
| `lib/features/slideshow/data/search_media_source.dart` | Correct implementation, no changes needed |
| `lib/features/feed/data/feed_repository.dart` | Backend-facing, no changes needed |
| `lib/features/search/data/search_repository.dart` | Backend-facing, no changes needed |
| `lib/core/network/api_client.dart` | Network layer, no changes needed |
| `lib/core/network/result.dart` | Utility, no changes needed |
| `lib/core/errors/app_error.dart` | Error types, no changes needed |
| `lib/core/router/app_router.dart` | Routing, no changes needed |
| `lib/core/media/media_error.dart` | Error logging, no changes needed |
| `lib/core/media/safe_network_image.dart` | Utility widget, no changes needed |
| `lib/features/slideshow/presentation/widgets/slideshow_overlay.dart` | Pure UI, no changes needed |
| `lib/features/slideshow/presentation/widgets/slideshow_controls.dart` | Pure UI, no changes needed |
| `lib/features/slideshow/presentation/widgets/queue_indicator.dart` | Pure UI, no changes needed |
| `lib/features/feed/domain/media_asset.dart` | Domain model, no changes needed |
| `lib/core/utils/pipeline_timer.dart` | Utility, no changes needed |
| `lib/core/constants/api_constants.dart` | API paths, no changes needed |
| `lib/core/constants/theme_constants.dart` | Theme, no changes needed |
| Backend files | No backend changes required |
| Test files | Will need updates, but tests themselves remain valid patterns |

---

## 4. Dependency Graph

### 4.1 Current Dependency Graph

```
SlideshowScreen
  ├── slideshowProvider (riverpod) ──▶ SlideshowNotifier
  │     ├── FeedRepository (via family key)
  │     ├── SearchRepository (via family key)
  │     ├── PlaylistManager ◀──┐ (shared)
  │     ├── MergeEngine        │
  │     │     ├── MediaSource  │
  │     │     │     ├── FeedRepository
  │     │     │     └── SearchRepository
  │     │     └── SourceBuffer (internal)
  │     ├── AdaptivePreloader ──┘ (shares PlaylistManager)
  │     │     ├── CachedNetworkImageProvider
  │     │     └── ImageCache (via PaintingBinding)
  │     ├── Timer (auto-advance)
  │     └── Timer (overlay)
  │
  ├── MediaViewer
  │     ├── ImageViewer
  │     │     ├── CachedNetworkImageProvider
  │     │     ├── DefaultCacheManager (disk check)
  │     │     ├── InteractiveViewer
  │     │     └── ImageCache (containsKey check)
  │     └── VideoViewer
  │           ├── VideoPlayerController.networkUrl()
  │           ├── SafeNetworkImage
  │           └── Timer (retry)
  │
  ├── SlideshowOverlay
  │     ├── QueueIndicator
  │     └── SlideshowControls
  │
  └── Timer (overlay hide)

⚠ CIRCULAR DEPENDENCY:
  AdaptivePreloader ──depends on──▶ PlaylistManager
  SlideshowNotifier ──owns────────▶ AdaptivePreloader
  SlideshowNotifier ──owns────────▶ PlaylistManager
  (Not strictly circular but tightly coupled bidirectional relationship)
```

### 4.2 Target Dependency Graph

```
SlideshowScreen
  ├── slideshowProvider (riverpod) ──▶ SlideshowNotifier
  │     ├── PlaylistManager ◀──────────┐
  │     ├── MergeEngine                │
  │     │     └── MediaSource          │
  │     ├── MediaPreparationEngine ────┘ (shares PlaylistManager)
  │     │     ├── PreparationCoordinator
  │     │     │     ├── PreparationPolicy
  │     │     │     ├── DownloadScheduler ──▶ CachedNetworkImageProvider
  │     │     │     ├── DecodeScheduler ──▶ VideoPlayerController
  │     │     │     │                     └── CachedNetworkImageProvider
  │     │     │     ├── CancellationManager
  │     │     │     ├── PaginationManager
  │     │     │     │     └── MergeEngine.autoRefill()
  │     │     │     └── MetricsCollector
  │     │     └── MemoryManager ──▶ ImageCache (eviction)
  │     ├── Timer (auto-advance)
  │     └── Timer (overlay)
  │
  ├── MediaViewer
  │     ├── PreparedImageViewer
  │     │     ├── Image (from ImageCache — guaranteed hit)
  │     │     └── InteractiveViewer
  │     └── PreparedVideoViewer
  │           ├── Pre-initialized VideoPlayerController
  │           └── SafeNetworkImage (thumbnail fallback)
  │
  ├── SlideshowOverlay (unchanged)
  └── Timer (overlay hide)

✅ NO circular dependencies
✅ Clear separation: Preparation → Cache → Render
```

### 4.3 Circular Dependency Analysis

**Current**: No hard circular dependencies, but `SlideshowNotifier` ↔ `AdaptivePreloader` ↔ `PlaylistManager` form a tightly coupled triad where the notifier manages preloader lifecycle, the preloader shares the playlist, and the notifier advances the playlist.

**Target**: `MediaPreparationEngine` subscribes to `PlaylistManager` index changes (via `SlideshowNotifier`) and prepares items. Data flows one direction: Notifier → MPE → Cache → Widgets.

---

## 5. Migration Plan

### Phase 1: Create MediaPreparationEngine Foundation

**Goal**: Establish the MPE abstraction without modifying production code paths.

**Steps**:
1. Create `lib/core/media/media_preparation_engine.dart` — main class
2. Create `PreparationCoordinator`, `PreparationPolicy`, `DownloadScheduler` — extracted from `AdaptivePreloader`
3. Create `CancellationManager` — new
4. Create `MetricsCollector` — new (wraps existing log calls)
5. Create `PaginationManager` — extracted from `AdaptivePreloader._checkLoadMore`

**Existing code unchanged**: `AdaptivePreloader` continues working; MPE exists in parallel.

**Testable**: New classes are pure Dart + Flutter dependencies, testable in isolation.

**Risk**: Low — new code, no production impact.

**Rollback**: Delete the new files.

---

### Phase 2: Decouple SlideshowNotifier

**Goal**: Strip preloading concerns from `SlideshowNotifier`.

**Steps**:
1. Remove `AdaptivePreloader` creation from `attachPreloaderContext()`
2. Remove `_preloader` field from `SlideshowNotifier`
3. Remove `_notifyPreloader()` calls from `next()`, `previous()`, `jumpTo()`
4. Remove `_preloader?.dispose()` from `SlideshowNotifier.dispose()`
5. Have `SlideshowScreen` create and manage MPE separately
6. `SlideshowScreen` calls `mpe.onIndexChanged()` instead of `notifier.attachPreloaderContext()`

**Existing code modified**: `SlideshowNotifier` loses 3 fields/methods. `SlideshowScreen` gains MPE management.

**Testable**: Existing tests for notifier still pass (playlist, navigation, state unchanged). New tests for MPE.

**Risk**: **Medium** — if MPE is not correctly wired, preloading silently stops. This must be caught by integration testing.

**Rollback**: Restore `attachPreloaderContext()` and `_notifyPreloader()` calls.

---

### Phase 3: Add Video Pre-Initialization

**Goal**: Pre-initialize video controllers before items become visible.

**Steps**:
1. Create `DecodeScheduler` with `VideoControllerPool` (caches pre-initialized controllers)
2. MPE pre-initializes video controllers for next N items (defined by `AppConstants.videoPreloadWindow`)
3. Controller pooled by URL; eviction via LRU/memory pressure
4. Wire MPE → `DecodeScheduler` in `PreparationCoordinator`

**Testable**: Integration test verifies video controller is pre-initialized before page becomes visible.

**Risk**: **Medium** — video controllers use system resources (codecs). Pool must have a max size. Memory pressure handling is critical.

**Rollback**: Disable `videoPreloadWindow` → revert to on-demand initialization.

---

### Phase 4: Strip Widget Preparation

**Goal**: Make widgets consume already-prepared media only.

**Steps**:
1. Create `PreparedVideoViewer` — receives pre-initialized `VideoPlayerController`
2. `MediaViewer` dispatches to `PreparedVideoViewer` when controller is available
3. Fall back to `VideoViewer` (on-demand) when controller is not yet prepared
4. Remove `DefaultCacheManager.getFileFromCache()` from `ImageViewer`
5. Simplify `ImageViewer` — remove performance logging pipeline (now in `MetricsCollector`)

**Testable**: Run all existing tests. Visual verification that videos play correctly.

**Risk**: **Medium** — video playback path is significantly changed. The prepare-on-demand fallback is critical for safety.

**Rollback**: Revert to `VideoViewer` directly.

---

### Phase 5: Add Memory Management

**Goal**: Respond to system memory pressure by evicting distant preloaded items.

**Steps**:
1. Create `MemoryManager` — subscribes to `WidgetsBindingObserver.didChangeAppLifecycleState()`
2. On memory pressure: evict items far from current index from `ImageCache`
3. Register with MPE to unregister distant preload tasks
4. Set max size for video controller pool

**Testable**: Simulate memory pressure in test environment.

**Risk**: **Low** — memory eviction is additive and conservative.

**Rollback**: Remove memory pressure listener.

---

### Phase 6: Metrics Integration

**Goal**: Replace ad-hoc debug logging with structured metrics.

**Steps**:
1. Implement `MetricsCollector` with counters for: preload hits, preload misses, decode time, video init time, cache hit rate
2. Remove `[PRELOAD_*]`, `[IMAGE_*]`, `[VIDEO_*]` log calls from widgets
3. MPE reports metrics to `MetricsCollector`
4. Add `debugDump()` method to MPE

**Testable**: Unit tests for MetricsCollector. Integration tests verify metrics are collected.

**Risk**: **Low** — purely additive; removes noisy logs.

**Rollback**: Keep metrics collection; re-enable verbose logging if needed.

---

## 6. Risks

### 6.1 Technical Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| MPE over-engineering (too many sub-components) | **Medium** | **Low** — slows development | Start with minimal MPE; add sub-components only when needed. The `PreparationCoordinator` can be a single class initially. |
| Video pre-initialization resource exhaustion | **Medium** | **Medium** — app crash | Enforce max pool size (3-5 controllers). Evict by LRU. Release all on memory pressure. |
| Widget still prepares media (fallback path becomes permanent) | **Low** | **Low** — works but suboptimal | Add a metric to track how often fallback is used; if high, fix MPE. |
| CancellationManager races with in-flight preloads | **Low** | **Low** — wasted bandwidth | Use `AbortController`-like pattern. Allow in-flight preloads to complete but discard result. |

### 6.2 Performance Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| MPE adds overhead (more abstraction layers) | **Low** | **Low** — MPE is just Dart | Benchmark before/after. MPE is orchestrating, not doing heavy work. |
| Video pre-init increases bandwidth usage | **Medium** | **Low-Moderate** | Only pre-init `videoPreloadWindow` (2) videos ahead. Respect mute setting (don't stream audio). |
| Memory pressure from pooled video controllers | **Medium** | **Medium** | Strict pool limit. Release on memory pressure notification. |

### 6.3 Regression Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Preloading stops working after decoupling | **Medium** | **High** — visible waiting | **Phase 2 must be validated with integration tests.** Keep `AdaptivePreloader` as fallback until MPE is proven. |
| Video playback breaks after widget changes | **Medium** | **High** — core feature | Keep `VideoViewer` fallback in `PreparedVideoViewer`. If no prepared controller, fall back to on-demand. |
| Auto-advance timing changes | **Low** | **Medium** | No changes to auto-advance timer logic. Only preloading path changes. |
| Gallery navigation breaks | **Low** | **High** | Gallery navigation is in `SlideshowNotifier` — untouched by MPE changes. |
| MergeEngine ordering changes | **None** | **High** | MergeEngine is completely untouched. |

### 6.4 Memory Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| ImageCache grows unbounded | **Low** | **Low** | Already capped at 500 entries / 200MB. MPE can evict distant entries. |
| Video controller pool leaks | **Medium** | **Medium** | `dispose()` controllers on eviction. Use `WeakReference` for controller mapping. |

### 6.5 Testing Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| MPE requires real ImageCache for integration tests | **High** | **Medium** | Use test bindings (`TestWidgetsFlutterBinding`). Mock network for deterministic tests. |
| Video pre-init cannot be tested without platform support | **High** | **Low** | Unit test the scheduling logic. Integration test on real device. |
| Metrics collection creates test noise | **Low** | **Low** | MetricsCollector is injectable; disable in tests. |

### 6.6 Future Extensibility Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| MPE is too tightly coupled to current MediaAsset model | **Low** | **Low** | MPE operates on URLs, not MediaAsset. MediaAsset is extensible. |
| New media types (AI feeds) require different prep pipelines | **Low** | **Low** | PreparationPolicy can be extended with new strategies. |
| Groups/Favorites need different preloading priorities | **Low** | **Low** | MPE already has priority-based scheduling. |

---

## 7. Validation Plan

### 7.1 Per-Phase Validation

| Phase | flutter analyze | flutter test | Unit Tests | Integration Tests | Manual Testing | Real-Device Validation | Benchmarking |
|-------|----------------|-------------|------------|-------------------|----------------|----------------------|-------------|
| **Phase 1**: MPE Foundation | ✅ | ✅ | MPE creation, policy, coordinator, cancellation, metrics | — | — | — | — |
| **Phase 2**: Decouple Notifier | ✅ | ✅ | Notifier without preloader | Preloader continues working via MPE | Run slideshow, verify images preload correctly | Phone with 20+ items | Compare preload timings |
| **Phase 3**: Video Pre-Init | ✅ | ✅ | DecodeScheduler, controller pool | Video appears before swipe | Video plays without waiting | Phone, check video loading indicator disappears before navigation | Measure video-ready time |
| **Phase 4**: Strip Widget Prep | ✅ | ✅ | ImageViewer without disk check, PreparedVideoViewer | Full slideshow with all media types | All media types (image, gallery, video, mixed) | Phone with all media types | Compare image decode time |
| **Phase 5**: Memory Manager | ✅ | ✅ | MemoryManager eviction | Simulate memory pressure | Background app, return, continue slideshow | Phone with memory pressure | Measure memory usage |
| **Phase 6**: Metrics | ✅ | ✅ | MetricsCollector | Verify metrics are collected | Check debugDump output | Phone | Track hit rates |

### 7.2 Test Command Reference

```bash
# Lint
flutter analyze

# Unit tests
flutter test test/merge_engine_test.dart
flutter test test/benchmark_test.dart

# All tests
flutter test

# Manual testing checklist (for each phase):
# 1. Single subreddit slideshow
# 2. Multi-subreddit slideshow
# 3. Search slideshow
# 4. Gallery items navigation
# 5. Video playback + mute
# 6. Infinite scroll (loadMore)
# 7. Auto-advance
# 8. Back navigation
# 9. Download/Share/Open on Reddit
```

### 7.3 Benchmarking

```bash
# Existing benchmark
flutter test test/benchmark_test.dart

# Future benchmarks to add:
# - Preload hit rate: % of items already in ImageCache when viewed
# - Video ready time: time from navigation to first frame
# - Image ready time: time from navigation to image visible
# - Memory usage: peak RSS during 50-item slideshow
```

---

## 8. Rollback Strategy

### 8.1 Git-Based Rollback

Each phase is implemented in its own commit. Rollback is a simple `git revert`:

```bash
# Phase 1 revert
git revert <phase-1-commit-hash>

# Phase 2 revert
git revert <phase-2-commit-hash>

# etc.
```

### 8.2 Feature-Flag Rollback

For phases 2-6, the MPE can be disabled at compile time:

```dart
// lib/core/constants/app_constants.dart
static const bool enableMediaPreparationEngine = true; // Toggle for rollback
```

If `false`, revert to `AdaptivePreloader` + on-demand video initialization.

### 8.3 Per-Phase Rollback

| Phase | Rollback Action | Complexity | Service Impact |
|-------|----------------|------------|----------------|
| **Phase 1**: MPE Foundation | Delete new files | **Trivial** | None (no production code changed) |
| **Phase 2**: Decouple Notifier | Restore `attachPreloaderContext()`, `_notifyPreloader()` | **Trivial** | Preloading restored to previous behavior |
| **Phase 3**: Video Pre-Init | Set `videoPreloadWindow = 0` | **Trivial** | Videos fall back to on-demand initialization |
| **Phase 4**: Strip Widget Prep | Revert to `VideoViewer`, keep old `ImageViewer` | **Low** | Widgets return to doing prep work |
| **Phase 5**: Memory Manager | Remove memory pressure listener | **Trivial** | Memory management reverts to Flutter defaults |
| **Phase 6**: Metrics | Keep metrics; re-enable verbose logging | **Trivial** | Metrics stop being collected; logs return |

### 8.4 Safety Net

Before every phase:

```bash
git stash  # or commit current work
flutter test          # all tests pass
flutter analyze       # no warnings
```

After every phase:

```bash
flutter test          # all tests still pass
flutter analyze       # no new warnings
# Manual smoke test on device
```

---

## 9. Documentation Plan

### 9.1 Documents to Update After Each Phase

| Document | Location | Update When | What to Update |
|----------|----------|-------------|----------------|
| `frontend.md` | `/frontend.md` | After Phase 1 | Add MediaPreparationEngine to architecture diagram and component descriptions |
| `frontend.md` | `/frontend.md` | After Phase 2 | Update SlideshowNotifier responsibility description; remove AdaptivePreloader from notifier |
| `frontend.md` | `/frontend.md` | After Phase 3 | Add video pre-initialization to component description |
| `frontend.md` | `/frontend.md` | After Phase 4 | Update widget descriptions — they are now "consumers only" |
| `frontend.md` | `/frontend.md` | After Phase 5 | Add MemoryManager description |
| `frontend.md` | `/frontend.md` | After Phase 6 | Add MetricsCollector description |
| `README.md` | `/README.md` | After Phase 5 | If architecture diagram changes significantly |
| `ARCHITECTURE_AUDIT_PHASE5_1.md` | `/ARCHITECTURE_AUDIT_PHASE5_1.md` | After each phase | Mark phases as completed; add retrospective notes |

### 9.2 New Documentation to Create

None — all documentation lives in `frontend.md` and this audit document.

---

## 10. Final Recommendation

### 10.1 Do I Agree with the Target Architecture?

**Yes**, with reservations.

The target architecture correctly identifies the key problem: **SlideshowNotifier has too many responsibilities**. Splitting preloading concerns into a dedicated `MediaPreparationEngine` is the right architectural evolution.

The specific reservations are:

1. **The sub-component decomposition is too aggressive initially.** Creating 8 sub-components (`PreparationCoordinator`, `PreparationPolicy`, `DownloadScheduler`, `DecodeScheduler`, `MemoryManager`, `CancellationManager`, `PaginationManager`, `MetricsCollector`) in one phase risks over-engineering. **Recommendation**: Start with 1-2 classes. Evolve `AdaptivePreloader` → `MediaPreparationEngine` as a single class first. Split into sub-components only when justified by measured complexity.

2. **Video pre-initialization is the highest-value change.** Of all the proposed features, video pre-initialization has the most visible user impact. Current behavior: user taps "Next" → video widget creates controller → network fetch → decode → play. Target: controller already initialized. **This should be the priority.**

3. **Cancellation is important but must be implemented carefully.** Aborting `precacheImage()` is not straightforward — the API has no cancel mechanism. The `CancellationManager` should cancel *future* scheduled work rather than aborting in-flight downloads, unless using `AbortController`-wrapped HTTP.

4. **MemoryManager adds complexity for marginal gain.** The Flutter `ImageCache` already handles memory well at 500 entries / 200MB. Adding a `MemoryManager` that evicts entries preemptively may cause thrashing. **Recommendation**: Defer MemoryManager until real memory pressure is observed, or keep it minimal (just listen to `didChangeAppLifecycleState` → evict distant items).

### 10.2 Would I Change Anything?

**Yes**.

#### Simplify the Sub-Component Hierarchy

```
Current target:               Proposed simplification:
MediaPreparationEngine        MediaPreparationEngine
├── PreparationCoordinator     ├── PreparationPolicy
├── PreparationPolicy          ├── DownloadScheduler (images)
├── DownloadScheduler          ├── VideoPreparer (videos)
├── DecodeScheduler            ├── MetricsCollector
├── MemoryManager              └── PaginationManager
├── CancellationManager
├── PaginationManager
└── MetricsCollector
```

Rationale: `PreparationCoordinator` is unnecessary indirection if `MediaPreparationEngine` is the coordinator. `DecodeScheduler` and `DownloadScheduler` distinguish decode vs download, but both are just "prepare this URL" — one for images (precacheImage), one for videos (init controller). `MemoryManager` and `CancellationManager` can be methods on MPE.

#### Keep AdaptivePreloader as a Fallback

For at least one release cycle after Phase 2, keep `AdaptivePreloader` as a compile-time fallback. This is purely defensive — if MPE has bugs, the fallback ensures the app remains functional.

#### Rename Conservatively

The current code uses `AdaptivePreloader`. Renaming to `MediaPreparationEngine` is acceptable (it reflects the expanded scope). But sub-components should not be renamed unnecessarily. For example, `_processQueue` can remain `_processQueue` inside the MPE.

### 10.3 Are There Unnecessary Abstractions?

**Yes, in the current codebase:**

1. **`SafeNetworkImage`** (`lib/core/media/safe_network_image.dart`): Only used in `VideoViewer` thumbnail fallback. At 31 lines for a simple `Image` wrapper, it adds complexity without meaningful abstraction. Can be inline.

2. **`GroupsPlaceholderScreen`**: A 30-line widget in `app_router.dart` for a "Coming Soon" screen. Should be in its own feature file or removed.

3. **`ResumeSession`** (in `home_screen.dart`): Stub class returning `null`. At this point it's dead code.

**In the current architecture (not unnecessary):**

- `MediaSource` — clean, correct abstraction
- `MergeEngine` — clean, correct abstraction  
- `PlaylistManager` — clean, correct abstraction
- `SlideshowState` — clean, correct immutable state

### 10.4 Are There Missing Abstractions?

**Yes**:

1. **MediaPreparationEngine** — as proposed. The missing abstraction that this entire phase addresses.

2. **Prepared Video Controller Pool** — a pool of pre-initialized `VideoPlayerController` instances mapped by URL. Currently missing; videos are created on-demand.

3. **MetricsCollector** — currently scattered ad-hoc `debugPrint` calls throughout `adaptive_preloader.dart`, `image_viewer.dart`, `video_viewer.dart`, `slideshow_provider.dart`. A centralized collector would make performance analysis systematic.

### 10.5 Is This Architecture Appropriate for RedSlide's Scale?

**Yes**.

RedSlide is a single-developer Flutter app with:
- ~3,000 lines of frontend Dart code
- 6 backend API endpoints
- 3 configured subreddits (demo), ~25 lines in backend
- 3 test files (621 + 245 + 15 lines)

The target architecture is **not over-engineered for this scale** because:

1. **The current notifier already does too much** — it's a 371-line monolithic class that touches every concern. Splitting it is a maintenance necessity, even at current scale.

2. **Future extensibility is a stated goal** — Groups, Favorites, Saved, AI feeds. The current architecture does not cleanly support adding these without growing the notifier further.

3. **The performance requirements justify the complexity** — "the user should almost never wait after pressing Next" requires video pre-initialization, which requires a preparation engine.

4. **The proposed components are small and focused** — `CancellationManager`, `PaginationManager`, `MetricsCollector` are each < 50 lines. They are not heavy abstractions.

### 10.6 Would I Recommend Proceeding?

**Yes, with the following recommendations:**

#### Recommended Phase Order and Scope

```
Phase 1: MPE Foundation — START HERE
  ├── Create MediaPreparationEngine (single class, not 8 sub-components)
  ├── Move AdaptivePreloader logic into MPE
  ├── Keep AdaptivePreloader as compile-time fallback
  └── Create PaginationManager and MetricsCollector

Phase 2: Video Pre-initialization
  ├── Create VideoPreparer (manages VideoControllerPool)
  ├── Wire into MPE
  └── videoPreloadWindow = 2 (current constant, now used)

Phase 3: Decouple SlideshowNotifier
  ├── Remove AdaptivePreloader from notifier
  ├── SlideshowScreen creates MPE
  └── Notifier only manages state + navigation

Phase 4: Strip Widget Preparation
  ├── PreparedVideoViewer (receives pre-initialized controller)
  ├── PreparedImageViewer (no disk check, no logging)
  ├── Fallback to on-demand if no prepared media
  └── Remove disk cache check from ImageViewer

Phase 5: Cancellation and Memory
  ├── MPE cancels scheduled work for irrelevant items
  ├── MPE evicts distant items from ImageCache
  └── VideoControllerPool eviction on memory pressure

Phase 6: Metrics
  ├── Move log calls to MetricsCollector
  └── Remove ad-hoc debugPrint statements from widgets
```

#### Guidance for Phase 5.2 (Implementation)

- **Start with Phase 1** — the MPE foundation
- **Don't create all 8 sub-components upfront** — start with a single `MediaPreparationEngine` class
- **Keep AdaptivePreloader working** during the transition
- **Preserve all existing log statements** until MetricsCollector is implemented
- **Do not touch MergeEngine, MediaSource, PlaylistManager, or SlideshowState**
- **Do not touch backend code**
- **Each phase must pass `flutter analyze` and all existing tests before moving to the next**

---

## Appendix A: File-by-File Migration Table Summary

| Phase | Files Changed | Files Created | Test Changes | Risk |
|-------|--------------|--------------|-------------|------|
| 1 | 0 | 3-4 (MPE, policy, pagination, metrics) | New unit tests | Low |
| 2 | 0 | 1 (VideoPreparer) | New unit + integration tests | Medium |
| 3 | 2 (notifier, screen) | 0 | Existing tests must pass | Medium |
| 4 | 3 (media_viewer, image_viewer, video_viewer) | 2 (prepared image/video widgets) | Existing + new tests | Medium |
| 5 | 1 (MPE) | 0 | New unit tests | Low |
| 6 | 4 (all *viewer files) | 0 | Existing tests must pass | Low |

**Total**: 10 files modified, ~7 files created, 0 backend changes.

## Appendix C: Phase 5.2 Completion Report

### Completed Work
| Item | Status | Details |
|------|--------|---------|
| `MediaPreparationEngine` class | ✅ | Created at `lib/features/slideshow/domain/media_preparation_engine.dart` (36 lines) |
| Wraps `AdaptivePreloader` | ✅ | Internal composition; all existing behavior preserved |
| Clean public API | ✅ | `attachContext()`, `initialize()`, `onPlaylistChanged()`, `onIndexChanged()`, `dispose()` |
| SlideshowNotifier updated | ✅ | Uses `_preparationEngine` instead of `_preloader`; references renamed |
| SlideshowScreen updated | ✅ | Calls `attachPreparationEngine(context)` |
| `AdaptivePreloader` preserved | ✅ | Unchanged, used internally by MPE |
| Unit tests created | ✅ | 6 tests covering creation, no-context safety, dispose safety |
| `flutter analyze` | ✅ | No new issues (44 pre-existing info-level warnings only) |
| `flutter test` | ✅ | 33/33 tests pass |
| Docs updated | ✅ | `frontend.md` updated with MPE section; architecture audit updated |

### File Changes Summary
| Action | File | Lines |
|--------|------|-------|
| **Created** | `lib/features/slideshow/domain/media_preparation_engine.dart` | +36 |
| **Created** | `test/media_preparation_engine_test.dart` | +56 |
| **Modified** | `lib/features/slideshow/providers/slideshow_provider.dart` | -4 / +4 (field rename, method rename) |
| **Modified** | `lib/features/slideshow/presentation/slideshow_screen.dart` | -1 / +1 (method call rename) |
| **Modified** | `frontend.md` | +45 (new MPE section + notifier updates) |

### Responsibility Changes
| Before | After | Reason |
|--------|-------|--------|
| `SlideshowNotifier._preloader` (AdaptivePreloader) | `SlideshowNotifier._preparationEngine` (MPE) | Clear architectural boundary; MPE is the dedicated preparation layer |
| `attachPreloaderContext()` | `attachPreparationEngine()` | Reflects new component name |
| AdaptivePreloader created inline in notifier | Created via MPE.attachContext() | MPE owns preloader lifecycle |

### Regression Verification
| Feature | Status | Test Method |
|---------|--------|-------------|
| Single subreddit slideshow | ✅ Unchanged | Code path identical — MPE delegates to AdaptivePreloader |
| Multi subreddit slideshow | ✅ Unchanged | Same delegation |
| Search slideshow | ✅ Unchanged | Same delegation |
| Gallery navigation | ✅ Unchanged | Notifier.galleryNext() untouched |
| Video playback | ✅ Unchanged | Widgets unchanged |
| Infinite scrolling | ✅ Unchanged | loadMore() path untouched |
| Auto-advance | ✅ Unchanged | Timer logic untouched |
| Preloading behavior | ✅ Unchanged | AdaptivePreloader unchanged internally |
| Overlay timers | ✅ Unchanged | Untouched |

## Appendix B: Key Architectural Invariants (MUST NOT CHANGE)

```
1. MediaSource.loadNext() → MediaPage
2. MergeEngine.initialize() → create buffers → load → merge
3. PlaylistManager.items + index
4. SlideshowState as immutable data class
5. Flutter ImageCache as the ONLY bitmap cache
6. No custom bitmap cache
7. No native plugins
8. No isolates
9. No ML prediction
10. Backend API contract (endpoints, response shapes)
11. Route paths (/slideshow, /subreddit/:name, etc.)
12. SlideshowSource sealed class hierarchy
```
