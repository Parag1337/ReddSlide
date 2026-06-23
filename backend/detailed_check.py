import asyncio
import aiosqlite

DATABASE_PATH = "/home/parag/Projects/Application/redslide/backend/data/redslide.db"

async def check_db():
    """Check database structure and data."""
    print("=" * 60)
    print("DATABASE STRUCTURE CHECK")
    print("=" * 60)
    
    async with aiosqlite.connect(DATABASE_PATH) as db:
        db.row_factory = aiosqlite.Row
        
        # Get all tables
        cursor = await db.execute("SELECT name FROM sqlite_master WHERE type='table'")
        tables = await cursor.fetchall()
        
        print(f"\nFound {len(tables)} tables:")
        for i, table in enumerate(tables):
            print(f"  {i+1}. {table['name']}")
        
        # Check media_assets table structure
        print("\nChecking media_assets table structure:")
        cursor = await db.execute("PRAGMA table_info(media_assets)")
        columns = await cursor.fetchall()
        for col in columns:
            print(f"  {col['name']} ({col['type']})")
        
        # Check media_assets data
        print("\nChecking media_assets data:")
        cursor = await db.execute("SELECT COUNT(*) as count FROM media_assets")
        count = await cursor.fetchone()
        print(f"  Total rows: {count['count']}")
        
        if count['count'] > 0:
            cursor = await db.execute("SELECT * FROM media_assets LIMIT 3")
            rows = await cursor.fetchall()
            print(f"  Sample rows:")
            for row in rows:
                print(f"    ID: {row['id']}")
                print(f"    Title: {row['title'][:50]}...")
                print(f"    Subreddit: {row['subreddit']}")
                print(f"    Author: {row['author']}")
                print(f"    Score: {row['score']}")
                print(f"    NSFW: {row['nsfw']}")
                print(f"    is_video: {row['is_video']}")
                print(f"    is_gallery: {row['is_gallery']}")
                print(f"    Quality: {row['quality_score']}")
                print()
        
        # Check media_queue table
        print("\nChecking media_queue table:")
        cursor = await db.execute("SELECT COUNT(*) as count FROM media_queue")
        count = await cursor.fetchone()
        print(f"  Total rows: {count['count']}")
        
        # Check gallery_items table
        print("\nChecking gallery_items table:")
        cursor = await db.execute("SELECT COUNT(*) as count FROM gallery_items")
        count = await cursor.fetchone()
        print(f"  Total rows: {count['count']}")
        
        # Check FTS5 table
        print("\nChecking FTS5 table:")
        cursor = await db.execute("SELECT COUNT(*) as count FROM media_search")
        count = await cursor.fetchone()
        print(f"  Total rows: {count['count']}")
        
        # Check oauth_tokens table
        print("\nChecking oauth_tokens table:")
        cursor = await db.execute("SELECT COUNT(*) as count FROM oauth_tokens")
        count = await cursor.fetchone()
        print(f"  Total rows: {count['count']}")
        
        # Check subreddit_configs table
        print("\nChecking subreddit_configs table:")
        cursor = await db.execute("SELECT COUNT(*) as count FROM subreddit_configs")
        count = await cursor.fetchone()
        print(f"  Total rows: {count['count']}")
        
        if count['count'] > 0:
            cursor = await db.execute("SELECT * FROM subreddit_configs")
            rows = await cursor.fetchall()
            print(f"  Subreddit configs:")
            for row in rows:
                print(f"    {row['subreddit']}: enabled={row['enabled']}, provider={row['provider']}, sort={row['sort_mode']}")

if __name__ == "__main__":
    asyncio.run(check_db())