const express = require("express");
const axios = require("axios");
const NodeCache = require("node-cache");

const REDDIT_API_BASE = "https://www.reddit.com";
const REDGIFS_AUTH_URL = "https://api.redgifs.com/v2/auth/temporary";
const REDGIFS_GIF_URL_BASE = "https://api.redgifs.com/v2/gifs";
const REDGIFS_TOKEN_KEY = "redgifs_token";
const REDDIT_OAUTH_TOKEN_KEY = "reddit_oauth_token";
const REDDIT_OAUTH_URL = "https://www.reddit.com/api/v1/access_token";
const REDDIT_OAUTH_API_BASE = "https://oauth.reddit.com";
function parseSubreddits(subs = "") {
  return String(subs)
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
  const content = typeof post?.selftext === "string" ? post.selftext : "";

  if (galleryImages.length) {
    return {
      id: post.id,
      title: post.title,
      subreddit: post.subreddit,
      url: galleryImages[0],
      images: galleryImages,
      type: "image",
      isNsfw: Boolean(post.over_18),
      content,
      createdUtc: Number(post?.created_utc || 0),
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
      content,
      createdUtc: Number(post?.created_utc || 0),
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
      content,
      createdUtc: Number(post?.created_utc || 0),
    };
  }

  if (lowerUrl.includes("i.redd.it") || lowerUrl.match(/\.(jpg|jpeg|png|gif|webp)(\?.*)?$/)) {
    return {
      id: post.id,
      title: post.title,
      subreddit: post.subreddit,
      url,
      type: "image",
      images: [url],
      isNsfw: Boolean(post.over_18),
      content,
      createdUtc: Number(post?.created_utc || 0),
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
      content,
      createdUtc: Number(post?.created_utc || 0),
    };
  }

  return null;
}

function postMatchesQuery(post, qLower) {
  if (!qLower) return true;

  const normalize = (s) =>
    String(s || "")
      .toLowerCase()
      .normalize("NFKD")
      .replace(/[\u0300-\u036f]/g, "");

  const title = normalize(post?.title);
  const content = normalize(post?.selftext);
  const haystack = `${title} ${content}`.trim();
  if (!haystack) return false;

  // First, exact phrase check.
  const phrase = normalize(qLower).trim();
  if (phrase && haystack.includes(phrase)) return true;

  // Then, token-based check (all tokens must appear somewhere).
  const tokens = phrase.split(/\s+/).filter(Boolean);
  if (!tokens.length) return true;
  return tokens.every((t) => haystack.includes(t));
}

function extractRedgifsId(input = "") {
  const raw = String(input).trim();
  if (!raw) return "";
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

function createApp() {
  const app = express();

  const redditCache = new NodeCache({
    stdTTL: Number(process.env.REDDIT_CACHE_TTL_SECONDS || 3600),
    useClones: false,
  });
  const redgifsCache = new NodeCache({
    stdTTL: Number(process.env.REDGIFS_TOKEN_CACHE_TTL_SECONDS || 3600),
    useClones: false,
  });
  const authCache = new NodeCache({
    stdTTL: 3500,
    useClones: false,
  });

  const redditInflight = new Map(); // cacheKey -> Promise
  const REDDIT_FRESH_TTL_MS = Number(process.env.REDDIT_FRESH_TTL_MS || 3 * 60 * 1000);
  const REDDIT_STALE_OK_MS = Number(process.env.REDDIT_STALE_OK_MS || 10 * 60 * 1000);

  async function getRedditAccessToken(forceRefresh = false) {
    const clientId = process.env.REDDIT_CLIENT_ID;
    const clientSecret = process.env.REDDIT_CLIENT_SECRET;
    if (!clientId || !clientSecret) return null;

    if (!forceRefresh) {
      const cached = authCache.get(REDDIT_OAUTH_TOKEN_KEY);
      if (cached) return cached;
    }

    const authString = Buffer.from(`${clientId}:${clientSecret}`).toString("base64");
    const response = await axios.post(
      REDDIT_OAUTH_URL,
      "grant_type=client_credentials",
      {
        headers: {
          Authorization: `Basic ${authString}`,
          "Content-Type": "application/x-www-form-urlencoded",
          "User-Agent": "web:reddit-slideshow-app:v1.0.0 (by /u/Parag1337)",
        },
        timeout: 10000,
      }
    );

    const token = response.data?.access_token;
    if (token) {
      const expiresIn = response.data?.expires_in || 3600;
      authCache.set(REDDIT_OAUTH_TOKEN_KEY, token, Math.max(60, expiresIn - 60));
    }
    return token;
  }

  async function fetchRedditPosts({ subs, after }) {
    const subredditPath = subs.join("+");
    const cacheKey = `reddit:${subredditPath}:${after || ""}`;
    const cached = redditCache.get(cacheKey);
    if (cached && typeof cached.fetchedAt === "number") {
      if (Date.now() - cached.fetchedAt <= REDDIT_FRESH_TTL_MS) return cached;
    }

    const inflight = redditInflight.get(cacheKey);
    if (inflight) return inflight;

    const promise = (async () => {
      try {
        let token = await getRedditAccessToken(false);
        let baseUrl = token ? REDDIT_OAUTH_API_BASE : REDDIT_API_BASE;

        const makeRequest = (t, base) => axios.get(`${base}/r/${subredditPath}/new.json`, {
          params: after ? { after, raw_json: 1 } : { raw_json: 1 },
          timeout: 10000,
          headers: {
            "User-Agent": "web:reddit-slideshow-app:v1.0.0 (by /u/Parag1337)",
            Accept: "application/json",
            ...(t ? { Authorization: `Bearer ${t}` } : {}),
          },
        });

        let response;
        try {
          response = await makeRequest(token, baseUrl);
        } catch (initialErr) {
          if (initialErr?.response?.status === 401 && token) {
            token = await getRedditAccessToken(true);
            response = await makeRequest(token, baseUrl);
          } else {
            throw initialErr;
          }
        }

        const payload = {
          posts: response.data?.data?.children?.map((c) => c.data) || [],
          after: response.data?.data?.after || null,
          fetchedAt: Date.now(),
        };
        redditCache.set(cacheKey, payload);
        return payload;
      } catch (err) {
        const status = err?.response?.status;
        if (status === 429) {
          const stale = redditCache.get(cacheKey);
          if (stale && typeof stale.fetchedAt === "number") {
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

  async function fetchRedditSearchPage({ subs, q, after }) {
    const subredditPath = subs.join("+");
    const cacheKey = `reddit-search:${subredditPath}:${q}:${after || ""}`;
    const cached = redditCache.get(cacheKey);
    if (cached && typeof cached.fetchedAt === "number") {
      if (Date.now() - cached.fetchedAt <= REDDIT_FRESH_TTL_MS) return cached;
    }

    const inflight = redditInflight.get(cacheKey);
    if (inflight) return inflight;

    const promise = (async () => {
      try {
        const response = await axios.get(`${REDDIT_API_BASE}/r/${subredditPath}/search.json`, {
          params: {
            q,
            restrict_sr: "1",
            sort: "relevance",
            t: "all",
            limit: 100,
            raw_json: 1,
            ...(after ? { after } : {}),
          },
          timeout: 10000,
          headers: {
            "User-Agent": "reddslide/1.0",
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
        const status = err?.response?.status;
        if (status === 429) {
          const stale = redditCache.get(cacheKey);
          if (stale && typeof stale.fetchedAt === "number") return stale;
        }
        throw err;
      } finally {
        redditInflight.delete(cacheKey);
      }
    })();

    redditInflight.set(cacheKey, promise);
    return promise;
  }

  async function fetchSubredditSearchPosts({ sub, q, after }) {
    const cacheKey = `reddit-sub-search:${sub}:${q}:${after || ""}`;
    const cached = redditCache.get(cacheKey);
    if (cached && typeof cached.fetchedAt === "number") {
      if (Date.now() - cached.fetchedAt <= REDDIT_FRESH_TTL_MS) return cached;
    }

    const inflight = redditInflight.get(cacheKey);
    if (inflight) return inflight;

    const promise = (async () => {
      try {
        let token = await getRedditAccessToken(false);
        let baseUrl = token ? REDDIT_OAUTH_API_BASE : REDDIT_API_BASE;

        const makeRequest = (t, base) => axios.get(`${base}/r/${sub}/search.json`, {
          params: {
            q,
            restrict_sr: "1",
            sort: "new",
            t: "all",
            limit: 100,
            raw_json: 1,
            ...(after ? { after } : {}),
          },
          timeout: 15000,
          headers: {
            "User-Agent": "web:reddit-slideshow-app:v1.0.0 (by /u/Parag1337)",
            Accept: "application/json",
            ...(t ? { Authorization: `Bearer ${t}` } : {}),
          },
        });

        let response;
        try {
          response = await makeRequest(token, baseUrl);
        } catch (initialErr) {
          if (initialErr?.response?.status === 401 && token) {
            token = await getRedditAccessToken(true);
            response = await makeRequest(token, baseUrl);
          } else {
            throw initialErr;
          }
        }

        const payload = {
          posts: response.data?.data?.children?.map((c) => c.data) || [],
          after: response.data?.data?.after || null,
          fetchedAt: Date.now(),
        };
        redditCache.set(cacheKey, payload);
        return payload;
      } catch (err) {
        const status = err?.response?.status;
        if (status === 429) {
          const stale = redditCache.get(cacheKey);
          if (stale && typeof stale.fetchedAt === "number") return stale;
        }
        throw err;
      } finally {
        redditInflight.delete(cacheKey);
      }
    })();

    redditInflight.set(cacheKey, promise);
    return promise;
  }

  async function getRedgifsToken(forceRefresh = false) {
    if (!forceRefresh) {
      const cached = redgifsCache.get(REDGIFS_TOKEN_KEY);
      if (cached) return cached;
    }

    const response = await axios.get(REDGIFS_AUTH_URL, { timeout: 10000 });
    const token = response.data?.token;
    if (!token) throw new Error("Failed to acquire Redgifs token");
    redgifsCache.set(REDGIFS_TOKEN_KEY, token);
    return token;
  }

  async function fetchRedgifsGif(gifId) {
    const requestWithToken = async (token) =>
      axios.get(`${REDGIFS_GIF_URL_BASE}/${gifId}`, {
        timeout: 10000,
        headers: { Authorization: `Bearer ${token}` },
      });

    let token = await getRedgifsToken(false);
    try {
      return await requestWithToken(token);
    } catch (error) {
      if (error?.response?.status !== 401) throw error;
      token = await getRedgifsToken(true);
      return requestWithToken(token);
    }
  }

  app.get("/api/posts", async (req, res) => {
    const subs = parseSubreddits(req.query.subs);
    const includeNsfw = isTrue(req.query.nsfw);
    const after = req.query.after ? String(req.query.after) : "";
    const q = req.query.q ? String(req.query.q).trim() : "";

    if (!subs.length) {
      return res.status(400).json({
        error: "Invalid query: provide at least one subreddit in `subs`",
      });
    }

    try {
      const qLower = q ? q.toLowerCase() : "";
      const MAX_RESULTS = Number(process.env.REDDIT_SEARCH_MAX_RESULTS || 2000);
      const PER_SUB_PAGES = Number(process.env.REDDIT_SEARCH_PER_SUB_PAGES || 5); // Reduced from 80 to avoid rate limits

      // Query strategy: scan each subreddit feed IN PARALLEL using Reddit's search API
      if (qLower) {
        const searchOneSub = async (sub) => {
          const subResults = [];
          let subAfter = "";
          let subPages = 0;
          while (subPages < PER_SUB_PAGES && subResults.length < MAX_RESULTS) {
            // Use actual reddit search to be 100x faster and not get rate-limited aggressively
            const subData = await fetchSubredditSearchPosts({ sub, q: qLower, after: subAfter });
            const candidates = subData.posts.filter((post) => (includeNsfw ? true : !post.over_18));
            // Apply our custom substring logic just to be safe
            const searched = candidates.filter((post) => postMatchesQuery(post, qLower));
            for (const post of searched) {
              const media = buildMediaPost(post);
              if (media) subResults.push(media);
              if (subResults.length >= MAX_RESULTS) break;
            }
            subAfter = subData.after || "";
            subPages += 1;
            if (!subAfter) break;
          }
          return subResults;
        };

        // Fan out all subreddit searches in parallel
        const allResults = await Promise.all(subs.map(searchOneSub));

        // Merge, deduplicate, sort newest first
        const seen = new Set();
        const merged = [];
        for (const batch of allResults) {
          for (const post of batch) {
            if (!seen.has(post.id)) {
              seen.add(post.id);
              merged.push(post);
            }
          }
        }
        const strictMerged = merged.filter((p) => postMatchesQuery(
          { title: p.title, selftext: p.content || "" },
          qLower
        ));
        strictMerged.sort((a, b) => (b.createdUtc || 0) - (a.createdUtc || 0));
        return res.json({
          posts: strictMerged.slice(0, MAX_RESULTS),
          after: null,
        });
      }

      // Non-search strategy: regular multi-subreddit listing page.
      const redditData = await fetchRedditPosts({ subs, after });
      const candidates = redditData.posts.filter((post) => (includeNsfw ? true : !post.over_18));
      const results = candidates.map(buildMediaPost).filter(Boolean);
      return res.json({
        posts: results,
        after: redditData.after || null,
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

      if (details.length > 500) details = details.slice(0, 500) + "…";

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

      return res.status(status).json({ error: message, status, details });
    }
  });

  app.get("/api/redgifs", async (req, res) => {
    const gifId = extractRedgifsId(req.query.id);
    if (!gifId) {
      return res.status(400).json({ error: "Invalid query: provide a Redgifs id or URL in `id`" });
    }

    try {
      const response = await fetchRedgifsGif(gifId);
      const urls = response.data?.gif?.urls || {};
      const videoUrl = urls.hd || urls.sd || urls.fhd || null;
      if (!videoUrl) return res.status(404).json({ error: "No playable video URL found for this Redgifs id" });
      return res.json({ id: gifId, url: videoUrl });
    } catch (error) {
      const status = error?.response?.status || 500;
      return res.status(status).json({
        error: "Failed to fetch Redgifs video URL",
        details: error?.response?.data || error.message,
      });
    }
  });

  app.get("/health", (req, res) => res.json({ ok: true }));
  return app;
}

module.exports = { createApp };

