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

const DEFAULT_AUTOPLAY_MS = 5000;
const API_BASE = import.meta.env.VITE_API_BASE || "";
const SWIPE_THRESHOLD = 50;
const RESUME_DELAY_MS = 5000;
const LAST_SUBS_KEY = "reddit_slideshow_last_subs";
const MEDIA_MODE_SEQUENCE = ["both", "video", "image"];
const MEDIA_MODE_LABEL = {
  both: "Video + Image",
  video: "Video only",
  image: "Image only",
};

const postsCache = new Map();
const POSTS_CACHE_TTL_MS = 30_000;

function getTypeFromUrl(url = "") {
  const lower = String(url).toLowerCase();
  if (lower.includes("redgifs.com")) return "redgifs";
  if (lower.includes("v.redd.it")) return "video";
  if (lower.match(/\.(mp4|webm)(\?.*)?$/)) return "video";
  return "image";
}

async function fetchPostsApi({ subs, includeNsfw, afterToken = "", q = "", signal } = {}) {
  const cacheKey = `${subs}::${includeNsfw ? "1" : "0"}::${afterToken || ""}::${q || ""}`;
  const cached = postsCache.get(cacheKey);
  if (cached && Date.now() - cached.ts < POSTS_CACHE_TTL_MS) return cached.data;

  const params = new URLSearchParams({
    subs,
    nsfw: includeNsfw ? "true" : "false",
  });
  if (afterToken) params.set("after", afterToken);
  if (q) params.set("q", q);
  const response = await fetch(`${API_BASE}/api/posts?${params.toString()}`, { signal });
  const rawText = await response.text();
  const payload = (() => {
    try {
      return rawText ? JSON.parse(rawText) : {};
    } catch {
      return {};
    }
  })();
  if (!response.ok) {
    let detail = "";
    if (payload.details) {
      if (typeof payload.details === "string") detail = payload.details;
      else {
        try {
          detail = JSON.stringify(payload.details);
        } catch {
          detail = String(payload.details);
        }
      }
    }
    const base = payload.error || payload.message || `Request failed (${response.status})`;
    const fallback = !detail && rawText && rawText.length < 300 ? ` (${rawText})` : "";
    throw new Error(base + (detail ? ` (${detail})` : "") + fallback);
  }
  const posts = (payload.posts || []).map((post) => ({
    ...post,
    type: post.type || getTypeFromUrl(post.url),
  }));
  const data = { posts, after: payload.after || null };
  postsCache.set(cacheKey, { ts: Date.now(), data });
  return data;
}

function HomePage() {
  const navigate = useNavigate();
  const [subs, setSubs] = useState(localStorage.getItem(LAST_SUBS_KEY) || "pics,wallpapers,memes");
  const [search, setSearch] = useState("");
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
    const q = search.trim();
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
        q,
        signal: inflight.current.signal,
      });
      if (!initialData.posts.length) {
        throw new Error(q ? "No matching posts found." : "No media found for the selected subreddit(s).");
      }
      const params = new URLSearchParams({ subs: sanitized, nsfw: "true" });
      if (q) params.set("q", q);
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
        <p>Fullscreen media viewer for multiple subreddits with search, autoplay, and gestures.</p>

        <label htmlFor="subs-input">Subreddits (comma-separated)</label>
        <input
          id="subs-input"
          value={subs}
          onChange={(event) => setSubs(event.target.value)}
          placeholder="pics, wallpapers, memes"
          autoComplete="off"
        />

        <label htmlFor="home-search-input">Search (optional)</label>
        <input
          id="home-search-input"
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          placeholder="e.g. car, beach, sunset"
          autoComplete="off"
        />

        <div className="home-help">
          <span>Examples: `pics, wallpapers, memes`</span>
          <span>Tip: add a search term to pre-filter before entering viewer</span>
        </div>

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
  const initialQuery = query.get("q") || "";

  const [posts, setPosts] = useState(location.state?.initialData?.posts || []);
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
  const [mediaMode, setMediaMode] = useState("both");
  const [showSearch, setShowSearch] = useState(false);
  const [searchValue, setSearchValue] = useState(initialQuery);
  const [searchError, setSearchError] = useState("");
  const [activeQuery, setActiveQuery] = useState(initialQuery);
  const touchStartX = useRef(null);
  const inflight = useRef(null);
  const activeQueryRef = useRef(initialQuery);

  const visiblePosts = useMemo(() => {
    if (mediaMode === "both") return posts;
    if (mediaMode === "video") {
      return posts.filter((p) => p.type === "video" || p.type === "redgifs");
    }
    return posts.filter((p) => p.type === "image");
  }, [posts, mediaMode]);

  const hasPosts = visiblePosts.length > 0;
  const currentPost = hasPosts ? visiblePosts[index] : null;
  const isPaused = Date.now() < pausedUntil;
  const currentImageIndex = currentPost ? imageIndexByPost[currentPost.id] || 0 : 0;
  const totalImages = currentPost?.images?.length || 1;

  const pauseAutoplay = useCallback(() => {
    setPausedUntil(Date.now() + RESUME_DELAY_MS);
  }, []);

  const fetchPosts = useCallback(
    async ({ append = false, afterToken = "", q } = {}) => {
      if (loading || !subs) return;
      setLoading(true);
      setError("");
      try {
        const effectiveQ = typeof q === "string" ? q : activeQueryRef.current;
        if (!append) {
          if (inflight.current) inflight.current.abort();
          inflight.current = new AbortController();
        }
        const data = await fetchPostsApi({
          subs,
          includeNsfw,
          afterToken,
          q: effectiveQ,
          signal: inflight.current?.signal,
        });
        setPosts((prev) => (append ? [...prev, ...data.posts] : data.posts));
        setAfter(data.after);
        if (!append && !data.posts.length && !effectiveQ) {
          setError("No media found for the selected subreddit(s).");
        }
        return data;
      } catch (err) {
        if (err?.name === "AbortError") return;
        setError(err.message || "Failed to load posts");
        throw err;
      } finally {
        setLoading(false);
      }
    },
    [loading, subs, includeNsfw, activeQuery]
  );

  useEffect(() => {
    if (!subs) navigate("/", { replace: true });
  }, [subs, navigate]);

  useEffect(() => {
    if (!posts.length && subs) {
      fetchPosts();
    }
  }, [posts.length, subs, fetchPosts]);

  useEffect(() => {
    if (!visiblePosts.length) {
      setIndex(0);
      return;
    }
    if (index > visiblePosts.length - 1) {
      setIndex(0);
    }
  }, [visiblePosts.length, index]);

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
      const bounded = Math.max(0, Math.min(nextIndex, visiblePosts.length - 1));
      const nextPost = visiblePosts[bounded];
      setIndex(bounded);
      if (nextPost?.id) {
        setImageIndexByPost((prev) => ({ ...prev, [nextPost.id]: 0 }));
      }
    },
    [visiblePosts]
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
    const total = visiblePosts.length;
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
  }, [visiblePosts.length, index]);

  useEffect(() => {
    // Resolve redgifs for current and next 3 posts in advance
    for (let i = 0; i <= 3; i++) {
      const p = visiblePosts[index + i];
      if (p && p.type === "redgifs") resolveRedgifs(p);
    }
  }, [index, visiblePosts, resolveRedgifs]);

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
      visiblePosts.length > 0 && index >= visiblePosts.length - 3 && after && !loading;
    if (shouldLoadMore) fetchPosts({ append: true, afterToken: after });
  }, [index, visiblePosts.length, after, loading, fetchPosts]);

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

  const preloadMediaUrls = useMemo(() => {
    const urls = [];
    if (!currentPost) return urls;

    // Preload the next image of the current gallery post
    if (totalImages > 1 && currentImageIndex < totalImages - 1) {
      urls.push({ url: currentPost.images[currentImageIndex + 1], type: "image", key: "preload_gallery" });
    }

    // Preload the next 3 posts' primary media
    for (let i = 1; i <= 3; i++) {
      const nextPost = visiblePosts[index + i];
      if (nextPost) {
        let url = nextPost.type === "redgifs"
          ? resolvedRedgifs[nextPost.id]
          : (nextPost.images?.[0] || nextPost.url);
        if (url) {
          urls.push({ url, type: nextPost.type === "image" ? "image" : "video", key: `preload_${nextPost.id}` });
        }
      }
    }
    return urls;
  }, [currentPost, totalImages, currentImageIndex, visiblePosts, index, resolvedRedgifs]);

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
    activeQueryRef.current = q;
    setActiveQuery(q);
    setSearchError("");
    setError("");
    setIndex(0);
    setImageIndexByPost({});
    setAfter(null);
    setShowSearch(false);
    setLoading(true);

    try {
      if (inflight.current) inflight.current.abort();
      inflight.current = new AbortController();

      const params = new URLSearchParams({ subs, nsfw: String(includeNsfw) });
      if (q) params.set("q", q);
      navigate(`/viewer?${params.toString()}`, { replace: true });

      // Single call — backend searches all subs in parallel and returns merged results
      const data = await fetchPostsApi({
        subs,
        includeNsfw,
        afterToken: "",
        q: activeQueryRef.current,
        signal: inflight.current.signal,
      });

      setPosts(data.posts);
      setAfter(data.after);

      if (q && !data.posts.length) {
        setSearchError("No matching posts found.");
      }
    } catch (err) {
      if (err?.name === "AbortError") return;
      setSearchError(err?.message || "Failed to search.");
    } finally {
      setLoading(false);
    }
  };

  const cycleMediaMode = () => {
    setIndex(0);
    setMediaMode((prev) => {
      const i = MEDIA_MODE_SEQUENCE.indexOf(prev);
      return MEDIA_MODE_SEQUENCE[(i + 1) % MEDIA_MODE_SEQUENCE.length];
    });
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

        {/* Invisible DOM preloader for upcoming images/videos */}
        <div style={{ display: "none" }}>
          {preloadMediaUrls.map((media) =>
            media.type === "image" ? (
              <img key={media.key} src={media.url} alt="" />
            ) : (
              <video key={media.key} src={media.url} preload="auto" />
            )
          )}
        </div>
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
              <span>{hasPosts ? index + 1 : 0} / {visiblePosts.length}</span>
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
                className="overlay-btn media-mode-btn"
                title="Cycle media mode"
                aria-label="Cycle media mode"
                onClick={cycleMediaMode}
              >
                {MEDIA_MODE_LABEL[mediaMode]}
              </button>
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
            {visiblePosts.length > 1 ? (
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
                      aria-label={`Open post ${item.i + 1} of ${visiblePosts.length}`}
                      title={`${item.i + 1}/${visiblePosts.length}`}
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
