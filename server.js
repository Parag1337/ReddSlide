require("dotenv").config();
const express = require("express");
const axios = require("axios");
const NodeCache = require("node-cache");

const app = express();
const PORT = Number(process.env.PORT || 3000);

const redditCache = new NodeCache({
  // Keep responses long enough to serve stale during rate-limits.
  stdTTL: Number(process.env.REDDIT_CACHE_TTL_SECONDS || 3600),
  useClones: false,
});
const redgifsCache = new NodeCache({
  stdTTL: Number(process.env.REDGIFS_TOKEN_CACHE_TTL_SECONDS || 3600),
  useClones: false,
});

const REDGIFS_TOKEN_KEY = "redgifs_token";
const REDDIT_API_BASE = "https://www.reddit.com";
const REDGIFS_AUTH_URL = "https://api.redgifs.com/v2/auth/temporary";
const REDGIFS_GIF_URL_BASE = "https://api.redgifs.com/v2/gifs";

const redditInflight = new Map(); // cacheKey -> Promise
const REDDIT_FRESH_TTL_MS = Number(process.env.REDDIT_FRESH_TTL_MS || 3 * 60 * 1000);
const REDDIT_STALE_OK_MS = Number(process.env.REDDIT_STALE_OK_MS || 10 * 60 * 1000);

function parseSubreddits(subs = "") {
  return subs
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
}

function isTrue(value) {
  return String(value).toLowerCase() === "true";
}

function extractGalleryImages(post) {
  const galleryItems = post?.gallery_data?.items;
  const metadata = post?.media_metadata;
  if (!Array.isArray(galleryItems) || !metadata) return [];

  const images = [];
  for (const item of galleryItems) {
    const media = metadata[item.media_id];
    const candidate = media?.s?.u || media?.s?.gif || "";
    if (!candidate) continue;
    images.push(candidate.replace(/&amp;/g, "&"));
  }
  return images;
}

function buildMediaPost(post) {
  const url = post?.url_overridden_by_dest || post?.url || "";
  const lowerUrl = String(url).toLowerCase();
  const domain = String(post?.domain || "").toLowerCase();
  const galleryImages = extractGalleryImages(post);

  if (galleryImages.length) {
    return {
      id: post.id,
      title: post.title,
      subreddit: post.subreddit,
      url: galleryImages[0],
      images: galleryImages,
      type: "image",
      isNsfw: Boolean(post.over_18),
    };
  }

  if (lowerUrl.includes("redgifs.com/watch/") || domain.includes("redgifs.com")) {
    return {
      id: post.id,
      title: post.title,
      subreddit: post.subreddit,
      url,
      type: "redgifs",
      isNsfw: Boolean(post.over_18),
    };
  }

  if (lowerUrl.includes("v.redd.it")) {
    return {
      id: post.id,
      title: post.title,
      subreddit: post.subreddit,
      url,
      type: "video",
      isNsfw: Boolean(post.over_18),
    };
  }

  if (
    lowerUrl.includes("i.redd.it") ||
    lowerUrl.match(/\.(jpg|jpeg|png|gif|webp)(\?.*)?$/)
  ) {
    return {
      id: post.id,
      title: post.title,
      subreddit: post.subreddit,
      url,
      type: "image",
      images: [url],
      isNsfw: Boolean(post.over_18),
    };
  }

  if (domain.includes("imgur.com")) {
    const isVideo = lowerUrl.match(/\.(mp4|webm)(\?.*)?$/);
    return {
      id: post.id,
      title: post.title,
      subreddit: post.subreddit,
      url,
      type: isVideo ? "video" : "image",
      images: isVideo ? undefined : [url],
      isNsfw: Boolean(post.over_18),
    };
  }

  return null;
}

async function fetchRedditPosts({ subs, after }) {
  const subredditPath = subs.join("+");
  const cacheKey = `reddit:${subredditPath}:${after || ""}`;
  const cached = redditCache.get(cacheKey);
  if (cached && typeof cached.fetchedAt === "number") {
    if (Date.now() - cached.fetchedAt <= REDDIT_FRESH_TTL_MS) return cached;
  }

  // Deduplicate concurrent requests to the same key.
  const inflight = redditInflight.get(cacheKey);
  if (inflight) return inflight;

  const promise = (async () => {
    try {
      const response = await axios.get(`${REDDIT_API_BASE}/r/${subredditPath}.json`, {
        params: after ? { after, raw_json: 1 } : { raw_json: 1 },
        timeout: 10000,
        headers: {
          "User-Agent": "reddit-slideshow-backend/1.0",
          Accept: "application/json",
        },
      });

      const payload = {
        posts: response.data?.data?.children?.map((c) => c.data) || [],
        after: response.data?.data?.after || null,
        fetchedAt: Date.now(),
      };
      redditCache.set(cacheKey, payload);
      return payload;
    } catch (err) {
      // If we're rate-limited, try serving a stale cached response if available.
      const status = err?.response?.status;
      if (status === 429) {
        const stale = redditCache.get(cacheKey);
        if (stale && typeof stale.fetchedAt === "number") {
          // Prefer "recent" stale, but if we have anything cached, return it to keep UX working.
          if (Date.now() - stale.fetchedAt <= REDDIT_STALE_OK_MS) return stale;
          return stale;
        }
      }
      throw err;
    } finally {
      redditInflight.delete(cacheKey);
    }
  })();

  redditInflight.set(cacheKey, promise);
  return promise;
}

function extractRedgifsId(input = "") {
  const raw = String(input).trim();
  if (!raw) return "";

  // Accept plain ID or a full Redgifs URL.
  if (!raw.includes("http")) return raw;

  try {
    const parsed = new URL(raw);
    const parts = parsed.pathname.split("/").filter(Boolean);
    const watchIndex = parts.findIndex((p) => p.toLowerCase() === "watch");
    if (watchIndex >= 0 && parts[watchIndex + 1]) return parts[watchIndex + 1];
    return parts[parts.length - 1] || "";
  } catch {
    return "";
  }
}

async function getRedgifsToken(forceRefresh = false) {
  if (!forceRefresh) {
    const cached = redgifsCache.get(REDGIFS_TOKEN_KEY);
    if (cached) return cached;
  }

  const response = await axios.get(REDGIFS_AUTH_URL, { timeout: 10000 });
  const token = response.data?.token;
  if (!token) {
    throw new Error("Failed to acquire Redgifs token");
  }

  redgifsCache.set(REDGIFS_TOKEN_KEY, token);
  return token;
}

async function fetchRedgifsGif(gifId) {
  const requestWithToken = async (token) =>
    axios.get(`${REDGIFS_GIF_URL_BASE}/${gifId}`, {
      timeout: 10000,
      headers: {
        Authorization: `Bearer ${token}`,
      },
    });

  let token = await getRedgifsToken(false);
  try {
    return await requestWithToken(token);
  } catch (error) {
    const unauthorized = error?.response?.status === 401;
    if (!unauthorized) throw error;

    token = await getRedgifsToken(true);
    return requestWithToken(token);
  }
}

app.get("/api/posts", async (req, res) => {
  const subs = parseSubreddits(req.query.subs);
  const includeNsfw = isTrue(req.query.nsfw);
  const after = req.query.after ? String(req.query.after) : "";

  if (!subs.length) {
    return res.status(400).json({
      error: "Invalid query: provide at least one subreddit in `subs`",
    });
  }

  try {
    const redditData = await fetchRedditPosts({ subs, after });
    const filtered = redditData.posts
      .filter((post) => (includeNsfw ? true : !post.over_18))
      .map(buildMediaPost)
      .filter(Boolean);

    return res.json({
      posts: filtered,
      after: redditData.after,
    });
  } catch (error) {
    let status = error?.response?.status || 500;
    let details = error?.response?.data || error?.message || "Unknown error";
    if (typeof details !== "string") {
      try {
        details = JSON.stringify(details);
      } catch {
        details = String(details);
      }
    }

    // Reddit may return HTML (e.g. 429 page); keep it short.
    if (details.length > 500) details = details.slice(0, 500) + "…";

    // Sometimes the rate-limit response comes back as HTML; normalize to 429.
    const lower = details.toLowerCase();
    if (lower.includes("too many requests") || lower.includes("whoa there, pardner")) {
      status = 429;
    }

    if (status === 429) {
      details = "Reddit rate-limited this IP. Wait a few minutes and retry.";
    }

    let message = "Failed to fetch Reddit posts";
    if (status === 404) message = "Subreddit not found";
    if (status === 429) message = "Rate limited by Reddit";
    if (status === 403) message = "Blocked by Reddit (try again later)";

    return res.status(status).json({
      error: message,
      status,
      details,
    });
  }
});

app.get("/api/redgifs", async (req, res) => {
  const gifId = extractRedgifsId(req.query.id);
  if (!gifId) {
    return res
      .status(400)
      .json({ error: "Invalid query: provide a Redgifs id or URL in `id`" });
  }

  try {
    const response = await fetchRedgifsGif(gifId);
    const urls = response.data?.gif?.urls || {};
    const videoUrl = urls.hd || urls.sd || urls.fhd || null;

    if (!videoUrl) {
      return res.status(404).json({
        error: "No playable video URL found for this Redgifs id",
      });
    }

    return res.json({
      id: gifId,
      url: videoUrl,
    });
  } catch (error) {
    const status = error?.response?.status || 500;
    return res.status(status).json({
      error: "Failed to fetch Redgifs video URL",
      details: error?.response?.data || error.message,
    });
  }
});

app.get("/health", (req, res) => {
  res.json({ ok: true });
});

app.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});
