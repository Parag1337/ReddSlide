#!/usr/bin/env python3
"""Comprehensive issue analysis and testing."""
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


async def test_oauth_flow():
    """Test Issue 1: OAuth refresh flow."""
    print("\n" + "=" * 60)
    print("ISSUE 1: OAuth Refresh Flow Validation")
    print("=" * 60)
    
    from app.core.database import init_db, DATABASE_PATH
    from app.managers.oauth import OAuthManager
    
    os.makedirs(os.path.dirname(DATABASE_PATH), exist_ok=True)
    await init_db()
    
    oauth = OAuthManager(CLIENT_ID, CLIENT_SECRET, USER_AGENT)
    
    try:
        # Test 1: Initialize (should load existing or fail gracefully)
        print("1. Testing initialization...")
        await oauth.initialize()
        print("   ✓ Initialization succeeded")
    except Exception as e:
        print(f"   ✗ Initialization failed: {e}")
        return False
    
    try:
        # Test 2: Get token (should fail if no token exists)
        print("2. Testing get_valid_token()...")
        token = await oauth.get_valid_token()
        if token:
            print(f"   ✓ Got token: {token[:20]}...")
        else:
            print("   ✗ No token available")
            return False
    except Exception as e:
        print(f"   ✗ Token retrieval failed: {e}")
        return False
    
    try:
        # Test 3: Check stored token
        print("3. Verifying token storage...")
        from app.core.database import get_db
        async with get_db() as db:
            cursor = await db.execute("SELECT * FROM oauth_tokens LIMIT 1")
            row = await cursor.fetchone()
            if row:
                token_data = dict(row)
                print(f"   ✓ Token stored with expiry: {token_data['expires_at']}")
            else:
                print("   ✗ No token in database")
                return False
    except Exception as e:
        print(f"   ✗ Token verification failed: {e}")
        return False
    
    print("\n✓ OAuth flow tests completed")
    return True


async def test_video_extraction():
    """Test Issue 2: Video extraction."""
    print("\n" + "=" * 60)
    print("ISSUE 2: Video Extraction (v.redd.it URLs)")
    print("=" * 60)
    
    import praw
    
    reddit = praw.Reddit(client_id=CLIENT_ID, client_secret=CLIENT_SECRET, user_agent=USER_AGENT)
    
    print("1. Fetching video posts from r/videos...")
    video_posts = []
    for post in reddit.subreddit("videos").hot(limit=50):
        if post.is_video:
            video_posts.append(post)
            if len(video_posts) >= 5:
                break
    
    if not video_posts:
        print("   ✗ No video posts found")
        return False
    
    print(f"   ✓ Found {len(video_posts)} video posts")
    
    print("\n2. Analyzing video extraction...")
    for i, post in enumerate(video_posts):
        print(f"\n   Post {i+1}: {post.title[:50]}...")
        print(f"   - URL: {post.url}")
        print(f"   - is_video: {post.is_video}")
        
        # Check for v.redd.it
        if "v.redd.it" in post.url:
            print(f"   ✓ v.redd.it URL detected")
        
        # Check media structure
        if post.media:
            media = post.media
            if "reddit_video" in media:
                rv = media["reddit_video"]
                print(f"   - Fallback URL: {rv.get('fallback_url', 'N/A')[:60]}...")
                print(f"   - Duration: {rv.get('duration', 'N/A')}")
            else:
                print(f"   - Media keys: {list(media.keys())}")
        
        # Check preview
        if post.preview:
            print(f"   - Preview available: Yes")
    
    print("\n✓ Video extraction analysis completed")
    return True


async def test_gallery_extraction():
    """Test Issue 3: Gallery extraction."""
    print("\n" + "=" * 60)
    print("ISSUE 3: Gallery Extraction")
    print("=" * 60)
    
    import praw
    
    reddit = praw.Reddit(client_id=CLIENT_ID, client_secret=CLIENT_SECRET, user_agent=USER_AGENT)
    
    print("1. Fetching gallery posts...")
    gallery_posts = []
    for post in reddit.subreddit("pics").hot(limit=100):
        if post.is_gallery:
            gallery_posts.append(post)
            if len(gallery_posts) >= 3:
                break
    
    if not gallery_posts:
        print("   ✗ No gallery posts found")
        return False
    
    print(f"   ✓ Found {len(gallery_posts)} gallery posts")
    
    print("\n2. Analyzing gallery extraction...")
    for i, post in enumerate(gallery_posts):
        print(f"\n   Gallery {i+1}: {post.title[:50]}...")
        print(f"   - is_gallery: {post.is_gallery}")
        
        # Check media_metadata
        if hasattr(post, 'media_metadata') and post.media_metadata:
            print(f"   - Total items: {len(post.media_metadata)}")
            for idx, (key, item) in enumerate(post.media_metadata.items()):
                e = item.get("e", "unknown")
                print(f"     Item {idx+1}: type={e}, key={key}")
                if e == "Image" and "s" in item:
                    u = item["s"].get("u", "N/A")
                    print(f"       URL: {u[:60]}...")
        else:
            print(f"   - No media_metadata available")
    
    print("\n✓ Gallery extraction analysis completed")
    return True


async def test_fts5_search():
    """Test Issue 5: FTS5 search."""
    print("\n" + "=" * 60)
    print("ISSUE 5: FTS5 Search Migration")
    print("=" * 60)
    
    from app.core.database import init_db, get_db, DATABASE_PATH
    
    os.makedirs(os.path.dirname(DATABASE_PATH), exist_ok=True)
    await init_db()
    
    # Insert test data
    async with get_db() as db:
        print("1. Inserting test data...")
        for i in range(20):
            await db.execute('''
                INSERT OR IGNORE INTO media_assets 
                (id, reddit_id, permalink, media_url, title, author, score, subreddit,
                 created_utc, is_video, is_gallery, nsfw, quality_score,
                 source_provider, created_at, last_seen)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''', (
                f'test_{i}', f'reddit_{i}', f'/r/test/post{i}', f'https://example.com/img{i}.jpg',
                f'Beautiful mountain landscape with black cat in city', f'user_{i % 5}', 
                100 + i, 'earthporn',
                int(time.time()) - i, 0, 0, 0, 50, 'reddit_oauth',
                int(time.time()), int(time.time())
            ))
        await db.commit()
        print("   ✓ Inserted 20 test items")
    
    # Test search
    print("\n2. Testing FTS5 searches...")
    test_queries = ["mountain", "black", "city", "landscape"]
    
    async with get_db() as db:
        for query in test_queries:
            try:
                cursor = await db.execute('''
                    SELECT ma.* FROM media_assets ma, media_search ms
                    WHERE ma.reddit_id = ms.reddit_post_id AND ms.title MATCH ?
                    LIMIT 10
                ''', (query,))
                rows = await cursor.fetchall()
                print(f"   - Query '{query}': {len(rows)} results")
                if not rows:
                    print(f"     ✗ No results for '{query}'")
            except Exception as e:
                print(f"   ✗ Search failed: {e}")
    
    # Check FTS5 table
    print("\n3. Checking FTS5 index...")
    async with get_db() as db:
        cursor = await db.execute("SELECT COUNT(*) as count FROM media_search")
        row = await cursor.fetchone()
        print(f"   - Items in media_search index: {row['count'] if row else 0}")
    
    print("\n✓ FTS5 search analysis completed")
    return True


async def main():
    """Run all tests."""
    print("\nRedSlide Production Hardening - Issue Analysis")
    print("=" * 60)
    
    results = {
        "OAuth": await test_oauth_flow(),
        "Videos": await test_video_extraction(),
        "Galleries": await test_gallery_extraction(),
        "FTS5": await test_fts5_search(),
    }
    
    print("\n" + "=" * 60)
    print("Summary")
    print("=" * 60)
    for test, result in results.items():
        status = "✓ PASS" if result else "✗ FAIL"
        print(f"{test}: {status}")


if __name__ == "__main__":
    asyncio.run(main())
