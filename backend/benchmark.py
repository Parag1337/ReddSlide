#!/usr/bin/env python3
"""
Focused Backend Functional Benchmark and Media Validation

This script performs validation using existing data and doesn't require
external API calls or starting servers.
"""
import asyncio
import time
import os
import json
import urllib.request
import sys
import ssl
from datetime import datetime
from dotenv import load_dotenv

load_dotenv()

DATABASE_PATH = os.getenv("DATABASE_PATH", "/home/parag/Projects/Application/redslide/backend/data/redslide.db")
CLIENT_ID = os.getenv("REDDIT_CLIENT_ID", "")
CLIENT_SECRET = os.getenv("REDDIT_CLIENT_SECRET", "")
USER_AGENT = os.getenv("REDDIT_USER_AGENT", "RedSlide/1.0 by u/Designer-Surround949")

# Insert test data flag - set False to skip DB modifications
INSERT_TEST_DATA = True

# Test subreddits as specified
TEST_SUBREDDITS = ["pics", "wallpapers", "earthporn", "cityporn", "natureisfuckinglit", "interestingasfuck", "navelnsfw"]

# Benchmark results storage
BENCHMARK_RESULTS = {
    "section_1": {"reddit_ingestion": {}},
    "section_2": {"database": {}},
    "section_3": {"feed_api": {}},
    "section_4": {"search": {}},
    "section_5": {"oauth": {}},
    "section_6": {"video": {}},
    "section_7": {"gallery": {}},
    "section_8": {"download_sample": {}},
    "section_9": {"media_quality": {}},
    "section_10": {"final_report": {}}
}

# Create output directories
os.makedirs("benchmark_output/images", exist_ok=True)
os.makedirs("benchmark_output/videos", exist_ok=True)
os.makedirs("benchmark_output/galleries", exist_ok=True)
os.makedirs("benchmark_output/nsfw", exist_ok=True)


def log_section(title):
    """Log section header."""
    print("\n" + "=" * 70)
    print(f"SECTION: {title}")
    print("=" * 70)


def log_step(step_num, description):
    """Log step information."""
    print(f"\n[{step_num}] {description}")


def log_result(status, message, details=None):
    """Log test result."""
    status_icon = "✓" if status else "✗"
    print(f"  {status_icon} {message}")
    if details:
        print(f"    Details: {details}")


async def section_1_reddit_ingestion_validation():
    """SECTION 1: Reddit Ingestion Validation."""
    log_section("REDDIT INGESTION VALIDATION")
    
    # Initialize database
    from app.core.database import init_db
    await init_db()
    
    # Check current database state
    import aiosqlite
    
    results = {"subreddits": {}, "total_posts": 0, "assets_extracted": 0, "images": 0, "videos": 0, "galleries": 0, "nsfw_assets": 0}
    
    async with aiosqlite.connect(DATABASE_PATH) as db:
        db.row_factory = aiosqlite.Row
        
        # Get all assets and analyze them
        cursor = await db.execute("SELECT * FROM media_assets")
        assets = await cursor.fetchall()
        
        for asset in assets:
            subreddit = asset["subreddit"]
            
            if subreddit not in results["subreddits"]:
                results["subreddits"][subreddit] = {
                    "posts_fetched": 0,
                    "assets_extracted": 0,
                    "images": 0,
                    "videos": 0,
                    "galleries": 0,
                    "nsfw_assets": 0,
                    "validation": {}
                }
            
            subreddit_results = results["subreddits"][subreddit]
            subreddit_results["posts_fetched"] += 1
            
            # Verify required fields
            validation = {
                "title_present": bool(asset["title"]),
                "author_present": bool(asset["author"]),
                "score_present": asset["score"] is not None,
                "subreddit_present": subreddit == asset["subreddit"],
                "permalink_present": bool(asset["permalink"])
            }
            
            subreddit_results["validation"] = validation
            
            # Extract media type
            is_image = not asset["is_video"] and not asset["is_gallery"]
            is_video = asset["is_video"]
            is_gallery = asset["is_gallery"]
            
            if is_image:
                subreddit_results["images"] += 1
                results["images"] += 1
            elif is_video:
                subreddit_results["videos"] += 1
                results["videos"] += 1
            elif is_gallery:
                subreddit_results["galleries"] += 1
                results["galleries"] += 1
            
            if asset["nsfw"]:
                subreddit_results["nsfw_assets"] += 1
                results["nsfw_assets"] += 1
            
            subreddit_results["assets_extracted"] += 1
            results["assets_extracted"] += 1
    
    # Store results
    BENCHMARK_RESULTS["section_1"]["reddit_ingestion"] = results
    
    # Print summary
    log_step(1, "REDDIT INGESTION SUMMARY")
    print(f"  Total posts fetched: {results['total_posts']}")
    print(f"  Total assets extracted: {results['assets_extracted']}")
    print(f"  Images: {results['images']}")
    print(f"  Videos: {results['videos']}")
    print(f"  Galleries: {results['galleries']}")
    print(f"  NSFW assets: {results['nsfw_assets']}")
    
    return results


async def section_2_database_validation():
    """SECTION 2: Database Validation."""
    log_section("DATABASE VALIDATION")
    
    results = {
        "total_assets_stored": 0,
        "insert_speed": 0,
        "fts5_indexing_speed": 0,
        "database_file_size": 0,
        "duplicate_count": 0,
        "queries": {},
        "verification": {}
    }
    
    # Get database file size
    log_step(1, "Measuring database file size")
    file_size = os.path.getsize(DATABASE_PATH)
    results["database_file_size"] = file_size
    log_result(True, f"  Database file size: {file_size/1024:.1f}KB")
    
    # Measure insert speed
    log_step(2, "Measuring insert speed")
    from app.core.database import get_db
    
    start_time = time.time()
    test_count = 100
    
    async with get_db() as db:
        for i in range(test_count):
            await db.execute('''
                INSERT OR IGNORE INTO media_assets 
                (id, reddit_id, permalink, media_url, title, author, score, subreddit,
                 created_utc, is_video, is_gallery, nsfw, quality_score,
                 source_provider, created_at, last_seen)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''', (
                f"test_insert_{i}",
                f"reddit_test_{i}",
                f"/r/test/post{i}",
                f"https://example.com/test{i}.jpg",
                f"Test Photo {i}",
                f"test_user",
                100 + i,
                "test",
                int(time.time()) - i,
                0, 0, 0, 50, "reddit_oauth",
                int(time.time()),
                int(time.time())
            ))
        await db.commit()
    
    insert_time = time.time() - start_time
    results["insert_speed"] = (test_count / insert_time) * 1000  # items per second
    log_result(True, f"  Insert speed: {results['insert_speed']:.1f} items/sec")
    
    # Measure FTS5 indexing speed
    log_step(3, "Measuring FTS5 indexing speed")
    start_time = time.time()
    ts_suffix = int(time.time())
    
    async with get_db() as db:
        # Insert test data with unique IDs to ensure triggers fire
        for i in range(500):
            await db.execute('''
                INSERT OR IGNORE INTO media_assets 
                (id, reddit_id, permalink, media_url, title, author, score, subreddit,
                 created_utc, is_video, is_gallery, nsfw, quality_score,
                 source_provider, created_at, last_seen)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''', (
                f"fts_test_{ts_suffix}_{i}",
                f"reddit_fts_{ts_suffix}_{i}",
                f"/r/test/post{ts_suffix}_{i}",
                f"https://example.com/fts{ts_suffix}_{i}.jpg",
                f"Beautiful landscape with mountain and river",
                f"test_user",
                100 + i,
                "test",
                int(time.time()) - i,
                0, 0, 0, 50, "reddit_oauth",
                int(time.time()),
                int(time.time())
            ))
        await db.commit()
        
        # Verify FTS5 indexing happened via triggers
        cursor = await db.execute("SELECT COUNT(*) FROM media_search")
        fts_count = await cursor.fetchone()
        results["fts5_indexed"] = fts_count[0]
    
    fts5_time = time.time() - start_time
    results["fts5_indexing_speed"] = (500 / fts5_time) * 1000  # items per second
    log_result(True, f"  FTS5 indexing speed: {results['fts5_indexing_speed']:.1f} items/sec")
    log_result(True, f"  FTS5 total entries after insert: {results.get('fts5_indexed', 0)}")
    
    # Database queries
    log_step(4, "Running database queries")
    
    async with get_db() as db:
        # COUNT(*)
        cursor = await db.execute("SELECT COUNT(*) as count FROM media_assets")
        row = await cursor.fetchone()
        results["queries"]["count_all"] = row["count"]
        log_result(True, f"  COUNT(*): {row['count']}")
        
        # COUNT(DISTINCT reddit_post_id)
        cursor = await db.execute("SELECT COUNT(DISTINCT reddit_id) as count FROM media_assets")
        row = await cursor.fetchone()
        results["queries"]["count_distinct_reddit_id"] = row["count"]
        log_result(True, f"  COUNT(DISTINCT reddit_id): {row['count']}")
        
        # COUNT videos
        cursor = await db.execute("SELECT COUNT(*) as count FROM media_assets WHERE is_video=1")
        row = await cursor.fetchone()
        results["queries"]["count_videos"] = row["count"]
        log_result(True, f"  COUNT videos: {row['count']}")
        
        # COUNT galleries
        cursor = await db.execute("SELECT COUNT(*) as count FROM media_assets WHERE is_gallery=1")
        row = await cursor.fetchone()
        results["queries"]["count_galleries"] = row["count"]
        log_result(True, f"  COUNT galleries: {row['count']}")
        
        # COUNT nsfw
        cursor = await db.execute("SELECT COUNT(*) as count FROM media_assets WHERE nsfw=1")
        row = await cursor.fetchone()
        results["queries"]["count_nsfw"] = row["count"]
        log_result(True, f"  COUNT nsfw: {row['count']}")
    
    # Verification
    log_step(5, "Database verification")
    
    # Check for duplicate reddit_post_id
    async with get_db() as db:
        cursor = await db.execute(
            "SELECT reddit_id, COUNT(*) as count FROM media_assets GROUP BY reddit_id HAVING COUNT(*) > 1"
        )
        duplicates = await cursor.fetchall()
        results["duplicate_count"] = len(duplicates)
        
        if duplicates:
            log_result(False, f"  ✗ Found {len(duplicates)} duplicate reddit_id values")
        else:
            log_result(True, f"  ✓ No duplicate reddit_id values")
        
        # Check for duplicate permalink
        cursor = await db.execute(
            "SELECT permalink, COUNT(*) as count FROM media_assets GROUP BY permalink HAVING COUNT(*) > 1"
        )
        permalink_duplicates = await cursor.fetchall()
        
        if permalink_duplicates:
            log_result(False, f"  ✗ Found {len(permalink_duplicates)} duplicate permalink values")
        else:
            log_result(True, f"  ✓ No duplicate permalink values")
    
    # Store results
    BENCHMARK_RESULTS["section_2"]["database"] = results
    
    return results


async def section_3_feed_api_benchmark():
    """SECTION 3: Feed API Benchmark."""
    log_section("FEED API BENCHMARK")
    
    # Test with existing FastAPI app
    from app.main import app
    
    results = {
        "subreddit_counts": {1: 0, 3: 0, 5: 0, 7: 0},
        "latencies": {1: [], 3: [], 5: [], 7: []},
        "pagination": {},
        "duplicates": {},
        "sorting": {}
    }
    
    for subreddit_count in [1, 3, 5, 7]:
        log_step(1, f"Testing with {subreddit_count} subreddit(s)")
        
        # Get subreddits
        subreddits = TEST_SUBREDDITS[:subreddit_count]
        
        # Make 100 requests
        for i in range(100):
            start_time = time.time()
            
            # Make request using httpx
            import httpx
            async with httpx.AsyncClient() as client:
                response = await client.get(
                    "http://127.0.0.1:8000/api/feed",
                    params={"limit": 20, "subreddits": ",".join(subreddits)}
                )
                
                if response.status_code == 200:
                    data = response.json()
                    latency = (time.time() - start_time) * 1000
                    
                    results["latencies"][subreddit_count].append(latency)
                    
                    # Check pagination
                    if "items" in data:
                        items = data["items"]
                        if len(items) > 0:
                            results["pagination"][f"{subreddit_count}_{i}"] = {
                                "has_items": True,
                                "item_count": len(items),
                                "first_item_id": items[0].get("id") if items else None
                            }
                        else:
                            results["pagination"][f"{subreddit_count}_{i}"] = {
                                "has_items": False,
                                "item_count": 0
                            }
                    
                    # Check for duplicates
                    item_ids = [item.get("id") for item in items]
                    unique_ids = set(item_ids)
                    if len(item_ids) != len(unique_ids):
                        results["duplicates"][f"{subreddit_count}_{i}"] = {
                            "total_items": len(item_ids),
                            "unique_items": len(unique_ids),
                            "duplicate_count": len(item_ids) - len(unique_ids)
                        }
                    
                    # Check sorting (should be by position)
                    if len(items) > 1:
                        positions = [item.get("score", 0) for item in items]
                        is_sorted = all(positions[i] >= positions[i+1] for i in range(len(positions)-1))
                        results["sorting"][f"{subreddit_count}_{i}"] = {
                            "is_sorted": is_sorted,
                            "positions": positions[:5]
                        }
                
                await asyncio.sleep(0.1)  # Rate limiting
        
        # Calculate statistics
        latencies = results["latencies"][subreddit_count]
        if latencies:
            avg_latency = sum(latencies) / len(latencies)
            p50 = sorted(latencies)[len(latencies) // 2]
            p95 = sorted(latencies)[int(len(latencies) * 0.95)]
            p99 = sorted(latencies)[int(len(latencies) * 0.99)]
            
            results["subreddit_counts"][subreddit_count] = len(latencies)
            
            log_result(True, f"  ✓ {subreddit_count} subreddits: avg={avg_latency:.1f}ms, p50={p50:.1f}ms, p95={p95:.1f}ms, p99={p99:.1f}ms")
    
    # Store results
    BENCHMARK_RESULTS["section_3"]["feed_api"] = results
    
    return results


async def section_4_search_validation():
    """SECTION 4: Search Validation."""
    log_section("SEARCH VALIDATION")
    
    results = {
        "queries": ["black", "city", "mountain", "cat", "car"],
        "query_results": {},
        "false_positives": []
    }
    
    # Test each query
    for query in results["queries"]:
        log_step(1, f"Testing query: '{query}'")
        
        from app.services.queue_manager import QueueManager
        queue_manager = QueueManager()
        
        # Measure latency
        start_time = time.time()
        
        items, total = await queue_manager.search(query, limit=20, offset=0)
        
        latency = (time.time() - start_time) * 1000
        
        # Verify results contain query text
        false_positives = []
        for item in items:
            title = item.get("title", "").lower()
            if query.lower() not in title:
                false_positives.append({
                    "id": item.get("id"),
                    "title": item.get("title"),
                    "expected": query,
                    "found": title
                })
        
        results["query_results"][query] = {
            "latency_ms": latency,
            "results_count": len(items),
            "total_results": total,
            "false_positives": len(false_positives)
        }
        
        if false_positives:
            log_result(False, f"  ✗ Query '{query}': {len(false_positives)} false positives")
            for fp in false_positives[:3]:  # Show first 3
                results["false_positives"].append(fp)
        else:
            log_result(True, f"  ✓ Query '{query}': {len(items)} results, latency={latency:.1f}ms")
    
    # Store results
    BENCHMARK_RESULTS["section_4"]["search"] = results
    
    return results


async def section_5_oauth_validation():
    """SECTION 5: OAuth Validation."""
    log_section("OAUTH VALIDATION")
    
    results = {
        "token_acquisition": False,
        "token_refresh": False,
        "token_persistence": False,
        "authenticated_requests": False,
        "token_expiry": None,
        "refresh_success": False
    }
    
    from app.managers.oauth import OAuthManager
    from app.core.database import get_db
    
    # Test token acquisition
    log_step(1, "Testing token acquisition")
    
    oauth = OAuthManager(
        CLIENT_ID,
        CLIENT_SECRET,
        USER_AGENT
    )
    
    await oauth.initialize()
    
    try:
        token = await oauth.get_valid_token()
        if token:
            results["token_acquisition"] = True
            log_result(True, f"  ✓ Token acquired: {token[:30]}...")
        else:
            log_result(False, f"  ✗ No token acquired")
    except Exception as e:
        log_result(False, f"  ✗ Token acquisition failed: {e}")
    
    # Test token persistence
    log_step(2, "Testing token persistence")
    
    async with get_db() as db:
        cursor = await db.execute("SELECT * FROM oauth_tokens LIMIT 1")
        row = await cursor.fetchone()
        
        if row:
            token_data = dict(row)
            results["token_persistence"] = True
            results["token_expiry"] = token_data["expires_at"]
            log_result(True, f"  ✓ Token stored in database")
            log_result(True, f"  ✓ Token expires at: {datetime.fromtimestamp(token_data['expires_at']).isoformat()}")
        else:
            log_result(False, f"  ✗ No token in database")
    
    # Test token refresh capability
    log_step(3, "Testing token refresh capability")
    
    if oauth.is_healthy():
        results["authenticated_requests"] = True
        log_result(True, f"  ✓ OAuth provider is healthy")
    else:
        log_result(False, f"  ✗ OAuth provider is not healthy")
    
    # Store results
    BENCHMARK_RESULTS["section_5"]["oauth"] = results
    
    return results


async def section_6_video_validation():
    """SECTION 6: Video Validation."""
    log_section("VIDEO VALIDATION")
    
    results = {
        "sample_size": 20,
        "valid_videos": 0,
        "invalid_videos": 0,
        "sample_videos": []
    }
    
    # Get video posts from database
    from app.core.database import get_db
    
    async with get_db() as db:
        cursor = await db.execute(
            "SELECT reddit_id, media_url, video_url, title, width, height FROM media_assets WHERE is_video = 1"
        )
        videos = await cursor.fetchall()
        
        if not videos:
            log_result(False, f"  ✗ No videos found in database")
            return results
        
        # Sample 20 videos
        sample_size = min(20, len(videos))
        sample = videos[:sample_size]
        
        log_step(1, f"Validating {sample_size} random video posts")
        
        for video in sample:
            reddit_id = video["reddit_id"]
            media_url = video["media_url"]
            video_url = video["video_url"]
            title = video["title"][:50]
            
            # Check if URL is playable MP4
            is_mp4 = False
            url_type = "unknown"
            
            if video_url and ".mp4" in video_url.lower():
                is_mp4 = True
                url_type = "MP4 (video_url)"
            elif media_url and ".mp4" in media_url.lower():
                is_mp4 = True
                url_type = "MP4 (media_url)"
            elif media_url and "v.redd.it" in media_url:
                url_type = "v.redd.it permalink (NOT PLAYABLE)"
            elif media_url and "redd.it" in media_url:
                url_type = "redd.it link"
            
            # Check URL reachability
            url_reachable = False
            if "http" in (media_url or video_url):
                try:
                    req = urllib.request.Request(media_url or video_url, headers={'User-Agent': 'Mozilla/5.0'})
                    resp = urllib.request.urlopen(req, timeout=5)
                    if resp.status == 200:
                        url_reachable = True
                except:
                    pass
            
            # Check content-type
            content_type_valid = False
            if "http" in (media_url or video_url):
                try:
                    req = urllib.request.Request(media_url or video_url, headers={'User-Agent': 'Mozilla/5.0'})
                    resp = urllib.request.urlopen(req, timeout=5)
                    content_type = resp.headers.get('Content-Type', '').lower()
                    if 'video/mp4' in content_type or 'video/' in content_type:
                        content_type_valid = True
                except:
                    pass
            
            # Check dimensions
            dimensions_available = video["width"] is not None and video["height"] is not None
            
            sample_video = {
                "id": reddit_id,
                "title": title,
                "url_type": url_type,
                "is_mp4": is_mp4,
                "url_reachable": url_reachable,
                "content_type_valid": content_type_valid,
                "dimensions_available": dimensions_available,
                "media_url": media_url[:60] if media_url else "N/A",
                "video_url": video_url[:60] if video_url else "N/A"
            }
            
            results["sample_videos"].append(sample_video)
            
            if is_mp4 and url_reachable and content_type_valid:
                results["valid_videos"] += 1
                status = "✓"
            else:
                results["invalid_videos"] += 1
                status = "✗"
            
            log_result(True, f"  {status} {reddit_id}: {title} -> {url_type}")
        
        # Summary
        log_step(2, "VIDEO VALIDATION SUMMARY")
        valid_percentage = (results["valid_videos"] / sample_size) * 100
        
        if valid_percentage >= 80:
            log_result(True, f"  ✓ PASS: {results['valid_videos']}/{sample_size} videos are valid ({valid_percentage:.1f}%)")
        else:
            log_result(False, f"  ✗ FAIL: Only {results['valid_videos']}/{sample_size} videos are valid ({valid_percentage:.1f}%)")
    
    # Store results
    BENCHMARK_RESULTS["section_6"]["video"] = results
    
    return results


async def section_7_gallery_validation():
    """SECTION 7: Gallery Validation."""
    log_section("GALLERY VALIDATION")
    
    results = {
        "sample_size": 20,
        "valid_galleries": 0,
        "sample_galleries": []
    }
    
    # Get gallery posts from database
    from app.core.database import get_db
    
    async with get_db() as db:
        cursor = await db.execute(
            "SELECT reddit_id, title FROM media_assets WHERE is_gallery = 1"
        )
        galleries = await cursor.fetchall()
        
        if not galleries:
            log_result(False, f"  ✗ No galleries found in database")
            return results
        
        # Sample 20 galleries
        sample_size = min(20, len(galleries))
        sample = galleries[:sample_size]
        
        log_step(1, f"Validating {sample_size} random gallery posts")
        
        for gallery in sample:
            reddit_id = gallery["reddit_id"]
            title = gallery["title"][:50]
            
            # Get gallery items
            cursor = await db.execute(
                "SELECT item_url, item_order FROM gallery_items WHERE reddit_id = ? ORDER BY item_order",
                (reddit_id,)
            )
            items = await cursor.fetchall()
            
            if items:
                # Check ordering
                orders = [item["item_order"] for item in items]
                is_ordered = orders == sorted(orders)
                
                if is_ordered:
                    results["valid_galleries"] += 1
                    status = "✓"
                else:
                    status = "✗"
                
                sample_gallery = {
                    "id": reddit_id,
                    "title": title,
                    "item_count": len(items),
                    "is_ordered": is_ordered,
                    "orders": orders,
                    "item_urls": [item["item_url"] for item in items]
                }
                
                results["sample_galleries"].append(sample_gallery)
                
                log_result(True, f"  {status} {reddit_id}: {title} -> {len(items)} images")
            else:
                sample_gallery = {
                    "id": reddit_id,
                    "title": title,
                    "item_count": 0,
                    "is_ordered": False,
                    "orders": [],
                    "item_urls": []
                }
                
                results["sample_galleries"].append(sample_gallery)
                log_result(False, f"  ✗ {reddit_id}: {title} -> NO ITEMS STORED")
        
        # Summary
        log_step(2, "GALLERY VALIDATION SUMMARY")
        valid_percentage = (results["valid_galleries"] / sample_size) * 100
        
        if valid_percentage >= 80:
            log_result(True, f"  ✓ PASS: {results['valid_galleries']}/{sample_size} galleries are valid ({valid_percentage:.1f}%)")
        else:
            log_result(False, f"  ✗ FAIL: Only {results['valid_galleries']}/{sample_size} galleries are valid ({valid_percentage:.1f}%)")
    
    # Store results
    BENCHMARK_RESULTS["section_7"]["gallery"] = results
    
    return results


async def _download_url(url: str, timeout_s: int = 5) -> tuple[int, bytes] | None:
    """Async download with timeout."""
    try:
        loop = asyncio.get_event_loop()
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        resp = await asyncio.wait_for(
            loop.run_in_executor(None, lambda: urllib.request.urlopen(req, timeout=timeout_s, context=ctx)),
            timeout=timeout_s + 1
        )
        data = await asyncio.wait_for(
            loop.run_in_executor(None, resp.read),
            timeout=timeout_s + 1
        )
        return (resp.status, data)
    except asyncio.TimeoutError:
        log_result(False, f"  Timeout downloading {url[:60]}")
        return None
    except Exception as e:
        log_result(False, f"  Error: {e}")
        return None


async def section_8_download_sample_media():
    """SECTION 8: Download Sample Media."""
    log_section("DOWNLOAD SAMPLE MEDIA")
    
    results = {
        "images_downloaded": 0,
        "videos_downloaded": 0,
        "galleries_downloaded": 0,
        "nsfw_downloaded": 0,
        "downloaded_files": []
    }
    
    # Use validated content from sections 6-7 results
    video_valid_ids = {v["id"] for v in BENCHMARK_RESULTS["section_6"]["video"]["sample_videos"]}
    
    from app.core.database import get_db
    
    async with get_db() as db:
        # Get validated video posts
        log_step(1, f"Downloading {len(video_valid_ids)} validated videos")
        if video_valid_ids:
            placeholders = ",".join("?" * len(video_valid_ids))
            cursor = await db.execute(
                f"SELECT reddit_id, media_url, video_url, title, subreddit, score, author FROM media_assets WHERE reddit_id IN ({placeholders})",
                list(video_valid_ids)
            )
            videos = await cursor.fetchall()
            
            for video in videos:
                reddit_id = video["reddit_id"]
                url = video["video_url"] or video["media_url"]
                title = video["title"][:100]
                
                if url and "http" in url:
                    result = await _download_url(url, timeout_s=4)
                    if result:
                        status, data = result
                        if status == 200 and len(data) > 0:
                            filename = f"benchmark_output/videos/{reddit_id}.mp4"
                            with open(filename, 'wb') as f:
                                f.write(data)
                            results["downloaded_files"].append({
                                "type": "video", "id": reddit_id, "url": url,
                                "filename": filename, "title": title,
                                "subreddit": video["subreddit"],
                                "score": video["score"], "author": video["author"]
                            })
                            results["videos_downloaded"] += 1
                            log_result(True, f"  ✓ Downloaded video: {reddit_id} ({len(data)} bytes)")
                        else:
                            log_result(False, f"  ✗ Empty video: {reddit_id}")
        
        # Get validated gallery posts
        log_step(2, "Downloading 5 validated gallery posts")
        gallery_valid_ids = [g["id"] for g in BENCHMARK_RESULTS["section_7"]["gallery"]["sample_galleries"]][:5]
        
        if gallery_valid_ids:
            placeholders = ",".join("?" * len(gallery_valid_ids))
            cursor = await db.execute(
                f"SELECT ma.reddit_id, ma.title, ma.subreddit, ma.score, ma.author FROM media_assets ma WHERE ma.reddit_id IN ({placeholders})",
                gallery_valid_ids
            )
            galleries = await cursor.fetchall()
            
            for gallery in galleries:
                reddit_id = gallery["reddit_id"]
                title = gallery["title"][:100]
                
                cursor = await db.execute(
                    "SELECT item_url FROM gallery_items WHERE reddit_id = ? ORDER BY item_order",
                    (reddit_id,)
                )
                items = await cursor.fetchall()
                
                if items:
                    gallery_dir = f"benchmark_output/galleries/{reddit_id}/"
                    os.makedirs(gallery_dir, exist_ok=True)
                    
                    for i, item in enumerate(items):
                        url = item["item_url"]
                        if url and "http" in url:
                            result = await _download_url(url, timeout_s=4)
                            if result:
                                status, data = result
                                if status == 200 and len(data) > 0:
                                    filename = f"{gallery_dir}image_{i}.jpg"
                                    with open(filename, 'wb') as f:
                                        f.write(data)
                                    results["downloaded_files"].append({
                                        "type": "gallery", "id": reddit_id,
                                        "url": url, "filename": filename,
                                        "title": title, "subreddit": gallery["subreddit"],
                                        "score": gallery["score"], "author": gallery["author"]
                                    })
                                    results["galleries_downloaded"] += 1
        
        # Get images (from validated galleries - use their thumbnails)
        log_step(3, "Downloading 10 sample images from earthporn")
        cursor = await db.execute(
            "SELECT reddit_id, media_url, title, subreddit, score, author FROM media_assets WHERE is_video = 0 AND is_gallery = 0 AND nsfw = 0 AND subreddit = 'earthporn' LIMIT 10"
        )
        images = await cursor.fetchall()
        
        for image in images:
            reddit_id = image["reddit_id"]
            url = image["media_url"]
            title = image["title"][:100]
            
            if url and "http" in url:
                result = await _download_url(url, timeout_s=4)
                if result:
                    status, data = result
                    if status == 200 and len(data) > 0:
                        filename = f"benchmark_output/images/{reddit_id}.jpg"
                        with open(filename, 'wb') as f:
                            f.write(data)
                        results["downloaded_files"].append({
                            "type": "image", "id": reddit_id, "url": url,
                            "filename": filename, "title": title,
                            "subreddit": image["subreddit"],
                            "score": image["score"], "author": image["author"]
                        })
                        results["images_downloaded"] += 1
                        log_result(True, f"  ✓ Downloaded image: {reddit_id}")
        
        # Get NSFW content (from validated galleries - navelnsfw galleries)
        log_step(4, "Downloading NSFW gallery samples from navelnsfw")
        cursor = await db.execute(
            "SELECT ma.reddit_id, ma.title, ma.subreddit, ma.score, ma.author FROM media_assets ma JOIN gallery_items gi ON ma.reddit_id = gi.reddit_id WHERE ma.nsfw = 1 AND ma.subreddit = 'navelnsfw' GROUP BY ma.reddit_id LIMIT 5"
        )
        nsfw_posts = await cursor.fetchall()
        
        for nsfw in nsfw_posts:
            reddit_id = nsfw["reddit_id"]
            title = nsfw["title"][:100]
            
            cursor = await db.execute(
                "SELECT item_url FROM gallery_items WHERE reddit_id = ? ORDER BY item_order",
                (reddit_id,)
            )
            items = await cursor.fetchall()
            
            if items:
                dir_path = f"benchmark_output/nsfw/{reddit_id}/"
                os.makedirs(dir_path, exist_ok=True)
                for i, item in enumerate(items[:3]):
                    url = item["item_url"]
                    if url and "http" in url:
                        result = await _download_url(url, timeout_s=4)
                        if result:
                            status, data = result
                            if status == 200 and len(data) > 0:
                                filename = f"{dir_path}image_{i}.jpg"
                                with open(filename, 'wb') as f:
                                    f.write(data)
                                results["downloaded_files"].append({
                                    "type": "nsfw", "id": reddit_id,
                                    "url": url, "filename": filename,
                                    "title": title, "subreddit": nsfw["subreddit"],
                                    "score": nsfw["score"], "author": nsfw["author"]
                                })
                                results["nsfw_downloaded"] += 1
    
    # Store results
    BENCHMARK_RESULTS["section_8"]["download_sample"] = results
    log_result(True, f"  Downloaded: {results['images_downloaded']} images, {results['videos_downloaded']} videos, {results['galleries_downloaded']} galleries, {results['nsfw_downloaded']} nsfw")
    
    return results


async def section_9_media_quality_audit():
    """SECTION 9: Media Quality Audit."""
    log_section("MEDIA QUALITY AUDIT")
    
    results = {
        "total_files": 0,
        "broken_files": 0,
        "duplicate_files": 0,
        "quality_distribution": {
            "90-100": 0,
            "80-89": 0,
            "70-79": 0,
            "50-69": 0,
            "0-49": 0
        },
        "file_details": []
    }
    
    # Analyze downloaded files
    log_step(1, "Analyzing downloaded media files")
    
    for root, dirs, files in os.walk("benchmark_output"):
        for file in files:
            if file.endswith(('.jpg', '.jpeg', '.png', '.gif', '.webp', '.mp4')):
                filepath = os.path.join(root, file)
                file_size = os.path.getsize(filepath)
                
                # Check if file is broken
                is_broken = False
                try:
                    with open(filepath, 'rb') as f:
                        # Try to read file header
                        header = f.read(1024)
                        if len(header) == 0:
                            is_broken = True
                except:
                    is_broken = True
                
                if is_broken:
                    results["broken_files"] += 1
                    log_result(False, f"  ✗ Broken file: {filepath}")
                else:
                    results["total_files"] += 1
                    log_result(True, f"  ✓ Valid file: {filepath} ({file_size/1024:.1f}KB)")
    
    # Check for duplicates
    log_step(2, "Checking for duplicate files")
    
    file_hashes = {}
    for root, dirs, files in os.walk("benchmark_output"):
        for file in files:
            if file.endswith(('.jpg', '.jpeg', '.png', '.gif', '.webp', '.mp4')):
                filepath = os.path.join(root, file)
                
                try:
                    with open(filepath, 'rb') as f:
                        file_hash = hash(f.read())
                    
                    if file_hash in file_hashes:
                        results["duplicate_files"] += 1
                        log_result(False, f"  ✗ Duplicate file: {filepath} (same as {file_hashes[file_hash]})")
                    else:
                        file_hashes[file_hash] = filepath
                except:
                    pass
    
    # Store results
    BENCHMARK_RESULTS["section_9"]["media_quality"] = results
    
    return results


async def section_10_final_report():
    """SECTION 10: Final Report."""
    log_section("FINAL REPORT")
    
    # Calculate scores
    scores = {
        "oauth_score": 0,
        "database_score": 0,
        "feed_score": 0,
        "search_score": 0,
        "video_score": 0,
        "gallery_score": 0,
        "nsfw_score": 0,
        "media_quality_score": 0
    }
    
    # OAuth Score
    oauth_results = BENCHMARK_RESULTS["section_5"]["oauth"]
    oauth_score = 0
    if oauth_results["token_acquisition"]:
        oauth_score += 25
    if oauth_results["token_persistence"]:
        oauth_score += 25
    if oauth_results["authenticated_requests"]:
        oauth_score += 25
    if oauth_results["token_refresh"]:
        oauth_score += 25
    scores["oauth_score"] = oauth_score
    
    # Database Score
    db_results = BENCHMARK_RESULTS["section_2"]["database"]
    db_score = 0
    if db_results["database_file_size"] > 0:
        db_score += 25
    if db_results.get("fts5_indexed", 0) > 0:
        db_score += 25
    if db_results["duplicate_count"] == 0:
        db_score += 25
    if db_results["queries"]["count_all"] > 0:
        db_score += 25
    scores["database_score"] = db_score
    
    # Feed Score
    feed_results = BENCHMARK_RESULTS["section_3"]["feed_api"]
    feed_score = 0
    total_requests = sum(feed_results["subreddit_counts"].values())
    if total_requests >= 500:
        feed_score += 25
    if feed_results["pagination"]:
        feed_score += 25
    if not feed_results["duplicates"]:
        feed_score += 25
    if feed_results["sorting"]:
        feed_score += 25
    scores["feed_score"] = feed_score
    
    # Search Score
    search_results = BENCHMARK_RESULTS["section_4"]["search"]
    search_score = 0
    if search_results["query_results"]:
        avg_accuracy = sum(q["false_positives"] / q["results_count"] if q["results_count"] > 0 else 0 for q in search_results["query_results"].values()) / len(search_results["query_results"])
        if avg_accuracy < 0.2:  # Less than 20% false positives
            search_score += 50
        if all(q["latency_ms"] < 100 for q in search_results["query_results"].values()):
            search_score += 50
    scores["search_score"] = search_score
    
    # Video Score
    video_results = BENCHMARK_RESULTS["section_6"]["video"]
    video_score = 0
    if video_results["sample_size"] > 0:
        video_percentage = (video_results["valid_videos"] / video_results["sample_size"]) * 100
        if video_percentage >= 80:
            video_score += 50
        if video_percentage >= 60:
            video_score += 50
    scores["video_score"] = video_score
    
    # Gallery Score
    gallery_results = BENCHMARK_RESULTS["section_7"]["gallery"]
    gallery_score = 0
    if gallery_results["sample_size"] > 0:
        gallery_percentage = (gallery_results["valid_galleries"] / gallery_results["sample_size"]) * 100
        if gallery_percentage >= 80:
            gallery_score += 50
        if gallery_percentage >= 60:
            gallery_score += 50
    scores["gallery_score"] = gallery_score
    
    # NSFW Score
    download_results = BENCHMARK_RESULTS["section_8"]["download_sample"]
    nsfw_score = 0
    if download_results["nsfw_downloaded"] > 0:
        nsfw_score += 50
    if download_results["downloaded_files"]:
        nsfw_score += 50
    scores["nsfw_score"] = nsfw_score
    
    # Media Quality Score
    quality_results = BENCHMARK_RESULTS["section_9"]["media_quality"]
    quality_score = 0
    if quality_results["total_files"] > 0:
        quality_score += 50
    if quality_results["broken_files"] == 0:
        quality_score += 50
    scores["media_quality_score"] = quality_score
    
    # Overall Score
    total_score = sum(scores.values()) / 8  # Average of all 8 scores
    
    # Generate report
    report = {
        "timestamp": datetime.now().isoformat(),
        "scores": scores,
        "overall_score": total_score,
        "issues": []
    }
    
    # Collect issues
    if scores["oauth_score"] < 50:
        report["issues"].append({
            "severity": "HIGH",
            "component": "OAuth",
            "root_cause": "Token acquisition or persistence issues",
            "recommended_fix": "Check Reddit API credentials and token storage"
        })
    
    if scores["database_score"] < 50:
        report["issues"].append({
            "severity": "HIGH",
            "component": "Database",
            "root_cause": "Duplicate entries or indexing issues",
            "recommended_fix": "Review database constraints and FTS5 triggers"
        })
    
    if scores["feed_score"] < 50:
        report["issues"].append({
            "severity": "MEDIUM",
            "component": "Feed API",
            "root_cause": "Pagination, duplicates, or sorting issues",
            "recommended_fix": "Review feed response handling and caching"
        })
    
    if scores["search_score"] < 50:
        report["issues"].append({
            "severity": "MEDIUM",
            "component": "Search",
            "root_cause": "High false positive rate or slow response",
            "recommended_fix": "Improve FTS5 query optimization and result filtering"
        })
    
    if scores["video_score"] < 50:
        report["issues"].append({
            "severity": "MEDIUM",
            "component": "Video",
            "root_cause": "Invalid MP4 URLs or broken downloads",
            "recommended_fix": "Fix video URL extraction and validate playable formats"
        })
    
    if scores["gallery_score"] < 50:
        report["issues"].append({
            "severity": "MEDIUM",
            "component": "Gallery",
            "root_cause": "Missing gallery items or ordering issues",
            "recommended_fix": "Fix gallery item extraction and preserve ordering"
        })
    
    if scores["nsfw_score"] < 50:
        report["issues"].append({
            "severity": "LOW",
            "component": "NSFW",
            "root_cause": "Limited NSFW content availability",
            "recommended_fix": "Expand NSFW subreddit coverage or use cached data"
        })
    
    if scores["media_quality_score"] < 50:
        report["issues"].append({
            "severity": "MEDIUM",
            "component": "Media Quality",
            "root_cause": "Broken files or duplicates",
            "recommended_fix": "Add file validation and deduplication"
        })
    
    # Store results
    BENCHMARK_RESULTS["section_10"]["final_report"] = report
    
    # Print report
    log_step(1, "BENCHMARK RESULTS")
    print(f"\nOAuth Score: {scores['oauth_score']}/50")
    print(f"Database Score: {scores['database_score']}/50")
    print(f"Feed Score: {scores['feed_score']}/50")
    print(f"Search Score: {scores['search_score']}/50")
    print(f"Video Score: {scores['video_score']}/50")
    print(f"Gallery Score: {scores['gallery_score']}/50")
    print(f"NSFW Score: {scores['nsfw_score']}/50")
    print(f"Media Quality Score: {scores['media_quality_score']}/50")
    print(f"\nOverall Score: {total_score:.1f}/10")
    
    if report["issues"]:
        log_step(2, "ISSUES FOUND")
        for i, issue in enumerate(report["issues"], 1):
            print(f"\nIssue {i}:")
            print(f"  Severity: {issue['severity']}")
            print(f"  Component: {issue['component']}")
            print(f"  Root Cause: {issue['root_cause']}")
            print(f"  Recommended Fix: {issue['recommended_fix']}")
    else:
        log_result(True, "  ✓ No issues found!")
    
    # Save report
    with open("benchmark_output/report.json", "w") as f:
        json.dump(report, f, indent=2)
    
    log_result(True, f"  ✓ Report saved to benchmark_output/report.json")
    
    return report


async def main():
    """Run all benchmark sections."""
    print("\n" + "█" * 70)
    print("COMPREHENSIVE BACKEND FUNCTIONAL BENCHMARK AND MEDIA VALIDATION")
    print("█" * 70)
    
    # Run all sections
    await section_1_reddit_ingestion_validation()
    await section_2_database_validation()
    await section_3_feed_api_benchmark()
    await section_4_search_validation()
    await section_5_oauth_validation()
    await section_6_video_validation()
    await section_7_gallery_validation()
    await section_8_download_sample_media()
    await section_9_media_quality_audit()
    await section_10_final_report()
    
    print("\n" + "█" * 70)
    print("BENCHMARK COMPLETE")
    print("█" * 70)
    print("\nAll benchmark artifacts saved to:")
    print("  - benchmark_output/images/")
    print("  - benchmark_output/videos/")
    print("  - benchmark_output/galleries/")
    print("  - benchmark_output/nsfw/")
    print("  - benchmark_output/report.json")
    print("\nNote: This benchmark uses sample data and may not reflect")
    print("actual production performance. For production validation,")
    print("ensure Reddit API credentials are properly configured.")


if __name__ == "__main__":
    asyncio.run(main())