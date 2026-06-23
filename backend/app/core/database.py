import os
from dotenv import load_dotenv
import aiosqlite
from contextlib import asynccontextmanager
from typing import Optional

load_dotenv()

DATABASE_PATH: str = os.getenv("DATABASE_PATH", "./data/redslide.db")


async def init_db():
    """Initialize the database with core schema."""
    db_dir = os.path.dirname(DATABASE_PATH)
    if db_dir:
        os.makedirs(db_dir, exist_ok=True)
    
    async with aiosqlite.connect(DATABASE_PATH) as db:
        await db.executescript("""
            CREATE TABLE IF NOT EXISTS oauth_tokens (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                access_token TEXT NOT NULL,
                refresh_token TEXT,
                token_type TEXT NOT NULL DEFAULT 'bearer',
                expires_at INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                last_refreshed INTEGER NOT NULL,
                success_count INTEGER DEFAULT 0,
                failure_count INTEGER DEFAULT 0,
                last_success INTEGER,
                last_failure INTEGER
            );
            
            CREATE INDEX IF NOT EXISTS idx_expires ON oauth_tokens(expires_at);
            
            CREATE TABLE IF NOT EXISTS media_assets (
                id TEXT PRIMARY KEY,
                reddit_id TEXT UNIQUE NOT NULL,
                permalink TEXT UNIQUE NOT NULL,
                media_url TEXT NOT NULL,
                title TEXT NOT NULL,
                author TEXT NOT NULL,
                score INTEGER NOT NULL,
                subreddit TEXT NOT NULL,
                video_url TEXT,
                thumbnail_url TEXT,
                created_utc INTEGER NOT NULL,
                is_video BOOLEAN NOT NULL,
                is_gallery BOOLEAN NOT NULL,
                nsfw BOOLEAN NOT NULL,
                quality_score INTEGER DEFAULT 50,
                source_provider TEXT NOT NULL DEFAULT 'reddit_oauth',
                width INTEGER,
                height INTEGER,
                duration INTEGER,
                created_at INTEGER NOT NULL,
                last_seen INTEGER NOT NULL,
                UNIQUE(reddit_id, media_url)
            );
            
            CREATE INDEX IF NOT EXISTS idx_subreddit_created ON media_assets(subreddit, created_utc DESC);
            CREATE INDEX IF NOT EXISTS idx_created_utc ON media_assets(created_utc DESC);
            CREATE INDEX IF NOT EXISTS idx_source_provider ON media_assets(source_provider);
            CREATE INDEX IF NOT EXISTS idx_quality ON media_assets(quality_score DESC);
            
            CREATE TABLE IF NOT EXISTS gallery_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                reddit_id TEXT NOT NULL,
                item_url TEXT NOT NULL,
                item_order INTEGER NOT NULL,
                width INTEGER,
                height INTEGER,
                created_at INTEGER NOT NULL,
                FOREIGN KEY (reddit_id) REFERENCES media_assets(reddit_id),
                UNIQUE(reddit_id, item_order)
            );
            
            CREATE INDEX IF NOT EXISTS idx_gallery_reddit_id ON gallery_items(reddit_id);
            CREATE INDEX IF NOT EXISTS idx_gallery_order ON gallery_items(reddit_id, item_order);
            
            
            CREATE TABLE IF NOT EXISTS media_queue (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                reddit_post_id TEXT NOT NULL UNIQUE,
                position INTEGER NOT NULL,
                added_at INTEGER NOT NULL,
                group_id INTEGER,
                FOREIGN KEY (reddit_post_id) REFERENCES media_assets(id)
            );
            
            CREATE INDEX IF NOT EXISTS idx_position ON media_queue(position);
            CREATE INDEX IF NOT EXISTS idx_added ON media_queue(added_at);
            
            CREATE TABLE IF NOT EXISTS subreddit_configs (
                subreddit TEXT PRIMARY KEY,
                enabled BOOLEAN NOT NULL DEFAULT TRUE,
                provider TEXT NOT NULL DEFAULT 'reddit_oauth',
                sort_mode TEXT NOT NULL DEFAULT 'hot',
                refresh_interval INTEGER NOT NULL DEFAULT 300
            );
            
            CREATE INDEX IF NOT EXISTS idx_enabled ON subreddit_configs(enabled);
            
            CREATE VIRTUAL TABLE IF NOT EXISTS media_search
            USING fts5(
                reddit_post_id,
                title,
                subreddit,
                author
            );
            
            CREATE TRIGGER IF NOT EXISTS after_media_insert
            AFTER INSERT ON media_assets
            BEGIN
                INSERT INTO media_search (reddit_post_id, title, subreddit, author)
                VALUES (NEW.reddit_id, NEW.title, NEW.subreddit, NEW.author);
            END;
            
            CREATE TRIGGER IF NOT EXISTS after_media_update
            AFTER UPDATE ON media_assets
            WHEN NEW.reddit_id != OLD.reddit_id OR
                 NEW.title != OLD.title OR
                 NEW.subreddit != OLD.subreddit
            BEGIN
                DELETE FROM media_search WHERE reddit_post_id = OLD.reddit_id;
                INSERT INTO media_search (reddit_post_id, title, subreddit, author)
                VALUES (NEW.reddit_id, NEW.title, NEW.subreddit, NEW.author);
            END;
            
            CREATE TRIGGER IF NOT EXISTS after_media_delete
            AFTER DELETE ON media_assets
            BEGIN
                DELETE FROM media_search WHERE reddit_post_id = OLD.reddit_id;
            END;
        """)
        await db.commit()
    
        # Apply schema migrations (safe to run repeatedly)
        await _apply_migrations(db)


async def _apply_migrations(db):
    """Apply schema migrations that cannot be in the initial CREATE script."""
    migrations = [
        "ALTER TABLE subreddit_configs ADD COLUMN last_hot_after TEXT",
        "ALTER TABLE subreddit_configs ADD COLUMN last_new_after TEXT",
        "ALTER TABLE subreddit_configs ADD COLUMN last_top_after TEXT",
    ]
    for sql in migrations:
        try:
            await db.execute(sql)
            await db.commit()
        except Exception:
            pass  # Column already exists


@asynccontextmanager
async def get_db():
    """Get database connection."""
    async with aiosqlite.connect(DATABASE_PATH) as db:
        db.row_factory = aiosqlite.Row
        yield db