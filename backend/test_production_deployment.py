#!/usr/bin/env python3
"""
Production Deployment Test Suite - Comprehensive Validation
Tests all requirements for production readiness
"""
import asyncio
import os
import time
import sqlite3
import random
from dotenv import load_dotenv

load_dotenv()

DATABASE_PATH = os.getenv("DATABASE_PATH", "./data/redslide.db")
CLIENT_ID = os.getenv("REDDIT_CLIENT_ID", "")
CLIENT_SECRET = os.getenv("REDDIT_CLIENT_SECRET", "")
USER_AGENT = os.getenv("REDDIT_USER_AGENT", "RedSlide/1.0")

SUBREDDITS = ["pics", "wallpapers", "earthporn", "cityporn", "natureisfuckinglit", "interestingasfuck", "navelnsfw"]


class ProductionDeploymentTest:
    def __init__(self):
        self.results = {}
        self.start_time = time.time()
    
    async def test_2_fetch_and_validate(self):
        """Test 2: Fetch from 7 subreddits and verify 500+ assets"""
        print("\n" + "="*70)
        print("TEST 2: FETCH AND ASSET VALIDATION")
        print("="*70)
        print(f"\nFetching from {len(SUBREDDITS)} subreddits...")
        print(f"Target: 500+ assets (Better: 1000+)")
        
        import praw
        from app.core.database import init_db, get_db
        
        os.makedirs(os.path.dirname(DATABASE_PATH), exist_ok=True)
        await init_db()
        
        try:
            reddit = praw.Reddit(
                client_id=CLIENT_ID,
                client_secret=CLIENT_SECRET,
                user_agent=USER_AGENT
            )
            
            total_fetched = 0
            subreddit_stats = {}
            
            async with get_db() as db:
                for subreddit_name in SUBREDDITS:
                    print(f"\n  Fetching r/{subreddit_name}...", end=" ")
                    fetched_this_sub = 0
                    
                    try:
                        for post in reddit.subreddit(subreddit_name).hot(limit=100):
                            if not hasattr(post, 'url') or not post.url:
                                continue
                            
                            # Check for duplicates
                            cursor = await db.execute(
                                "SELECT id FROM media_assets WHERE reddit_id = ?",
                                (post.id,)
                            )
                            if await cursor.fetchone():
                                continue
                            
                            # Determine post type
                            is_video = post.is_video if hasattr(post, 'is_video') else False
                            is_gallery = hasattr(post, 'gallery_data') and post.gallery_data is not None
                            
                            # Insert post
                            try:
                                await db.execute('''
                                    INSERT OR IGNORE INTO media_assets 
                                    (id, reddit_id, permalink, media_url, title, author, score, subreddit,
                                     created_utc, is_video, is_gallery, nsfw, quality_score,
                                     source_provider, created_at, last_seen)
                                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                                ''', (
                                    f"{subreddit_name}_{post.id}",
                                    post.id,
                                    f"https://reddit.com{post.permalink}",
                                    post.url[:2000] if post.url else "unknown",
                                    post.title[:500],
                                    post.author.name if post.author else "unknown",
                                    post.score,
                                    subreddit_name,
                                    int(post.created_utc),
                                    int(is_video),
                                    int(is_gallery),
                                    int(post.over_18),
                                    70,
                                    "reddit_oauth",
                                    int(time.time()),
                                    int(time.time())
                                ))
                                fetched_this_sub += 1
                                total_fetched += 1
                            except:
                                pass
                    
                    except Exception as e:
                        print(f"ERROR: {e}")
                        continue
                    
                    subreddit_stats[subreddit_name] = fetched_this_sub
                    print(f"✓ {fetched_this_sub} posts")
                
                await db.commit()
            
            # Verify results
            conn = sqlite3.connect(DATABASE_PATH)
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            
            print("\n" + "-"*70)
            print("VERIFICATION")
            print("-"*70)
            
            cursor.execute("SELECT COUNT(*) as c FROM media_assets")
            total_assets = cursor.fetchone()["c"]
            print(f"\n✓ Total assets in database: {total_assets}")
            
            cursor.execute("SELECT COUNT(*) as c FROM media_assets WHERE is_video = 1")
            video_count = cursor.fetchone()["c"]
            print(f"✓ Videos: {video_count}")
            
            cursor.execute("SELECT COUNT(*) as c FROM media_assets WHERE is_gallery = 1")
            gallery_count = cursor.fetchone()["c"]
            print(f"✓ Galleries: {gallery_count}")
            
            cursor.execute("SELECT COUNT(*) as c FROM media_assets WHERE nsfw = 1")
            nsfw_count = cursor.fetchone()["c"]
            print(f"✓ NSFW content: {nsfw_count}")
            
            print("\nSubreddit Distribution:")
            for sub, count in sorted(subreddit_stats.items(), key=lambda x: x[1], reverse=True):
                print(f"  r/{sub}: {count}")
            
            conn.close()
            
            # Verify target
            if total_assets >= 1000:
                print(f"\n✓✓ EXCELLENT: {total_assets} assets (target: 1000+)")
                self.results["test_2"] = f"PASS - {total_assets} assets"
                return True
            elif total_assets >= 500:
                print(f"\n✓ GOOD: {total_assets} assets (target: 500+)")
                self.results["test_2"] = f"PASS - {total_assets} assets"
                return True
            else:
                print(f"\n✗ FAIL: {total_assets} assets (target: 500+)")
                self.results["test_2"] = f"FAIL - {total_assets} assets (need 500+)"
                return False
            
        except Exception as e:
            print(f"\n✗ FAIL: {e}")
            self.results["test_2"] = f"FAIL - {e}"
            return False
    
    async def test_3_video_validation(self):
        """Test 3: Verify 20 random videos have playable MP4 URLs"""
        print("\n" + "="*70)
        print("TEST 3: VIDEO URL VALIDATION")
        print("="*70)
        print("\nVerifying video URLs are playable MP4s (not just v.redd.it links)...")
        
        from app.core.database import get_db
        
        try:
            valid_videos = 0
            invalid_videos = 0
            sample_videos = []
            
            async with get_db() as db:
                # Get all videos
                cursor = await db.execute(
                    "SELECT reddit_id, media_url, video_url, title FROM media_assets WHERE is_video = 1"
                )
                videos = await cursor.fetchall()
                
                if not videos:
                    print("\n✗ No videos found in database")
                    self.results["test_3"] = "FAIL - No videos in database"
                    return False
                
                # Sample 20 random videos
                sample = random.sample(videos, min(20, len(videos)))
                
                print(f"\nValidating {len(sample)} random videos:")
                
                for video in sample:
                    reddit_id = video["reddit_id"]
                    media_url = video["media_url"]
                    video_url = video["video_url"]
                    title = video["title"][:50]
                    
                    # Check if URL is playable MP4
                    is_mp4 = False
                    url_type = "unknown"
                    
                    if video_url and ".mp4" in video_url.lower():
                        is_mp4 = True
                        url_type = "MP4 (video_url)"
                    elif media_url and ".mp4" in media_url.lower():
                        is_mp4 = True
                        url_type = "MP4 (media_url)"
                    elif media_url and "v.redd.it" in media_url:
                        url_type = "v.redd.it permalink (NOT PLAYABLE)"
                    elif media_url and "redd.it" in media_url:
                        url_type = "redd.it link"
                    
                    if is_mp4:
                        valid_videos += 1
                        status = "✓"
                    else:
                        invalid_videos += 1
                        status = "✗"
                    
                    sample_videos.append({
                        "id": reddit_id,
                        "title": title,
                        "url_type": url_type,
                        "is_mp4": is_mp4,
                        "media_url": media_url[:60] if media_url else "N/A",
                        "video_url": video_url[:60] if video_url else "N/A"
                    })
                    
                    print(f"  {status} {reddit_id}: {title} -> {url_type}")
                
                print("\n" + "-"*70)
                print("DETAILED RESULTS:")
                print("-"*70)
                for v in sample_videos:
                    print(f"\n  Reddit ID: {v['id']}")
                    print(f"  Title: {v['title']}")
                    print(f"  URL Type: {v['url_type']}")
                    print(f"  Media URL: {v['media_url']}")
                    print(f"  Video URL: {v['video_url']}")
            
            print("\n" + "-"*70)
            print(f"SUMMARY: {valid_videos}/{len(sample)} videos have playable MP4 URLs")
            print("-"*70)
            
            if valid_videos >= len(sample) * 0.8:  # 80% should be MP4
                print(f"\n✓ PASS: {valid_videos}/{len(sample)} videos are playable MP4s")
                self.results["test_3"] = f"PASS - {valid_videos}/{len(sample)} MP4s"
                return True
            else:
                print(f"\n✗ FAIL: Only {valid_videos}/{len(sample)} videos are playable MP4s")
                self.results["test_3"] = f"FAIL - {valid_videos}/{len(sample)} MP4s"
                return False
            
        except Exception as e:
            print(f"\n✗ FAIL: {e}")
            self.results["test_3"] = f"FAIL - {e}"
            return False
    
    async def test_4_gallery_validation(self):
        """Test 4: Verify 20 galleries have all images stored in order"""
        print("\n" + "="*70)
        print("TEST 4: GALLERY VALIDATION")
        print("="*70)
        print("\nVerifying galleries have all images stored in correct order...")
        
        from app.core.database import get_db
        
        try:
            valid_galleries = 0
            sample_galleries = []
            
            async with get_db() as db:
                # Get all galleries
                cursor = await db.execute(
                    "SELECT reddit_id, title FROM media_assets WHERE is_gallery = 1"
                )
                galleries = await cursor.fetchall()
                
                if not galleries:
                    print("\n✗ No galleries found in database")
                    self.results["test_4"] = "FAIL - No galleries in database"
                    return False
                
                # Sample 20 random galleries
                sample = random.sample(galleries, min(20, len(galleries)))
                
                print(f"\nValidating {len(sample)} random galleries:")
                
                for gallery in sample:
                    reddit_id = gallery["reddit_id"]
                    title = gallery["title"][:50]
                    
                    # Get gallery items
                    cursor = await db.execute(
                        "SELECT item_url, item_order FROM gallery_items WHERE reddit_id = ? ORDER BY item_order",
                        (reddit_id,)
                    )
                    items = await cursor.fetchall()
                    
                    if items:
                        # Check ordering
                        orders = [item["item_order"] for item in items]
                        is_ordered = orders == sorted(orders)
                        
                        if is_ordered:
                            valid_galleries += 1
                            status = "✓"
                        else:
                            status = "✗"
                        
                        sample_galleries.append({
                            "id": reddit_id,
                            "title": title,
                            "item_count": len(items),
                            "is_ordered": is_ordered,
                            "orders": orders
                        })
                        
                        print(f"  {status} {reddit_id}: {title} -> {len(items)} images")
                    else:
                        sample_galleries.append({
                            "id": reddit_id,
                            "title": title,
                            "item_count": 0,
                            "is_ordered": False,
                            "orders": []
                        })
                        print(f"  ✗ {reddit_id}: {title} -> NO ITEMS STORED")
                
                print("\n" + "-"*70)
                print("DETAILED RESULTS:")
                print("-"*70)
                for g in sample_galleries:
                    print(f"\n  Reddit ID: {g['id']}")
                    print(f"  Title: {g['title']}")
                    print(f"  Items: {g['item_count']}")
                    print(f"  Ordered: {'YES' if g['is_ordered'] else 'NO'}")
                    if g['item_count'] > 0:
                        print(f"  Item orders: {g['orders']}")
            
            print("\n" + "-"*70)
            print(f"SUMMARY: {valid_galleries}/{len(sample)} galleries have items in correct order")
            print("-"*70)
            
            if valid_galleries >= len(sample) * 0.8:  # 80% should have items
                print(f"\n✓ PASS: {valid_galleries}/{len(sample)} galleries properly stored")
                self.results["test_4"] = f"PASS - {valid_galleries}/{len(sample)} galleries valid"
                return True
            else:
                print(f"\n✗ FAIL: Only {valid_galleries}/{len(sample)} galleries are valid")
                self.results["test_4"] = f"FAIL - {valid_galleries}/{len(sample)} galleries valid"
                return False
            
        except Exception as e:
            print(f"\n✗ FAIL: {e}")
            self.results["test_4"] = f"FAIL - {e}"
            return False
    
    async def test_5_search_validation(self):
        """Test 5: Search queries return results that actually contain the query"""
        print("\n" + "="*70)
        print("TEST 5: SEARCH VALIDATION")
        print("="*70)
        print("\nVerifying search results genuinely contain query terms...")
        
        from app.core.database import get_db
        
        try:
            search_queries = ["car", "black", "city", "mountain", "cat"]
            all_valid = True
            
            print(f"\nTesting {len(search_queries)} search queries:")
            
            async with get_db() as db:
                for query in search_queries:
                    print(f"\n  Query: '{query}'")
                    
                    # Search using FTS5
                    cursor = await db.execute(
                        """SELECT ma.title, ma.reddit_id FROM media_assets ma
                           WHERE ma.reddit_id IN (
                               SELECT reddit_post_id FROM media_search 
                               WHERE media_search MATCH ?
                           )
                           LIMIT 10""",
                        (query,)
                    )
                    results = await cursor.fetchall()
                    
                    if not results:
                        print(f"    ✗ No results found")
                        all_valid = False
                        continue
                    
                    # Verify results contain the query term
                    valid_results = 0
                    invalid_results = 0
                    
                    for result in results:
                        title = result["title"].lower()
                        if query.lower() in title:
                            valid_results += 1
                            print(f"    ✓ {result['reddit_id']}: ...{title[max(0, title.find(query)-10):title.find(query)+len(query)+10]}...")
                        else:
                            invalid_results += 1
                            print(f"    ✗ {result['reddit_id']}: {title[:60]} (doesn't contain '{query}')")
                    
                    accuracy = (valid_results / len(results)) * 100
                    print(f"    Accuracy: {valid_results}/{len(results)} ({accuracy:.0f}%)")
                    
                    if accuracy < 80:
                        all_valid = False
            
            print("\n" + "-"*70)
            
            if all_valid:
                print(f"✓ PASS: Search results are accurate")
                self.results["test_5"] = "PASS - Search results accurate"
                return True
            else:
                print(f"✗ FAIL: Search results contain irrelevant items")
                self.results["test_5"] = "FAIL - Search accuracy < 80%"
                return False
            
        except Exception as e:
            print(f"\n✗ FAIL: {e}")
            self.results["test_5"] = f"FAIL - {e}"
            return False
    
    async def run_all(self):
        """Run all tests"""
        print("\n" + "█"*70)
        print("PRODUCTION DEPLOYMENT TEST SUITE")
        print("█"*70)
        
        results = {
            "Test 2: Asset Fetch": await self.test_2_fetch_and_validate(),
            "Test 3: Video URLs": await self.test_3_video_validation(),
            "Test 4: Gallery Storage": await self.test_4_gallery_validation(),
            "Test 5: Search Accuracy": await self.test_5_search_validation(),
        }
        
        # Summary
        print("\n" + "█"*70)
        print("TEST SUMMARY")
        print("█"*70)
        
        for test_name, result in results.items():
            status = "✓ PASS" if result else "✗ FAIL"
            print(f"{test_name}: {status}")
        
        print("\n" + "-"*70)
        print("DETAILED RESULTS:")
        print("-"*70)
        for test_name, result_msg in self.results.items():
            print(f"{test_name}: {result_msg}")
        
        passed = sum(1 for v in results.values() if v)
        total = len(results)
        
        print("\n" + "█"*70)
        if passed == total:
            print(f"✓ ALL TESTS PASSED ({passed}/{total})")
            print("STATUS: READY FOR PRODUCTION DEPLOYMENT")
        else:
            print(f"✗ SOME TESTS FAILED ({passed}/{total})")
            print("STATUS: REVIEW FAILURES BEFORE DEPLOYMENT")
        print("█"*70 + "\n")
        
        return passed == total


async def main():
    tester = ProductionDeploymentTest()
    success = await tester.run_all()
    exit(0 if success else 1)


if __name__ == "__main__":
    asyncio.run(main())
