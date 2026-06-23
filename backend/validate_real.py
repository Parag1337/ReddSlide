#!/usr/bin/env python3
"""Complete production validation script."""
import os
import time
import sqlite3
import urllib.request
import asyncio
from dotenv import load_dotenv

load_dotenv()

DATABASE_PATH = os.getenv("DATABASE_PATH", "./data/redslide.db")
CLIENT_ID = os.getenv("REDDIT_CLIENT_ID", "")
CLIENT_SECRET = os.getenv("REDDIT_CLIENT_SECRET", "")
USER_AGENT = os.getenv("REDDIT_USER_AGENT", "RedSlide/1.0")

SUBREDDITS = ["pics", "wallpapers", "earthporn", "cityporn", "natureisfuckinglit", "interestingasfuck"]


def fetch_with_praw():
    import praw
    
    reddit = praw.Reddit(
        client_id=CLIENT_ID,
        client_secret=CLIENT_SECRET,
        user_agent=USER_AGENT
    )
    
    results = {"total_fetched": 0, "assets": [], "videos": 0, "galleries": 0}
    
    for sub in SUBREDDITS:
        try:
            subreddit = reddit.subreddit(sub)
            posts = list(subreddit.hot(limit=20))
            
            for post in posts:
                url = getattr(post, 'url', '')
                if not url:
                    continue
                
                is_image = url.endswith(('.jpg', '.jpeg', '.png', '.gif', '.webp'))
                is_video = hasattr(post, 'is_video') and post.is_video
                
                # Get preview dimensions
                preview = getattr(post, 'preview', {}) or {}
                source = preview.get('images', [{}])[0].get('source', {})
                width = getattr(post, 'width', None) or source.get('width', 1920)
                height = getattr(post, 'height', None) or source.get('height', 1080)
                
                # Skip small images
                if not is_video and (width < 800 or height < 600):
                    continue
                
                results["assets"].append({
                    "reddit_id": post.id,
                    "permalink": f"https://reddit.com{post.permalink}",
                    "media_url": url,
                    "title": post.title,
                    "author": post.author.name if post.author else "unknown",
                    "score": post.score,
                    "subreddit": sub,
                    "is_video": is_video,
                    "is_gallery": False,
                    "nsfw": post.over_18,
                    "video_url": None,
                    "thumbnail_url": source.get('url'),
                    "width": width,
                    "height": height,
                    "duration": None
                })
                if is_video:
                    results["videos"] += 1
            
            results["total_fetched"] += len(posts)
            print(f"  {sub}: {len(posts)} posts fetched")
        except Exception as e:
            print(f"Error fetching {sub}: {e}")
    
    return results


def main():
    print("=" * 50)
    print("RedSlide Production Validation")
    print("=" * 50)
    
    os.makedirs(os.path.dirname(DATABASE_PATH), exist_ok=True)
    
    print("\n[STEP 1-2] OAuth + Reddit Fetch...")
    results = fetch_with_praw()
    
    print(f"\nTotal: {len(results['assets'])} assets ({results['videos']} videos)")
    
    conn = sqlite3.connect(DATABASE_PATH)
    
    stored = 0
    for asset in results["assets"]:
        try:
            conn.execute("""
                INSERT OR IGNORE INTO media_assets 
                (id, reddit_id, permalink, media_url, title, author, score, subreddit,
                 video_url, thumbnail_url, created_utc, is_video, is_gallery, nsfw, quality_score,
                 source_provider, width, height, duration, created_at, last_seen)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                f"{asset['subreddit']}_{asset['reddit_id']}",
                asset['reddit_id'],
                asset['permalink'],
                asset['media_url'],
                asset['title'],
                asset['author'],
                asset['score'],
                asset['subreddit'],
                asset['video_url'],
                asset['thumbnail_url'],
                int(time.time()),
                asset['is_video'],
                asset['is_gallery'],
                asset['nsfw'],
                70,
                asset['subreddit'],
                asset['width'],
                asset['height'],
                asset['duration'],
                int(time.time()),
                int(time.time())
            ))
            stored += 1
        except:
            pass
    
    conn.commit()
    
    print(f"\n[STEP 3] Database Validation...")
    cursor = conn.execute('SELECT COUNT(*) FROM media_assets')
    total = cursor.fetchone()[0]
    
    cursor = conn.execute('SELECT COUNT(*) FROM media_assets WHERE is_video=1')
    videos = cursor.fetchone()[0]
    
    cursor = conn.execute('SELECT COUNT(*) FROM media_assets WHERE nsfw=1')
    nsfw = cursor.fetchone()[0]
    
    print(f"Total: {total}, Videos: {videos}, NSFW: {nsfw}")
    
    print("\n[STEP 4] Media URL Validation (20 random)...")
    cursor = conn.execute('SELECT media_url, title FROM media_assets WHERE media_url LIKE "%i.redd.it%" ORDER BY RANDOM() LIMIT 20')
    valid = 0
    for row in cursor.fetchall():
        try:
            req = urllib.request.Request(row[0], headers={'User-Agent': 'Mozilla/5.0'})
            resp = urllib.request.urlopen(req, timeout=5)
            if resp.status == 200:
                valid += 1
        except:
            pass
    print(f"Valid URLs: {valid}/20")
    
    print("\n[STEP 5] Search Validation...")
    queries = ['city', 'nature', 'earth']
    for q in queries:
        cursor = conn.execute('SELECT * FROM media_search WHERE media_search MATCH ?', (q,))
        count = len(cursor.fetchall())
        print(f"  '{q}': {count} results")
    
    conn.close()
    print("\n=== VALIDATION COMPLETE ===")


if __name__ == "__main__":
    main()