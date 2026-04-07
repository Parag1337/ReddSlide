# Reddit Slideshow Backend

Express backend with APIs to fetch Reddit media posts and resolve Redgifs direct video URLs.

## Endpoints

### `GET /api/posts`

Query params:

- `subs=sub1,sub2,sub3` (required)
- `nsfw=true|false` (optional, default: false)
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
- Excludes NSFW posts unless `nsfw=true`
- Caches Reddit responses in-memory

Response shape:

```json
{
  "posts": [
    {
      "id": "abc123",
      "title": "Post title",
      "subreddit": "pics",
      "url": "https://i.redd.it/example.jpg",
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

## Run locally

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

## Quick examples

```bash
curl "http://localhost:3000/api/posts?subs=aww,pics&nsfw=false"
curl "http://localhost:3000/api/posts?subs=aww,pics&after=t3_xxxxx"
curl "http://localhost:3000/api/redgifs?id=helpfulfoolhardyant"
```
