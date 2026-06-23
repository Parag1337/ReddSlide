import asyncio
import aiosqlite

DATABASE_PATH = "/home/parag/Projects/Application/redslide/backend/data/redslide.db"

async def check_db():
    """Check database structure."""
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
            print(f"  {i+1}. {table}")
        
        # Check media_assets table structure
        print("\nChecking media_assets table structure:")
        cursor = await db.execute("PRAGMA table_info(media_assets)")
        columns = await cursor.fetchall()
        for col in columns:
            print(f"  {col[1]} ({col[2]})")
        
        # Check media_assets data
        print("\nChecking media_assets data:")
        cursor = await db.execute("SELECT COUNT(*) FROM media_assets")
        count = await cursor.fetchone()
        print(f"  Total rows: {count[0]}")
        
        if count[0] > 0:
            cursor = await db.execute("SELECT * FROM media_assets LIMIT 3")
            rows = await cursor.fetchall()
            print(f"  Sample rows:")
            for row in rows:
                print(f"    Row: {row}")
        
        # Check media_queue table
        print("\nChecking media_queue table:")
        cursor = await db.execute("SELECT COUNT(*) FROM media_queue")
        count = await cursor.fetchone()
        print(f"  Total rows: {count[0]}")
        
        # Check gallery_items table
        print("\nChecking gallery_items table:")
        cursor = await db.execute("SELECT COUNT(*) FROM gallery_items")
        count = await cursor.fetchone()
        print(f"  Total rows: {count[0]}")

if __name__ == "__main__":
    asyncio.run(check_db())