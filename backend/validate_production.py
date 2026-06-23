#!/usr/bin/env python3
"""Production validation runner."""
import os
import time
import sqlite3
import urllib.request
import json
from dotenv import load_dotenv

load_dotenv()

DATABASE_PATH = os.getenv("DATABASE_PATH", "./data/redslide.db")
CLIENT_ID = os.getenv("REDDIT_CLIENT_ID", "")
CLIENT_SECRET = os.getenv("REDDIT_CLIENT_SECRET", "")
USER_AGENT = os.getenv("REDDIT_USER_AGENT", "RedSlide/1.0")

SUBREDDITS = ["pics", "wallpapers", "earthporn", "cityporn", "natureisfuckinglit", "interestingasfuck"]

def run():
    os.makedirs(os.path.dirname(DATABASE_PATH), exist_ok=True)
    
    print("=" * 60)
    print("RedSlide Production Validation Report")
    print("=" * 60)
    
    # Initialize DB
    import asyncio
    from app.core.database import init_db
    asyncio.run(init_db())
    
    conn = sqlite3.connect(DATABASE_PATH)
    conn.row_factory = sqlite3.Row
    
    # Fetch
    import praw
    reddit = praw.Reddit(client_id=CLIENT_ID, client_secret=CLIENT_SECRET, user_agent=USER_AGENT)
    
    total_fetched = 0
    for sub in SUBREDDITS:
        try:
            posts = list(reddit.subreddit(sub).hot(limit=20))
            total_fetched += len(posts)
            for post in posts:
                try:
                    url = getattr(post, 'url', '')
                    if not url or not url.endswith(('.jpg', '.jpeg', '.png', '.gif', '.webp')):
                        continue
                    conn.execute('''
                        INSERT OR IGNORE INTO media_assets 
                        (id, reddit_id, permalink, media_url, title, author, score, subreddit,
                         video_url, thumbnail_url, created_utc, is_video, is_gallery, nsfw, quality_score,
                         source_provider, width, height, duration, created_at, last_seen)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ''', (
                        f"{sub}_{post.id}", post.id, f"https://reddit.com{post.permalink}", url,
                        post.title[:500], post.author.name if post.author else "unknown", post.score, sub,
                        None, None, int(getattr(post, 'created_utc', time.time())), False, False, post.over_18, 70,
                        "reddit_oauth", getattr(post, 'width', 1920), getattr(post, 'height', 1080), None,
                        int(time.time()), int(time.time())
                    ))
                except:
                    pass
        except Exception as e:
            print(f"  Error {sub}: {e}")
    
    conn.commit()
    
    # Stats
    cursor = conn.execute('SELECT COUNT(*) as c FROM media_assets')
    total = cursor.fetchone()['c']
    
    cursor = conn.execute('SELECT COUNT(*) as c FROM media_assets WHERE is_video=1')
    videos = cursor.fetchone()['c']
    
    cursor = conn.execute('SELECT COUNT(*) as c FROM media_assets WHERE nsfw=1')
    nsfw = cursor.fetchone()['c']
    
    cursor = conn.execute('SELECT subreddit, COUNT(*) as c FROM media_assets GROUP BY subreddit')
    sub_counts = {row['subreddit']: row['c'] for row in cursor.fetchall()}
    
    # URL test
    cursor = conn.execute('SELECT media_url, title FROM media_assets WHERE media_url LIKE "%i.redd.it%" ORDER BY RANDOM() LIMIT 10')
    valid = 0
    for row in cursor.fetchall():
        try:
            urllib.request.urlopen(urllib.request.Request(row['media_url'], headers={'User-Agent': 'Mozilla/5.0'}), timeout=3)
            valid += 1
        except:
            pass
    
    # Search test
    cursor = conn.execute('SELECT * FROM media_search WHERE media_search MATCH ?', ('earthporn',))
    search_earthporn = len(cursor.fetchall())
    
    conn.close()
    
    # Report
    print(f"\nDatabase: {total} assets")
    print(f"  - Videos: {videos}")
    print(f"  - NSFW: {nsfw}")
    print(f"  - Subreddit counts: {sub_counts}")
    print(f"\nURL validation: {valid}/10 valid")
    print(f"Search FTS5: {search_earthporn} 'earthporn' matches")
    print(f"\nFile size: {os.path.getsize(DATABASE_PATH)/1024:.1f}KB")

if __name__ == "__main__":
    run()