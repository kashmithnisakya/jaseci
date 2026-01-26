"""Webhook Repository Implementation using ScaleTieredMemory-style storage.

Uses MongoDB when available, falls back to SQLite-based storage.
Follows the same patterns as memory_hierarchy.jac for consistency.
"""
import logging;
import json;
import from datetime { datetime, UTC, timedelta }
import from typing { Any }
import from pymongo { MongoClient }
import from pymongo.errors { ConnectionFailure }
import from jac_scale.abstractions.webhook_repository { WebhookRepository }
import from jac_scale.abstractions.models.webhook {
    WebhookRegistration,
    WebhookDeliveryLog,
    DeadLetterEntry,
    WebhookApiKey
}
import from jac_scale.config_loader { get_scale_config }

glob _db_config = get_scale_config().get_database_config(),
     logger = logging.getLogger(__name__);

"""MongoDB-backed webhook repository implementation."""
class MongoWebhookRepository(WebhookRepository) {
    has client: (MongoClient | None) = None,
        db_name: str = 'jac_db',
        mongo_url: str = _db_config['mongodb_uri'],
        _available: bool = False;

    def postinit -> None;
    def is_available -> bool;
    def _get_collection(collection_name: str) -> Any;
}

"""SQLite/Shelf-backed webhook repository implementation (fallback)."""
class ShelfWebhookRepository(WebhookRepository) {
    has shelf_path: str = _db_config['shelf_db_path'],
        _webhooks: dict[str, dict[str, Any]] = {},
        _delivery_logs: dict[str, dict[str, Any]] = {},
        _dead_letters: dict[str, dict[str, Any]] = {},
        _api_keys: dict[str, dict[str, Any]] = {};

    def postinit -> None;
    def _save -> None;
    def _load -> None;
}

"""Factory function to create the appropriate webhook repository."""
def create_webhook_repository -> WebhookRepository {
    mongo_repo = MongoWebhookRepository();
    if mongo_repo.is_available() {
        logger.debug("Using MongoDB for webhook storage");
        return mongo_repo;
    }
    logger.debug("MongoDB not available, using shelf for webhook storage");
    return ShelfWebhookRepository();
}
