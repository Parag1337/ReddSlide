import asyncio
import time
import os
import aiosqlite

async def validate_backend():
    """Run comprehensive backend validation."""
    results = {"passed": 0, "failed": 0, "tests": []}
    
    os.makedirs('data', exist_ok=True)
    os.environ['DATABASE_PATH'] = './data/redslide.db'
    
    print("=" * 50)
    print("RedSlide Backend Validation")
    print("=" * 50)
    
    # Test 1: Database initialization
    try:
        from app.core.database import init_db, DATABASE_PATH
        await init_db()
        results["tests"].append(("Database initialization", True, "Schema created"))
        results["passed"] += 1
    except Exception as e:
        results["tests"].append(("Database initialization", False, str(e)))
        results["failed"] += 1
    
    # Test 2: Schema validation
    async with aiosqlite.connect(DATABASE_PATH) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute("SELECT name FROM sqlite_master WHERE type='table'")
        tables = [row["name"] async for row in cursor]
        expected = ["oauth_tokens", "media_assets", "media_queue", "subreddit_configs", "media_search"]
        missing = [t for t in expected if t not in tables]
        if not missing:
            results["tests"].append(("Schema tables", True, f"All {len(expected)} tables present"))
            results["passed"] += 1
        else:
            results["tests"].append(("Schema tables", False, f"Missing: {missing}"))
            results["failed"] += 1
    
    # Test 3: FTS5 search
    async with aiosqlite.connect(DATABASE_PATH) as db:
        db.row_factory = aiosqlite.Row
        
        # Insert test data
        for i in range(100):
            await db.execute('''
                INSERT OR IGNORE INTO media_assets 
                (id, reddit_id, permalink, media_url, title, author, score, subreddit,
                 video_url, created_utc, is_video, is_gallery, nsfw, quality_score,
                 source_provider, width, height, created_at, last_seen)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''', (
                f'test_{i}', f'reddit_{i}', f'/r/test/post{i}', f'https://example.com/img{i}.jpg',
                f'Test Photo {i} - Beautiful Landscape Nature', f'user_{i % 10}', 
                100 + i, ['EarthPorn', 'spaceporn', 'Animewallpaper', 'wallpapers'][i % 4],
                None, int(time.time()) - i, 0, 0, 0, 50 + (i % 50), 'reddit_oauth',
                1920 + (i % 100), 1080 + (i % 100), int(time.time()), int(time.time())
            ))
        await db.commit()
        
        # Test FTS5
        cursor = await db.execute('SELECT COUNT(*) as count FROM media_search')
        row = await cursor.fetchone()
        if row["count"] == 100:
            results["tests"].append(("FTS5 indexing", True, f"{row['count']} items indexed"))
            results["passed"] += 1
        else:
            results["tests"].append(("FTS5 indexing", False, f"Expected 100, got {row['count']}"))
            results["failed"] += 1
    
    # Test 4: Queue operations
    async with aiosqlite.connect(DATABASE_PATH) as db:
        db.row_factory = aiosqlite.Row
        
        for i in range(50):
            await db.execute('INSERT OR IGNORE INTO media_queue (reddit_post_id, position, added_at) VALUES (?, ?, ?)',
                (f'reddit_{i}', i, int(time.time())))
        await db.commit()
        
        cursor = await db.execute('SELECT COUNT(*) as count FROM media_queue')
        row = await cursor.fetchone()
        if row["count"] == 50:
            results["tests"].append(("Queue operations", True, f"{row['count']} items in queue"))
            results["passed"] += 1
        else:
            results["tests"].append(("Queue operations", False, f"Expected 50, got {row['count']}"))
            results["failed"] += 1
    
    # Test 5: Search performance
    async with aiosqlite.connect(DATABASE_PATH) as db:
        db.row_factory = aiosqlite.Row
        
        start = time.time()
        cursor = await db.execute('''
            SELECT ma.* FROM media_assets ma, media_search ms
            WHERE ma.reddit_id = ms.reddit_post_id AND media_search MATCH ?
            LIMIT 20
        ''', ('landscape',))
        rows = await cursor.fetchall()
        search_time = (time.time() - start) * 1000
        
        if search_time < 10 and len(rows) > 0:
            results["tests"].append(("Search performance", True, f"{search_time:.2f}ms"))
            results["passed"] += 1
        else:
            results["tests"].append(("Search performance", False, f"{search_time:.2f}ms, {len(rows)} results"))
            results["failed"] += 1
    
    # Test 6: FastAPI app loads
    try:
        os.environ['REDDIT_CLIENT_ID'] = 'test'
        os.environ['REDDIT_CLIENT_SECRET'] = 'test'
        from app.main import app
        results["tests"].append(("FastAPI loading", True, f"{len(app.routes)} routes registered"))
        results["passed"] += 1
    except Exception as e:
        results["tests"].append(("FastAPI loading", False, str(e)))
        results["failed"] += 1
    
    # Print results
    print("\nTest Results:")
    for name, passed, detail in results["tests"]:
        status = "✓" if passed else "✗"
        print(f"  {status} {name}: {detail}")
    
    print(f"\n{results['passed']} passed, {results['failed']} failed")
    
    if results["failed"] == 0:
        print("\n✓ Backend validation PASSED - Ready for Flutter development")
    else:
        print(f"\n✗ Backend validation FAILED - {results['failed']} issues to resolve")
    
    return results["failed"] == 0

if __name__ == "__main__":
    success = asyncio.run(validate_backend())
    exit(0 if success else 1)