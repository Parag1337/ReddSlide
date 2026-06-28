from fastapi import Request
from ..managers.oauth import OAuthManager
from ..managers.provider import ProviderManager


async def get_oauth_manager(request: Request) -> OAuthManager:
    return request.app.state.oauth_manager


async def get_provider_manager(request: Request) -> ProviderManager:
    return request.app.state.provider_manager
