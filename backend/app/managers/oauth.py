import asyncio
import time
from typing import Optional
import httpx
from ..core.database import get_db
from ..models.schemas import OAuthToken


class OAuthManager:
    """Internal OAuth manager - no public endpoints."""

    REFRESH_BUFFER_SECONDS = 300  # Refresh 5 minutes before expiry
    MAX_RETRIES = 3
    BACKOFF_BASE = 1

    def __init__(self, client_id: str, client_secret: str, user_agent: str, redirect_uri: str = "http://localhost:8080"):
        self.client_id = client_id
        self.client_secret = client_secret
        self.user_agent = user_agent
        self.redirect_uri = redirect_uri
        self._token: Optional[str] = None
        self._refresh_token_value: Optional[str] = None
        self._token_id: Optional[int] = None
        self._refresh_lock = asyncio.Lock()
    
    async def initialize(self):
        """Initialize OAuth tokens table and load existing token."""
        async with get_db() as db:
            cursor = await db.execute("SELECT * FROM oauth_tokens LIMIT 1")
            row = await cursor.fetchone()
            if row:
                token = OAuthToken.model_validate(dict(row))
                self._token_id = row[0]  # Store the ID
                if token.expires_at > int(time.time()):
                    self._token = token.access_token
                    self._refresh_token_value = token.refresh_token
            else:
                # No token exists, try to acquire one using client credentials
                await self._acquire_initial_token()
    
    async def get_valid_token(self) -> str:
        """Get valid token, refresh if needed.

        Thread-safe: only one refresh occurs at a time via _refresh_lock.
        Concurrent callers reuse the refreshed token.
        """
        async with self._refresh_lock:
            if self._token is None:
                await self._ensure_token()

            token_data = await self._get_stored_token()
            if token_data and token_data.expires_at <= int(time.time()) + self.REFRESH_BUFFER_SECONDS:
                await self.refresh_token()

            return self._token or ""
    
    async def _ensure_token(self):
        """Ensure a token exists."""
        token_data = await self._get_stored_token()
        if token_data and token_data.expires_at > int(time.time()):
            self._token = token_data.access_token
            self._refresh_token_value = token_data.refresh_token
        else:
            # Try to acquire a new token
            await self._acquire_initial_token()
    
    async def _get_stored_token(self) -> Optional[OAuthToken]:
        """Get stored token from database."""
        async with get_db() as db:
            cursor = await db.execute("SELECT * FROM oauth_tokens LIMIT 1")
            row = await cursor.fetchone()
            if row:
                return OAuthToken.model_validate(dict(row))
            return None
    
    async def _acquire_initial_token(self) -> None:
        """Acquire initial token using client credentials flow."""
        for attempt in range(self.MAX_RETRIES):
            try:
                async with httpx.AsyncClient() as client:
                    response = await client.post(
                        "https://www.reddit.com/api/v1/access_token",
                        auth=(self.client_id, self.client_secret),
                        data={"grant_type": "client_credentials"},
                        headers={"User-Agent": self.user_agent}
                    )
                    
                    if response.status_code == 200:
                        data = response.json()
                        self._token = data["access_token"]
                        current_time = int(time.time())
                        
                        # Store token in database
                        async with get_db() as db:
                            # Check if token already exists
                            cursor = await db.execute("SELECT id FROM oauth_tokens LIMIT 1")
                            existing = await cursor.fetchone()
                            
                            if existing:
                                # Update existing row
                                await db.execute(
                                    """UPDATE oauth_tokens 
                                       SET access_token = ?, token_type = ?, expires_at = ?, 
                                           created_at = ?, last_refreshed = ?, success_count = success_count + 1
                                       WHERE id = ?""",
                                    (self._token, "bearer", current_time + data.get("expires_in", 3600), 
                                     current_time, current_time, existing[0])
                                )
                                self._token_id = existing[0]
                            else:
                                # Insert new row
                                await db.execute(
                                    """INSERT INTO oauth_tokens 
                                       (access_token, refresh_token, token_type, expires_at, created_at, last_refreshed)
                                       VALUES (?, ?, ?, ?, ?, ?)""",
                                    (self._token, None, "bearer", current_time + data.get("expires_in", 3600), 
                                     current_time, current_time)
                                )
                                # Get the inserted ID
                                cursor = await db.execute("SELECT last_insert_rowid()")
                                result = await cursor.fetchone()
                                self._token_id = result[0]
                            
                            await db.commit()
                        
                        return
                    else:
                        # Retry with exponential backoff
                        if attempt < self.MAX_RETRIES - 1:
                            wait_time = self.BACKOFF_BASE * (2 ** attempt)
                            await asyncio.sleep(wait_time)
                        else:
                            raise RuntimeError(f"Failed to acquire token: {response.status_code}")
            except Exception as e:
                if attempt == self.MAX_RETRIES - 1:
                    print(f"OAuth token acquisition failed after {self.MAX_RETRIES} attempts: {e}")
                    raise
                await asyncio.sleep(self.BACKOFF_BASE * (2 ** attempt))
    
    async def refresh_token(self) -> None:
        """Refresh OAuth token using refresh token if available, otherwise acquire new."""
        async with get_db() as db:
            cursor = await db.execute("SELECT refresh_token FROM oauth_tokens LIMIT 1")
            row = await cursor.fetchone()
            
            if row and row[0]:
                # Use refresh token flow
                await self._refresh_with_token(row[0])
            else:
                # No refresh token available, acquire new token
                await self._acquire_initial_token()
    
    async def _refresh_with_token(self, refresh_token: str) -> None:
        """Perform token refresh with Reddit API."""
        for attempt in range(self.MAX_RETRIES):
            try:
                async with httpx.AsyncClient() as client:
                    response = await client.post(
                        "https://www.reddit.com/api/v1/access_token",
                        auth=(self.client_id, self.client_secret),
                        data={"grant_type": "refresh_token", "refresh_token": refresh_token},
                        headers={"User-Agent": self.user_agent}
                    )
                    
                    if response.status_code == 200:
                        data = response.json()
                        self._token = data["access_token"]
                        # Reddit returns a new refresh_token with each refresh
                        if "refresh_token" in data:
                            self._refresh_token_value = data["refresh_token"]
                        current_time = int(time.time())
                        
                        async with get_db() as db:
                            # Update existing row using the stored ID
                            if self._token_id:
                                await db.execute(
                                    """UPDATE oauth_tokens 
                                       SET access_token = ?, refresh_token = ?, expires_at = ?, 
                                           last_refreshed = ?, success_count = success_count + 1, last_success = ?
                                       WHERE id = ?""",
                                    (self._token, self._refresh_token_value or refresh_token, 
                                     current_time + data.get("expires_in", 3600), 
                                     current_time, current_time, self._token_id)
                                )
                            else:
                                # Fallback: try to update any existing row
                                await db.execute(
                                    """UPDATE oauth_tokens 
                                       SET access_token = ?, refresh_token = ?, expires_at = ?, 
                                           last_refreshed = ?, success_count = success_count + 1, last_success = ?"""
                                    ,
                                    (self._token, self._refresh_token_value or refresh_token, 
                                     current_time + data.get("expires_in", 3600), 
                                     current_time, current_time)
                                )
                            
                            await db.commit()
                        
                        await self.record_success()
                        return
                    elif response.status_code == 401:
                        # Invalid refresh token, need to acquire new token
                        await self._acquire_initial_token()
                        return
                    else:
                        # Retry with exponential backoff
                        if attempt < self.MAX_RETRIES - 1:
                            wait_time = self.BACKOFF_BASE * (2 ** attempt)
                            await asyncio.sleep(wait_time)
                        else:
                            await self.record_failure()
                            raise RuntimeError(f"Token refresh failed: {response.status_code}")
            except Exception as e:
                if attempt == self.MAX_RETRIES - 1:
                    await self.record_failure()
                    raise RuntimeError(f"Token refresh failed: {e}")
                await asyncio.sleep(self.BACKOFF_BASE * (2 ** attempt))
    
    async def record_success(self) -> None:
        """Record successful API call."""
        async with get_db() as db:
            current_time = int(time.time())
            await db.execute(
                """UPDATE oauth_tokens SET success_count = success_count + 1, 
                   last_success = ?, last_failure = NULL
                   WHERE id = (SELECT id FROM oauth_tokens LIMIT 1)""",
                (current_time,)
            )
            await db.commit()
    
    async def record_failure(self) -> None:
        """Record failed API call."""
        async with get_db() as db:
            current_time = int(time.time())
            await db.execute(
                """UPDATE oauth_tokens SET failure_count = failure_count + 1,
                   last_failure = ?
                   WHERE id = (SELECT id FROM oauth_tokens LIMIT 1)""",
                (current_time,)
            )
            await db.commit()
    
    def is_healthy(self) -> bool:
        """Check if OAuth provider is healthy."""
        if not self._token:
            return False
        return True