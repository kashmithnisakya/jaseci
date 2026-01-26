"""Webhook Repository Implementation - Shelf Backend (Fallback).

Provides SQLite/Shelf-backed storage for webhooks when MongoDB is not available.
Uses the same shelf_db_path from config as other jac-scale components.
"""
import logging;
import shelve;
import os;
import from datetime { datetime, UTC, timedelta }
import from typing { Any }
import from jac_scale.abstractions.models.webhook {
    WebhookRegistration,
    WebhookDeliveryLog,
    DeadLetterEntry,
    WebhookApiKey
}

glob logger = logging.getLogger(__name__);

# Shelf key prefixes
glob WEBHOOK_PREFIX = 'webhook:',
     LOG_PREFIX = 'log:',
     DLQ_PREFIX = 'dlq:',
     APIKEY_PREFIX = 'apikey:';

impl ShelfWebhookRepository.postinit -> None {
    self._load();
}

impl ShelfWebhookRepository._load -> None {
    """Load data from shelf storage."""
    try {
        shelf_dir = os.path.dirname(self.shelf_path);
        if shelf_dir and not os.path.exists(shelf_dir) {
            os.makedirs(shelf_dir, exist_ok=True);
        }
        webhook_shelf_path = self.shelf_path + '_webhooks';
        with shelve.open(webhook_shelf_path) as shelf {
            self._webhooks = dict(shelf.get('webhooks', {}));
            self._delivery_logs = dict(shelf.get('delivery_logs', {}));
            self._dead_letters = dict(shelf.get('dead_letters', {}));
            self._api_keys = dict(shelf.get('api_keys', {}));
        }
        logger.debug("Loaded webhook data from shelf storage");
    } except Exception as e {
        logger.warning(f"Failed to load webhook shelf: {e}");
        self._webhooks = {};
        self._delivery_logs = {};
        self._dead_letters = {};
        self._api_keys = {};
    }
}

impl ShelfWebhookRepository._save -> None {
    """Persist data to shelf storage."""
    try {
        webhook_shelf_path = self.shelf_path + '_webhooks';
        with shelve.open(webhook_shelf_path) as shelf {
            shelf['webhooks'] = self._webhooks;
            shelf['delivery_logs'] = self._delivery_logs;
            shelf['dead_letters'] = self._dead_letters;
            shelf['api_keys'] = self._api_keys;
        }
    } except Exception as e {
        logger.error(f"Failed to save webhook shelf: {e}");
    }
}

# =============================================================================
# Webhook Registration CRUD
# =============================================================================

impl ShelfWebhookRepository.create_webhook(
    self: ShelfWebhookRepository, webhook: WebhookRegistration
) -> WebhookRegistration {
    self._webhooks[webhook.id] = webhook.model_dump();
    self._save();
    logger.debug(f"Created webhook {webhook.id} for walker {webhook.walker_name}");
    return webhook;
}

impl ShelfWebhookRepository.get_webhook(
    self: ShelfWebhookRepository, webhook_id: str
) -> (WebhookRegistration | None) {
    doc = self._webhooks.get(webhook_id);
    if doc {
        return WebhookRegistration(**doc);
    }
    return None;
}

impl ShelfWebhookRepository.get_webhooks_by_walker(
    self: ShelfWebhookRepository, walker_name: str
) -> list[WebhookRegistration] {
    result: list[WebhookRegistration] = [];
    for doc in self._webhooks.values() {
        if doc.get('walker_name') == walker_name {
            result.append(WebhookRegistration(**doc));
        }
    }
    return result;
}

impl ShelfWebhookRepository.get_active_outbound_webhooks(
    self: ShelfWebhookRepository, walker_name: str
) -> list[WebhookRegistration] {
    result: list[WebhookRegistration] = [];
    for doc in self._webhooks.values() {
        if (
            doc.get('walker_name') == walker_name
            and doc.get('direction') == 'outbound'
            and doc.get('is_active', True)
        ) {
            result.append(WebhookRegistration(**doc));
        }
    }
    return result;
}

impl ShelfWebhookRepository.get_active_inbound_webhooks(
    self: ShelfWebhookRepository, walker_name: str
) -> list[WebhookRegistration] {
    result: list[WebhookRegistration] = [];
    for doc in self._webhooks.values() {
        if (
            doc.get('walker_name') == walker_name
            and doc.get('direction') == 'inbound'
            and doc.get('is_active', True)
        ) {
            result.append(WebhookRegistration(**doc));
        }
    }
    return result;
}

impl ShelfWebhookRepository.update_webhook(
    self: ShelfWebhookRepository, webhook_id: str, updates: dict[str, Any]
) -> (WebhookRegistration | None) {
    if webhook_id not in self._webhooks {
        return None;
    }
    doc = self._webhooks[webhook_id];
    updates['updated_at'] = datetime.now(UTC).isoformat();
    doc.update(updates);
    self._webhooks[webhook_id] = doc;
    self._save();
    return WebhookRegistration(**doc);
}

impl ShelfWebhookRepository.delete_webhook(
    self: ShelfWebhookRepository, webhook_id: str
) -> bool {
    if webhook_id in self._webhooks {
        del self._webhooks[webhook_id];
        self._save();
        return True;
    }
    return False;
}

impl ShelfWebhookRepository.list_webhooks(
    self: ShelfWebhookRepository,
    direction: (str | None) = None,
    is_active: (bool | None) = None,
    limit: int = 100,
    offset: int = 0
) -> list[WebhookRegistration] {
    result: list[WebhookRegistration] = [];
    for doc in self._webhooks.values() {
        if direction is not None and doc.get('direction') != direction {
            continue;
        }
        if is_active is not None and doc.get('is_active') != is_active {
            continue;
        }
        result.append(WebhookRegistration(**doc));
    }
    return result[offset:offset + limit];
}

# =============================================================================
# Delivery Log Operations
# =============================================================================

impl ShelfWebhookRepository.create_delivery_log(
    self: ShelfWebhookRepository, log: WebhookDeliveryLog
) -> WebhookDeliveryLog {
    self._delivery_logs[log.id] = log.model_dump();
    self._save();
    return log;
}

impl ShelfWebhookRepository.get_delivery_log(
    self: ShelfWebhookRepository, log_id: str
) -> (WebhookDeliveryLog | None) {
    doc = self._delivery_logs.get(log_id);
    if doc {
        return WebhookDeliveryLog(**doc);
    }
    return None;
}

impl ShelfWebhookRepository.update_delivery_log(
    self: ShelfWebhookRepository, log_id: str, updates: dict[str, Any]
) -> (WebhookDeliveryLog | None) {
    if log_id not in self._delivery_logs {
        return None;
    }
    doc = self._delivery_logs[log_id];
    doc.update(updates);
    self._delivery_logs[log_id] = doc;
    self._save();
    return WebhookDeliveryLog(**doc);
}

impl ShelfWebhookRepository.get_delivery_logs_by_webhook(
    self: ShelfWebhookRepository,
    webhook_id: str,
    limit: int = 50,
    offset: int = 0
) -> list[WebhookDeliveryLog] {
    result: list[WebhookDeliveryLog] = [];
    for doc in self._delivery_logs.values() {
        if doc.get('webhook_id') == webhook_id {
            result.append(WebhookDeliveryLog(**doc));
        }
    }
    # Sort by created_at descending
    result.sort(key=lambda x: x.created_at, reverse=True);
    return result[offset:offset + limit];
}

impl ShelfWebhookRepository.get_pending_retries(
    self: ShelfWebhookRepository, before_time: str
) -> list[WebhookDeliveryLog] {
    result: list[WebhookDeliveryLog] = [];
    for doc in self._delivery_logs.values() {
        if (
            doc.get('status') == 'retrying'
            and doc.get('next_retry_at')
            and doc.get('next_retry_at') <= before_time
        ) {
            result.append(WebhookDeliveryLog(**doc));
        }
    }
    return result;
}

# =============================================================================
# Dead Letter Queue Operations
# =============================================================================

impl ShelfWebhookRepository.add_to_dead_letter(
    self: ShelfWebhookRepository, entry: DeadLetterEntry
) -> DeadLetterEntry {
    self._dead_letters[entry.id] = entry.model_dump();
    self._save();
    logger.info(f"Added delivery to dead letter queue: {entry.id}");
    return entry;
}

impl ShelfWebhookRepository.get_dead_letter(
    self: ShelfWebhookRepository, entry_id: str
) -> (DeadLetterEntry | None) {
    doc = self._dead_letters.get(entry_id);
    if doc {
        return DeadLetterEntry(**doc);
    }
    return None;
}

impl ShelfWebhookRepository.list_dead_letters(
    self: ShelfWebhookRepository,
    webhook_id: (str | None) = None,
    limit: int = 50,
    offset: int = 0
) -> list[DeadLetterEntry] {
    result: list[DeadLetterEntry] = [];
    for doc in self._dead_letters.values() {
        if webhook_id is not None and doc.get('webhook_id') != webhook_id {
            continue;
        }
        result.append(DeadLetterEntry(**doc));
    }
    result.sort(key=lambda x: x.created_at, reverse=True);
    return result[offset:offset + limit];
}

impl ShelfWebhookRepository.remove_dead_letter(
    self: ShelfWebhookRepository, entry_id: str
) -> bool {
    if entry_id in self._dead_letters {
        del self._dead_letters[entry_id];
        self._save();
        return True;
    }
    return False;
}

impl ShelfWebhookRepository.mark_dead_letter_permanent(
    self: ShelfWebhookRepository, entry_id: str
) -> (DeadLetterEntry | None) {
    if entry_id not in self._dead_letters {
        return None;
    }
    doc = self._dead_letters[entry_id];
    doc['can_retry'] = False;
    self._dead_letters[entry_id] = doc;
    self._save();
    return DeadLetterEntry(**doc);
}

# =============================================================================
# API Key Operations
# =============================================================================

impl ShelfWebhookRepository.create_api_key(
    self: ShelfWebhookRepository, api_key: WebhookApiKey
) -> WebhookApiKey {
    self._api_keys[api_key.id] = api_key.model_dump();
    self._save();
    logger.debug(f"Created API key {api_key.key_prefix}... for webhook {api_key.webhook_id}");
    return api_key;
}

impl ShelfWebhookRepository.get_api_key(
    self: ShelfWebhookRepository, key_id: str
) -> (WebhookApiKey | None) {
    doc = self._api_keys.get(key_id);
    if doc {
        return WebhookApiKey(**doc);
    }
    return None;
}

impl ShelfWebhookRepository.find_api_key_by_hash(
    self: ShelfWebhookRepository, key_hash: str
) -> (WebhookApiKey | None) {
    for doc in self._api_keys.values() {
        if doc.get('key_hash') == key_hash and doc.get('is_active', True) {
            return WebhookApiKey(**doc);
        }
    }
    return None;
}

impl ShelfWebhookRepository.get_api_keys_by_webhook(
    self: ShelfWebhookRepository, webhook_id: str
) -> list[WebhookApiKey] {
    result: list[WebhookApiKey] = [];
    for doc in self._api_keys.values() {
        if doc.get('webhook_id') == webhook_id {
            result.append(WebhookApiKey(**doc));
        }
    }
    return result;
}

impl ShelfWebhookRepository.revoke_api_key(
    self: ShelfWebhookRepository, key_id: str
) -> bool {
    if key_id in self._api_keys {
        self._api_keys[key_id]['is_active'] = False;
        self._save();
        return True;
    }
    return False;
}

impl ShelfWebhookRepository.touch_api_key(
    self: ShelfWebhookRepository, key_id: str
) -> None {
    if key_id in self._api_keys {
        self._api_keys[key_id]['last_used_at'] = datetime.now(UTC).isoformat();
        self._save();
    }
}

impl ShelfWebhookRepository.delete_api_key(
    self: ShelfWebhookRepository, key_id: str
) -> bool {
    if key_id in self._api_keys {
        del self._api_keys[key_id];
        self._save();
        return True;
    }
    return False;
}

# =============================================================================
# Utility Operations
# =============================================================================

impl ShelfWebhookRepository.get_webhook_stats(
    self: ShelfWebhookRepository, webhook_id: str
) -> dict[str, Any] {
    total_deliveries = 0;
    successful = 0;
    failed = 0;
    pending = 0;

    for doc in self._delivery_logs.values() {
        if doc.get('webhook_id') == webhook_id {
            total_deliveries += 1;
            status = doc.get('status');
            if status == 'success' {
                successful += 1;
            } elif status == 'failed' {
                failed += 1;
            } elif status in ['pending', 'retrying'] {
                pending += 1;
            }
        }
    }

    dead_letters = sum(
        1 for doc in self._dead_letters.values()
        if doc.get('webhook_id') == webhook_id
    );

    return {
        'webhook_id': webhook_id,
        'total_deliveries': total_deliveries,
        'successful': successful,
        'failed': failed,
        'pending': pending,
        'dead_letters': dead_letters,
        'success_rate': (successful / total_deliveries * 100) if total_deliveries > 0 else 0.0
    };
}

impl ShelfWebhookRepository.cleanup_old_logs(
    self: ShelfWebhookRepository, older_than_days: int = 30
) -> int {
    cutoff = datetime.now(UTC) - timedelta(days=older_than_days);
    cutoff_str = cutoff.isoformat();
    to_delete: list[str] = [];

    for (log_id, doc) in self._delivery_logs.items() {
        if (
            doc.get('created_at', '') < cutoff_str
            and doc.get('status') in ['success', 'failed', 'dead_letter']
        ) {
            to_delete.append(log_id);
        }
    }

    for log_id in to_delete {
        del self._delivery_logs[log_id];
    }

    if to_delete {
        self._save();
        logger.info(f"Cleaned up {len(to_delete)} old delivery logs");
    }

    return len(to_delete);
}
