from datetime import datetime
from typing import Optional
from pydantic import BaseModel


class MediaAsset(BaseModel):
    id: str
    reddit_id: str
    permalink: str
    media_url: str
    title: str
    author: str
    score: int
    subreddit: str
    video_url: Optional[str] = None
    thumbnail_url: Optional[str] = None
    created_utc: int
    is_video: bool
    is_gallery: bool
    nsfw: bool
    quality_score: int = 50
    source_provider: str = "reddit_oauth"
    width: Optional[int] = None
    height: Optional[int] = None
    duration: Optional[int] = None
    created_at: int
    last_seen: int

    class Config:
        from_attributes = True


class MediaAssetResponse(BaseModel):
    id: str
    title: str
    author: str
    score: int
    subreddit: str
    media_url: str
    video_url: Optional[str] = None
    thumbnail_url: Optional[str] = None
    is_video: bool
    is_gallery: bool
    nsfw: bool
    quality_score: int
    width: Optional[int] = None
    height: Optional[int] = None
    duration: Optional[int] = None
    gallery_urls: Optional[list[str]] = None


class FeedResponse(BaseModel):
    items: list[MediaAssetResponse]
    after: Optional[str] = None
    has_more: bool


class QueueResponse(BaseModel):
    items: list[MediaAssetResponse]
    total: int
    pending: int


class SearchResponse(BaseModel):
    items: list[MediaAssetResponse]
    page: int
    limit: int
    total_results: int
    has_more: bool = False
    after: Optional[str] = None


class SubredditConfig(BaseModel):
    subreddit: str
    enabled: bool = True
    provider: str = "reddit_oauth"
    sort_mode: str = "hot"
    refresh_interval: int = 300


class OAuthToken(BaseModel):
    access_token: str
    refresh_token: Optional[str] = None
    token_type: str = "bearer"
    expires_at: int
    created_at: int
    last_refreshed: int
    success_count: int = 0
    failure_count: int = 0
    last_success: Optional[int] = None
    last_failure: Optional[int] = None

    class Config:
        from_attributes = True


class HealthResponse(BaseModel):
    status: str
    database: bool
    oauth_valid: bool
    queue_size: int
    providers: dict


class ProviderStatus(BaseModel):
    name: str
    healthy: bool
    success_count: int
    failure_count: int
    last_success: Optional[int] = None
    last_failure: Optional[int] = None
    cooldown_until: Optional[int] = None