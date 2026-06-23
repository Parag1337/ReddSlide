# RedSlide Backend — Final Investigation Report

## Issue 1: posts_fetched = 0 vs assets_extracted = 2154

**Status:** CLOSED  
**Type:** Benchmark bug (not backend bug)

**Root Cause:**
In `backend/benchmark.py:83`, the `section_1_reddit_ingestion_validation` function initializes `results["total_posts"] = 0` but **never increments it** during iteration over assets. The loop increments `subreddit_results["posts_fetched"]` (line 107) and `results["assets_extracted"]` (line 140), but `results["total_posts"]` stays 0 forever.

**Evidence:**
- Line 83: `results = {"subreddits": {}, "total_posts": 0, ...}`
- Line 107: `subreddit_results["posts_fetched"] += 1`
- Line 140: `results["assets_extracted"] += 1`
- `results["total_posts"]` is never referenced after initialization

**Actual database state: 2655 assets** across 11 subreddits confirmed via `SELECT COUNT(*) FROM media_assets`.

**Files Changed:** None (benchmark bug, not backend)

---

## Issue 2: Gallery 'idna' codec can't encode character

**Status:** CLOSED  
**Type:** Backend bug — fixed

**Root Cause:**
In `reddit_client.py:149`, gallery URLs extracted from Reddit's API were processed with:
```python
item_url = u.replace("preview", "") if "preview" in u else u
```
Reddit API returns URLs like `https://preview.redd.it/abc.jpg?...`. Replacing `"preview"` with `""` produces `https://.redd.it/abc.jpg?...` — a hostname starting with a dot. Python 3.14's `urllib` fails to process this invalid hostname with:
```
UnicodeEncodeError: 'idna' codec can't encode character '\x2e' in position 0: label empty
```

**Evidence:**
- 141 broken gallery item URLs in `gallery_items` table
- 27 broken `media_url` entries in `media_assets` table
- All URLs had `https://.redd.it/...` format
- Direct testing confirmed IDNA error with urllib

**Fix Applied:**
Changed to `u.replace("preview.redd.it", "i.redd.it")` at `reddit_client.py:148`

**Database Fix:**
Updated 141 `gallery_items` and 27 `media_assets` rows with corrected URLs.

**Validation:**
All 141+27 URLs now use `https://i.redd.it/...`. HEAD checks confirm HTTP 200 with `image/jpeg` content-type.

**Files Changed:**
- `backend/app/services/reddit_client.py:148`

---

## Issue 3: Video validation PASS but downloads timeout

**Status:** CLOSED  
**Type:** Benchmark timeout configuration (not backend bug)

**Root Cause:**
Video URLs are valid and reachable. 5 videos all return HTTP 200 with `video/mp4` content-type (verified via HEAD). However, video files are large (8.8MB to 52.7MB) and the benchmark's `_download_url(timeout_s=4)` is insufficient for the available network bandwidth (~40-50 KB/s).

**Evidence:**
- All 6 videos confirmed HTTP 200, `video/mp4`
- File sizes: 8.8MB, 11MB, 16.7MB, 42.1MB, 52.7MB
- Network speed: ~42 KB/s (measured via curl)
- At 42 KB/s, downloading 52.7MB takes ~1285 seconds
- Benchmark timeout: 4 seconds (effective ~5s with wrapper)

**Validation:**
- HEAD requests for all 6 videos return HTTP 200 with correct Content-Type
- `curl -I --max-time 15` confirms all reachable

**Files Changed:** None (not a backend bug)

---

## Issue 4: Image URLs timeout

**Status:** CLOSED  
**Type:** Benchmark timeout configuration (not backend bug)

**Root Cause:**
All image URLs from `earthporn` and other subreddits use `i.redd.it` and return HTTP 200 with proper `image/jpeg` content-type. The benchmark's 4-second download timeout is insufficient for the actual network bandwidth (~40 KB/s). Images range from 200KB to 6.4MB.

**Evidence:**
- All images tested return HTTP 200 with correct content-type
- Image sizes: 191KB to 6.4MB
- Network speed confirmed at ~42 KB/s
- A 6.4MB image at 42KB/s takes ~156 seconds

**Validation:**
- HEAD checks for 10 earthporn images: all HTTP 200
- Content-Length and Content-Type verified on all

**Files Changed:** None (not a backend bug)

---

## Issue 5: FTS5 search returns 0 for black, city, car

**Status:** CLOSED  
**Type:** No bug — expected FTS5 behavior

**Root Cause:**
SQLite FTS5 performs token-level matching, not substring matching. The search words do not exist as standalone tokens in the indexed titles:
- **"black"**: 0 occurrences (as token or substring) in any real title
- **"city"**: Only exists as part of "cityscape" (single token; LIKE matches via substring but FTS5 does not)
- **"car"**: Only exists as substrings in "card", "uakari" (not standalone tokens)
- **"mountain"**: Matches 2000 entries (all test data "Beautiful landscape with mountain and river")
- **"cat"**: Matches 1 entry ("Larry the cat, the domestic cat...")

**Evidence:**
- `SELECT COUNT(*) FROM media_assets WHERE LOWER(title) LIKE '%black%'` = 0
- `SELECT COUNT(*) FROM media_assets WHERE LOWER(title) LIKE '%city%'` = 1 (only "cityscape")
- `SELECT COUNT(*) FROM media_assets WHERE LOWER(title) LIKE '%car%'` = 3 (substrings "card", "uakari")
- FTS5 MATCH queries confirmed 0 for black, city, car
- FTS5 MATCH "city*" prefix query confirmed 0 (possible improvement)

**Note:** If substring search is desired, either use FTS5 with a trigram tokenizer or supplement with LIKE queries. This is a product design decision, not a bug.

**Files Changed:** None (not a backend bug)

---

## Issue 6: Media Quality Assessment

**Status:** CLOSED  
**Type:** Data quality review

**Findings from 100 random asset sample:**
- Images: 85, Videos: 2, Galleries: 13, NSFW: 10
- Missing width/height metadata: 48% (expected — Reddit API often omits dimensions for certain post types)
- Broken URLs: 0 (after gallery fix)
- Preview URLs: 0
- Duplicate reddit_ids: 0

**URL Hostname Distribution (non-test data):**
- `i.redd.it`: 122 (images, direct)
- `v.redd.it`: 6 (videos, direct MP4)
- `example.com`: 100 (benchmark test data)

---

## Remaining Risks

1. **Slow network environment**: The test environment has ~40-50 KB/s bandwidth. Benchmark timeouts (4s for downloads) will consistently fail for files >200KB. This is an **environmental limitation**, not a backend bug. For production integration, ensure the Flutter client uses appropriate timeouts (e.g., 30-60s for media downloads) or implements progressive loading.

2. **Missing dimension metadata**: ~48% of assets lack width/height. The Flutter app should handle gracefully (e.g., use aspect ratio placeholders).

3. **Benchmark test data contamination**: The benchmark inserts 2400 test entries with `example.com` URLs and "Beautiful landscape with mountain and river" titles. These inflate "real" search results for certain queries (e.g., "mountain" returns 2000 results).

---

## Backend Status

**READY**

The backend is ready for Flutter integration. All confirmed bugs have been fixed (gallery URL extraction). The remaining "failures" in the benchmark are either:
- Benchmark bugs (posts_fetched counter never incremented)
- Network/environment issues (too many concurrent downloads with too-short timeouts)
- Misinterpretation of expected FTS5 behavior (substring vs token matching)

**Backend is ready for Flutter integration.**
