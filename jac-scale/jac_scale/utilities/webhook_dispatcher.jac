"""Webhook Dispatcher - Handles outbound webhook delivery.

Provides async delivery with HMAC signing, retry logic with exponential backoff,
and dead letter queue for failed deliveries.
"""
import logging;
import hmac;
import hashlib;
import time;
import asyncio;
import secrets;
import from datetime { datetime, UTC, timedelta }
import from typing { Any }
import from jac_scale.abstractions.models.webhook {
    WebhookRegistration,
    WebhookPayload,
    WebhookDeliveryLog,
    DeadLetterEntry,
    WebhookDeliveryResult,
    DeliveryStatus,
    WebhookApiKey
}
import from jac_scale.abstractions.webhook_repository { WebhookRepository }

glob logger = logging.getLogger(__name__);

"""Dispatcher for outbound webhook deliveries.

Handles HTTP POST requests to registered webhook URLs with:
- HMAC-SHA256 payload signing
- Retry with exponential backoff
- Delivery logging for audit trail
- Dead letter queue for exhausted retries
"""
class WebhookDispatcher {
    has repository: WebhookRepository,
        _http_client: Any = None,
        default_timeout: float = 30.0,
        max_response_size: int = 10240;  # 10KB max response stored

    def postinit -> None;

    """Dispatch webhook to all registered URLs for a walker."""
    async def dispatch(
        walker_name: str,
        data: Any,
        username: (str | None) = None
    ) -> list[WebhookDeliveryResult];

    """Dispatch to a single webhook."""
    async def dispatch_single(
        webhook: WebhookRegistration,
        data: Any,
        username: (str | None) = None
    ) -> WebhookDeliveryResult;

    """Retry a failed delivery from the dead letter queue."""
    async def retry_dead_letter(entry_id: str) -> WebhookDeliveryResult;

    """Process pending retries (call periodically)."""
    async def process_pending_retries -> list[WebhookDeliveryResult];

    """Sign a payload using HMAC-SHA256."""
    def sign_payload(payload: str, secret: str) -> str;

    """Generate a new API key for inbound webhook authentication."""
    def generate_api_key(
        webhook_id: str,
        name: str = '',
        expires_in_days: (int | None) = None,
        created_by: (str | None) = None
    ) -> tuple[str, WebhookApiKey];

    """Hash an API key for storage."""
    def hash_api_key(api_key: str) -> str;

    """Validate an API key for inbound webhook."""
    def validate_api_key(api_key: str, webhook_id: str) -> bool;

    """Shutdown the dispatcher and close HTTP client."""
    async def close -> None;
}
