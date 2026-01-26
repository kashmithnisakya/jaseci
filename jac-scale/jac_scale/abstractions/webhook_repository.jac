"""Webhook Repository abstraction for jac-scale.

Provides interface for storing and managing webhook registrations,
delivery logs, dead letter queue entries, and API keys.
"""
import from typing { Any }
import from jac_scale.abstractions.models.webhook {
    WebhookRegistration,
    WebhookDeliveryLog,
    DeadLetterEntry,
    WebhookApiKey
}

"""Repository interface for webhook management.

All implementations must provide thread-safe operations for
webhook CRUD, delivery logging, and dead letter queue management.
"""
class WebhookRepository {
    # =========================================================================
    # Webhook Registration CRUD
    # =========================================================================

    """Create a new webhook registration."""
    def create_webhook(
        self: WebhookRepository, webhook: WebhookRegistration
    ) -> WebhookRegistration;

    """Get a webhook by ID."""
    def get_webhook(self: WebhookRepository, webhook_id: str) -> (WebhookRegistration | None);

    """Get all webhooks for a specific walker."""
    def get_webhooks_by_walker(
        self: WebhookRepository, walker_name: str
    ) -> list[WebhookRegistration];

    """Get all active outbound webhooks for a walker."""
    def get_active_outbound_webhooks(
        self: WebhookRepository, walker_name: str
    ) -> list[WebhookRegistration];

    """Get all active inbound webhooks for a walker."""
    def get_active_inbound_webhooks(
        self: WebhookRepository, walker_name: str
    ) -> list[WebhookRegistration];

    """Update an existing webhook."""
    def update_webhook(
        self: WebhookRepository, webhook_id: str, updates: dict[str, Any]
    ) -> (WebhookRegistration | None);

    """Delete a webhook by ID."""
    def delete_webhook(self: WebhookRepository, webhook_id: str) -> bool;

    """List all webhooks with optional filtering."""
    def list_webhooks(
        self: WebhookRepository,
        direction: (str | None) = None,
        is_active: (bool | None) = None,
        limit: int = 100,
        offset: int = 0
    ) -> list[WebhookRegistration];

    # =========================================================================
    # Delivery Log Operations
    # =========================================================================

    """Create a delivery log entry."""
    def create_delivery_log(
        self: WebhookRepository, log: WebhookDeliveryLog
    ) -> WebhookDeliveryLog;

    """Get a delivery log by ID."""
    def get_delivery_log(
        self: WebhookRepository, log_id: str
    ) -> (WebhookDeliveryLog | None);

    """Update a delivery log entry."""
    def update_delivery_log(
        self: WebhookRepository, log_id: str, updates: dict[str, Any]
    ) -> (WebhookDeliveryLog | None);

    """Get delivery logs for a webhook."""
    def get_delivery_logs_by_webhook(
        self: WebhookRepository,
        webhook_id: str,
        limit: int = 50,
        offset: int = 0
    ) -> list[WebhookDeliveryLog];

    """Get pending deliveries that need retry."""
    def get_pending_retries(
        self: WebhookRepository, before_time: str
    ) -> list[WebhookDeliveryLog];

    # =========================================================================
    # Dead Letter Queue Operations
    # =========================================================================

    """Add entry to dead letter queue."""
    def add_to_dead_letter(
        self: WebhookRepository, entry: DeadLetterEntry
    ) -> DeadLetterEntry;

    """Get dead letter entry by ID."""
    def get_dead_letter(
        self: WebhookRepository, entry_id: str
    ) -> (DeadLetterEntry | None);

    """List dead letter entries."""
    def list_dead_letters(
        self: WebhookRepository,
        webhook_id: (str | None) = None,
        limit: int = 50,
        offset: int = 0
    ) -> list[DeadLetterEntry];

    """Remove entry from dead letter queue (after successful retry or manual removal)."""
    def remove_dead_letter(self: WebhookRepository, entry_id: str) -> bool;

    """Mark dead letter entry as non-retryable."""
    def mark_dead_letter_permanent(
        self: WebhookRepository, entry_id: str
    ) -> (DeadLetterEntry | None);

    # =========================================================================
    # API Key Operations
    # =========================================================================

    """Create a new API key for a webhook."""
    def create_api_key(
        self: WebhookRepository, api_key: WebhookApiKey
    ) -> WebhookApiKey;

    """Get API key by ID."""
    def get_api_key(self: WebhookRepository, key_id: str) -> (WebhookApiKey | None);

    """Find API key by hash (for validation)."""
    def find_api_key_by_hash(
        self: WebhookRepository, key_hash: str
    ) -> (WebhookApiKey | None);

    """Get all API keys for a webhook."""
    def get_api_keys_by_webhook(
        self: WebhookRepository, webhook_id: str
    ) -> list[WebhookApiKey];

    """Revoke (deactivate) an API key."""
    def revoke_api_key(self: WebhookRepository, key_id: str) -> bool;

    """Update API key last_used_at timestamp."""
    def touch_api_key(self: WebhookRepository, key_id: str) -> None;

    """Delete an API key."""
    def delete_api_key(self: WebhookRepository, key_id: str) -> bool;

    # =========================================================================
    # Utility Operations
    # =========================================================================

    """Get statistics for a webhook."""
    def get_webhook_stats(
        self: WebhookRepository, webhook_id: str
    ) -> dict[str, Any];

    """Cleanup old delivery logs (retention policy)."""
    def cleanup_old_logs(self: WebhookRepository, older_than_days: int = 30) -> int;
}
