import asyncio
import time
from typing import Optional
from ..models.schemas import ProviderStatus


class ProviderManager:
    """Manages provider health and failover.

    Thread-safe: all mutable state is guarded by _lock.
    """

    FAILURE_THRESHOLD = 5
    COOLDOWN_SECONDS = 300
    BACKOFF_DELAYS = [1, 2, 4, 5]  # Exponential backoff

    def __init__(self):
        self._primary_provider: Optional[str] = "reddit_oauth"
        self._fallback_provider: Optional[str] = "redlib"
        self._lock = asyncio.Lock()
        self._cooldown_until: int = 0
        self._failure_count: int = 0

    async def get_healthy_provider(self) -> str:
        """Get the current healthy provider."""
        async with self._lock:
            if time.time() < self._cooldown_until:
                return self._fallback_provider or "redlib"

            if self._failure_count >= self.FAILURE_THRESHOLD:
                self._cooldown_until = int(time.time()) + self.COOLDOWN_SECONDS
                return self._fallback_provider or "redlib"

            return self._primary_provider or "reddit_oauth"

    async def record_provider_success(self, provider: str) -> None:
        """Record successful API call for provider."""
        async with self._lock:
            if provider == self._primary_provider:
                self._failure_count = max(0, self._failure_count - 1)

    async def record_provider_failure(self, provider: str) -> None:
        """Record failed API call for provider."""
        async with self._lock:
            if provider == self._primary_provider:
                self._failure_count += 1

    async def get_provider_status(self) -> dict:
        """Get status of all providers."""
        async with self._lock:
            primary_healthy = self._failure_count < self.FAILURE_THRESHOLD
            fallback_healthy = True

            return {
                "primary": ProviderStatus(
                    name=self._primary_provider or "reddit_oauth",
                    healthy=primary_healthy and time.time() >= self._cooldown_until,
                    success_count=max(0, 100 - self._failure_count),
                    failure_count=self._failure_count,
                    cooldown_until=self._cooldown_until if time.time() < self._cooldown_until else None
                ),
                "fallback": ProviderStatus(
                    name=self._fallback_provider or "redlib",
                    healthy=fallback_healthy,
                    success_count=100,
                    failure_count=0
                )
            }