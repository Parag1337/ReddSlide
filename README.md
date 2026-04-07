# Reddit Slideshow

Fullscreen Reddit media slideshow (backend + frontend).

This project includes:

- **Node/Express backend** to fetch and normalize Reddit posts + resolve Redgifs direct video URLs
- **React (Vite) frontend** with a fullscreen slideshow viewer (tap zones, swipe, autoplay, multi-image support)

## Quick start (dev)

In two terminals:

```bash
# Terminal 1 (backend)
cd ~/Projects/reddit-slideshow-backend
cp .env.example .env
npm install
npm run start
```

```bash
# Terminal 2 (frontend)
cd ~/Projects/reddit-slideshow-backend/frontend
npm install
npm run dev
```

Open the app at `http://localhost:5173`.

## Features

### Viewer controls

- **Navigation zones**
  - Left 30%: previous post
  - Right 30%: next post
  - Center: cycle images within a multi-image post
- **Gestures**
  - Swipe left: next post
  - Swipe right: previous post
- **Keyboard**
  - Left/Right arrow: prev/next post
  - Up/Down arrow: next/prev image (multi-image posts)
- **Autoplay**
  - Play/Pause button + configurable timer (seconds)
  - Autoplay cycles images first (if a post has multiple images), then advances posts
- **Search**
  - Filters the **currently loaded** multi-subreddit post list by title/content (pure client-side search)
- **UI**
  - Dark theme, fullscreen, no scrolling
  - Hide/show overlay UI (eye icon)
  - Fullscreen toggle
  - Compact numbered strip for post navigation

### Media support

- Images (`i.redd.it`, imgur images, galleries)
- Videos (`v.redd.it`, imgur mp4/webm)
- Redgifs (resolved to direct mp4 via backend)

## Backend API

Base URL (dev): `http://localhost:3000`

## Endpoints

### `GET /api/posts`

Query params:

- `subs=sub1,sub2,sub3` (required)
- `nsfw=true|false` (optional; frontend defaults to **including** NSFW)
- `after=token` (optional, for Reddit pagination)

Behavior:

- Calls `https://www.reddit.com/r/{sub1+sub2+sub3}.json`
- Converts comma-separated `subs` into `+` format
- Supports pagination with `after`
- Filters only media posts:
  - `i.redd.it` images
  - `v.redd.it` videos
  - `imgur.com` links
  - `redgifs.com` links
- Reddit gallery posts are normalized into `images: string[]`
- **Caches** Reddit responses in-memory and deduplicates concurrent calls
- **Rate limit handling**: on Reddit `429`, the backend will return cached data when available

Response shape:

```json
{
  "posts": [
    {
      "id": "abc123",
      "title": "Post title",
      "subreddit": "pics",
      "url": "https://i.redd.it/example.jpg",
      "images": ["https://i.redd.it/example.jpg"],
      "type": "image",
      "isNsfw": false
    }
  ],
  "after": "t3_nextToken"
}
```

### `GET /api/redgifs`

Query params:

- `id=xyz` (Redgifs ID or full Redgifs URL)

Behavior:

- Gets temporary token from `https://api.redgifs.com/v2/auth/temporary`
- Caches and reuses token
- Automatically refreshes token if expired (401)
- Calls `https://api.redgifs.com/v2/gifs/{id}`
- Returns direct video URL (prefers HD)

Response shape:

```json
{
  "id": "xyz",
  "url": "https://media.redgifs.com/....mp4"
}
```

## Frontend

Frontend lives in `frontend/` and uses Vite with an `/api` proxy to the backend:

```bash
cd frontend
npm install
npm run dev
```

## Configuration

Copy `.env.example` to `.env` in the project root.

Useful variables:

- `PORT`: backend port (default 3000)
- `REDDIT_CACHE_TTL_SECONDS`: how long to keep Reddit responses in cache (default 3600)
- `REDDIT_FRESH_TTL_MS`: how long a cached entry is considered “fresh” before attempting refresh (default 180000)
- `REDDIT_STALE_OK_MS`: preferred maximum age for “stale” cache when rate-limited (default 600000)
- `REDGIFS_TOKEN_CACHE_TTL_SECONDS`: cache TTL for Redgifs token (default 3600)

## Run locally (backend)

1. Install dependencies:

   ```bash
   npm install
   ```

2. Create env file:

   ```bash
   cp .env.example .env
   ```

3. Start server:

   ```bash
   npm run start
   ```

Server runs on `http://localhost:3000` by default.

## Curl examples

```bash
curl "http://localhost:3000/api/posts?subs=aww,pics&nsfw=true"
curl "http://localhost:3000/api/posts?subs=aww,pics&after=t3_xxxxx&nsfw=true"
curl "http://localhost:3000/api/redgifs?id=helpfulfoolhardyant"
```

## Notes on Reddit rate limits

This project intentionally uses Reddit’s public JSON endpoints (`reddit.com/r/...json`), which can be **aggressively rate-limited** (HTTP 429) depending on IP, request volume, and timing.

Mitigations included here:

- caching + in-flight dedupe
- serving cached results during rate-limits when available

If you need consistently reliable access, you’ll want to migrate to Reddit’s authenticated API flow.
