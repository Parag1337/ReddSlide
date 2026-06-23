import asyncio
import aiosqlite

DATABASE_PATH = "/home/parag/Projects/Application/redslide/backend/data/redslide.db"

async def test_connection():
    """Test database connection."""
    print(f"Trying to connect to: {DATABASE_PATH}")
    
    try:
        async with aiosqlite.connect(DATABASE_PATH) as db:
            print("✓ Connected successfully!")
            
            # Test a simple query
            cursor = await db.execute("SELECT name FROM sqlite_master WHERE type='table'")
            tables = await cursor.fetchall()
            print(f"✓ Found {len(tables)} tables")
            
            for table in tables:
                print(f"  - {table['name']}")
                
    except Exception as e:
        print(f"✗ Error: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    asyncio.run(test_connection())