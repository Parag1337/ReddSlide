import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { BrowserRouter, Navigate, Route, Routes, useLocation, useNavigate } from "react-router-dom";
import {
  Eye,
  EyeOff,
  Home,
  Pause,
  Play,
  Search,
  Maximize,
} from "lucide-react";
import { searchPosts } from "./utils/searchPosts";

const DEFAULT_AUTOPLAY_MS = 5000;
const API_BASE = import.meta.env.VITE_API_BASE || "";
const SWIPE_THRESHOLD = 50;
const RESUME_DELAY_MS = 5000;
const LAST_SUBS_KEY = "reddit_slideshow_last_subs";

const postsCache = new Map();
const POSTS_CACHE_TTL_MS = 30_000;

function getTypeFromUrl(url = "") {
  const lower = String(url).toLowerCase();
  if (lower.includes("redgifs.com")) return "redgifs";
  if (lower.includes("v.redd.it")) return "video";
  if (lower.match(/\.(mp4|webm)(\?.*)?$/)) return "video";
  return "image";
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
    return { id: post.id, title: post.title, subreddit: post.subreddit, url: galleryImages[0], images: galleryImages, type: "image", isNsfw: Boolean(post.over_18) };
  }
  if (lowerUrl.includes("redgifs.com/watch/") || domain.includes("redgifs.com")) {
    return { id: post.id, title: post.title, subreddit: post.subreddit, url, type: "redgifs", isNsfw: Boolean(post.over_18) };
  }
  if (lowerUrl.includes("v.redd.it")) {
    return { id: post.id, title: post.title, subreddit: post.subreddit, url, type: "video", isNsfw: Boolean(post.over_18) };
  }
  if (lowerUrl.includes("i.redd.it") || lowerUrl.match(/\.(jpg|jpeg|png|gif|webp)(\?.*)?$/)) {
    return { id: post.id, title: post.title, subreddit: post.subreddit, url, type: "image", images: [url], isNsfw: Boolean(post.over_18) };
  }
  if (domain.includes("imgur.com")) {
    const isVideo = lowerUrl.match(/\.(mp4|webm)(\?.*)?$/);
    return { id: post.id, title: post.title, subreddit: post.subreddit, url, type: isVideo ? "video" : "image", images: isVideo ? undefined : [url], isNsfw: Boolean(post.over_18) };
  }
  return null;
}

async function fetchPostsApi({ subs, includeNsfw, afterToken = "", signal } = {}) {
  const cacheKey = `${subs}::${includeNsfw ? "1" : "0"}::${afterToken || ""}`;
  const cached = postsCache.get(cacheKey);
  if (cached && Date.now() - cached.ts < POSTS_CACHE_TTL_MS) return cached.data;

  const params = new URLSearchParams({
    subs,
    nsfw: includeNsfw ? "true" : "false",
  });
  if (afterToken) params.set("after", afterToken);
  let rawText = "";
  let payload = {};
  
  try {
    const response = await fetch(`https://api.reddit.com/r/${subs}.json?raw_json=1&limit=50${afterToken ? `&after=${afterToken}` : ''}`, { signal });
    rawText = await response.text();
    payload = rawText ? JSON.parse(rawText) : {};
    
    if (!response.ok) {
      throw new Error(`Reddit error (${response.status})`);
    }
  } catch (err) {
    if (err.name === "AbortError") throw err;
    throw new Error("Failed to fetch from Reddit. It might be blocking your browser. Try running locally!");
  }

  const rawPosts = payload?.data?.children?.map((c) => c.data) || [];
  let posts = rawPosts
    .filter((post) => (includeNsfw ? true : !post.over_18))
    .map(buildMediaPost)
    .filter(Boolean);

  payload.after = payload?.data?.after || null;
  const data = { posts, after: payload.after || null };
  postsCache.set(cacheKey, { ts: Date.now(), data });
  return data;
}

function HomePage() {
  const navigate = useNavigate();
  const [subs, setSubs] = useState(localStorage.getItem(LAST_SUBS_KEY) || "pics,wallpapers,memes");
  const includeNsfw = true;
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const inflight = useRef(null);

  const onSubmit = async (event) => {
    event.preventDefault();
    const sanitized = subs
      .split(",")
      .map((item) => item.trim())
      .filter(Boolean)
      .join(",");
    if (!sanitized) {
      setError("Enter at least one subreddit name.");
      return;
    }

    setLoading(true);
    setError("");
    localStorage.setItem(LAST_SUBS_KEY, sanitized);

    try {
      if (inflight.current) inflight.current.abort();
      inflight.current = new AbortController();
      const initialData = await fetchPostsApi({
        subs: sanitized,
        includeNsfw,
        signal: inflight.current.signal,
      });
      if (!initialData.posts.length) {
        throw new Error("No media found for the selected subreddit(s).");
      }
      const params = new URLSearchParams({ subs: sanitized, nsfw: "true" });
      navigate(`/viewer?${params.toString()}`, { state: { initialData } });
    } catch (err) {
      if (err?.name === "AbortError") return;
      const message = String(err.message || "");
      if (message.toLowerCase().includes("request failed")) {
        setError("Invalid subreddit or Reddit API error. Please check names and try again.");
      } else {
        setError(message);
      }
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="home-page">
      <form className="home-card fade-in" onSubmit={onSubmit}>
        <h1>Reddit Slideshow</h1>
        <p>Enter subreddits to start a fullscreen media slideshow.</p>

        <label htmlFor="subs-input">Subreddits (comma-separated)</label>
        <input
          id="subs-input"
          value={subs}
          onChange={(event) => setSubs(event.target.value)}
          placeholder="pics, wallpapers, memes"
          autoComplete="off"
        />

        {error ? <div className="form-error">{error}</div> : null}

        <button type="submit" className="start-btn" disabled={loading}>
          {loading ? "Loading..." : "Start Slideshow"}
        </button>
      </form>
    </div>
  );
}

function ViewerPage() {
  const location = useLocation();
  const navigate = useNavigate();
  const query = new URLSearchParams(location.search);
  const subs = query.get("subs") || "";
  const includeNsfw = query.get("nsfw") !== "false";

  const [allPosts, setAllPosts] = useState(location.state?.initialData?.posts || []);
  const [index, setIndex] = useState(0);
  const [after, setAfter] = useState(location.state?.initialData?.after || null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [uiVisible, setUiVisible] = useState(true);
  const [pausedUntil, setPausedUntil] = useState(0);
  const [resolvedRedgifs, setResolvedRedgifs] = useState({});
  const [imageIndexByPost, setImageIndexByPost] = useState({});
  const [autoplayEnabled, setAutoplayEnabled] = useState(true);
  const [autoplayMs, setAutoplayMs] = useState(DEFAULT_AUTOPLAY_MS);
  const [showSearch, setShowSearch] = useState(false);
  const [searchValue, setSearchValue] = useState("");
  const [searchError, setSearchError] = useState("");
  const touchStartX = useRef(null);
  const inflight = useRef(null);

  const filteredPosts = useMemo(() => searchPosts(allPosts, searchValue), [allPosts, searchValue]);
  const hasPosts = filteredPosts.length > 0;
  const currentPost = hasPosts ? filteredPosts[index] : null;
  const isPaused = Date.now() < pausedUntil;
  const currentImageIndex = currentPost ? imageIndexByPost[currentPost.id] || 0 : 0;
  const totalImages = currentPost?.images?.length || 1;

  const pauseAutoplay = useCallback(() => {
    setPausedUntil(Date.now() + RESUME_DELAY_MS);
  }, []);

  const fetchPosts = useCallback(
    async ({ append = false, afterToken = "" } = {}) => {
      if (loading || !subs) return;
      setLoading(true);
      setError("");
      try {
        if (!append) {
          if (inflight.current) inflight.current.abort();
          inflight.current = new AbortController();
        }
        const data = await fetchPostsApi({
          subs,
          includeNsfw,
          afterToken,
          signal: inflight.current?.signal,
        });
        setAllPosts((prev) => (append ? [...prev, ...data.posts] : data.posts));
        setAfter(data.after);
        if (!append && !data.posts.length) {
          setError("No media found for the selected subreddit(s).");
        }
      } catch (err) {
        if (err?.name === "AbortError") return;
        setError(err.message || "Failed to load posts");
      } finally {
        setLoading(false);
      }
    },
    [loading, subs, includeNsfw]
  );

  useEffect(() => {
    if (!subs) navigate("/", { replace: true });
  }, [subs, navigate]);

  useEffect(() => {
    if (!allPosts.length && subs) {
      fetchPosts();
    }
  }, [allPosts.length, subs, fetchPosts]);

  const resolveRedgifs = useCallback(
    async (post) => {
      if (!post || post.type !== "redgifs") return null;
      if (resolvedRedgifs[post.id]) return resolvedRedgifs[post.id];
      try {
        const params = new URLSearchParams({ id: post.url || post.id });
        const response = await fetch(`${API_BASE}/api/redgifs?${params.toString()}`);
        if (!response.ok) throw new Error("Redgifs fetch failed");
        const data = await response.json();
        setResolvedRedgifs((prev) => ({ ...prev, [post.id]: data.url }));
        return data.url;
      } catch {
        return null;
      }
    },
    [resolvedRedgifs]
  );

  const mediaUrl = useMemo(() => {
    if (!currentPost) return "";
    if (currentPost.type === "redgifs") return resolvedRedgifs[currentPost.id] || "";
    if (currentPost.images?.length) {
      return currentPost.images[Math.min(currentImageIndex, currentPost.images.length - 1)] || currentPost.url;
    }
    return currentPost.url;
  }, [currentPost, resolvedRedgifs, currentImageIndex]);

  const setPostAndResetImage = useCallback(
    (nextIndex) => {
      const bounded = Math.max(0, Math.min(nextIndex, filteredPosts.length - 1));
      const nextPost = filteredPosts[bounded];
      setIndex(bounded);
      if (nextPost?.id) {
        setImageIndexByPost((prev) => ({ ...prev, [nextPost.id]: 0 }));
      }
    },
    [filteredPosts]
  );

  const goNext = useCallback(() => {
    if (!hasPosts) return;
    pauseAutoplay();
    setPostAndResetImage(index + 1);
  }, [hasPosts, pauseAutoplay, setPostAndResetImage, index]);

  const goPrev = useCallback(() => {
    if (!hasPosts) return;
    pauseAutoplay();
    setPostAndResetImage(index - 1);
  }, [hasPosts, pauseAutoplay, setPostAndResetImage, index]);

  const cycleCurrentPostImage = useCallback(() => {
    if (!currentPost || totalImages <= 1) return;
    pauseAutoplay();
    setImageIndexByPost((prev) => {
      const current = prev[currentPost.id] || 0;
      return { ...prev, [currentPost.id]: (current + 1) % totalImages };
    });
  }, [currentPost, totalImages, pauseAutoplay]);

  const prevCurrentPostImage = useCallback(() => {
    if (!currentPost || totalImages <= 1) return;
    pauseAutoplay();
    setImageIndexByPost((prev) => {
      const current = prev[currentPost.id] || 0;
      const next = (current - 1 + totalImages) % totalImages;
      return { ...prev, [currentPost.id]: next };
    });
  }, [currentPost, totalImages, pauseAutoplay]);

  const jumpToImage = useCallback(
    (nextImageIndex) => {
      if (!currentPost || totalImages <= 1) return;
      pauseAutoplay();
      const bounded = Math.max(0, Math.min(nextImageIndex, totalImages - 1));
      setImageIndexByPost((prev) => ({ ...prev, [currentPost.id]: bounded }));
    },
    [currentPost, totalImages, pauseAutoplay]
  );

  const visiblePostIndices = useMemo(() => {
    const total = filteredPosts.length;
    if (total <= 1) return [];

    const MAX_VISIBLE = 15; // keep row short
    const current = index;
    const half = Math.floor(MAX_VISIBLE / 2);
    let start = Math.max(0, current - half);
    let end = Math.min(total - 1, start + MAX_VISIBLE - 1);
    start = Math.max(0, end - (MAX_VISIBLE - 1));

    const indices = [];
    for (let i = start; i <= end; i++) indices.push(i);

    const out = [];
    const pushIndex = (i) => out.push({ kind: "index", i });
    const pushEllipsis = (key) => out.push({ kind: "ellipsis", key });

    if (start > 0) {
      pushIndex(0);
      if (start > 1) pushEllipsis("left");
    }
    for (const i of indices) pushIndex(i);
    if (end < total - 1) {
      if (end < total - 2) pushEllipsis("right");
      pushIndex(total - 1);
    }
    return out;
  }, [filteredPosts.length, index]);

  useEffect(() => {
    if (!currentPost || currentPost.type !== "redgifs") return;
    resolveRedgifs(currentPost);
  }, [currentPost, resolveRedgifs]);

  useEffect(() => {
    if (!hasPosts || isPaused || !autoplayEnabled) return;
    const timer = window.setTimeout(() => {
      if (currentPost && totalImages > 1 && currentImageIndex < totalImages - 1) {
        setImageIndexByPost((prev) => ({ ...prev, [currentPost.id]: (prev[currentPost.id] || 0) + 1 }));
      } else {
        setPostAndResetImage(index + 1);
      }
    }, autoplayMs);
    return () => window.clearTimeout(timer);
  }, [
    hasPosts,
    isPaused,
    autoplayEnabled,
    autoplayMs,
    currentPost,
    totalImages,
    currentImageIndex,
    setPostAndResetImage,
    index,
  ]);

  useEffect(() => {
    const shouldLoadMore =
      filteredPosts.length > 0 && index >= filteredPosts.length - 3 && after && !loading;
    if (shouldLoadMore) fetchPosts({ append: true, afterToken: after });
  }, [index, filteredPosts.length, after, loading, fetchPosts]);

  useEffect(() => {
    const onKeyDown = (event) => {
      const targetTag = event.target?.tagName?.toLowerCase?.() || "";
      const isTypingTarget =
        targetTag === "input" || targetTag === "textarea" || event.target?.isContentEditable;
      if (isTypingTarget) return;

      if (
        event.key === "ArrowLeft" ||
        event.key === "ArrowRight" ||
        event.key === "ArrowUp" ||
        event.key === "ArrowDown"
      ) {
        event.preventDefault();
      }

      if (event.key === "ArrowRight") goNext();
      else if (event.key === "ArrowLeft") goPrev();
      else if (event.key === "ArrowUp") cycleCurrentPostImage();
      else if (event.key === "ArrowDown") prevCurrentPostImage();
    };

    window.addEventListener("keydown", onKeyDown, { passive: false });
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [goNext, goPrev, cycleCurrentPostImage, prevCurrentPostImage]);

  useEffect(() => {
    const nextPost = filteredPosts[index + 1];
    if (!nextPost) return;
    const nextUrl = nextPost.type === "redgifs"
      ? resolvedRedgifs[nextPost.id]
      : (nextPost.images?.[0] || nextPost.url);
    if (!nextUrl) return;
    if (nextPost.type === "image") {
      const image = new Image();
      image.src = nextUrl;
    } else {
      const video = document.createElement("video");
      video.preload = "metadata";
      video.src = nextUrl;
    }
  }, [index, filteredPosts, resolvedRedgifs]);

  const onTouchStart = (event) => {
    touchStartX.current = event.changedTouches[0]?.clientX ?? null;
  };
  const onTouchEnd = (event) => {
    const start = touchStartX.current;
    const end = event.changedTouches[0]?.clientX ?? null;
    if (start === null || end === null) return;
    const delta = end - start;
    if (Math.abs(delta) < SWIPE_THRESHOLD) return;
    if (delta < 0) goNext();
    else goPrev();
  };

  const requestFullscreen = async () => {
    pauseAutoplay();
    if (!document.fullscreenElement) await document.documentElement.requestFullscreen();
    else await document.exitFullscreen();
  };

  const submitSearch = async (event) => {
    event.preventDefault();
    const q = typeof searchValue === "string" ? searchValue.trim() : "";
    if (!q) {
      setSearchError("");
      setIndex(0);
      setShowSearch(false);
      return;
    }
    const results = searchPosts(allPosts, q);
    setSearchError(results.length ? "" : "No matching posts in current slideshow.");
    setIndex(0);
    setShowSearch(false);
  };

  return (
    <div className="app fade-in" onTouchStart={onTouchStart} onTouchEnd={onTouchEnd}>
      <div className="tap-zone left" onClick={goPrev} aria-label="Previous post" />
      <div className="tap-zone center" onClick={cycleCurrentPostImage} aria-label="Next image in post" />
      <div className="tap-zone right" onClick={goNext} aria-label="Next post" />

      <main className="media-stage">
        {!hasPosts && loading && <div className="status">Loading posts...</div>}
        {!hasPosts && !loading && error && <div className="status error">{error}</div>}
        {hasPosts && currentPost ? (
          <>
            {currentPost.type === "image" ? (
              <img className="media" src={mediaUrl} alt={currentPost.title} loading="lazy" draggable="false" />
            ) : (
              <video className="media" key={mediaUrl} src={mediaUrl} muted autoPlay playsInline loop preload="metadata" />
            )}
          </>
        ) : null}
      </main>

      {uiVisible ? (
        <>
          <div className="top-bar">
            {currentPost ? (
              <span>
                ({Math.min(currentImageIndex + 1, totalImages)}/{totalImages}) {currentPost.title}
              </span>
            ) : null}
          </div>
          <div className="top-right-controls">
            <button
              type="button"
              className="overlay-btn icon-btn"
              title="Hide UI"
              aria-label="Hide UI"
              onClick={() => setUiVisible(false)}
            >
              <Eye size={18} />
            </button>
            <button
              type="button"
              className="overlay-btn icon-btn"
              title="Fullscreen"
              aria-label="Fullscreen"
              onClick={requestFullscreen}
            >
              <Maximize size={18} />
            </button>
            <button
              type="button"
              className="overlay-btn icon-btn"
              title="Home"
              aria-label="Home"
              onClick={() => navigate("/")}
            >
              <Home size={18} />
            </button>
          </div>
          <div className="bottom-bar">
            <div className="meta">
              <span>{hasPosts ? index + 1 : 0} / {filteredPosts.length}</span>
              {currentPost ? <span>r/{currentPost.subreddit}</span> : null}
            </div>
            <div className="bottom-controls">
              <button
                type="button"
                className="overlay-btn icon-btn"
                title={autoplayEnabled ? "Pause slideshow" : "Play slideshow"}
                aria-label={autoplayEnabled ? "Pause slideshow" : "Play slideshow"}
                onClick={() => {
                  pauseAutoplay();
                  setAutoplayEnabled((v) => !v);
                }}
              >
                {autoplayEnabled ? <Pause size={18} /> : <Play size={18} />}
              </button>
              <input
                className="timer-input"
                type="number"
                min="1"
                max="30"
                value={Math.round(autoplayMs / 1000)}
                onChange={(event) => setAutoplayMs(Math.max(1000, Number(event.target.value || 5) * 1000))}
              />
              <button
                type="button"
                className="overlay-btn icon-btn"
                title="Search subreddit"
                aria-label="Search subreddit"
                onClick={() => setShowSearch((v) => !v)}
              >
                <Search size={18} />
              </button>
            </div>
            {showSearch ? (
              <form className="search-inline" onSubmit={submitSearch}>
                <input
                  value={searchValue}
                  onChange={(event) => setSearchValue(event.target.value)}
                  placeholder="Search subreddit (e.g. wallpapers)"
                />
                <button type="submit" className="overlay-btn" disabled={loading}>
                  Go
                </button>
              </form>
            ) : null}
            {searchError ? <div className="search-error">{searchError}</div> : null}
            {filteredPosts.length > 1 ? (
              <div className="post-strip" aria-label="Posts in slideshow">
                {visiblePostIndices.map((item) =>
                  item.kind === "ellipsis" ? (
                    <span key={item.key} className="strip-ellipsis" aria-hidden="true">
                      …
                    </span>
                  ) : (
                    <button
                      key={item.i}
                      type="button"
                      className={`strip-num ${item.i === index ? "active" : ""}`}
                      onClick={() => setPostAndResetImage(item.i)}
                      aria-label={`Open post ${item.i + 1} of ${filteredPosts.length}`}
                      title={`${item.i + 1}/${filteredPosts.length}`}
                    >
                      {item.i + 1}
                    </button>
                  )
                )}
              </div>
            ) : null}
            {totalImages > 1 ? (
              <div className="image-strip" aria-label="Images in current post">
                {Array.from({ length: totalImages }).map((_, i) => (
                  <button
                    key={i}
                    type="button"
                    className={`img-num ${i === currentImageIndex ? "active" : ""}`}
                    onClick={() => jumpToImage(i)}
                    aria-label={`Open image ${i + 1} of ${totalImages}`}
                    title={`${i + 1}/${totalImages}`}
                  >
                    {i + 1}
                  </button>
                ))}
                <span className="image-strip-total">{totalImages}/{totalImages}</span>
              </div>
            ) : null}
          </div>
        </>
      ) : (
        <button
          type="button"
          className="show-ui-btn icon-btn"
          title="Show UI"
          aria-label="Show UI"
          onClick={() => setUiVisible(true)}
        >
          <EyeOff size={18} />
        </button>
      )}

      {loading && hasPosts ? <div className="loading-hint">Loading more...</div> : null}
      {error && hasPosts ? <div className="loading-hint error">{error}</div> : null}
    </div>
  );
}

function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<HomePage />} />
        <Route path="/viewer" element={<ViewerPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </BrowserRouter>
  );
}

export default App;
