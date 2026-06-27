# RedSlide Frontend Architecture

## Table of Contents
1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Technology Stack](#technology-stack)
4. [Directory Structure](#directory-structure)
5. [App Entry & Root](#app-entry--root)
6. [Routing & Navigation](#routing--navigation)
7. [State Management](#state-management)
8. [Data Layer](#data-layer)
9. [Feature: Feed](#feature-feed)
10. [Feature: Search](#feature-search)
11. [Feature: Slideshow & MergeEngine](#feature-slideshow--mergeengine)
12. [Feature: Settings](#feature-settings)
13. [Feature: Groups](#feature-groups)
14. [Core: MediaSource Abstraction](#core-mediasource-abstraction)
15. [Core: AdaptivePreloader](#core-adaptivepreloader)
16. [Core: PlaylistManager](#core-playlistmanager)
17. [Media Loading & Preloading](#media-loading--preloading)
18. [Widgets & Components](#widgets--components)
19. [Theme & Styling](#theme--styling)
20. [Utilities & Extensions](#utilities--extensions)
21. [API Integration](#api-integration)
22. [Data Flow](#data-flow)
23. [Known Limitations](#known-limitations)
24. [Future Improvements](#future-improvements)

---

## Overview

**RedSlide** is a Flutter-based media-first slideshow and wallpaper discovery app that connects to a Python FastAPI backend. It aggregates media from Reddit subreddits and presents it in an immersive slideshow format, allowing users to browse images and videos from their favorite communities.

The frontend is fully implemented and provides:
- Home screen with configured subreddits and cover image previews
- Media feed browsing per subreddit with infinite scroll
- Full-text search (local within subreddits or global across Reddit)
- Fullscreen slideshow with auto-advance, video playback, gallery support
- Multi-subreddit merging client-side via MergeEngine using the MediaSource abstraction
- MediaSource-based abstract data loading (SubredditMediaSource, SearchMediaSource)
- PlaylistManager for item list + index management separated from state
- Dedicated AdaptivePreloader class with priority-queue-based image preloading
- Settings management with SharedPreferences persistence and backend auto-sync
- Bottom navigation with Home, Search, Groups (placeholder), and Settings tabs

---

## Architecture

### High-Level Architecture Diagram

```
┌────────────────────────────────────────────────────────────────────────────┐
│                          FLUTTER FRONTEND                                   │
│                                                                             │
│  main.dart                                                                  │
│    └── ProviderScope                                                        │
│          └── RedSlideApp (ConsumerStatefulWidget)                          │
│                ├── MaterialApp.router                                      │
│                │     ├── routerProvider (GoRouter)                        │
│                │     │     ├── ShellRoute (AppShell + NavigationBar)     │
│                │     │     │     ├── /          → HomeScreen             │
│                │     │     │     ├── /search    → SearchScreen           │
│                │     │     │     ├── /groups    → GroupsPlaceholder      │
│                │     │     │     └── /settings  → SettingsScreen         │
│                │     │     ├── /subreddit/:name → SubredditScreen        │
│                │     │     └── /slideshow       → SlideshowScreen        │
│                │     │           (via SlideshowRouteExtra)                │
│                │     ├── ThemeData (Material 3, Inter font, red seed)     │
│                │     └── settingsProvider (AsyncNotifier)                │
│                │                                                          │
│                └── Feature Modules (per feature folder)                   │
│                      ┌─────────────────────────────────────┐              │
│                      │  presentation/ (screens & widgets)  │              │
│                      │  providers/    (StateNotifier/      │              │
│                      │                AsyncNotifier)       │              │
│                      │  domain/       (models, state)      │              │
│                      │  data/         (repositories)       │              │
│                      └──────────┬──────────────────────────┘              │
│                                 │                                          │
│                                 ▼                                          │
│                      ┌─────────────────────────────────────┐              │
│                      │ MediaSource abstraction             │              │
│                      │  SubredditMediaSource (feed)        │              │
│                      │  SearchMediaSource (search)         │              │
│                      └──────────┬──────────────────────────┘              │
│                                 │                                          │
│                                 ▼                                          │
│                      ┌─────────────────────────────────────┐              │
│                      │ MergeEngine (multi-subreddit merger) │              │
│                      │ ─────────────────────────────────── │              │
│                      │ SourceBuffer per MediaSource        │              │
│                      │ Round-robin + freshness + diversity │              │
│                      │ Auto-refill at low watermark (8)    │              │
│                      │ Used for all multi-source types     │              │
│                      └──────────┬──────────────────────────┘              │
│                                 │                                          │
│                                 ▼                                          │
│                      ┌─────────────────────┐                              │
│                      │ ApiClient (Dio)     │                              │
│                      │ ─────────────────── │                              │
│                      │ Result<T> sealed    │                              │
│                      │ Success / Failure   │                              │
│                      └──────────┬──────────┘                              │
└─────────────────────────────────┼──────────────────────────────────────────┘
                                  │ HTTP (JSON)
                                  ▼
                     ┌─────────────────────────┐
                     │   Backend API (FastAPI)  │
                     └─────────────────────────┘
```

### Architecture Pattern: Feature-First with Riverpod

The app follows a **feature-first** architecture where each feature (feed, search, slideshow, settings, groups) is a self-contained module with its own:

- **`domain/`** — Data models and state classes (plain Dart, no code generation)
- **`data/`** — Repositories that communicate with the backend via `ApiClient`
- **`providers/`** — Riverpod providers and notifiers that hold state and business logic
- **`presentation/`** — Screens and widgets

Shared code lives in `lib/core/` (constants, network, errors, routing, utils, media_source) and `lib/shared/` (reusable widgets, utilities).

---

## Technology Stack

| Category | Library | Version | Purpose |
|---|---|---|---|
| **Framework** | Flutter | SDK | Cross-platform UI framework |
| **Language** | Dart | ^3.12.2 | Programming language |
| **State Management** | flutter_riverpod | ^2.6.1 | Reactive state management |
| **Routing** | go_router | ^14.8.1 | Declarative, type-safe routing |
| **HTTP Client** | dio | ^5.7.0 | Network requests |
| **Local Storage** | shared_preferences | ^2.5.3 | Key-value persistence |
| **Image Caching** | cached_network_image | ^3.4.1 | Network image with disk cache |
| **Cache Manager** | flutter_cache_manager | ^3.4.1 | Generic file caching |
| **Video Playback** | video_player | ^2.9.3 | MP4 video playback |
| **Fonts** | google_fonts | ^6.2.1 | Inter typeface |
| **Shimmer** | shimmer | ^3.0.0 | Loading skeleton effects |
| **Share** | share_plus | ^10.1.4 | Share media externally |
| **URL Launcher** | url_launcher | ^6.3.1 | Open Reddit links |
| **Path Provider** | path_provider | ^2.1.5 | Temp directory for downloads |
| **Permission Handler** | permission_handler | ^11.3.1 | Runtime permissions (declared, not used) |
| **Intl** | intl | ^0.19.0 | Internationalization (declared, not used) |
| **Universal HTML** | universal_html | ^2.2.4 | Web HTML support |
| **Code Gen (dev)** | freezed / json_serializable | ^2.5.8 / ^6.9.5 | Annotations present, generators not run |

### Platform Support

- **Android**: Primary target (build configured)
- **iOS**: Configurable (not tested)
- **Web**: Configured with `universal_html`
- **Desktop**: Linux, Windows configured (not primary targets)

---

## Directory Structure

```
lib/
├── main.dart                              # Entry point
├── app.dart                               # Root widget (RedSlideApp)
├── core/
│   ├── constants/
│   │   ├── api_constants.dart             # API paths, timeouts, defaults
│   │   ├── app_constants.dart             # Preload config, pagination, merge engine params
│   │   └── theme_constants.dart           # Spacing, radius, duration, colors
│   ├── errors/
│   │   └── app_error.dart                 # Sealed error hierarchy
│   ├── extensions/
│   │   ├── context_extensions.dart        # BuildContext helpers
│   │   └── string_extensions.dart         # String formatting helpers
│   ├── media/
│   │   ├── media_error.dart               # Media error types + logging
│   │   ├── media_source.dart              # MediaSource abstract class + MediaPage
│   │   └── safe_network_image.dart        # Safe image widget with fallback
│   ├── network/
│   │   ├── api_client.dart                # Dio HTTP client wrapper
│   │   └── result.dart                    # Result<T> sealed class
│   ├── router/
│   │   └── app_router.dart                # GoRouter config + AppShell
│   └── utils/
│       ├── debouncer.dart                 # Generic debounce utility
│       └── pipeline_timer.dart            # Performance timing utility
├── features/
│   ├── feed/
│   │   ├── data/
│   │   │   └── feed_repository.dart       # Feed API calls + response models
│   │   ├── domain/
│   │   │   └── media_asset.dart           # MediaAsset model
│   │   ├── presentation/
│   │   │   ├── home_screen.dart           # Subreddit grid / main hub
│   │   │   ├── subreddit_screen.dart      # Per-subreddit media grid
│   │   │   └── widgets/
│   │   │       ├── media_card.dart        # Grid card with thumbnail
│   │   │       ├── media_grid.dart        # Adaptive grid with pagination
│   │   │       ├── shimmer_card.dart      # Loading placeholder
│   │   │       └── subreddit_card.dart    # Subreddit tile with cover
│   │   └── providers/
│   │       └── feed_provider.dart         # FeedNotifier + FeedState
│   ├── groups/
│   │   └── domain/
│   │       └── group_model.dart           # GroupModel (unused)
│   ├── search/
│   │   ├── data/
│   │   │   └── search_repository.dart     # Search API calls
│   │   ├── presentation/
│   │   │   ├── search_screen.dart         # Search UI
│   │   │   └── widgets/
│   │   │       ├── search_filter_sheet.dart
│   │   │       ├── search_history_chip.dart
│   │   │       ├── search_result_card.dart
│   │   │       ├── search_result_tile.dart
│   │   │       └── subreddit_selector_sheet.dart
│   │   └── providers/
│   │       └── search_provider.dart       # SearchNotifier + SearchState
│   ├── settings/
│   │   ├── data/
│   │   │   └── settings_repository.dart   # SharedPreferences persistence
│   │   ├── domain/
│   │   │   └── settings_model.dart        # SettingsModel
│   │   ├── presentation/
│   │   │   └── settings_screen.dart       # Settings UI
│   │   └── providers/
│   │       └── settings_provider.dart     # SettingsNotifier (AsyncNotifier)
│   └── slideshow/
│       ├── data/
│       │   ├── search_media_source.dart   # SearchMediaSource — wraps search as MediaSource
│       │   └── subreddit_media_source.dart # SubredditMediaSource — wraps feed as MediaSource
│       ├── domain/
│       │   ├── adaptive_preloader.dart    # Priority-queue image preloader
│       │   ├── merge_engine.dart          # Multi-subreddit merge engine
│       │   ├── playlist_manager.dart      # Item list + index management
│       │   ├── slideshow_source.dart      # Sealed source types + SlideshowRouteExtra
│       │   └── slideshow_state.dart       # SlideshowState
│       ├── presentation/
│       │   ├── slideshow_screen.dart      # Fullscreen slideshow
│       │   └── widgets/
│       │       ├── image_viewer.dart      # Zoomable image with performance logging
│       │       ├── media_viewer.dart      # Dispatches to video/image
│       │       ├── queue_indicator.dart   # Horizontal queue chips
│       │       ├── slideshow_controls.dart
│       │       ├── slideshow_overlay.dart
│       │       └── video_viewer.dart      # Video player with thumbnail fallback + retry
│       └── providers/
│           └── slideshow_provider.dart    # SlideshowNotifier (refactored — uses MediaSource)
├── shared/
│   ├── utils/
│   │   └── url_sanitizer.dart            # Reddit URL sanitization
│   └── widgets/
│       ├── app_error_widget.dart          # Error display with actions
│       ├── empty_state_widget.dart        # Empty state placeholder
│       ├── loading_shimmer.dart           # Shimmer grid/rectangle
│       └── nsfw_blur_widget.dart          # NSFW blur overlay
└── l10n/                                  # Empty - no localization yet
```

---

## App Entry & Root

### `main.dart` — Entry Point

**Path:** `lib/main.dart`

The entry point configures the app environment and launches the widget tree:

1. **`WidgetsFlutterBinding.ensureInitialized()`** — Ensures plugin channels are ready
2. **Orientation lock** — All four orientations enabled
3. **System UI overlay** — Transparent status bar and navigation bar with light icons
4. **Image cache configuration** — Sets `ImageCache` maximum size (500 entries, 200MB)
5. **ProviderScope** — Riverpod's root provider container wraps the entire app
6. **RedSlideApp** — The root widget is rendered

### `app.dart` — Root Widget

**Path:** `lib/app.dart`

`RedSlideApp` is a `ConsumerStatefulWidget` that:

1. **Watches `settingsProvider`** to load persisted settings (backend URL, subreddits, theme mode, etc.)
2. **Initial subreddit sync** — On first load, if a backend URL and subreddits are configured, it POSTs the subreddit list to `/api/subreddits/sync`
3. **Renders MaterialApp.router** with:
   - `routerConfig` from `routerProvider`
   - `themeMode` resolved from settings (system/light/dark)
   - Light and dark themes built with Material 3 `ColorScheme.fromSeed` (seed: red `#E53935`)
   - `GoogleFonts.interTextTheme()` for all typography
4. **Loading state** — Shows a centered `CircularProgressIndicator`
5. **Error state** — Shows `Text('Failed to load settings')`

#### Theme Configuration

Themes are built with Material 3 and share common styling:

| Property | Light | Dark |
|---|---|---|
| Seed Color | `#E53935` (red) | `#E53935` (red) |
| Surface | Default | `#121212` |
| AppBar | No elevation, scrolledUnderElevation: 1 | Same |
| Card | Border with `surfaceContainerHighest`, elevation: 0 | Same |
| NavigationBar | No elevation, surface background | Same |
| FAB | No elevation, rounded | Same |
| Dividers | `outlineVariant` color, 0.5 thickness | Same |
| SegmentedButton | Rounded | Same |

---

## Routing & Navigation

**Path:** `lib/core/router/app_router.dart`

Routing is handled by **go_router** with a `ShellRoute` for the bottom navigation bar and full-screen routes for the subreddit feed and slideshow.

### Route Table

| Path | Screen | Navigator | Transition | Extra Data |
|---|---|---|---|---|
| `/` | HomeScreen | ShellRoute (tab 0) | NoTransition | — |
| `/search` | SearchScreen | ShellRoute (tab 1) | NoTransition | — |
| `/groups` | GroupsPlaceholderScreen | ShellRoute (tab 2) | NoTransition | — |
| `/settings` | SettingsScreen | ShellRoute (tab 3) | NoTransition | — |
| `/subreddit/:name` | SubredditScreen | Root navigator (full-screen) | Default push | Path param: `name` |
| `/slideshow` | SlideshowScreen | Root navigator (full-screen dialog) | Fade transition | `SlideshowRouteExtra` via `state.extra` |

### AppShell (NavigationBar)

The `AppShell` widget wraps the four main tab routes with a `NavigationBar` containing four destinations:

| Index | Label | Icon | Selected Icon |
|---|---|---|---|---|
| 0 | Home | `Icons.home_outlined` | `Icons.home` |
| 1 | Search | `Icons.search` | Same |
| 2 | Groups | `Icons.folder_outlined` (with `Badge("Soon")`) | `Icons.folder` |
| 3 | Settings | `Icons.settings_outlined` | `Icons.settings` |

The `_indexFromLocation()` method maps the current route path to the correct tab index. Only the slideshow and subreddit routes are pushed on the root navigator (hiding the bottom nav bar).

### Slideshow Route Parameters

The `/slideshow` route receives data via `state.extra`:
- If `SlideshowRouteExtra` is passed: contains a `SlideshowSource` + optional `startIndex`
- Otherwise: the extra itself is treated as a `SlideshowSource` (with a fallback to `GlobalFeedSource`)

`SlideshowRouteExtra` is defined in `slideshow_source.dart`:
```dart
class SlideshowRouteExtra {
  final SlideshowSource source;
  final int startIndex;
  const SlideshowRouteExtra({required this.source, this.startIndex = 0});
}
```

### Groups Placeholder

The Groups tab shows a placeholder screen with an icon and "Coming in a future update" message. The feature is stubbed out.

---

## State Management

The app uses **Riverpod** exclusively with these provider types:
- **`Provider`** — For singletons (GoRouter, repositories, ApiClient family)
- **`Provider.family`** — For parameterized singletons (ApiClient by baseUrl)
- **`StateNotifierProvider` / `StateNotifierProvider.family`** — For mutable state (feed, search, slideshow)
- **`AsyncNotifierProvider`** — For async initialization (settings)
- **`FutureProvider.autoDispose.family`** — For one-shot async fetches (home feed cover images)

### Provider Inventory

| Provider Name | Type | Family? | File | State Class |
|---|---|---|---|---|
| `routerProvider` | `Provider<GoRouter>` | No | `app_router.dart` | — |
| `settingsProvider` | `AsyncNotifierProvider<SettingsNotifier, SettingsModel>` | No | `settings_provider.dart` | `SettingsModel` |
| `settingsRepositoryProvider` | `Provider<SettingsRepository>` | No | `settings_repository.dart` | — |
| `feedRepositoryProvider` | `Provider<FeedRepository>` | No | `feed_repository.dart` | — |
| `apiClientProvider` | `Provider.family<ApiClient, String>` | Yes (by baseUrl) | `api_client.dart` | — |
| `searchRepositoryProvider` | `Provider<SearchRepository>` | No | `search_repository.dart` | — |
| `feedProvider` | `StateNotifierProvider.family<FeedNotifier, FeedState, String?>` | Yes (by subreddit) | `feed_provider.dart` | `FeedState` |
| `searchProvider` | `StateNotifierProvider<SearchNotifier, SearchState>` | No | `search_provider.dart` | `SearchState` |
| `searchResultsProvider` | `Provider<SearchState>` | No | `search_provider.dart` | (alias) |
| `slideshowProvider` | `StateNotifierProvider.family<SlideshowNotifier, SlideshowState, SlideshowSource>` | Yes (by source) | `slideshow_provider.dart` | `SlideshowState` |
| `homeFeedProvider` | `FutureProvider.autoDispose.family<Map<String, String?>, String>` | Yes (by subreddit) | `home_screen.dart` | — |
| `resumeSessionProvider` | `Provider.family<ResumeSession?, String>` | Yes | `home_screen.dart` | (stub returning null) |

### Provider Lifecycle

- **`apiClientProvider`** — Family provider keyed by `baseUrl` string. Each unique base URL gets its own `ApiClient` instance.
- **`feedProvider`** — Family provider keyed by `String?` (subreddit name or null for global feed). Each subreddit gets its own `FeedNotifier`.
- **`slideshowProvider`** — Family provider keyed by `SlideshowSource` (sealed class with custom equality). Each slideshow session gets its own notifier.
- **`homeFeedProvider`** — Auto-disposing future provider that fetches a single cover image for each configured subreddit on the home screen.

### SettingsNotifier

**Type:** `AsyncNotifier<SettingsModel>`

Initializes by loading `SettingsModel` from `SharedPreferences`. Exposes mutation methods that:
1. Update the in-memory state via `state = AsyncData(updated)`
2. Persist to `SharedPreferences` via `SettingsRepository`
3. On subreddit changes: also syncs to backend via `_syncSubredditsToBackend()`

### FeedNotifier

**Type:** `StateNotifier<FeedState>` (family by subreddit name)

Manages a paginated list of `MediaAsset` items for a single subreddit (or the global feed). Exposes:
- `loadInitial()` — First page load
- `refresh()` — Reset and reload from scratch
- `loadMore()` — Append next page (cursor-based)
- `setSort()` — Change sort mode and refresh

### SearchNotifier

**Type:** `StateNotifier<SearchState>`

Manages search query, results, pagination, filters, and recent queries. Exposes:
- `search(query)` — Execute search with current filters. Calls `/api/search/reddit`
- `loadMore()` — Paginate results (cursor-based, only works in global mode; local always returns `after=None`)
- `setMode()` — Toggle local (within selected subreddits) vs global (all Reddit)
- `toggleSubreddit()` / `setSelectedSubreddits()` — Filter subreddits
- `setMediaType()` / `setSort()` — Filter/sort controls
- `syncSelectedSubreddits()` — Keep subreddit selection in sync with settings (intersection)
- `clearResults()` / `clearHistory()` / `removeRecentQuery()` / `resetFilters()` — State management

**Search result deduplication**: `loadMore()` deduplicates by `MediaAsset.id` to prevent duplicates from appearing when paginating.

### SlideshowNotifier

**Type:** `StateNotifier<SlideshowState>` (family by `SlideshowSource`)

The most complex notifier. Manages a **unified** pipeline using `MediaSource` abstraction + `MergeEngine`:

**Internal architecture:**
- `PlaylistManager _playlist` — Manages the flat item list + current index + navigation
- `MergeEngine? _mergeEngine` — Optional merge engine (null for single-source direct feeds, but currently always created since even single subreddits use a MergeEngine with one SourceBuffer)
- `AdaptivePreloader? _preloader` — Lazily attached via `attachPreloaderContext()`

**Construction (`_buildMediaSources`):**
```
SlideshowSource → List<MediaSource>
  SubredditSource       → [SubredditMediaSource(repository, subreddit, sortMode)]
  MultiSubredditSource  → [SubredditMediaSource × N]
  GlobalFeedSource      → [SubredditMediaSource × allConfiguredSubreddits]
  SearchSource          → [SearchMediaSource(repository, query, mode, subreddits)]
  GroupSource           → [SubredditMediaSource × groupSubreddits]
```

All source types now go through a single MergeEngine pipeline. The MergeEngine
wraps the list of `MediaSource` objects in `SourceBuffer` instances.

**Initialization:**
- `initialize()` — Single unified method:
  1. Calls `_mergeEngine.initialize()` — fires parallel `loadNext()` on all sources
  2. `drainMerged()` — Gets first batch of merged items
  3. Appends to `_playlist`, copies to `state.items`, starts auto-advance
  4. If items empty, sets `hasMorePages: false` early

**Preloader attachment (separate from constructor):**
- `attachPreloaderContext(BuildContext)` — Called from `SlideshowScreen.initState()` after the notifier is created but before `initialize()`. Creates `AdaptivePreloader` with `_playlist`, a `loadMore` callback, and the build context (needed for `precacheImage`).
- This separation avoids requiring `BuildContext` during provider construction.

**Navigation:**
- `next()` / `previous()` / `jumpTo()` — Navigation with auto-advance restart
  - `next()` handles boundary: if at end of `_playlist`, waits for `loadMore()`, then advances
  - `_syncState()` copies `_playlist` state to `SlideshowState`
  - `_notifyPreloader()` calls `_preloader.onIndexChanged(currentIndex)`
- `galleryNext()` / `galleryPrevious()` — Gallery sub-item navigation (advances to next asset at gallery end)

**UI State:**
- `togglePlay()` / `toggleMute()` / `toggleFullscreen()` / `toggleOverlay()` / `showOverlay()` — Standard state toggles

**Pagination:**
- `loadMore()` — Guarded by `isLoadingMore`, ensures only one in-flight. Calls `_doLoadMore()`
  - `_doLoadMore()` calls `_mergeEngine.autoRefill()` (refills buffers below low watermark)
  - `drainMerged()` returns new items → `_playlist.append(newItems)` → update state
  - `hasMorePages` set based on whether new items exist OR engine has more sources

**No more separate init methods**: Unlike the previous architecture, there are no separate `_initMergeEngine()`, `_initSearchMergeEngine()`, or `_loadInitialItems()` methods. All source types are handled uniformly.

**State fields removed**: `source` and `paginationCursor` are no longer part of `SlideshowState`. The source is held by the notifier itself.

**Auto-advance:**
- `_startAutoAdvance()` / `_restartAutoAdvance()` / `_cancelAutoAdvance()` — Timer-based auto-play

**Overlay:**
- `_startOverlayTimer()` / `_cancelOverlayTimer()` — Auto-hide overlay in fullscreen (3 seconds)

**Advanced:**
- `setInterval()` — Configure auto-advance interval from settings
- `debugDump()` — Forensic dump of complete internal state including MergeEngine buffer audit

---

## Data Layer

### ApiClient

**Path:** `lib/core/network/api_client.dart`

A thin wrapper around **Dio** that provides `get<T>()` and `post<T>()` methods. Key characteristics:

- **Configuration:** 10s connect timeout, 30s receive timeout, JSON content type
- **Debug logging:** LogInterceptor enabled in debug mode only
- **Empty base URL guard:** Returns `Failure(NotConfiguredError())` if `baseUrl` is empty
- **Error handling:** Maps `DioException` types to specific `AppError` subtypes:
  - `connectionTimeout` / `receiveTimeout` / `connectionError` → `NetworkError`
  - HTTP errors → `ServerError`
  - Other → `NetworkError`
- **Family provider:** `apiClientProvider(baseUrl)` creates one client per base URL

### Result<T> — Sealed Class

**Path:** `lib/core/network/result.dart`

All API calls return `Result<T>` — a sealed class with two variants:

```dart
sealed class Result<T> {
  R when<R>(R Function(T data) onSuccess, R Function(AppError error) onFailure);
}
class Success<T> extends Result<T> { final T data; }
class Failure<T> extends Result<T> { final AppError error; }
```

This forces callers to handle both success and failure paths.

### AppError — Sealed Class Hierarchy

**Path:** `lib/core/errors/app_error.dart`

| Error Type | Fields | Meaning |
|---|---|---|
| `NetworkError` | `message` | Connectivity issues, timeouts, DNS failures |
| `ServerError` | `statusCode`, `message` | HTTP error responses |
| `NotConfiguredError` | — | Backend URL not set |
| `ParseError` | `message` | JSON parsing failures |
| `NotFoundError` | — | 404 content |

### Repositories

Each feature has a repository that:
1. Reads the backend URL from `settingsProvider`
2. Creates an `ApiClient` via `apiClientProvider(baseUrl)`
3. Calls the appropriate API endpoints
4. Maps JSON responses to domain models via `fromJson` factories
5. Returns `Result<T>`

#### FeedRepository

**Path:** `lib/features/feed/data/feed_repository.dart`

| Method | Endpoint | Params | Return |
|---|---|---|---|
| `getFeed()` | `GET /api/feed` | `limit`, `after`, `subreddits`, `sort` | `Result<FeedResponse>` |
| `getQueueStatus()` | `GET /api/feed/queue` | — | `Result<QueueResponse>` |
| `getMedia(id)` | `GET /api/media/{id}` | — | `Result<MediaAsset>` |
| `startSlideshow(id)` | `POST /api/media/start/{id}` | — | `Result<void>` |
| `syncSubreddits(list)` | `POST /api/subreddits/sync` | `{subreddits: [...]}` | `Result<void>` |
| `getHealth()` | `GET /api/health` | — | `Result<HealthResponse>` |

**Response models** (defined in same file):
- `FeedResponse` — `items`, `after`, `hasMore`, `totalResults`
- `QueueResponse` — `queueSize`
- `HealthResponse` — `status`, `database`, `oauthValid`, `queueSize`, `providers`

#### SearchRepository

**Path:** `lib/features/search/data/search_repository.dart`

| Method | Endpoint | Params | Return |
|---|---|---|---|
| `searchReddit()` | `GET /api/search/reddit` | `query` (sent as `q`), `mode`, `limit`, `after`, `subreddits` | `Result<FeedResponse>` |
| `search()` | `GET /api/search` | `query` (sent as `q`), `limit`, `page`, `subreddits`, `mediaType`, `sort` | `Result<FeedResponse>` |
| `searchDebug()` | `GET /api/search/debug` | `q`, `limit`, `page` | `Result<FeedResponse>` |

#### SettingsRepository

**Path:** `lib/features/settings/data/settings_repository.dart`

Uses `SharedPreferences` with keys prefixed `redslide_settings_`:

| Key | Stores |
|---|---|
| `redslide_settings_url` | Backend URL (string) |
| `redslide_settings_nsfw` | NSFW enabled (bool) |
| `redslide_settings_theme` | Theme mode (string: system/light/dark) |
| `redslide_settings_interval` | Slideshow interval (int, seconds) |
| `redslide_settings_sort` | Default sort mode (string) |
| `redslide_settings_subreddits` | Subreddit list (List<string>) |

| Method | Description |
|---|---|
| `loadFull()` | Load all settings from SharedPreferences |
| `saveFull(settings)` | Save all settings to SharedPreferences |
| `validateBackendUrl(url, client)` | Hit `/api/health` to validate backend |

---

## Feature: Feed

The Feed feature manages subreddit browsing and media display.

### Domain Model: MediaAsset

**Path:** `lib/features/feed/domain/media_asset.dart`

```dart
class MediaAsset {
  final String id;              // Reddit post ID (not the composite id)
  final String title;
  final String author;
  final int score;
  final String subreddit;
  final String mediaUrl;        // URL to media (sanitized by UrlSanitizer)
  final String? videoUrl;       // Video URL (sanitized)
  final String? thumbnailUrl;   // Thumbnail URL (sanitized)
  final bool isVideo;
  final bool isGallery;
  final bool nsfw;
  final int qualityScore;       // Default 50
  final int? width;
  final int? height;
  final int? duration;
  final int? createdUtc;        // Reddit creation timestamp
  final List<String>? galleryUrls;  // Gallery image URLs (sanitized)
}
```

Key behaviors:
- **URL sanitization** — All URLs are sanitized via `UrlSanitizer` during `fromJson()`
- **Immutable** — `copyWith()` for state updates
- **JSON serialization** — `fromJson()` and `toJson()` for API communication

### State: FeedState

```dart
class FeedState {
  final List<MediaAsset> items;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final String? after;          // Pagination cursor
  final AppError? error;
}
```

### Provider: `feedProvider(String?)`

Family provider keyed by optional subreddit name. `null` = global feed.

### Home Feed Cover Provider: `homeFeedProvider`

**Defined in:** `home_screen.dart`

A `FutureProvider.autoDispose.family` that fetches a single cover image per subreddit for display in `SubredditCard`. Fires one `GET /api/feed?limit=1&subreddits=<name>` per configured subreddit.

### Screens

#### HomeScreen (`/`)

The main hub displays:
- A grid of **SubredditCard** widgets for each configured subreddit with cover images
- Adaptive grid: 2 columns (<600px), 3 columns (600–900px), 4 columns (≥900px)
- **Multi-select mode**: Long-press to enter, tap to toggle selection
- **FAB**: "Start All" (no selection) or "N selected" (multi-select) → push `/slideshow` with `MultiSubredditSource`
- Empty states for: no backend URL configured, no subreddits added
- **`_QueueStatusChip`** — Placeholder/debug queue size indicator in app bar (shows `--`)
- **`_HealthIndicator`** — Placeholder/debug backend health dot in app bar
- **`resumeSessionProvider`** — Stub `Provider.family<ResumeSession?, String>` returning `null`. `ResumeSession` class with `source`, `index`, `isPlaying` fields for future session resume feature

#### SubredditScreen (`/subreddit/:name`)

Shows a paginated grid of media for one subreddit:
- AppBar with subreddit name, refresh button, sort popup menu (Hot/New/Top)
- Shimmer loading grid, error widget, or empty state
- `MediaGrid` with infinite scroll at 80% scroll threshold via `ScrollController`
- FAB: "Slideshow" → push `/slideshow` with `SubredditSource`

### Feed Widgets

| Widget | Purpose |
|---|---|
| `SubredditCard` | 3:4 aspect ratio card with cover image (or letter placeholder), gradient overlay, name, disabled label, selection checkbox |
| `MediaCard` | 1:1 grid card with thumbnail (CachedNetworkImage), video/gallery/NSFW badges |
| `MediaGrid` | Adaptive grid (2–4 columns) with infinite scroll, loading-more indicator |
| `ShimmerCard` | Single shimmer placeholder for loading state |

---

## Feature: Search

### State: SearchState

```dart
class SearchState {
  final String query;
  final SearchMode mode;              // local or global
  final List<MediaAsset> results;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final String? afterCursor;
  final AppError? error;
  final List<String> recentQueries;   // Max 8, in-memory only
  final List<String> selectedSubreddits;
  final String? mediaType;            // Filter: all/images/galleries/videos
  final String? sort;                 // Filter: relevance/newest/most upvoted
  final int totalResults;
}
```

### SearchMode Enum

**Defined in:** `lib/features/slideshow/domain/slideshow_source.dart`

| Value | Meaning |
|---|---|
| `local` | Search within selected subreddits (sends `subreddits` param) |
| `global` | Search across all Reddit (no subreddit filter) |

### Screens

#### SearchScreen (`/search`)

Initial state (no query):
- Mode selector (Local/Global segmented button)
- Subreddit selector (tap to open `SubredditSelectorSheet`)
- Recent search history chips (in-memory, max 8)

Results state:
- Results header with `totalResults` count and "Start Slideshow" button
- Filter icon button (opens `SearchFilterSheet` bottom sheet)
- Scrollable grid of `SearchResultCard` with infinite scroll at 80% threshold
- Subreddit filter syncs with settings on each search

### Search Widgets

| Widget | Purpose |
|---|---|
| `SearchResultCard` | 1:1 thumbnail + title, subreddit, author, badges |
| `SearchResultTile` | List tile variant with leading thumbnail |
| `SearchHistoryChip` | InputChip with history icon, query text, delete |
| `SearchFilterSheet` | Bottom sheet: Media Type filter, Sort options, Apply button |
| `SubredditSelectorSheet` | Bottom sheet: search filter, select all/clear, checkbox list |

---

## Feature: Slideshow & MergeEngine

The slideshow is the core experience — a fullscreen, auto-advancing media viewer with a sophisticated client-side multi-subreddit merge engine.

### Domain Model: SlideshowSource

**Path:** `lib/features/slideshow/domain/slideshow_source.dart`

A sealed class hierarchy that determines where slideshow items come from:

| Source Type | Fields | Meaning |
|---|---|---|
| `SubredditSource` | `subreddit`, `sortMode?` | Single subreddit feed — wrapped as one SubredditMediaSource |
| `MultiSubredditSource` | `subreddits`, `sortMode?` | Multiple subreddits — wrapped as N SubredditMediaSources |
| `GlobalFeedSource` | (empty) | All configured subreddits — wrapped as N SubredditMediaSources |
| `SearchSource` | `query`, `mode`, `subreddits?`, `mediaType?`, `sort?` | Search results — wrapped as one SearchMediaSource |
| `GroupSource` | `groupName`, `subreddits`, `filter?` | Group feed — wrapped as N SubredditMediaSources (not yet used) |

Each source has custom `==` and `hashCode` for proper Riverpod family key comparison (`ListEquality` for list fields).

`SlideshowRouteExtra` wraps a `SlideshowSource` with an optional `startIndex` for route transitions.

### Domain Model: SlideshowState

```dart
class SlideshowState {
  final List<MediaAsset> items;
  final int currentIndex;
  final bool isPlaying;
  final bool isMuted;
  final bool isFullscreen;
  final bool overlayVisible;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMorePages;
  final int gallerySubIndex;   // Position within multi-image gallery
}
```

**Removed fields**: `source` and `paginationCursor` are no longer in state.
- `source` is held by the `SlideshowNotifier` instance (it is the family key)
- `paginationCursor` is managed internally by the MergeEngine's SourceBuffers and PlaylistManager

### MergeEngine (`lib/features/slideshow/domain/merge_engine.dart`)

The MergeEngine is a client-side multi-subreddit media merger. It is now built
on the `MediaSource` abstraction — each source is wrapped in a `SourceBuffer`
that calls `source.loadNext()` for pagination.

**Architecture:**

```
MergeEngine
├── List<MediaSource> sources (provided at construction)
│
├── N SourceBuffers (one per MediaSource)
│   ├── source: MediaSource
│   ├── items: List<MediaAsset> — buffered items
│   ├── hasMore: bool — whether source has more pages
│   ├── isLoading: bool — whether a loadNextPage is in progress
│   └── _consumePointer: int — tracks consumed items
│
├── Load: loadNextPage() → source.loadNext()
│         → dedup by item.id → append to buffer items
│         → update hasMore from MediaPage.hasMore
│
├── Merged output list (_merged)
│
└── Selection algorithm (_selectNext)
    ├── 45% randomness (Random.nextDouble)
    ├── 35% freshness (based on createdUtc age, max 7 days)
    ├── 20% diversity
    │   ├── -20% consecutive same-buffer
    │   ├── -5% same-author
    │   └── -2% same-domain
    └── Constraint: max 2 consecutive from same subreddit
```

**Key constants:**
| Constant | Value | Purpose |
|---|---|---|
| `_lowWatermark` | 8 | Trigger buffer refill when remaining drops below this |
| `_mergeBatchSize` | 20 | Items generated per merge batch |

**Key methods:**

| Method | Purpose |
|---|---|
| `initialize()` | Create SourceBuffers for all MediaSources, fire parallel `loadNextPage()` on all, generate first merged batch |
| `autoRefill()` | Check all buffers for low-watermark, refill those that need it via `loadNextPage()`, generate new batch |
| `drainMerged()` | Return and clear the merged output list |
| `generateBatch()` | Generate a batch of merged items without buffer refill (called by autoRefill) |
| `_selectNext()` | Core selection — scores all candidate items by freshness + diversity + randomness |
| `hasMoreSources` | Whether any buffer still has unconsumed items or can fetch more pages |
| `dispose()` | Dispose all MediaSources, clear buffers and merged output |

**SourceBuffer** — Each buffer tracks its own cursor internally via the `MediaSource` interface (callers don't need to manage cursors directly). The buffer deduplicates incoming items by `item.id`.

### Screen: SlideshowScreen (`/slideshow`)

The slideshow is a fullscreen page with a fade transition:

**Layout:**
- Full-screen black background
- `PageView` for swiping between media items
- Tap zones: left 30% = previous, right 30% = next, middle = toggle overlay
- Three-finger double-tap for fullscreen toggle (via `SystemChrome`)

**Initialization sequence** (in `initState` → `Future.microtask`):
1. `notifier.attachPreloaderContext(context)` — Creates AdaptivePreloader with context
2. `notifier.initialize()` — Fires parallel MediaSource loads, drains first batch
3. `notifier.setStartIndex(widget.startIndex)` — Jump to starting position if not zero
4. `notifier.setInterval(settings.slideshowIntervalSeconds)` — Apply saved interval

**Overlay** (auto-hides after 3 seconds in fullscreen, tracks via `_overlayTimer`):
- **Top bar**: Back button, title, subreddit/author, NSFW badge, source label, more menu
- **Queue indicator**: Horizontal scrollable chip list showing ±25 items around current index (tap to jump)
- **Control bar**: Previous / Play-Pause / Next, Fullscreen toggle, Mute, Download, Share, Open on Reddit

**Auto-advance**: Timer advances to next item (or gallery sub-item) after configurable interval (default 5 seconds). Resets on any navigation.

**Gallery support:** Multi-image Reddit galleries tracked via `gallerySubIndex`. Gallery navigation stays within the current asset until all images are viewed, then advances to the next asset.

**Session resume:** `_saveSession()` is called on `didChangeAppLifecycleState.paused` (stub implementation — currently a no-op).

**Actions:**
- **Download**: Downloads to temp directory via `Dio().download()` and shows a snackbar on completion
- **Share**: Via `share_plus`
- **Open on Reddit**: Via `url_launcher` (constructs `reddit.com/r/{subreddit}/comments/{id}`)

### Slideshow Widgets

| Widget | Purpose |
|---|---|
| `MediaViewer` | Dispatches to `VideoViewer` or `ImageViewer` based on asset type (video/gallery/image). Logs render build time via `[RENDER_TIMELINE]` |
| `VideoViewer` | `VideoPlayerController.networkUrl` with 1 retry on failure, thumbnail fallback, mute support, tap to play/pause. Logs `[VIDEO_ENTER]`, `[VIDEO_CONTROLLER_CREATE]`, `[VIDEO_INITIALIZE_START/DONE]`, `[VIDEO_PLAY]`, `[VIDEO_VISIBLE]` timing |
| `ImageViewer` | Loads via `CachedNetworkImageProvider`, displays with `InteractiveViewer` (pinch-to-zoom, double-tap zoom toggle). Extensive performance logging: `[USER_REQUESTED_IMAGE]`, `[NEED_IMAGE]`, `[IMG_WIDGET_CREATED]`, `[CACHE_AUDIT]`, `[IMAGE_READY]`, `[IMAGE_VISIBLE]`. Async disk cache check via `DefaultCacheManager.getFileFromCache()` |
| `SlideshowOverlay` | Gradient background overlay combining top bar, queue indicator, and controls |
| `SlideshowControls` | Navigation row (prev/play-pause/next) + actions row (fullscreen, mute, download, share, open on Reddit) |
| `QueueIndicator` | Horizontal scrollable chip list showing ±25 items around current index |

---

## Feature: Settings

### Domain Model: SettingsModel

```dart
class SettingsModel {
  final String backendUrl;                 // Default: ''
  final bool nsfwEnabled;                  // Default: false
  final String themeMode;                  // Default: 'system'
  final int slideshowIntervalSeconds;      // Default: 5
  final String defaultSortMode;            // Default: 'hot'
  final List<String> subreddits;          // Default: []
}
```

### Screen: SettingsScreen (`/settings`)

Organized into sections:

| Section | Controls |
|---|---|
| **Backend** | Backend URL text field (edit dialog), health validation button (calls `/api/health` via raw `ApiClient`) |
| **Content** | Subreddit management (bottom sheet with add/remove), NSFW toggle, default sort mode dropdown |
| **Slideshow** | Interval selector radio dialog (3s / 5s / 10s / 15s / 30s) |
| **Display** | Theme mode segmented button (System / Light / Dark) |
| **Cache** | Clear session cache button (dialog, currently a stub) |
| **About** | App version (1.0.0+1), backend version from health check |

**Subreddit management:** A bottom sheet displays the current list with delete buttons. A text field at the top allows adding new subreddits. Each change syncs to the backend via `POST /api/subreddits/sync`.

---

## Feature: Groups

**Status:** PLACEHOLDER — Not implemented

The Groups feature exists as a domain model (`GroupModel`) and a route (`/groups`) but:
- The screen is a placeholder with a "Coming Soon" message
- `GroupModel` has fields (`id`, `name`, `subreddits`, `filter`, `coverImageUrl`, `enabled`) but is not used anywhere in the app
- `GroupSource` exists in `SlideshowSource` but is never instantiated
- The `GroupsPlaceholderScreen` is a simple `StatelessWidget` with an icon and explanatory text

---

## Core: MediaSource Abstraction

**Path:** `lib/core/media/media_source.dart`

The `MediaSource` abstract class provides a uniform interface for loading paginated media, unifying feed and search data sources.

```dart
class MediaPage {
  final List<MediaAsset> items;
  final String? cursor;
  final bool hasMore;
}

abstract class MediaSource {
  Future<MediaPage> loadNext();
  bool get hasMore;
  Future<void> dispose();
}
```

### Implementations

#### SubredditMediaSource

**Path:** `lib/features/slideshow/data/subreddit_media_source.dart`

Wraps `FeedRepository.getFeed()` as a `MediaSource`. Used for single and multi-subreddit slideshows.

- Calls `_repository.getFeed(limit: mergeEngineBufferSize, after: cursor, subreddits:, sort:)`
- Returns `MediaPage` with items, cursor, hasMore from the FeedResponse
- Used by: `SubredditSource`, `MultiSubredditSource`, `GlobalFeedSource`, `GroupSource`

#### SearchMediaSource

**Path:** `lib/features/slideshow/data/search_media_source.dart`

Wraps `SearchRepository.searchReddit()` as a `MediaSource`. Used for search-based slideshows.

- Calls `_repository.searchReddit(query:, mode:, limit: mergeEngineBufferSize, after: cursor, subreddits:)`
- Returns `MediaPage` with items, cursor, hasMore from the FeedResponse
- Used by: `SearchSource`

---

## Core: AdaptivePreloader

**Path:** `lib/features/slideshow/domain/adaptive_preloader.dart`

A standalone priority-queue-based image preloader, extracted from the old inline preload system in `SlideshowScreen`. Manages preloading via a priority queue with concurrent download limit.

### Data structures:
- `_LruSet` — LRU-tracked set of preloaded URLs (max 500 entries)
- `_activeUrls` — Set of URLs currently being downloaded
- `_queuedUrls` — Set of URLs queued for download
- `_preloadQueue` — `List<_PreloadTask>` sorted by `_PreloadPriority` enum
- `_inFlightPreloads` — Counter of concurrent downloads
- `_maxConcurrentPreloads = 3`

### Priority Levels:

| Priority | Level | When |
|---|---|---|
| `urgent` | 0 | Current item + immediate next window |
| `high` | 1 | Medium-range items ahead |
| `medium` | 2 | Far ahead (tier1+tier2) |
| `background` | 3 | History items (last 5) |

### Flow:

```
AdaptivePreloader(playlist, onLoadMore, context)
  │
  └── onIndexChanged(currentIndex)
      │
      ├── Current item: urgent (includes video URL if present, gallery URLs)
      ├── Next N items (adaptive: 6-12 based on remaining count): urgent
      ├── Next M items (adaptive): high priority
      ├── Far ahead (tier1+tier2): medium priority
      ├── History (last 5): background priority
      │
      ├── _enqueueUrl() for each URL
      │     ├── Skip if already in _preloadedUrls, _activeUrls, _queuedUrls, or ImageCache
      │     └── Insert into _preloadQueue sorted by priority (lower index = higher priority)
      │
      ├── _processQueue()
      │     └── While _inFlightPreloads < 3 and queue not empty:
      │           ├── Remove first task from queue
      │           └── _executePreload(url) via precacheImage(CachedNetworkImageProvider)
      │
      └── _checkLoadMore(currentIndex)
            └── If remaining items ≤ preloadTriggerRemaining (30):
                  └── unawaited(_onLoadMore())  // triggers MergeEngine autoRefill
```

### Adaptive Window Sizing:
- remaining >= 40 → wide window (urgent: 12 items ahead)
- remaining < 15 → tight window (urgent: 6 items ahead)
- otherwise → normal (urgent: 8 items ahead)

### Key Methods:
| Method | Purpose |
|---|---|
| `onIndexChanged(currentIndex)` | Main entry point — recalculates priority queue for new position |
| `_enqueueUrl(url, priority)` | Adds URL to priority queue with dedup checks (preloaded, active, queued, cached) |
| `_processQueue()` | Drains queue up to max concurrent limit |
| `_executePreload(url)` | Preloads one image via `CachedNetworkImageProvider.precacheImage()` |
| `_checkLoadMore(index)` | Triggers loadMore when playlist is running low |
| `dispose()` | Clears all tracking sets, queues, and active URLs |

**Memory tracking**: Preloaded URLs tracked in `_LruSet` (max 500). Dedup checks also include `ImageCache.containsKey()` to avoid re-preloading.

---

## Core: PlaylistManager

**Path:** `lib/features/slideshow/domain/playlist_manager.dart`

A simple list+index manager separated from `SlideshowState`. Used by both `SlideshowNotifier` and `AdaptivePreloader`.

```dart
class PlaylistManager {
  List<MediaAsset> get items;
  int get currentIndex;
  int get length;
  bool get hasPrevious / hasNext / isNearEnd;
  MediaAsset? get current;
  MediaAsset? itemAt(int index);

  void append(List<MediaAsset> items);
  MediaAsset? next();
  MediaAsset? previous();
  void jumpTo(int index);
  bool advance();          // Advance index without returning item
  int get remainingCount;  // items.length - currentIndex - 1
  void clear();
  void dispose();
}
```

Key design: `items` and `currentIndex` are managed in the `PlaylistManager` rather than copied into state on every change. `_syncState()` copies the playlist state into `SlideshowState` for reactive UI updates.

---

## Media Loading & Preloading

### SafeNetworkImage

**Path:** `lib/core/media/safe_network_image.dart`

A `StatefulWidget` that loads images via `CachedNetworkImageProvider` and displays using `Image.memory`. Used as thumbnail fallback in `VideoViewer`. Provides retry logic and error state handling.

### MediaError

**Path:** `lib/core/media/media_error.dart`

**Enum:** `MediaErrorType` — `http404`, `http410`, `timeout`, `socketError`, `videoInitError`, `unknown`

**Function:** `logMediaError(...)` — Logs structured error info with action label (`SKIP_GALLERY_NEXT` or `SKIP_NEXT`). Records reddit_id, subreddit, url, errorType, isGallery, isLastInGallery.

### Image Cache Configuration

Configured in `main.dart`:
- `PaintingBinding.instance.imageCache.maximumSize = 500` (entries)
- `PaintingBinding.instance.imageCache.maximumSizeBytes = 200 * 1024 * 1024` (200MB)

---

## Theme & Styling

### Constants

**Path:** `lib/core/constants/theme_constants.dart`

| Class | Content |
|---|---|
| `AppSpacing` | `xxs(2)`, `xs(4)`, `sm(8)`, `md(12)`, `lg(16)`, `xl(20)`, `xxl(24)`, `xxxl(32)`, `huge(48)`, `massive(64)` |
| `AppRadius` | `card(16)`, `chip(8)`, `dialog(24)`, `button(12)`, `indicator(6)` |
| `AppDuration` | `fast(150ms)`, `normal(250ms)`, `slow(400ms)`, `pageTransition(300ms)` |
| `primarySeed` | `Color(0xFFE53935)` (red) |

### App Constants

**Path:** `lib/core/constants/app_constants.dart`

| Constant | Value | Purpose |
|---|---|---|
| `defaultSlideshowIntervalSeconds` | 5 | Auto-advance delay |
| `maxCacheMemoryItems` | 500 | Max preloaded URLs tracked |
| `tier1PreloadCount` | 10 | Immediate next items to preload |
| `tier2PreloadCount` | 20 | Secondary items to preload |
| `historyCount` | 5 | Items behind current kept preloaded |
| `preloadTriggerRemaining` | 30 | Trigger loadMore when remaining hits this |
| `queueChipWindow` | 25 | Items shown on each side in queue indicator |
| `searchHistoryMax` | 8 | Max recent search queries |
| `searchDebounceMs` | 500 | Debounce delay for search input |
| `grid80PercentTrigger` | 0.8 | Scroll trigger for lazy loading |
| `maxRetries` | 3 | Max retries for pagination errors |
| `overlayAutoHideMs` | 3000 | Auto-hide overlay in fullscreen |
| `paginationPageSize` | 50 | Items per page fetch |
| `mergeEngineBufferSize` | 25 | Items per buffer refill fetch |
| `imageCacheCapacity` | 500 | ImageCache max entries |
| `imageCacheSizeMb` | 200 | ImageCache max size (MB) |
| `maxConcurrentPreloads` | 3 | Parallel preload downloads |
| `preloadedUrlSetMaxSize` | 500 | LRU set max for preload tracking |
| `preloadCheckIntervalMs` | 100 | Preload interval |
| `videoPreloadWindow` | 2 | Videos ahead to prepare |

### API Constants

**Path:** `lib/core/constants/api_constants.dart`

| Constant | Value | Purpose |
|---|---|---|
| `feed` | `/api/feed` | Get media feed |
| `feedQueue` | `/api/feed/queue` | Get queue status |
| `search` | `/api/search` | Search media (FTS5) |
| `searchDebug` | `/api/search/debug` | Debug search (LIKE) |
| `searchReddit` | `/api/search/reddit` | Reddit search (backend proxy) |
| `health` | `/api/health` | Health check |
| `mediaStart` | `/api/media/start` | Start slideshow |
| `media` | `/api/media` | Media item |
| `subredditsSync` | `/api/subreddits/sync` | Sync subreddits to backend |
| `subredditsFetch` | `/api/subreddits/fetch` | Fetch subreddits (unused) |
| `defaultLimit` | 20 | Default page size |
| `maxLimit` | 100 | Maximum page size |
| `searchDefaultLimit` | 20 | Default page size for search |
| `connectTimeoutMs` | 10000 | Connection timeout |
| `receiveTimeoutMs` | 30000 | Receive timeout |

---

## Utilities & Extensions

### UrlSanitizer

**Path:** `lib/shared/utils/url_sanitizer.dart`

Static utility that fixes Reddit CDN URL issues:

| Input Pattern | Output Pattern |
|---|---|
| `external-preview.redd.it` | `preview.redd.it` |
| `external-i.redd.it` | `i.redd.it` |

Methods: `sanitize(String)`, `sanitizeOptional(String?)`, `sanitizeAll(List<String>)`, `hasPreviewUrl(String)`

### Debouncer

**Path:** `lib/core/utils/debouncer.dart`

Generic debounce utility with `call()`, `cancel()`, `dispose()` methods. Used in search (500ms debounce).

### PipelineTimer

**Path:** `lib/core/utils/pipeline_timer.dart`

Performance timing utility that logs render timeline with `[RENDER_TIMELINE]` prefix. Tracks elapsed time between stages (mark points). Used in `SlideshowNotifier.next()` for performance debugging.

```dart
PipelineTimer({required String label})
  ├── mark(String stage)  → log elapsed + since-last
  └── end()               → log final elapsed
```

### Extensions

**BuildContextExtensions** (`lib/core/extensions/context_extensions.dart`):
- `theme`, `textTheme`, `colorScheme`, `mediaQuery`, `screenSize`, `screenWidth`, `screenHeight`
- `isDark` — Check if dark mode
- `isTablet` — Check if screen width ≥ 600px
- `isLargeTablet` — Check if screen width ≥ 900px
- `showSnackBar(message, {isError})` — Show floating snackbar

**StringExtensions** (`lib/core/extensions/string_extensions.dart`):
- `truncateSubreddit` — Prepend `r/` if missing
- `formatNumber` — Format large numbers (e.g., `1500` → `1.5K`)

---

## API Integration

### Backend Connection

1. **Base URL** stored in `SettingsModel.backendUrl` (persisted in `SharedPreferences`)
2. Every repository reads the base URL from `settingsProvider` and creates an `ApiClient` via `apiClientProvider(baseUrl)`
3. `ApiClient` returns `Result<T>` — callers must unwrap via `.when()`

### API Endpoints Used

| Method | Endpoint | Feature | Parameters |
|---|---|---|---|
| GET | `/api/feed` | Feed | `limit`, `after`, `subreddits` (single only), `sort` |
| GET | `/api/feed/queue` | Feed | — |
| GET | `/api/search` | Search | `q`, `limit`, `page`, `subreddits`, `media_type`, `sort` |
| GET | `/api/search/debug` | Search | `q`, `limit`, `page` |
| GET | `/api/search/reddit` | Search | `q`, `mode`, `limit`, `after`, `subreddits` |
| GET | `/api/health` | Settings | — |
| GET | `/api/media/{id}` | Feed | — |
| POST | `/api/media/start/{id}` | Feed | — |
| POST | `/api/subreddits/sync` | Settings | `{subreddits: [...]}` |

**Important**: The backend rejects multi-subreddit requests to `/api/feed` with status 400. The Flutter Merge Engine handles multi-subreddit merging client-side.

### Error Handling Flow

```
Widget
  │
  ▼ watches provider
Provider
  │
  ▼ calls repository method
Repository
  │
  ▼ calls apiClient.get/post
ApiClient
  │
  ├── DioException → NetworkError / ServerError
  ├── HTTP error  → ServerError
  ├── empty URL   → NotConfiguredError
  └── success     → parse via fromJson → Success(data)
  │
  ▼ returns Result<T>
Repository → provider → widget rebuild
```

---

## Data Flow

### App Startup Flow

```
main()
  └── ProviderScope
        └── RedSlideApp.build()
              ├── settingsProvider.build()  ← loads SharedPreferences
              │     └── SettingsRepository.loadFull()
              │           └── returns SettingsModel
              │
              ├── If settings loaded:
              │     ├── If first load + valid URL + subreddits:
              │     │     └── POST /api/subreddits/sync  (via raw ApiClient)
              │     ├── Build MaterialApp.router
              │     │     ├── routerProvider → GoRouter
              │     │     ├── ThemeData (light + dark)
              │     │     └── themeMode from settings
              │     └── Show the app
              │
              └── If loading: CircularProgressIndicator
              └── If error: Text('Failed to load settings')
```

### Media Browsing Flow

```
User opens SubredditScreen (/subreddit/:name)
  │
  ├── feedProvider(subredditName) is created
  │     └── FeedNotifier constructor → state = FeedState(isLoading: false)
  │
  ├── SubredditScreen.build() → watches feedProvider
  │     └── Calls feedNotifier.loadInitial()
  │           ├── state = (isLoading: true)
  │           ├── Call FeedRepository.getFeed(limit: 50, subreddits: name)
  │           │     └── ApiClient.get(/api/feed?limit=50&subreddits=name)
  │           │           ├── Success → FeedResponse.fromJson(json)
  │           │           │     Backend: cursor-based on media_assets
  │           │           │     (single subreddit only; multi-sub→400)
  │           │           └── Failure → wraps AppError
  │           └── Update state (items, hasMore, after, isLoading: false)
  │
  ├── User scrolls to 80% → feedNotifier.loadMore()
  │     └── Same flow with after cursor
  │
  └── User taps FAB → context.push('/slideshow', SlideshowRouteExtra(...))
```

### Search Flow

```
User types query in SearchScreen
  │
  ├── Debounce 500ms → searchProvider.search(query)
  │     ├── state = (isLoading: true, query: query)
  │     ├── Sync selected subreddits from settings (intersection)
  │     ├── Call SearchRepository.searchReddit()
  │     │     └── ApiClient.get(/api/search/reddit?q=...&mode=...)
  │   │           Backend (accumulation-based, v4.1):
  │   │             Global mode: scans up to 20 pages until target (limit×4)
  │   │             media items found or 5s budget exhausted
  │   │           Local mode: searches each subreddit individually
  │   │             (workaround for Reddit multi-subreddit API bug),
  │   │             merges & deduplicates
  │   │           Returns FeedResponse directly (no caching)
  │     └── Update state (results, hasMore, afterCursor, isLoading: false)
  │
  ├── User taps "Start Slideshow" → push /slideshow with SearchSource
  │
  └── User scrolls → searchNotifier.loadMore()
        (deduplicates by MediaAsset.id; caps at 1000 items)
        Note: local search always returns after=None, so loadMore only
        works meaningfully in global mode
```

### Slideshow Flow (with MergeEngine + MediaSource)

```
User starts slideshow (MultiSubredditSource from home)
  │
  ├── slideshowProvider(source) is created
  │     └── SlideshowNotifier constructor
  │           ├── Creates PlaylistManager
  │           ├── _buildMediaSources() → List<MediaSource>
  │           └── MergeEngine(sources: mediaSources)
  │
  ├── SlideshowScreen.initState()
  │     ├── notifier.attachPreloaderContext(context)
  │     │     └── Creates AdaptivePreloader(playlist, onLoadMore, context)
  │     ├── notifier.initialize()
  │     │     ├── engine.initialize()
  │     │     │     ├── Create N SourceBuffers (one per MediaSource)
  │     │     │     ├── Fire N parallel source.loadNext() calls
  │     │     │     │     └── SubredditMediaSource → FeedRepository.getFeed()
  │     │     │     ├── generateBatch(20) via round-robin + scoring
  │     │     │     └── drainMerged() → first batch of items
  │     │     ├── _playlist.append(items)
  │     │     └── state = (items, isLoading: false)
  │     ├── notifier.setStartIndex(startIndex)  // if > 0
  │     └── notifier.setInterval(settings.interval)
  │
  ├── User navigates → next() / previous()
  │     ├── _playlist.next() / _playlist.previous()
  │     ├── _syncState() → copies playlist to state
  │     ├── _restartAutoAdvance()
  │     └── _notifyPreloader() → _preloader.onIndexChanged(index)
  │           ├── Enqueue URLs for current, upcoming, far, history
  │           └── _checkLoadMore() if remaining ≤ 30
  │
  ├── Auto-advance timer fires → galleryNext()
  │     ├── If gallery asset + more images → advance gallerySubIndex
  │     ├── Else → _playlist.next()
  │     └── _restartAutoAdvance() + _notifyPreloader()
  │
  ├── Load more triggered:
  │     └── MergeEngine.autoRefill()
  │           ├── Check each SourceBuffer:
  │           │     if remaining < 8 and hasMore → loadNextPage()
  │           └── generateBatch() → drainMerged() → _playlist.append()
  │
  └── User exits → dispose()
        ├── Cancel auto-advance timer
        ├── Cancel overlay timer
        ├── _preloader.dispose()
        ├── _mergeEngine.dispose()  (disposes all MediaSources)
        └── _playlist.dispose()
```

### Settings Change Flow

```
User changes setting in SettingsScreen
  │
  ├── SettingsNotifier method called (e.g., addSubreddit(name))
  │     ├── state = AsyncData(updated SettingsModel)
  │     ├── SettingsRepository.saveFull(updated)
  │     │     └── SharedPreferences.setString/setBool/setStringList
  │     └── If subreddit change: _syncSubredditsToBackend()
  │           └── POST /api/subreddits/sync (via raw ApiClient)
  │
  └── Widgets watching settingsProvider rebuild
```

### Pagination Flow (used by Feed, Search, Slideshow)

```
loadMore() called
  │
  ├── Guard: if isLoadingMore or !hasMore → return
  │
  ├── state = (isLoadingMore: true)
  │
  ├── Call repository getFeed/searchReddit(limit: 50, after: cursor)
  │
  ├── On Success:
  │     ├── Append data.items to existing items
  │     │     (SearchNotifier deduplicates by MediaAsset.id, caps at 1000)
  │     ├── state = (isLoadingMore: false, hasMore: data.hasMore, after: data.after)
  │     └── Trigger preload check (slideshow only)
  │
  └── On Failure:
        ├── Increment retry count
        ├── If retries < maxRetries: retry with exponential backoff (2s, 4s, 6s)
        └── Else: state = (isLoadingMore: false)

  Merge Engine Path (slideshow only):
    ├── Refill buffers below low-watermark (8 remaining)
    ├── Load next page from each MediaSource via source.loadNext()
    ├── Generate new batch from unconsumed items
    └── State: (hasMorePages = hasMoreSources)
```

---

## Known Limitations

### Frontend

1. **No automated tests** — Only a single smoke test that checks `RedSlideApp` renders
2. **No internationalization** — `lib/l10n/` is empty, all strings hardcoded in English
3. **Groups feature** — Only a placeholder screen, `GroupModel` unused, `GroupSource` never instantiated
4. **Session resume** — `resumeSessionProvider` is a stub returning `null`; `_saveSession()` is a no-op
5. **Cache clearing** — Clear cache button triggers a dialog but is a no-op
6. **Download** — Downloads to temp directory via `Dio().download()`. No user-visible file location, no progress indicator, and files are in a temp directory
7. **Permissions** — `permission_handler` is declared as dependency but never used
8. **Code generation** — `freezed` and `json_serializable` annotations are present but generators are not run; models are hand-written
9. **Backend URL validation** — `SettingsNotifier.validateBackendUrl()` only checks for empty string. In `SettingsScreen._validateUrl()`, a raw `ApiClient` is created directly to make `GET /api/health`
10. **Local search loadMore** — Local mode search returns `after=None` (cursorless), so infinite scroll pagination does not work for local searches; only global mode supports cursor-based `loadMore`
11. **Search history** — Recent queries are tracked in-memory only (not persisted) and reset on app restart
12. **Subreddit sync on startup** — `app.dart` creates a raw `ApiClient` for initial sync, bypassing `apiClientProvider`
13. **Settings subreddit sync** — `settings_provider.dart` also creates raw `ApiClient` instances, bypassing DI
14. **Preload system memory** — Preloading uses `CachedNetworkImageProvider.precacheImage()` which adds to `ImageCache`. With aggressive preloading (up to 30 items ahead), memory pressure may be significant on low-end devices
15. **No `chewie` package** — Despite earlier plans, video playback uses raw `video_player` without `chewie` wrapper
16. **No `image_loader.dart`** — The previous `loadImageWithRetry` utility was removed. Image loading now uses `CachedNetworkImageProvider` directly
17. **AdaptivePreloader requires BuildContext injection** — The preloader is created separately from the notifier via `attachPreloaderContext()`, which means preloading only starts after the screen is mounted

### Backend Referenced

For backend limitations, see `backend.md`.

---

## Future Improvements

1. **Testing** — Unit tests for providers, widget tests for screens, integration tests for full flows
2. **Internationalization** — Add `.arb` files and wire up `intl` for multi-language support
3. **Groups feature** — Full implementation of group management with custom filters
4. **Session resume** — Persist slideshow state (current position, source) to SharedPreferences for resume across restarts
5. **Offline support** — Cache media assets for offline viewing, queue management
6. **Download** — Implement actual file download with progress and gallery saving
7. **Permissions** — Proper runtime permission requests for storage (Android 13+)
8. **Push notifications** — Notify users when new content is available from their subreddits
9. **Animations** — Enhanced page transitions, hero animations for media cards → slideshow
10. **Code generation** — Run `build_runner` to use `freezed` for immutable models and `json_serializable` for serialization
11. **Performance** — Virtual scrolling for large media lists, memory-efficient image caching
12. **Accessibility** — Add semantic labels, keyboard navigation, screen reader support
13. **User preferences** — Per-subreddit sort modes, custom slideshow intervals per source
14. **Desktop/web** — Responsive layouts optimized for keyboard/mouse input
