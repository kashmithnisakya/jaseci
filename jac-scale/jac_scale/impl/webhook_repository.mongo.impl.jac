"""Webhook Repository Implementation - MongoDB Backend.

Provides MongoDB-backed storage for webhooks, delivery logs,
dead letter queue entries, and API keys.
"""
import logging;
import from datetime { datetime, UTC, timedelta }
import from typing { Any }
import from pymongo.errors { ConnectionFailure }
import from jac_scale.abstractions.models.webhook {
    WebhookRegistration,
    WebhookDeliveryLog,
    DeadLetterEntry,
    WebhookApiKey
}

glob logger = logging.getLogger(__name__);

# Collection names
glob WEBHOOKS_COLLECTION = 'webhooks',
     DELIVERY_LOGS_COLLECTION = 'webhook_delivery_logs',
     DEAD_LETTERS_COLLECTION = 'webhook_dead_letters',
     API_KEYS_COLLECTION = 'webhook_api_keys';

impl MongoWebhookRepository.postinit -> None {
    try {
        import from pymongo { MongoClient }
        self.client = MongoClient(self.mongo_url, serverSelectionTimeoutMS=2000);
        # Test connection
        self.client.admin.command('ping');
        self._available = True;
        logger.debug("MongoDB webhook repository connected");
        # Create indexes for efficient queries
        self._create_indexes();
    } except Exception as e {
        logger.debug(f"MongoDB not available for webhooks: {e}");
        self.client = None;
        self._available = False;
    }
}

impl MongoWebhookRepository.is_available -> bool {
    return self._available;
}

impl MongoWebhookRepository._get_collection(collection_name: str) -> Any {
    if not self.client {
        raise RuntimeError("MongoDB client not available");
    }
    return self.client[self.db_name][collection_name];
}

"""Create indexes for efficient queries."""
def _create_indexes(self: MongoWebhookRepository) -> None {
    try {
        # Webhooks indexes
        webhooks = self._get_collection(WEBHOOKS_COLLECTION);
        webhooks.create_index('walker_name');
        webhooks.create_index([('walker_name', 1), ('direction', 1)]);
        webhooks.create_index([('walker_name', 1), ('is_active', 1)]);

        # Delivery logs indexes
        logs = self._get_collection(DELIVERY_LOGS_COLLECTION);
        logs.create_index('webhook_id');
        logs.create_index([('status', 1), ('next_retry_at', 1)]);
        logs.create_index('created_at');

        # Dead letters indexes
        dlq = self._get_collection(DEAD_LETTERS_COLLECTION);
        dlq.create_index('webhook_id');
        dlq.create_index('walker_name');

        # API keys indexes
        keys = self._get_collection(API_KEYS_COLLECTION);
        keys.create_index('webhook_id');
        keys.create_index('key_hash', unique=True);
    } except Exception as e {
        logger.warning(f"Failed to create indexes: {e}");
    }
}

# =============================================================================
# Webhook Registration CRUD
# =============================================================================

impl MongoWebhookRepository.create_webhook(
    self: MongoWebhookRepository, webhook: WebhookRegistration
) -> WebhookRegistration {
    collection = self._get_collection(WEBHOOKS_COLLECTION);
    doc = webhook.model_dump();
    doc['_id'] = webhook.id;
    collection.insert_one(doc);
    logger.debug(f"Created webhook {webhook.id} for walker {webhook.walker_name}");
    return webhook;
}

impl MongoWebhookRepository.get_webhook(
    self: MongoWebhookRepository, webhook_id: str
) -> (WebhookRegistration | None) {
    collection = self._get_collection(WEBHOOKS_COLLECTION);
    doc = collection.find_one({'_id': webhook_id});
    if doc {
        doc.pop('_id', None);
        return WebhookRegistration(**doc);
    }
    return None;
}

impl MongoWebhookRepository.get_webhooks_by_walker(
    self: MongoWebhookRepository, walker_name: str
) -> list[WebhookRegistration] {
    collection = self._get_collection(WEBHOOKS_COLLECTION);
    docs = collection.find({'walker_name': walker_name});
    result: list[WebhookRegistration] = [];
    for doc in docs {
        doc.pop('_id', None);
        result.append(WebhookRegistration(**doc));
    }
    return result;
}

impl MongoWebhookRepository.get_active_outbound_webhooks(
    self: MongoWebhookRepository, walker_name: str
) -> list[WebhookRegistration] {
    collection = self._get_collection(WEBHOOKS_COLLECTION);
    docs = collection.find({
        'walker_name': walker_name,
        'direction': 'outbound',
        'is_active': True
    });
    result: list[WebhookRegistration] = [];
    for doc in docs {
        doc.pop('_id', None);
        result.append(WebhookRegistration(**doc));
    }
    return result;
}

impl MongoWebhookRepository.get_active_inbound_webhooks(
    self: MongoWebhookRepository, walker_name: str
) -> list[WebhookRegistration] {
    collection = self._get_collection(WEBHOOKS_COLLECTION);
    docs = collection.find({
        'walker_name': walker_name,
        'direction': 'inbound',
        'is_active': True
    });
    result: list[WebhookRegistration] = [];
    for doc in docs {
        doc.pop('_id', None);
        result.append(WebhookRegistration(**doc));
    }
    return result;
}

impl MongoWebhookRepository.update_webhook(
    self: MongoWebhookRepository, webhook_id: str, updates: dict[str, Any]
) -> (WebhookRegistration | None) {
    collection = self._get_collection(WEBHOOKS_COLLECTION);
    updates['updated_at'] = datetime.now(UTC).isoformat();
    result = collection.find_one_and_update(
        {'_id': webhook_id},
        {'$set': updates},
        return_document=True
    );
    if result {
        result.pop('_id', None);
        return WebhookRegistration(**result);
    }
    return None;
}

impl MongoWebhookRepository.delete_webhook(
    self: MongoWebhookRepository, webhook_id: str
) -> bool {
    collection = self._get_collection(WEBHOOKS_COLLECTION);
    result = collection.delete_one({'_id': webhook_id});
    return result.deleted_count > 0;
}

impl MongoWebhookRepository.list_webhooks(
    self: MongoWebhookRepository,
    direction: (str | None) = None,
    is_active: (bool | None) = None,
    limit: int = 100,
    offset: int = 0
) -> list[WebhookRegistration] {
    collection = self._get_collection(WEBHOOKS_COLLECTION);
    query: dict[str, Any] = {};
    if direction is not None {
        query['direction'] = direction;
    }
    if is_active is not None {
        query['is_active'] = is_active;
    }
    docs = collection.find(query).skip(offset).limit(limit);
    result: list[WebhookRegistration] = [];
    for doc in docs {
        doc.pop('_id', None);
        result.append(WebhookRegistration(**doc));
    }
    return result;
}

# =============================================================================
# Delivery Log Operations
# =============================================================================

impl MongoWebhookRepository.create_delivery_log(
    self: MongoWebhookRepository, log: WebhookDeliveryLog
) -> WebhookDeliveryLog {
    collection = self._get_collection(DELIVERY_LOGS_COLLECTION);
    doc = log.model_dump();
    doc['_id'] = log.id;
    collection.insert_one(doc);
    return log;
}

impl MongoWebhookRepository.get_delivery_log(
    self: MongoWebhookRepository, log_id: str
) -> (WebhookDeliveryLog | None) {
    collection = self._get_collection(DELIVERY_LOGS_COLLECTION);
    doc = collection.find_one({'_id': log_id});
    if doc {
        doc.pop('_id', None);
        return WebhookDeliveryLog(**doc);
    }
    return None;
}

impl MongoWebhookRepository.update_delivery_log(
    self: MongoWebhookRepository, log_id: str, updates: dict[str, Any]
) -> (WebhookDeliveryLog | None) {
    collection = self._get_collection(DELIVERY_LOGS_COLLECTION);
    result = collection.find_one_and_update(
        {'_id': log_id},
        {'$set': updates},
        return_document=True
    );
    if result {
        result.pop('_id', None);
        return WebhookDeliveryLog(**result);
    }
    return None;
}

impl MongoWebhookRepository.get_delivery_logs_by_webhook(
    self: MongoWebhookRepository,
    webhook_id: str,
    limit: int = 50,
    offset: int = 0
) -> list[WebhookDeliveryLog] {
    collection = self._get_collection(DELIVERY_LOGS_COLLECTION);
    docs = collection.find({'webhook_id': webhook_id}).sort(
        'created_at', -1
    ).skip(offset).limit(limit);
    result: list[WebhookDeliveryLog] = [];
    for doc in docs {
        doc.pop('_id', None);
        result.append(WebhookDeliveryLog(**doc));
    }
    return result;
}

impl MongoWebhookRepository.get_pending_retries(
    self: MongoWebhookRepository, before_time: str
) -> list[WebhookDeliveryLog] {
    collection = self._get_collection(DELIVERY_LOGS_COLLECTION);
    docs = collection.find({
        'status': 'retrying',
        'next_retry_at': {'$lte': before_time}
    });
    result: list[WebhookDeliveryLog] = [];
    for doc in docs {
        doc.pop('_id', None);
        result.append(WebhookDeliveryLog(**doc));
    }
    return result;
}

# =============================================================================
# Dead Letter Queue Operations
# =============================================================================

impl MongoWebhookRepository.add_to_dead_letter(
    self: MongoWebhookRepository, entry: DeadLetterEntry
) -> DeadLetterEntry {
    collection = self._get_collection(DEAD_LETTERS_COLLECTION);
    doc = entry.model_dump();
    doc['_id'] = entry.id;
    collection.insert_one(doc);
    logger.info(f"Added delivery to dead letter queue: {entry.id}");
    return entry;
}

impl MongoWebhookRepository.get_dead_letter(
    self: MongoWebhookRepository, entry_id: str
) -> (DeadLetterEntry | None) {
    collection = self._get_collection(DEAD_LETTERS_COLLECTION);
    doc = collection.find_one({'_id': entry_id});
    if doc {
        doc.pop('_id', None);
        return DeadLetterEntry(**doc);
    }
    return None;
}

impl MongoWebhookRepository.list_dead_letters(
    self: MongoWebhookRepository,
    webhook_id: (str | None) = None,
    limit: int = 50,
    offset: int = 0
) -> list[DeadLetterEntry] {
    collection = self._get_collection(DEAD_LETTERS_COLLECTION);
    query: dict[str, Any] = {};
    if webhook_id is not None {
        query['webhook_id'] = webhook_id;
    }
    docs = collection.find(query).sort('created_at', -1).skip(offset).limit(limit);
    result: list[DeadLetterEntry] = [];
    for doc in docs {
        doc.pop('_id', None);
        result.append(DeadLetterEntry(**doc));
    }
    return result;
}

impl MongoWebhookRepository.remove_dead_letter(
    self: MongoWebhookRepository, entry_id: str
) -> bool {
    collection = self._get_collection(DEAD_LETTERS_COLLECTION);
    result = collection.delete_one({'_id': entry_id});
    return result.deleted_count > 0;
}

impl MongoWebhookRepository.mark_dead_letter_permanent(
    self: MongoWebhookRepository, entry_id: str
) -> (DeadLetterEntry | None) {
    collection = self._get_collection(DEAD_LETTERS_COLLECTION);
    result = collection.find_one_and_update(
        {'_id': entry_id},
        {'$set': {'can_retry': False}},
        return_document=True
    );
    if result {
        result.pop('_id', None);
        return DeadLetterEntry(**result);
    }
    return None;
}

# =============================================================================
# API Key Operations
# =============================================================================

impl MongoWebhookRepository.create_api_key(
    self: MongoWebhookRepository, api_key: WebhookApiKey
) -> WebhookApiKey {
    collection = self._get_collection(API_KEYS_COLLECTION);
    doc = api_key.model_dump();
    doc['_id'] = api_key.id;
    collection.insert_one(doc);
    logger.debug(f"Created API key {api_key.key_prefix}... for webhook {api_key.webhook_id}");
    return api_key;
}

impl MongoWebhookRepository.get_api_key(
    self: MongoWebhookRepository, key_id: str
) -> (WebhookApiKey | None) {
    collection = self._get_collection(API_KEYS_COLLECTION);
    doc = collection.find_one({'_id': key_id});
    if doc {
        doc.pop('_id', None);
        return WebhookApiKey(**doc);
    }
    return None;
}

impl MongoWebhookRepository.find_api_key_by_hash(
    self: MongoWebhookRepository, key_hash: str
) -> (WebhookApiKey | None) {
    collection = self._get_collection(API_KEYS_COLLECTION);
    doc = collection.find_one({'key_hash': key_hash, 'is_active': True});
    if doc {
        doc.pop('_id', None);
        return WebhookApiKey(**doc);
    }
    return None;
}

impl MongoWebhookRepository.get_api_keys_by_webhook(
    self: MongoWebhookRepository, webhook_id: str
) -> list[WebhookApiKey] {
    collection = self._get_collection(API_KEYS_COLLECTION);
    docs = collection.find({'webhook_id': webhook_id});
    result: list[WebhookApiKey] = [];
    for doc in docs {
        doc.pop('_id', None);
        result.append(WebhookApiKey(**doc));
    }
    return result;
}

impl MongoWebhookRepository.revoke_api_key(
    self: MongoWebhookRepository, key_id: str
) -> bool {
    collection = self._get_collection(API_KEYS_COLLECTION);
    result = collection.update_one(
        {'_id': key_id},
        {'$set': {'is_active': False}}
    );
    return result.modified_count > 0;
}

impl MongoWebhookRepository.touch_api_key(
    self: MongoWebhookRepository, key_id: str
) -> None {
    collection = self._get_collection(API_KEYS_COLLECTION);
    collection.update_one(
        {'_id': key_id},
        {'$set': {'last_used_at': datetime.now(UTC).isoformat()}}
    );
}

impl MongoWebhookRepository.delete_api_key(
    self: MongoWebhookRepository, key_id: str
) -> bool {
    collection = self._get_collection(API_KEYS_COLLECTION);
    result = collection.delete_one({'_id': key_id});
    return result.deleted_count > 0;
}

# =============================================================================
# Utility Operations
# =============================================================================

impl MongoWebhookRepository.get_webhook_stats(
    self: MongoWebhookRepository, webhook_id: str
) -> dict[str, Any] {
    logs_collection = self._get_collection(DELIVERY_LOGS_COLLECTION);
    dlq_collection = self._get_collection(DEAD_LETTERS_COLLECTION);

    total_deliveries = logs_collection.count_documents({'webhook_id': webhook_id});
    successful = logs_collection.count_documents({
        'webhook_id': webhook_id, 'status': 'success'
    });
    failed = logs_collection.count_documents({
        'webhook_id': webhook_id, 'status': 'failed'
    });
    pending = logs_collection.count_documents({
        'webhook_id': webhook_id, 'status': {'$in': ['pending', 'retrying']}
    });
    dead_letters = dlq_collection.count_documents({'webhook_id': webhook_id});

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

impl MongoWebhookRepository.cleanup_old_logs(
    self: MongoWebhookRepository, older_than_days: int = 30
) -> int {
    collection = self._get_collection(DELIVERY_LOGS_COLLECTION);
    cutoff = datetime.now(UTC) - timedelta(days=older_than_days);
    cutoff_str = cutoff.isoformat();
    result = collection.delete_many({
        'created_at': {'$lt': cutoff_str},
        'status': {'$in': ['success', 'failed', 'dead_letter']}
    });
    logger.info(f"Cleaned up {result.deleted_count} old delivery logs");
    return result.deleted_count;
}
