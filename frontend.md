# RedSlide Frontend Documentation

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
11. [Feature: Slideshow](#feature-slideshow)
12. [Feature: Settings](#feature-settings)
13. [Feature: Groups](#feature-groups)
14. [Screens & Pages](#screens--pages)
15. [Widgets & Components](#widgets--components)
16. [Theme & Styling](#theme--styling)
17. [Media Loading](#media-loading)
18. [Utilities & Extensions](#utilities--extensions)
19. [API Integration](#api-integration)
20. [Data Flow](#data-flow)
21. [Known Limitations](#known-limitations)
22. [Future Improvements](#future-improvements)

---

## Overview

**RedSlide** is a Flutter-based media-first slideshow and wallpaper discovery app that connects to a Python FastAPI backend. It aggregates media from Reddit subreddits and presents it in an immersive slideshow format, allowing users to browse images and videos from their favorite communities.

The frontend is fully implemented (not boilerplate) and provides:
- Home screen with configured subreddits
- Media feed browsing per subreddit
- Full-text search (local within subreddits or global across Reddit)
- Fullscreen slideshow with auto-advance, video playback, and gallery support
- Settings management with persistence
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

Shared code lives in `lib/core/` (constants, network, errors, routing, utils) and `lib/shared/` (reusable widgets, utilities).

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
│   │   ├── app_constants.dart             # Preload counts, pagination, etc.
│   │   └── theme_constants.dart           # Spacing, radius, duration, colors
│   ├── errors/
│   │   └── app_error.dart                 # Sealed error hierarchy
│   ├── extensions/
│   │   ├── context_extensions.dart        # BuildContext helpers
│   │   └── string_extensions.dart         # String formatting helpers
│   ├── media/
│   │   ├── image_loader.dart              # Image loading with retry+cache
│   │   ├── media_error.dart               # Media error types + logging
│   │   └── safe_network_image.dart        # Safe image widget with fallback
│   ├── network/
│   │   ├── api_client.dart                # Dio HTTP client wrapper
│   │   └── result.dart                    # Result<T> sealed class
│   ├── router/
│   │   └── app_router.dart                # GoRouter config + AppShell
│   └── utils/
│       └── debouncer.dart                 # Generic debounce utility
├── features/
│   ├── feed/
│   │   ├── data/
│   │   │   └── feed_repository.dart       # Feed API calls
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
│       ├── domain/
│       │   ├── slideshow_source.dart      # Sealed source types
│       │   └── slideshow_state.dart       # SlideshowState
│       ├── presentation/
│       │   ├── slideshow_screen.dart      # Fullscreen slideshow
│       │   └── widgets/
│       │       ├── image_viewer.dart      # Zoomable image
│       │       ├── media_viewer.dart      # Dispatches to video/image
│       │       ├── queue_indicator.dart   # Horizontal queue chips
│       │       ├── slideshow_controls.dart
│       │       └── slideshow_overlay.dart
│       └── providers/
│           └── slideshow_provider.dart    # SlideshowNotifier
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
2. **Orientation lock** — All four orientations enabled (portrait-up, portrait-down, landscape-left, landscape-right)
3. **System UI overlay** — Transparent status bar and navigation bar with light icons
4. **ProviderScope** — Riverpod's root provider container wraps the entire app
5. **RedSlideApp** — The root widget is rendered

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
4. **Loading state** — Shows a centered `CircularProgressIndicator` while settings load
5. **Error state** — Shows "Failed to load settings" text

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
|---|---|---|---|
| 0 | Home | `Icons.home_outlined` | `Icons.home` |
| 1 | Search | `Icons.search` | Same |
| 2 | Groups | `Icons.folder_outlined` (with `Badge("Soon")`) | `Icons.folder` |
| 3 | Settings | `Icons.settings_outlined` | `Icons.settings` |

The `_indexFromLocation()` method maps the current route path to the correct tab index. Only the slideshow and subreddit routes are pushed on the root navigator (hiding the bottom nav bar).

### Slideshow Route Parameters

The `/slideshow` route receives data via `state.extra`:
- If `SlideshowRouteExtra` is passed: contains a `SlideshowSource` + optional `startIndex`
- Otherwise: the extra itself is treated as a `SlideshowSource` (with a fallback to `GlobalFeedSource`)

### Groups Placeholder

The Groups tab shows a placeholder screen with an icon and "Coming in a future update" message. The feature is stubbed out.

---

## State Management

The app uses **Riverpod** exclusively with three provider types:
- **`Provider`** — For singletons (GoRouter, repositories, ApiClient family)
- **`StateNotifierProvider` / `StateNotifierProvider.family`** — For mutable state (feed, search, slideshow)
- **`AsyncNotifierProvider`** — For async initialization (settings)

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

### Provider Lifecycle

- **`apiClientProvider`** — Family provider keyed by `baseUrl` string. Each unique base URL gets its own `ApiClient` instance.
- **`feedProvider`** — Family provider keyed by `String?` (subreddit name or null for global feed). Each subreddit gets its own `FeedNotifier`.
- **`slideshowProvider`** — Family provider keyed by `SlideshowSource` (sealed class with equality). Each slideshow session gets its own notifier.

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
- `search(query)` — Execute search with current filters
- `loadMore()` — Paginate results
- `setMode()` — Toggle local (within selected subreddits) vs global (all Reddit)
- `toggleSubreddit()` / `setSelectedSubreddits()` — Filter subreddits
- `setMediaType()` / `setSort()` — Filter/sort controls
- `syncSelectedSubreddits()` — Keep subreddit selection in sync with settings
- `clearResults()` / `clearHistory()` / `removeRecentQuery()` / `resetFilters()` — State management

### SlideshowNotifier

**Type:** `StateNotifier<SlideshowState>` (family by `SlideshowSource`)

The most complex notifier. Manages:
- `initialize()` — Entry point that calls `_loadInitialItems()` and starts auto-advance
- `setStartIndex(int index)` — Jump to a specific start index after initial load
- `_loadInitialItems()` — Fetches first page from the appropriate source
- `next()` / `previous()` / `jumpTo()` — Navigation with auto-advance restart
- `galleryNext()` / `galleryPrevious()` — Gallery sub-item navigation (advances to next asset at gallery end)
- `togglePlay()` / `toggleMute()` / `toggleFullscreen()` / `toggleOverlay()` / `showOverlay()` — UI state
- `loadMore()` — Pagination with retry logic (up to 3 retries with exponential backoff, `retryCount * 2` seconds delay)
- `_checkPreload()` — Triggers `loadMore()` when remaining items hits `preloadTriggerRemaining` (30)
- `_startAutoAdvance()` / `_restartAutoAdvance()` / `_cancelAutoAdvance()` — Auto-play timer
- `_startOverlayTimer()` / `_cancelOverlayTimer()` — Auto-hide overlay in fullscreen (3 seconds)
- `setInterval()` — Configure auto-advance interval
- `_fetchPage()` — Dispatches to `FeedRepository` or `SearchRepository` based on source type

---

## Data Layer

### ApiClient

**Path:** `lib/core/network/api_client.dart`

A thin wrapper around **Dio** that provides `get<T>()` and `post<T>()` methods. Key characteristics:

> **Architecture note:** While `apiClientProvider` (a Riverpod family provider keyed by base URL) is the canonical way to obtain an `ApiClient`, several parts of the codebase create raw `ApiClient` instances directly: `app.dart._syncSubreddits()`, `settings_provider.dart._syncSubredditsToBackend()`, and `settings_screen.dart._validateUrl()`. This bypasses the dependency injection pattern.

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
| `searchReddit()` | `GET /api/search/reddit` | `query` (Dart param, sent as `q`), `mode`, `limit`, `after`, `subreddits` | `Result<FeedResponse>` |
| `search()` | `GET /api/search` | `query` (Dart param, sent as `q`), `limit`, `page`, `subreddits`, `mediaType`, `sort` | `Result<FeedResponse>` |
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
  final String id;              // Reddit post ID
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
  final List<String>? galleryUrls;  // Gallery image URLs (sanitized)
}
```

Key behaviors:
- **URL sanitization** — All URLs are sanitized via `UrlSanitizer` during `fromJson()` (replaces `external-preview.redd.it` → `preview.redd.it`, `external-i.redd.it` → `i.redd.it`)
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

### Screens

#### HomeScreen (`/`)

The main hub displays:
- A grid of **SubredditCard** widgets for each configured subreddit
- Adaptive grid: 2 columns (<600px), 3 columns (600–900px), 4 columns (≥900px)
- **Multi-select mode**: Long-press to enter, tap to toggle selection
- **FAB**: "Start All" (no selection) or "N selected" (multi-select) → push `/slideshow` with `MultiSubredditSource`
- Empty states for: no backend URL configured, no subreddits added
- **`_QueueStatusChip`** — Placeholder/debug queue size indicator in app bar
- **`_HealthIndicator`** — Placeholder/debug backend health dot in app bar
- **`resumeSessionProvider`** — Stub `Provider.family<ResumeSession?, String>` returning `null`. `ResumeSession` class with `source`, `index`, `isPlaying` fields for future session resume feature

#### SubredditScreen (`/subreddit/:name`)

Shows a paginated grid of media for one subreddit:
- AppBar with subreddit name, refresh button, sort popup menu (Hot/New/Top)
- Shimmer loading grid, error widget, or empty state
- `MediaGrid` with infinite scroll at 80% scroll threshold
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
  final String? sort;                 // Sort: relevance/newest/most upvoted
  final int totalResults;
}
```

### SearchMode Enum

**Defined in:** `lib/features/slideshow/domain/slideshow_source.dart` (cross-feature dependency — shared between search and slideshow)

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

## Feature: Slideshow

The slideshow is the core experience — a fullscreen, auto-advancing media viewer.

### Domain Model: SlideshowSource

**Path:** `lib/features/slideshow/domain/slideshow_source.dart`

A sealed class hierarchy that determines where slideshow items come from:

| Source Type | Fields | Meaning |
|---|---|---|
| `SubredditSource` | `subreddit`, `sortMode?` | Single subreddit feed |
| `MultiSubredditSource` | `subreddits`, `sortMode?` | Multiple subreddits combined |
| `GlobalFeedSource` | (empty) | Global Reddit feed |
| `SearchSource` | `query`, `mode`, `subreddits?`, `mediaType?`, `sort?` | Search results |
| `GroupSource` | `groupName`, `subreddits`, `filter?` | Group feed (not yet used) |

Each source has custom `==` and `hashCode` for proper Riverpod family key comparison (`ListEquality` for list fields).

### Domain Model: SlideshowState

```dart
class SlideshowState {
  final List<MediaAsset> items;
  final int currentIndex;
  final bool isPlaying;
  final bool isMuted;
  final bool isFullscreen;
  final bool overlayVisible;
  final SlideshowSource source;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMorePages;
  final String? paginationCursor;
  final int gallerySubIndex;   // Position within multi-image gallery
}
```

### Screen: SlideshowScreen (`/slideshow`)

The slideshow is a fullscreen page with a fade transition:

**Layout:**
- Full-screen black background
- `PageView` for swiping between media items
- Tap zones: left 30% = previous, right 30% = next, middle = toggle overlay
- Three-finger double-tap for fullscreen toggle

**Overlay** (auto-hides after 3 seconds in fullscreen):
- **Top bar**: Back button, title, subreddit/author, NSFW badge, source label, more menu
- **Queue indicator**: Horizontal scrollable chip list showing ±25 items around current index (tap to jump)
- **Control bar**: Previous / Play-Pause / Next, Fullscreen toggle, Mute, Download, Share, Open on Reddit

**Auto-advance**: Timer advances to next item (or gallery sub-item) after configurable interval (default 5 seconds). Resets on any navigation.

**Preloading (5-tier priority queue system):**
Preloading is managed via a priority queue (`_preloadQueue`) with concurrent download limit of 3.

| Priority | Items | What's Preloaded |
|---|---|---|
| `urgent` | Current + immediate next | Image + video URLs |
| `high` | Next 2-4 | Images only |
| `medium` | Next 5-10 | Images only |
| `low` | Next 11-30 | Images only |
| `background` | Last 5 (history) | Images only |

URLs are enqueued with a priority level and processed by `_processQueue()`. Preloaded URLs are tracked in a `_preloadedUrls` Set (max 500 entries). Active downloads are tracked in `_activeUrls` to prevent duplicate fetches. The concurrent limit (`_maxConcurrentPreloads = 3`) controls how many images are fetched simultaneously. Preloading uses `CachedNetworkImageProvider.precacheImage()`.

**Gallery support:** Multi-image Reddit galleries tracked via `gallerySubIndex`. Gallery navigation stays within the current asset until all images are viewed, then advances to the next asset.

**Error handling:** Media load errors are logged with structured info (`MediaErrorType`) and the slideshow advances to the next item. Video initialization has retry logic.

**Actions:**
- **Download**: Downloads to temp directory via `Dio().download()` and shows a snackbar on completion. No user-visible file location or download progress indicator.
- **Share**: Via `share_plus`
- **Open on Reddit**: Via `url_launcher`

### Slideshow Widgets

| Widget | Purpose |
|---|---|
| `MediaViewer` | Dispatches to `VideoViewer` or `ImageViewer` based on asset type |
| `VideoViewer` | `VideoPlayerController.networkUrl` with retry, thumbnail fallback on failure, mute support, tap to play/pause |
| `ImageViewer` | Loads via `loadImageWithRetry`, displays with `InteractiveViewer` (pinch-to-zoom, double-tap zoom toggle) |
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
| **Backend** | Backend URL text field (edit dialog), health validation button (calls `/api/health`) |
| **Content** | Subreddit management (bottom sheet with add/remove), NSFW toggle, default sort mode dropdown |
| **Slideshow** | Interval selector radio dialog (3s / 5s / 10s / 15s / 30s) |
| **Display** | Theme mode segmented button (System / Light / Dark) |
| **Cache** | Clear session cache button (dialog, currently a stub; uses private `_SectionHeader` widget for section titles) |
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

### GroupModel Fields

```dart
class GroupModel {
  final String id;
  final String name;
  final List<String> subreddits;
  final String? filter;
  final String? coverImageUrl;
  final bool enabled;  // default: true
}
```

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

## Media Loading

**Path:** `lib/core/media/`

### ImageLoader

**Key function:** `loadImageWithRetry(String url)` → `ImageLoadResult`

1. Checks `DefaultCacheManager` (flutter_cache_manager) for cached copy
2. If missing, fetches via dedicated Dio instance (`_mediaDio`) with 10s connect, 20s receive, 10s send timeout
3. On timeout/connection error: retries once
4. Caches successful results to disk via `DefaultCacheManager`
5. Returns `ImageLoadResult(status, bytes, errorType)`

```dart
enum ImageLoadStatus { success, failure }
class ImageLoadResult {
  final ImageLoadStatus status;
  final Uint8List? bytes;
  final MediaErrorType? errorType;
}
```

### MediaError

**Enum:** `MediaErrorType` — `http404`, `http410`, `timeout`, `socketError`, `videoInitError`, `unknown`

**Function:** `logMediaError(...)` — Logs structured error info with action label (`SKIP_GALLERY_NEXT` or `SKIP_NEXT`)

### SafeNetworkImage

A `StatefulWidget` that loads images via `loadImageWithRetry` and displays using `Image.memory`. Used as thumbnail fallback in `VideoViewer`.

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
| GET | `/api/feed` | Feed | `limit`, `after`, `subreddits`, `sort` |
| GET | `/api/feed/queue` | Feed | — |
| GET | `/api/search` | Search | `q`, `limit`, `page`, `subreddits`, `media_type`, `sort` |
| GET | `/api/search/debug` | Search | `q`, `limit`, `page` |
| GET | `/api/search/reddit` | Search | `q`, `mode`, `limit`, `after`, `subreddits` |
| GET | `/api/health` | Settings | — |
| GET | `/api/media/{id}` | Feed | — |
| POST | `/api/media/start/{id}` | Feed | — |
| POST | `/api/subreddits/sync` | Settings | `{subreddits: [...]}` |

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
              │     │     └── POST /api/subreddits/sync
              │     ├── Build MaterialApp.router
              │     │     ├── routerProvider → GoRouter
              │     │     ├── ThemeData (light + dark)
              │     │     └── themeMode from settings
              │     └── Show the app
              │
              └── If loading: CircularProgressIndicator
              └── If error: "Failed to load settings"
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
  │     ├── Sync selected subreddits from settings
  │     ├── Call SearchRepository.searchReddit()
  │     │     └── ApiClient.get(/api/search/reddit?q=...&mode=...)
  │     │         Backend (accumulation-based, v3+):
  │     │           Global mode: scans up to 20 pages until target (limit×4)
  │     │             media items found or 5s budget exhausted
  │     │           Local mode: searches each subreddit individually
  │     │             (workaround for Reddit multi-subreddit API bug),
  │     │             merges & deduplicates
  │     │           Returns FeedResponse directly (no caching)
  │     └── Update state (results, hasMore, isLoading: false)
  │
  ├── User taps "Start Slideshow" → push /slideshow with SearchSource
  │
  └── User scrolls → searchNotifier.loadMore()
        Note: local search always returns after=None, so loadMore only
        works meaningfully in global mode
```

### Slideshow Flow

```
User starts slideshow (from search, subreddit, or home)
  │
  ├── slideshowProvider(source) is created
  │     └── SlideshowNotifier constructor → state = (isLoading: true)
  │
  ├── initialize() → _loadInitialItems()
  │     └── _fetchPage(cursor: null)
  │           ├── SubredditSource → FeedRepository.getFeed(...)
  │           ├── SearchSource    → SearchRepository.searchReddit(...)
  │           ├── MultiSubreddit  → FeedRepository.getFeed(...)
  │           └── GlobalFeed     → FeedRepository.getFeed(...)
  │     └── Update state (items, hasMorePages, paginationCursor)
  │     └── Start auto-advance timer
  │
  ├── Auto-advance timer fires → galleryNext()
  │     ├── If gallery asset + more images → advance gallerySubIndex
  │     ├── Else → currentIndex++
  │     └── Restart auto-advance timer
  │
  ├── remaining ≤ 30 → trigger _checkPreload() → loadMore()
  │     └── _fetchPage(cursor: paginationCursor)
  │           └── Append to items
  │
  └── User exits → dispose() (cancel timers)
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
  │           └── POST /api/subreddits/sync
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
  │     ├── state = (isLoadingMore: false, hasMore: data.hasMore, after: data.after)
  │     └── Trigger preload check (slideshow only)
  │
  └── On Failure:
        ├── Increment retry count
        ├── If retries < maxRetries: retry with exponential backoff (2s, 4s, 6s)
        └── Else: state = (isLoadingMore: false)
```

---

## Known Limitations

### Frontend

1. **No automated tests** — Only a single smoke test that checks `RedSlideApp` renders
2. **No internationalization** — `lib/l10n/` is empty, all strings hardcoded in English
3. **Groups feature** — Only a placeholder screen, `GroupModel` unused, `GroupSource` never instantiated
4. **Session resume** — `resumeSessionProvider` (defined in `home_screen.dart`) is a stub returning `null`; slideshow session state is not saved across app restarts
5. **Cache clearing** — Clear cache button triggers a dialog but is a no-op
6. **Download** — Downloads to temp directory via `Dio().download()`. No user-visible file location, no progress indicator, and files are in a temp directory that may be cleaned up by the OS.
7. **Permissions** — `permission_handler` is declared as dependency but never used
8. **Code generation** — `freezed` and `json_serializable` annotations are present in `pubspec.yaml` models are hand-written with `copyWith`/`toJson`/`fromJson` instead of using generated code
9. **FTS5 search endpoint** — The app calls `/api/search/reddit` (a Reddit proxy endpoint) instead of the backend's own FTS5 `/api/search` in most paths
10. **Queue status chip** — The queue indicator in the app bar is a placeholder/debug display, not a polished UI element
11. **Search history** — Recent queries are tracked in-memory only (not persisted) and reset on app restart
12. **Backend URL validation** — `SettingsNotifier.validateBackendUrl()` only checks for empty string (no HTTP call). In `SettingsScreen._validateUrl()`, a **raw `ApiClient`** is created directly (not via `FeedRepository`) to make a `GET /api/health` call. This bypasses the `apiClientProvider` dependency injection pattern.
13. **Local search loadMore** — Local mode search returns `after=None` (cursorless), so infinite scroll pagination in the search results grid does not work for local searches; only global mode supports cursor-based `loadMore`

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
