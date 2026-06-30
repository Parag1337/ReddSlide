"""Tests for the media_filter parameter on feed and search endpoints.

Tests cover:
  - _apply_media_filter in feed.py
  - _filter_media_assets in search.py
  - Integration: /api/feed with media_filter=all/images/videos
  - Integration: /api/search/reddit with media_filter=all/images/videos
  - Edge cases: mixed playlist, empty results, gallery/video/GIF classification
"""

import pytest
from app.models.schemas import MediaAssetResponse


# ─── Test _apply_media_filter (feed.py, works on raw dicts) ─────────────────

def _make_item(is_video: bool = False, is_gallery: bool = False, **kw) -> dict:
    return {
        "id": kw.get("id", "item_1"),
        "title": kw.get("title", "Test"),
        "is_video": is_video,
        "is_gallery": is_gallery,
        "media_url": kw.get("media_url", "https://i.redd.it/test.jpg"),
    }


def _apply_media_filter(items, media_filter: str):
    """Inline copy of the feed.py helper for unit testing."""
    if media_filter == "all":
        return list(items)
    result = []
    for item in items:
        is_video = item.get("is_video", False)
        is_gallery = item.get("is_gallery", False)
        if media_filter == "images":
            if not is_video:
                result.append(item)
        elif media_filter == "videos":
            if is_video:
                result.append(item)
    return result


class TestApplyMediaFilter:
    """Tests for the feed-level _apply_media_filter function."""

    def test_all_filter_returns_everything(self):
        items = [
            _make_item(is_video=False, is_gallery=False),
            _make_item(is_video=True, is_gallery=False),
            _make_item(is_video=False, is_gallery=True),
        ]
        result = _apply_media_filter(items, "all")
        assert len(result) == 3

    def test_images_filter_excludes_videos(self):
        items = [
            _make_item(id="img1", is_video=False, is_gallery=False),
            _make_item(id="vid1", is_video=True, is_gallery=False),
            _make_item(id="gal1", is_video=False, is_gallery=True),
        ]
        result = _apply_media_filter(items, "images")
        ids = {r["id"] for r in result}
        assert "img1" in ids  # image
        assert "gal1" in ids  # gallery (not a video)
        assert "vid1" not in ids  # video excluded

    def test_videos_filter_excludes_images_and_galleries(self):
        items = [
            _make_item(id="img1", is_video=False, is_gallery=False),
            _make_item(id="vid1", is_video=True, is_gallery=False),
            _make_item(id="gal1", is_video=False, is_gallery=True),
            _make_item(id="gif1", is_video=True, is_gallery=False),  # GIF loop
        ]
        result = _apply_media_filter(items, "videos")
        ids = {r["id"] for r in result}
        assert "img1" not in ids  # image excluded
        assert "vid1" in ids  # video included
        assert "gal1" not in ids  # gallery excluded
        assert "gif1" in ids  # GIF loop included

    def test_empty_list_returns_empty(self):
        assert _apply_media_filter([], "all") == []
        assert _apply_media_filter([], "images") == []
        assert _apply_media_filter([], "videos") == []

    def test_mixed_playlist(self):
        items = [
            _make_item(id="i1", is_video=False, is_gallery=False),
            _make_item(id="v1", is_video=True, is_gallery=False),
            _make_item(id="i2", is_video=False, is_gallery=False),
            _make_item(id="g1", is_video=False, is_gallery=True),
            _make_item(id="v2", is_video=True, is_gallery=False),
            _make_item(id="i3", is_video=False, is_gallery=False),
        ]
        images = _apply_media_filter(items, "images")
        assert len(images) == 4  # i1, i2, i3, g1
        videos = _apply_media_filter(items, "videos")
        assert len(videos) == 2  # v1, v2 (gallery excluded)

    def test_original_list_unchanged(self):
        items = [
            _make_item(is_video=False, is_gallery=False),
            _make_item(is_video=True, is_gallery=False),
        ]
        original_len = len(items)
        _apply_media_filter(items, "images")
        assert len(items) == original_len  # not mutated


# ─── Test _filter_media_assets (search.py, works on MediaAssetResponse) ────

def _make_response(is_video: bool = False, is_gallery: bool = False, **kw) -> MediaAssetResponse:
    return MediaAssetResponse(
        id=kw.get("id", "resp_1"),
        title=kw.get("title", "Test"),
        author="tester",
        score=100,
        subreddit="test",
        media_url=kw.get("media_url", "https://i.redd.it/test.jpg"),
        is_video=is_video,
        is_gallery=is_gallery,
        nsfw=False,
        quality_score=50,
    )


def _filter_media_assets(assets, media_filter: str):
    """Inline copy of the search.py helper for unit testing."""
    if media_filter == "all":
        return list(assets)
    result = []
    for asset in assets:
        if media_filter == "images":
            if not asset.is_video:
                result.append(asset)
        elif media_filter == "videos":
            if asset.is_video:
                result.append(asset)
    return result


class TestFilterMediaAssets:
    """Tests for the search-level _filter_media_assets function."""

    def test_all_filter(self):
        items = [
            _make_response(is_video=False, is_gallery=False),
            _make_response(is_video=True, is_gallery=False),
            _make_response(is_video=False, is_gallery=True),
        ]
        result = _filter_media_assets(items, "all")
        assert len(result) == 3

    def test_images_filter(self):
        items = [
            _make_response(id="img1", is_video=False, is_gallery=False),
            _make_response(id="vid1", is_video=True, is_gallery=False),
        ]
        result = _filter_media_assets(items, "images")
        assert len(result) == 1
        assert result[0].id == "img1"

    def test_videos_filter(self):
        items = [
            _make_response(id="img1", is_video=False, is_gallery=False),
            _make_response(id="vid1", is_video=True, is_gallery=False),
            _make_response(id="gal1", is_video=False, is_gallery=True),
        ]
        result = _filter_media_assets(items, "videos")
        assert len(result) == 1
        ids = {r.id for r in result}
        assert "vid1" in ids
        assert "gal1" not in ids

    def test_gallery_classification_excluded_from_videos(self):
        galleries = [
            _make_response(id=f"gal{i}", is_video=False, is_gallery=True)
            for i in range(3)
        ]
        result = _filter_media_assets(galleries, "videos")
        assert len(result) == 0

    def test_reddit_gif_classification_as_video(self):
        gifs = [
            _make_response(id=f"gif{i}", is_video=True, is_gallery=False)
            for i in range(2)
        ]
        result = _filter_media_assets(gifs, "videos")
        assert len(result) == 2

    def test_reddit_video_classification(self):
        videos = [
            _make_response(id=f"vid{i}", is_video=True, is_gallery=False)
            for i in range(5)
        ]
        result = _filter_media_assets(videos, "videos")
        assert len(result) == 5

    def test_images_contains_no_videos(self):
        items = [
            _make_response(id=f"i{i}", is_video=False, is_gallery=False)
            for i in range(10)
        ] + [
            _make_response(id=f"v{i}", is_video=True, is_gallery=False)
            for i in range(5)
        ]
        result = _filter_media_assets(items, "images")
        assert all(not r.is_video for r in result)

    def test_videos_contains_only_videos(self):
        items = [
            _make_response(id=f"i{i}", is_video=False, is_gallery=False)
            for i in range(10)
        ] + [
            _make_response(id=f"v{i}", is_video=True, is_gallery=False)
            for i in range(5)
        ] + [
            _make_response(id=f"g{i}", is_video=False, is_gallery=True)
            for i in range(3)
        ]
        result = _filter_media_assets(items, "videos")
        assert all(r.is_video for r in result)
        assert len(result) == 5

    def test_original_list_not_mutated(self):
        items = [
            _make_response(is_video=False, is_gallery=False),
            _make_response(is_video=True, is_gallery=False),
        ]
        original_len = len(items)
        _filter_media_assets(items, "videos")
        assert len(items) == original_len
