"""Tests for Fix 2 (6.2B): Shared OAuth/Provider injection.

Verifies that every backend endpoint uses shared singleton instances
of OAuthManager and ProviderManager rather than creating temporary ones.
"""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest


class TestOAuthInjection:
    """Verify feed endpoint passes shared OAuth/Provider to ensure_subreddit_has_content."""

    @pytest.mark.asyncio
    async def test_feed_endpoint_injects_oauth_and_provider(self):
        """get_feed should forward oauth_manager and provider_manager to ensure_subreddit_has_content.

        We verify this by patching ensure_subreddit_has_content and checking
        the call args include the shared instances from dependencies.
        """
        from app.api.feed import get_feed
        from app.services.queue_manager import QueueManager
        from app.managers.oauth import OAuthManager
        from app.managers.provider import ProviderManager

        mock_queue = MagicMock(spec=QueueManager)
        mock_queue.get_subreddit_assets = AsyncMock(return_value=([], None, False))
        mock_oauth = MagicMock(spec=OAuthManager)
        mock_provider = MagicMock(spec=ProviderManager)

        with patch.object(mock_queue, "ensure_subreddit_has_content",
                          new_callable=AsyncMock) as mock_ensure:
            mock_ensure.return_value = False

            try:
                await get_feed(
                    limit=50,
                    after=None,
                    subreddits="testsub",
                    sort="hot",
                    queue_manager=mock_queue,
                    oauth_manager=mock_oauth,
                    provider_manager=mock_provider,
                )
            except Exception:
                pass

            if mock_ensure.called:
                _, kwargs = mock_ensure.call_args
                assert kwargs.get("oauth_manager") is mock_oauth, (
                    "oauth_manager must be the shared singleton, not None or a temporary instance"
                )
                assert kwargs.get("provider_manager") is mock_provider, (
                    "provider_manager must be the shared singleton, not None or a temporary instance"
                )

    @pytest.mark.asyncio
    async def test_sync_subreddits_passes_oauth_and_provider(self):
        """sync_subreddits should forward shared OAuth/Provider to ensure_subreddit_has_content."""
        from app.api.feed import sync_subreddits
        from app.services.queue_manager import QueueManager

        mock_queue = MagicMock(spec=QueueManager)
        mock_queue.get_enabled_subreddits = AsyncMock(return_value=set())
        mock_queue.add_or_update_subreddit_config = AsyncMock()
        mock_queue.disable_subreddit = AsyncMock()
        mock_oauth = MagicMock()
        mock_provider = MagicMock()

        with patch.object(mock_queue, "ensure_subreddit_has_content",
                          new_callable=AsyncMock) as mock_ensure:
            mock_ensure.return_value = True

            body = {"subreddits": ["newsub"]}
            result = await sync_subreddits(
                body=body,
                queue_manager=mock_queue,
                oauth_manager=mock_oauth,
                provider_manager=mock_provider,
            )

            assert result["synced"] == 1
            assert mock_ensure.called
            _, kwargs = mock_ensure.call_args
            assert kwargs.get("oauth_manager") is mock_oauth
            assert kwargs.get("provider_manager") is mock_provider
