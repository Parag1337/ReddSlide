import asyncio
import aiosqlite
from dotenv import load_dotenv
import os

load_dotenv()

DATABASE_PATH = os.getenv("DATABASE_PATH", "/home/parag/Projects/Application/redslide/backend/data/redslide.db")

async def check_database():
    """Check database contents and structure."""
    print("=" * 60)
    print("DATABASE INSPECTION")
    print("=" * 60)
    
    async with aiosqlite.connect(DATABASE_PATH) as db:
        db.row_factory = aiosqlite.Row
        
        # List tables
        print("\n1. Tables in database:")
        cursor = await db.execute("SELECT name FROM sqlite_master WHERE type='table'")
        tables = await cursor.fetchall()
        for table in tables:
            print(f"   - {table['name']}")
        
        # Check media_assets table
        print("\n2. media_assets table:")
        cursor = await db.execute("SELECT COUNT(*) as count FROM media_assets")
        row = await cursor.fetchone()
        print(f"   - Total assets: {row['count']}")
        
        if row['count'] > 0:
            # Get sample data
            cursor = await db.execute("SELECT * FROM media_assets LIMIT 5")
            sample = await cursor.fetchall()
            print(f"   - Sample assets:")
            for asset in sample:
                print(f"     ID: {asset['id'][:50]}...")
                print(f"     Title: {asset['title'][:50]}...")
                print(f"     Subreddit: {asset['subreddit']}")
                print(f"     Author: {asset['author']}")
                print(f"     Score: {asset['score']}")
                print(f"     NSFW: {asset['nsfw']}")
                print(f"     is_video: {asset['is_video']}")
                print(f"     is_gallery: {asset['is_gallery']}")
                print(f"     Quality: {asset['quality_score']}")
                print()
        
        # Check media_queue table
        print("3. media_queue table:")
        cursor = await db.execute("SELECT COUNT(*) as count FROM media_queue")
        row = await cursor.fetchone()
        print(f"   - Queue items: {row['count']}")
        
        # Check gallery_items table
        print("4. gallery_items table:")
        cursor = await db.execute("SELECT COUNT(*) as count FROM gallery_items")
        row = await cursor.fetchone()
        print(f"   - Gallery items: {row['count']}")
        
        # Check media_search table (FTS5)
        print("5. media_search table (FTS5):")
        cursor = await db.execute("SELECT COUNT(*) as count FROM media_search")
        row = await cursor.fetchone()
        print(f"   - FTS5 entries: {row['count']}")
        
        # Check oauth_tokens table
        print("6. oauth_tokens table:")
        cursor = await db.execute("SELECT COUNT(*) as count FROM oauth_tokens")
        row = await cursor.fetchone()
        print(f"   - OAuth tokens: {row['count']}")
        
        if row['count'] > 0:
            cursor = await db.execute("SELECT * FROM oauth_tokens LIMIT 1")
            token = await cursor.fetchone()
            if token:
                print(f"   - Sample token:")
                print(f"     ID: {token['id']}")
                print(f"     Expires at: {token['expires_at']}")
                print(f"     Created at: {token['created_at']}")
                print(f"     Success count: {token['success_count']}")
                print(f"     Failure count: {token['failure_count']}")
        
        # Check for duplicates
        print("\n7. Duplicate checks:")
        
        # Check duplicate reddit_post_id
        cursor = await db.execute("SELECT reddit_id, COUNT(*) as count FROM media_assets GROUP BY reddit_id HAVING COUNT(*) > 1")
        duplicates = await cursor.fetchall()
        if duplicates:
            print(f"   ✗ Found {len(duplicates)} duplicate reddit_id values")
            for dup in duplicates[:5]:
                print(f"     - {dup['reddit_id']}: {dup['count']} occurrences")
        else:
            print("   ✓ No duplicate reddit_id values")
        
        # Check duplicate permalink
        cursor = await db.execute("SELECT permalink, COUNT(*) as count FROM media_assets GROUP BY permalink HAVING COUNT(*) > 1")
        permalink_duplicates = await cursor.fetchall()
        if permalink_duplicates:
            print(f"   ✗ Found {len(permalink_duplicates)} duplicate permalink values")
        else:
            print("   ✓ No duplicate permalink values")
        
        # Check recent data
        print("\n8. Recent data analysis:")
        cursor = await db.execute("SELECT subreddit, COUNT(*) as count FROM media_assets GROUP BY subreddit ORDER BY count DESC")
        subreddit_counts = await cursor.fetchall()
        print("   Subreddit distribution:")
        for sub in subreddit_counts:
            print(f"     - r/{sub['subreddit']}: {sub['count']} assets")
        
        # Check for recent posts (last 24 hours)
        import time
        yesterday = int(time.time()) - 86400
        cursor = await db.execute("SELECT COUNT(*) as count FROM media_assets WHERE created_at > ?", (yesterday,))
        row = await cursor.fetchone()
        print(f"   - Assets from last 24 hours: {row['count']}")
        
        # Check quality distribution
        print("\n9. Quality score distribution:")
        cursor = await db.execute("SELECT quality_score, COUNT(*) as count FROM media_assets GROUP BY quality_score ORDER BY quality_score")
        quality_dist = await cursor.fetchall()
        for quality in quality_dist:
            print(f"     - Quality {quality['quality_score']}: {quality['count']} assets")
        
        # Check video and gallery stats
        print("\n10. Media type statistics:")
        cursor = await db.execute("SELECT is_video, COUNT(*) as count FROM media_assets GROUP BY is_video")
        video_stats = await cursor.fetchall()
        for stat in video_stats:
            media_type = "Videos" if stat['is_video'] else "Images"
            print(f"     - {media_type}: {stat['count']}")
        
        cursor = await db.execute("SELECT is_gallery, COUNT(*) as count FROM media_assets GROUP BY is_gallery")
        gallery_stats = await cursor.fetchall()
        for stat in gallery_stats:
            media_type = "Galleries" if stat['is_gallery'] else "Single images"
            print(f"     - {media_type}: {stat['count']}")
        
        cursor = await db.execute("SELECT nsfw, COUNT(*) as count FROM media_assets GROUP BY nsfw")
        nsfw_stats = await cursor.fetchall()
        for stat in nsfw_stats:
            media_type = "NSFW" if stat['nsfw'] else "SFW"
            print(f"     - {media_type}: {stat['count']}")

if __name__ == "__main__":
    asyncio.run(check_database())