"""
Database migration script to fix preview.redd.it URLs in the database.

Converts all preview.redd.it URLs to i.redd.it in:
- media_assets.media_url
- media_assets.video_url  
- media_assets.thumbnail_url
- gallery_items.item_url

Usage:
    python migrate_urls.py
    python migrate_urls.py --dry-run  (preview only, no changes)
"""

import asyncio
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from app.core.database import get_db, DATABASE_PATH


PREVIEW_DOMAIN = "preview.redd.it"
CORRECT_DOMAIN = "i.redd.it"


async def count_preview_urls() -> dict[str, int]:
    """Count preview.redd.it URLs in all relevant fields."""
    counts = {
        "media_assets.media_url": 0,
        "media_assets.video_url": 0,
        "media_assets.thumbnail_url": 0,
        "gallery_items.item_url": 0,
    }

    async with get_db() as db:
        cursor = await db.execute(
            "SELECT COUNT(*) as cnt FROM media_assets WHERE media_url LIKE ?",
            (f"%{PREVIEW_DOMAIN}%",)
        )
        row = await cursor.fetchone()
        counts["media_assets.media_url"] = row["cnt"] if row else 0

        cursor = await db.execute(
            "SELECT COUNT(*) as cnt FROM media_assets WHERE video_url LIKE ?",
            (f"%{PREVIEW_DOMAIN}%",)
        )
        row = await cursor.fetchone()
        counts["media_assets.video_url"] = row["cnt"] if row else 0

        cursor = await db.execute(
            "SELECT COUNT(*) as cnt FROM media_assets WHERE thumbnail_url LIKE ?",
            (f"%{PREVIEW_DOMAIN}%",)
        )
        row = await cursor.fetchone()
        counts["media_assets.thumbnail_url"] = row["cnt"] if row else 0

        cursor = await db.execute(
            "SELECT COUNT(*) as cnt FROM gallery_items WHERE item_url LIKE ?",
            (f"%{PREVIEW_DOMAIN}%",)
        )
        row = await cursor.fetchone()
        counts["gallery_items.item_url"] = row["cnt"] if row else 0

    return counts


async def count_reddit_urls() -> dict[str, int]:
    """Count i.redd.it URLs in all relevant fields."""
    counts = {
        "media_assets.media_url": 0,
        "media_assets.video_url": 0,
        "media_assets.thumbnail_url": 0,
        "gallery_items.item_url": 0,
    }

    async with get_db() as db:
        cursor = await db.execute(
            "SELECT COUNT(*) as cnt FROM media_assets WHERE media_url LIKE ?",
            (f"%{CORRECT_DOMAIN}%",)
        )
        row = await cursor.fetchone()
        counts["media_assets.media_url"] = row["cnt"] if row else 0

        cursor = await db.execute(
            "SELECT COUNT(*) as cnt FROM media_assets WHERE video_url LIKE ?",
            (f"%{CORRECT_DOMAIN}%",)
        )
        row = await cursor.fetchone()
        counts["media_assets.video_url"] = row["cnt"] if row else 0

        cursor = await db.execute(
            "SELECT COUNT(*) as cnt FROM media_assets WHERE thumbnail_url LIKE ?",
            (f"%{CORRECT_DOMAIN}%",)
        )
        row = await cursor.fetchone()
        counts["media_assets.thumbnail_url"] = row["cnt"] if row else 0

        cursor = await db.execute(
            "SELECT COUNT(*) as cnt FROM gallery_items WHERE item_url LIKE ?",
            (f"%{CORRECT_DOMAIN}%",)
        )
        row = await cursor.fetchone()
        counts["gallery_items.item_url"] = row["cnt"] if row else 0

    return counts


async def fix_preview_urls(dry_run: bool = False) -> dict[str, int]:
    """Fix preview.redd.it URLs in the database."""
    fixed = {
        "media_assets.media_url": 0,
        "media_assets.video_url": 0,
        "media_assets.thumbnail_url": 0,
        "gallery_items.item_url": 0,
    }

    async with get_db() as db:
        # Fix media_assets.media_url
        cursor = await db.execute(
            "SELECT id, media_url FROM media_assets WHERE media_url LIKE ?",
            (f"%{PREVIEW_DOMAIN}%",)
        )
        rows = await cursor.fetchall()
        for row in rows:
            new_url = row["media_url"].replace(PREVIEW_DOMAIN, CORRECT_DOMAIN)
            if not dry_run:
                await db.execute("UPDATE media_assets SET media_url = ? WHERE id = ?", (new_url, row["id"]))
            fixed["media_assets.media_url"] += 1

        # Fix media_assets.video_url
        cursor = await db.execute(
            "SELECT id, video_url FROM media_assets WHERE video_url LIKE ?",
            (f"%{PREVIEW_DOMAIN}%",)
        )
        rows = await cursor.fetchall()
        for row in rows:
            new_url = row["video_url"].replace(PREVIEW_DOMAIN, CORRECT_DOMAIN)
            if not dry_run:
                await db.execute("UPDATE media_assets SET video_url = ? WHERE id = ?", (new_url, row["id"]))
            fixed["media_assets.video_url"] += 1

        # Fix media_assets.thumbnail_url
        cursor = await db.execute(
            "SELECT id, thumbnail_url FROM media_assets WHERE thumbnail_url LIKE ?",
            (f"%{PREVIEW_DOMAIN}%",)
        )
        rows = await cursor.fetchall()
        for row in rows:
            new_url = row["thumbnail_url"].replace(PREVIEW_DOMAIN, CORRECT_DOMAIN)
            if not dry_run:
                await db.execute("UPDATE media_assets SET thumbnail_url = ? WHERE id = ?", (new_url, row["id"]))
            fixed["media_assets.thumbnail_url"] += 1

        # Fix gallery_items.item_url
        cursor = await db.execute(
            "SELECT id, item_url FROM gallery_items WHERE item_url LIKE ?",
            (f"%{PREVIEW_DOMAIN}%",)
        )
        rows = await cursor.fetchall()
        for row in rows:
            new_url = row["item_url"].replace(PREVIEW_DOMAIN, CORRECT_DOMAIN)
            if not dry_run:
                await db.execute("UPDATE gallery_items SET item_url = ? WHERE id = ?", (new_url, row["id"]))
            fixed["gallery_items.item_url"] += 1

        if not dry_run:
            await db.commit()

    return fixed


async def main():
    dry_run = "--dry-run" in sys.argv

    print("=" * 60)
    print("RedSlide URL Migration")
    print("=" * 60)
    print(f"Database: {DATABASE_PATH}")
    print(f"Mode: {'DRY RUN (no changes)' if dry_run else 'LIVE'}")
    print()

    print("Before migration:")
    preview_counts = await count_preview_urls()
    reddit_counts = await count_reddit_urls()

    total_bad = sum(preview_counts.values())
    total_good = sum(reddit_counts.values())
    print(f"  preview.redd.it URLs: {total_bad}")
    print(f"  i.redd.it URLs: {total_good}")
    for key in preview_counts:
        print(f"    {key}: {preview_counts[key]} bad, {reddit_counts[key]} good")

    if total_bad == 0:
        print("\nNo preview.redd.it URLs found. Database is clean.")
        return

    print()
    print("Fixing URLs...")
    fixed = await fix_preview_urls(dry_run=dry_run)

    total_fixed = sum(fixed.values())
    print(f"  Fixed: {total_fixed} URLs")
    for key in fixed:
        print(f"    {key}: {fixed[key]}")

    print()
    print("After migration:")
    preview_counts_after = await count_preview_urls()
    reddit_counts_after = await count_reddit_urls()

    total_bad_after = sum(preview_counts_after.values())
    total_good_after = sum(reddit_counts_after.values())
    print(f"  preview.redd.it URLs: {total_bad_after}")
    print(f"  i.redd.it URLs: {total_good_after}")

    if total_bad_after == 0:
        print("\nSUCCESS: All preview.redd.it URLs have been fixed.")
    else:
        print(f"\nWARNING: {total_bad_after} preview.redd.it URLs remain.")
        for key in preview_counts_after:
            if preview_counts_after[key] > 0:
                print(f"  {key}: {preview_counts_after[key]}")

    if dry_run and total_bad > 0:
        print(f"\nRun without --dry-run to apply changes.")


if __name__ == "__main__":
    asyncio.run(main())
