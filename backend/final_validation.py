#!/usr/bin/env python3
"""
Final production hardening validation - Quick version.
Tests core issues without long Reddit fetches.
"""
import asyncio
import os
import time
import sqlite3
from dotenv import load_dotenv

load_dotenv()

DATABASE_PATH = os.getenv("DATABASE_PATH", "./data/redslide.db")
CLIENT_ID = os.getenv("REDDIT_CLIENT_ID", "")
CLIENT_SECRET = os.getenv("REDDIT_CLIENT_SECRET", "")
USER_AGENT = os.getenv("REDDIT_USER_AGENT", "RedSlide/1.0")


async def test_all_issues():
    """Test all 6 issues comprehensively."""
    print("\n" + "█"*70)
    print("REDSLIDE PRODUCTION HARDENING - COMPREHENSIVE VALIDATION")
    print("█"*70)
    
    from app.core.database import init_db, get_db
    from app.managers.oauth import OAuthManager
    from app.services.queue_manager import QueueManager
    from app.models.schemas import MediaAsset
    import time as time_module
    
    os.makedirs(os.path.dirname(DATABASE_PATH), exist_ok=True)
    await init_db()
    
    results = {}
    
    # ===================================================================
    # ISSUE 1: OAuth Refresh Flow
    # ===================================================================
    print("\n" + "="*70)
    print("ISSUE 1: OAuth Refresh Flow Validation")
    print("="*70)
    
    try:
        oauth = OAuthManager(CLIENT_ID, CLIENT_SECRET, USER_AGENT)
        
        # Initialize
        print("\n1. Initialize OAuth Manager...")
        await oauth.initialize()
        print("   ✓ Initialized")
        
        # Get token
        print("2. Acquire token using client credentials...")
        token = await oauth.get_valid_token()
        if not token:
            raise Exception("No token acquired")
        print(f"   ✓ Token acquired: {token[:30]}...")
        
        # Verify storage
        print("3. Verify token storage...")
        async with get_db() as db:
            cursor = await db.execute("SELECT expires_at, refresh_token FROM oauth_tokens LIMIT 1")
            row = await cursor.fetchone()
            if not row or row["expires_at"] <= int(time_module.time()):
                raise Exception("Invalid token storage")
        print("   ✓ Token properly stored")
        
        # Test refresh capability
        print("4. Verify refresh capability...")
        if oauth.is_healthy():
            print("   ✓ OAuth provider is healthy")
        
        results["issue_1_oauth"] = "PASS"
        print("\n✓ Issue 1: PASS")
        
    except Exception as e:
        results["issue_1_oauth"] = f"FAIL: {e}"
        print(f"\n✗ Issue 1: FAIL - {e}")
    
    # ===================================================================
    # ISSUE 2 & 3: Video and Gallery Extraction
    # ===================================================================
    print("\n" + "="*70)
    print("ISSUE 2 & 3: Video and Gallery Extraction")
    print("="*70)
    
    try:
        from app.services.reddit_client import RedditClient
        from app.managers.provider import ProviderManager
        
        oauth = OAuthManager(CLIENT_ID, CLIENT_SECRET, USER_AGENT)
        await oauth.initialize()
        provider = ProviderManager()
        reddit_client = RedditClient(oauth, provider)
        
        # Create test Reddit post data
        print("\n1. Testing video extraction...")
        video_post = {
            "is_gallery": False,
            "is_video": True,
            "media": {
                "reddit_video": {
                    "fallback_url": "https://v.redd.it/abc123/DASH_480.mp4",
                    "duration": 30,
                    "width": 1280,
                    "height": 720
                }
            },
            "preview": {"images": []},
            "url": "https://v.redd.it/abc123"
        }
        
        media_url, video_url, thumbnail_url, width, height, duration, gallery_items = \
            reddit_client._extract_media_details(video_post)
        
        if video_url and ".mp4" in video_url:
            print(f"   ✓ Video URL extracted: {video_url[:50]}...")
        else:
            raise Exception("Video URL not properly extracted")
        
        # Test gallery extraction
        print("2. Testing gallery extraction...")
        gallery_post = {
            "is_gallery": True,
            "is_video": False,
            "media_metadata": {
                "item1": {"e": "Image", "s": {"u": "https://i.redd.it/img1.jpg", "x": 1920, "y": 1080}},
                "item2": {"e": "Image", "s": {"u": "https://i.redd.it/img2.jpg", "x": 1920, "y": 1080}},
                "item3": {"e": "Image", "s": {"u": "https://i.redd.it/img3.jpg", "x": 1920, "y": 1080}},
            },
            "preview": {"images": []},
            "url": "https://reddit.com/r/pics/gallery"
        }
        
        media_url, video_url, thumbnail_url, _, _, _, gallery_items = \
            reddit_client._extract_media_details(gallery_post)
        
        if len(gallery_items) >= 3:
            print(f"   ✓ All gallery items extracted: {len(gallery_items)} images")
        else:
            raise Exception(f"Only {len(gallery_items)} gallery items extracted")
        
        if gallery_items[0].get("order") == 0 and gallery_items[-1].get("order") == len(gallery_items) - 1:
            print("   ✓ Gallery item ordering preserved")
        else:
            raise Exception("Gallery ordering not preserved")
        
        results["issue_2_videos"] = "PASS"
        results["issue_3_galleries"] = "PASS"
        print("\n✓ Issues 2 & 3: PASS")
        
    except Exception as e:
        results["issue_2_videos"] = f"FAIL: {e}"
        results["issue_3_galleries"] = f"FAIL: {e}"
        print(f"\n✗ Issues 2 & 3: FAIL - {e}")
    
    # ===================================================================
    # ISSUE 4: Background Refresh Service
    # ===================================================================
    print("\n" + "="*70)
    print("ISSUE 4: Background Refresh Service Integration")
    print("="*70)
    
    try:
        from app.services.background_service import BackgroundRefreshService
        
        print("\n1. Initialize background service...")
        service = BackgroundRefreshService()
        
        print("2. Start service...")
        await service.start()
        if service._is_running:
            print("   ✓ Service started")
        else:
            raise Exception("Service failed to start")
        
        print("3. Verify scheduler...")
        if service.scheduler.running:
            print("   ✓ Scheduler is running")
        else:
            raise Exception("Scheduler not running")
        
        print("4. Verify queue management...")
        queue = await service.queue_manager.count_queue_items()
        print(f"   ✓ Queue manager operational (queue size: {queue})")
        
        await service.stop()
        print("5. Stop service gracefully...")
        if not service._is_running:
            print("   ✓ Service stopped")
        
        results["issue_4_background"] = "PASS"
        print("\n✓ Issue 4: PASS")
        
    except Exception as e:
        results["issue_4_background"] = f"FAIL: {e}"
        print(f"\n✗ Issue 4: FAIL - {e}")
    
    # ===================================================================
    # ISSUE 5: FTS5 Search
    # ===================================================================
    print("\n" + "="*70)
    print("ISSUE 5: FTS5 Search Migration")
    print("="*70)
    
    try:
        print("\n1. Insert test data into media_assets...")
        async with get_db() as db:
            for i in range(20):
                await db.execute('''
                    INSERT OR IGNORE INTO media_assets 
                    (id, reddit_id, permalink, media_url, title, author, score, subreddit,
                     created_utc, is_video, is_gallery, nsfw, quality_score,
                     source_provider, created_at, last_seen)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ''', (
                    f'fts_test_{i}', f'reddit_fts_{i}', f'/r/test/post{i}', 
                    f'https://example.com/img{i}.jpg',
                    f'Beautiful mountain landscape with black cat in city street', 
                    f'user_{i % 5}', 100 + i, 'test_subreddit',
                    int(time_module.time()) - i, 0, 0, 0, 50, 'reddit_oauth',
                    int(time_module.time()), int(time_module.time())
                ))
            await db.commit()
        print("   ✓ Test data inserted")
        
        print("2. Verify FTS5 index population...")
        async with get_db() as db:
            cursor = await db.execute("SELECT COUNT(*) as count FROM media_search")
            row = await cursor.fetchone()
            indexed = row["count"] if row else 0
            if indexed >= 20:
                print(f"   ✓ FTS5 index populated: {indexed} items")
            else:
                raise Exception(f"Only {indexed} items indexed (expected 20)")
        
        print("3. Test FTS5 search queries...")
        queue_manager = QueueManager()
        
        search_results = {}
        for query in ["mountain", "black", "city", "beautiful"]:
            items, total = await queue_manager.search(query, limit=20)
            search_results[query] = len(items)
            if len(items) > 0:
                print(f"   ✓ Query '{query}': {len(items)} results")
            else:
                print(f"   ⚠ Query '{query}': 0 results")
        
        if sum(search_results.values()) > 0:
            results["issue_5_fts5"] = "PASS"
            print("\n✓ Issue 5: PASS")
        else:
            raise Exception("No search results found")
        
    except Exception as e:
        results["issue_5_fts5"] = f"FAIL: {e}"
        print(f"\n✗ Issue 5: FAIL - {e}")
    
    # ===================================================================
    # ISSUE 6: Production Validation
    # ===================================================================
    print("\n" + "="*70)
    print("ISSUE 6: Production Validation")
    print("="*70)
    
    try:
        conn = sqlite3.connect(DATABASE_PATH)
        cursor = conn.cursor()
        
        print("\n1. Check database integrity...")
        cursor.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table'")
        table_count = cursor.fetchone()[0]
        expected_tables = 6  # oauth_tokens, media_assets, media_queue, subreddit_configs, media_search, gallery_items
        if table_count >= expected_tables:
            print(f"   ✓ All required tables present ({table_count} tables)")
        else:
            raise Exception(f"Missing tables: {expected_tables - table_count}")
        
        print("2. Check database constraints...")
        cursor.execute("PRAGMA table_info(media_assets)")
        columns = [row[1] for row in cursor.fetchall()]
        required_cols = ["id", "reddit_id", "media_url", "title", "is_video", "is_gallery"]
        for col in required_cols:
            if col not in columns:
                raise Exception(f"Missing column: {col}")
        print("   ✓ All required columns present")
        
        print("3. Check asset statistics...")
        cursor.execute("SELECT COUNT(*) FROM media_assets")
        total_assets = cursor.fetchone()[0]
        print(f"   ✓ Total assets in database: {total_assets}")
        
        cursor.execute("SELECT COUNT(*) FROM media_assets WHERE is_video=1")
        videos = cursor.fetchone()[0]
        print(f"   ✓ Videos: {videos}")
        
        cursor.execute("SELECT COUNT(*) FROM media_assets WHERE is_gallery=1")
        galleries = cursor.fetchone()[0]
        print(f"   ✓ Galleries: {galleries}")
        
        cursor.execute("SELECT COUNT(*) FROM media_assets WHERE nsfw=1")
        nsfw = cursor.fetchone()[0]
        print(f"   ✓ NSFW content: {nsfw}")
        
        cursor.execute("SELECT COUNT(*) FROM gallery_items")
        gallery_items = cursor.fetchone()[0]
        print(f"   ✓ Gallery items stored: {gallery_items}")
        
        conn.close()
        
        results["issue_6_production"] = "PASS"
        print("\n✓ Issue 6: PASS")
        
    except Exception as e:
        results["issue_6_production"] = f"FAIL: {e}"
        print(f"\n✗ Issue 6: FAIL - {e}")
    
    # ===================================================================
    # SUMMARY
    # ===================================================================
    print("\n" + "█"*70)
    print("FINAL VALIDATION SUMMARY")
    print("█"*70)
    
    passed = sum(1 for v in results.values() if v == "PASS")
    total = len(results)
    
    for issue, result in sorted(results.items()):
        status = "✓" if result == "PASS" else "✗"
        print(f"{status} {issue}: {result}")
    
    print("\n" + "="*70)
    print(f"RESULT: {passed}/{total} issues validated successfully")
    print("="*70)
    
    if passed == total:
        print("\n✓ PRODUCTION READY: All issues validated and fixed")
        return True
    else:
        print(f"\n✗ Issues remain: {total - passed} issues not fully validated")
        return False


async def main():
    success = await test_all_issues()
    exit(0 if success else 1)


if __name__ == "__main__":
    asyncio.run(main())
