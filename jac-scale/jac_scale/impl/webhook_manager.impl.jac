"""Webhook Manager Implementation.

Provides the business logic for webhook operations including
registration, dispatch, API key management, and inbound handling.
"""
import logging;
import from datetime { datetime, UTC }
import from typing { Any }
import from jaclang.runtimelib.transport { TransportResponse, Meta }
import from jac_scale.abstractions.models.webhook {
    WebhookRegistration,
    RetryPolicy,
    WebhookDirection
}

glob logger = logging.getLogger(__name__);

impl WebhookManager.init(self: WebhookManager) -> None {
    """Initialize the webhook manager with repository and dispatcher."""
    if self._initialized {
        return;
    }
    import from jac_scale.utilities.webhook_repository { create_webhook_repository }
    import from jac_scale.utilities.webhook_dispatcher { WebhookDispatcher }

    self.repository = create_webhook_repository();
    self.dispatcher = WebhookDispatcher(repository=self.repository);
    self._initialized = True;
    logger.debug("WebhookManager initialized");
}

impl WebhookManager.ensure_initialized(self: WebhookManager) -> None {
    """Ensure the manager is initialized before operations."""
    if not self._initialized {
        self.init();
    }
}

# =============================================================================
# Webhook CRUD Operations
# =============================================================================

impl WebhookManager.create_webhook(
    self: WebhookManager,
    request: CreateWebhookRequest,
    username: str
) -> TransportResponse {
    """Create a new webhook registration."""
    self.ensure_initialized();

    # Validate direction
    if request.direction not in ['inbound', 'outbound'] {
        return TransportResponse.fail(
            code='VALIDATION_ERROR',
            message="Direction must be 'inbound' or 'outbound'",
            meta=Meta(extra={'http_status': 400})
        );
    }

    # Outbound webhooks require URL
    if request.direction == 'outbound' and not request.url {
        return TransportResponse.fail(
            code='VALIDATION_ERROR',
            message='URL is required for outbound webhooks',
            meta=Meta(extra={'http_status': 400})
        );
    }

    # Create retry policy
    retry_policy = RetryPolicy(
        max_retries=request.retry_max_retries,
        initial_backoff_seconds=request.retry_initial_backoff
    );

    # Create webhook registration
    webhook = WebhookRegistration(
        walker_name=request.walker_name,
        direction=request.direction,
        url=request.url,
        api_key=request.api_key,
        api_key_header=request.api_key_header,
        secret=request.secret,
        custom_headers=request.custom_headers,
        retry_policy=retry_policy,
        created_by=username,
        metadata=request.metadata
    );

    created = self.repository.create_webhook(webhook);
    logger.info(f"Created webhook {created.id} for walker {created.walker_name}");

    return TransportResponse.success(
        data={
            'webhook': created.model_dump(),
            'message': 'Webhook created successfully'
        },
        meta=Meta(extra={'http_status': 201})
    );
}

impl WebhookManager.get_webhook(
    self: WebhookManager, webhook_id: str
) -> TransportResponse {
    """Get webhook details by ID."""
    self.ensure_initialized();

    webhook = self.repository.get_webhook(webhook_id);
    if not webhook {
        return TransportResponse.fail(
            code='NOT_FOUND',
            message=f'Webhook not found: {webhook_id}',
            meta=Meta(extra={'http_status': 404})
        );
    }

    return TransportResponse.success(
        data={'webhook': webhook.model_dump()},
        meta=Meta(extra={'http_status': 200})
    );
}

impl WebhookManager.list_webhooks(
    self: WebhookManager,
    direction: (str | None) = None,
    is_active: (bool | None) = None,
    limit: int = 100,
    offset: int = 0
) -> TransportResponse {
    """List webhooks with optional filtering."""
    self.ensure_initialized();

    webhooks = self.repository.list_webhooks(
        direction=direction,
        is_active=is_active,
        limit=limit,
        offset=offset
    );

    return TransportResponse.success(
        data={
            'webhooks': [w.model_dump() for w in webhooks],
            'count': len(webhooks),
            'limit': limit,
            'offset': offset
        },
        meta=Meta(extra={'http_status': 200})
    );
}

impl WebhookManager.update_webhook(
    self: WebhookManager,
    webhook_id: str,
    request: UpdateWebhookRequest
) -> TransportResponse {
    """Update an existing webhook."""
    self.ensure_initialized();

    # Build updates dict, only including non-None values
    updates: dict[str, Any] = {};
    if request.url is not None {
        updates['url'] = request.url;
    }
    if request.api_key is not None {
        updates['api_key'] = request.api_key;
    }
    if request.secret is not None {
        updates['secret'] = request.secret;
    }
    if request.custom_headers is not None {
        updates['custom_headers'] = request.custom_headers;
    }
    if request.is_active is not None {
        updates['is_active'] = request.is_active;
    }
    if request.metadata is not None {
        updates['metadata'] = request.metadata;
    }

    if not updates {
        return TransportResponse.fail(
            code='VALIDATION_ERROR',
            message='No updates provided',
            meta=Meta(extra={'http_status': 400})
        );
    }

    updated = self.repository.update_webhook(webhook_id, updates);
    if not updated {
        return TransportResponse.fail(
            code='NOT_FOUND',
            message=f'Webhook not found: {webhook_id}',
            meta=Meta(extra={'http_status': 404})
        );
    }

    logger.info(f"Updated webhook {webhook_id}");

    return TransportResponse.success(
        data={
            'webhook': updated.model_dump(),
            'message': 'Webhook updated successfully'
        },
        meta=Meta(extra={'http_status': 200})
    );
}

impl WebhookManager.delete_webhook(
    self: WebhookManager, webhook_id: str
) -> TransportResponse {
    """Delete a webhook."""
    self.ensure_initialized();

    deleted = self.repository.delete_webhook(webhook_id);
    if not deleted {
        return TransportResponse.fail(
            code='NOT_FOUND',
            message=f'Webhook not found: {webhook_id}',
            meta=Meta(extra={'http_status': 404})
        );
    }

    logger.info(f"Deleted webhook {webhook_id}");

    return TransportResponse.success(
        data={'message': 'Webhook deleted successfully'},
        meta=Meta(extra={'http_status': 200})
    );
}

# =============================================================================
# API Key Management
# =============================================================================

impl WebhookManager.create_api_key(
    self: WebhookManager,
    request: CreateApiKeyRequest,
    username: str
) -> TransportResponse {
    """Create a new API key for webhook authentication."""
    self.ensure_initialized();

    # Verify webhook exists
    webhook = self.repository.get_webhook(request.webhook_id);
    if not webhook {
        return TransportResponse.fail(
            code='NOT_FOUND',
            message=f'Webhook not found: {request.webhook_id}',
            meta=Meta(extra={'http_status': 404})
        );
    }

    # Generate API key
    (plaintext_key, api_key_record) = self.dispatcher.generate_api_key(
        webhook_id=request.webhook_id,
        name=request.name,
        expires_in_days=request.expires_in_days,
        created_by=username
    );

    logger.info(f"Created API key {api_key_record.key_prefix}... for webhook {request.webhook_id}");

    return TransportResponse.success(
        data={
            'api_key': plaintext_key,
            'key_id': api_key_record.id,
            'key_prefix': api_key_record.key_prefix,
            'expires_at': api_key_record.expires_at,
            'message': 'API key created successfully. Store this key securely - it cannot be retrieved again.'
        },
        meta=Meta(extra={'http_status': 201})
    );
}

impl WebhookManager.list_api_keys(
    self: WebhookManager, webhook_id: str
) -> TransportResponse {
    """List API keys for a webhook (without exposing the actual keys)."""
    self.ensure_initialized();

    keys = self.repository.get_api_keys_by_webhook(webhook_id);

    # Return safe info only (no key_hash)
    safe_keys = [
        {
            'id': k.id,
            'key_prefix': k.key_prefix,
            'name': k.name,
            'is_active': k.is_active,
            'created_at': k.created_at,
            'expires_at': k.expires_at,
            'last_used_at': k.last_used_at
        } for k in keys
    ];

    return TransportResponse.success(
        data={'api_keys': safe_keys, 'count': len(safe_keys)},
        meta=Meta(extra={'http_status': 200})
    );
}

impl WebhookManager.revoke_api_key(
    self: WebhookManager, key_id: str
) -> TransportResponse {
    """Revoke (deactivate) an API key."""
    self.ensure_initialized();

    revoked = self.repository.revoke_api_key(key_id);
    if not revoked {
        return TransportResponse.fail(
            code='NOT_FOUND',
            message=f'API key not found: {key_id}',
            meta=Meta(extra={'http_status': 404})
        );
    }

    logger.info(f"Revoked API key {key_id}");

    return TransportResponse.success(
        data={'message': 'API key revoked successfully'},
        meta=Meta(extra={'http_status': 200})
    );
}

# =============================================================================
# Delivery and Dead Letter Queue
# =============================================================================

async impl WebhookManager.dispatch_webhook(
    self: WebhookManager,
    walker_name: str,
    data: Any,
    username: (str | None) = None
) -> TransportResponse {
    """Dispatch webhook to all registered outbound URLs for a walker."""
    self.ensure_initialized();

    results = await self.dispatcher.dispatch(walker_name, data, username);

    successful = [r for r in results if r.success];
    failed = [r for r in results if not r.success];

    return TransportResponse.success(
        data={
            'dispatched': len(results),
            'successful': len(successful),
            'failed': len(failed),
            'results': [r.model_dump() for r in results]
        },
        meta=Meta(extra={'http_status': 200})
    );
}

impl WebhookManager.get_webhook_stats(
    self: WebhookManager, webhook_id: str
) -> TransportResponse {
    """Get delivery statistics for a webhook."""
    self.ensure_initialized();

    stats = self.repository.get_webhook_stats(webhook_id);

    return TransportResponse.success(
        data={'stats': stats},
        meta=Meta(extra={'http_status': 200})
    );
}

impl WebhookManager.get_delivery_logs(
    self: WebhookManager,
    webhook_id: str,
    limit: int = 50,
    offset: int = 0
) -> TransportResponse {
    """Get delivery logs for a webhook (audit trail)."""
    self.ensure_initialized();

    logs = self.repository.get_delivery_logs_by_webhook(webhook_id, limit, offset);

    return TransportResponse.success(
        data={
            'logs': [l.model_dump() for l in logs],
            'count': len(logs),
            'limit': limit,
            'offset': offset
        },
        meta=Meta(extra={'http_status': 200})
    );
}

impl WebhookManager.list_dead_letters(
    self: WebhookManager,
    webhook_id: (str | None) = None,
    limit: int = 50,
    offset: int = 0
) -> TransportResponse {
    """List entries in the dead letter queue."""
    self.ensure_initialized();

    entries = self.repository.list_dead_letters(webhook_id, limit, offset);

    return TransportResponse.success(
        data={
            'dead_letters': [e.model_dump() for e in entries],
            'count': len(entries),
            'limit': limit,
            'offset': offset
        },
        meta=Meta(extra={'http_status': 200})
    );
}

async impl WebhookManager.retry_dead_letter(
    self: WebhookManager, entry_id: str
) -> TransportResponse {
    """Retry a failed delivery from the dead letter queue."""
    self.ensure_initialized();

    result = await self.dispatcher.retry_dead_letter(entry_id);

    if result.success {
        return TransportResponse.success(
            data={
                'result': result.model_dump(),
                'message': 'Delivery retried successfully'
            },
            meta=Meta(extra={'http_status': 200})
        );
    } else {
        return TransportResponse.fail(
            code='RETRY_FAILED',
            message=result.error or 'Retry failed',
            details={'result': result.model_dump()},
            meta=Meta(extra={'http_status': 500})
        );
    }
}

impl WebhookManager.remove_dead_letter(
    self: WebhookManager, entry_id: str
) -> TransportResponse {
    """Remove an entry from the dead letter queue."""
    self.ensure_initialized();

    removed = self.repository.remove_dead_letter(entry_id);
    if not removed {
        return TransportResponse.fail(
            code='NOT_FOUND',
            message=f'Dead letter entry not found: {entry_id}',
            meta=Meta(extra={'http_status': 404})
        );
    }

    return TransportResponse.success(
        data={'message': 'Dead letter entry removed'},
        meta=Meta(extra={'http_status': 200})
    );
}

# =============================================================================
# Inbound Webhook Handling
# =============================================================================

async impl WebhookManager.handle_inbound_webhook(
    self: WebhookManager,
    walker_name: str,
    api_key: str,
    payload: dict[str, Any],
    execution_manager: Any,
    walkers: dict[str, Any]
) -> TransportResponse {
    """Handle an inbound webhook - authenticate and spawn walker."""
    self.ensure_initialized();

    # Find inbound webhooks for this walker
    inbound_webhooks = self.repository.get_active_inbound_webhooks(walker_name);

    if not inbound_webhooks {
        return TransportResponse.fail(
            code='NOT_FOUND',
            message=f'No inbound webhook configured for walker: {walker_name}',
            meta=Meta(extra={'http_status': 404})
        );
    }

    # Validate API key against any of the registered webhooks
    authenticated_webhook: WebhookRegistration | None = None;
    for webhook in inbound_webhooks {
        if self.dispatcher.validate_api_key(api_key, webhook.id) {
            authenticated_webhook = webhook;
            break;
        }
    }

    if not authenticated_webhook {
        return TransportResponse.fail(
            code='UNAUTHORIZED',
            message='Invalid or expired API key',
            meta=Meta(extra={'http_status': 401})
        );
    }

    # Check if walker exists
    if walker_name not in walkers {
        return TransportResponse.fail(
            code='NOT_FOUND',
            message=f'Walker not found: {walker_name}',
            meta=Meta(extra={'http_status': 404})
        );
    }

    # Spawn the walker with the payload
    try {
        result = await execution_manager.spawn_walker(
            walkers[walker_name],
            payload,
            '__webhook__'  # Special username for webhook-triggered walkers
        );

        if 'error' in result {
            return TransportResponse.fail(
                code='EXECUTION_ERROR',
                message=result.get('error', 'Walker execution failed'),
                details=result.get('traceback'),
                meta=Meta(extra={'http_status': 500})
            );
        }

        return TransportResponse.success(
            data=result,
            meta=Meta(extra={'http_status': 200})
        );
    } except Exception as e {
        logger.error(f"Error executing inbound webhook: {e}");
        return TransportResponse.fail(
            code='INTERNAL_ERROR',
            message=str(e),
            meta=Meta(extra={'http_status': 500})
        );
    }
}

# =============================================================================
# Introspection Helpers
# =============================================================================

impl WebhookManager.get_walker_transport_type(
    self: WebhookManager,
    walker_cls: type,
    introspector: Any
) -> TransportType {
    """Get the transport type for a walker class.

    Checks if the walker has a transport_type class variable set to 'webhook'.
    """
    import from jac_scale.serve { TransportType }

    # Check for transport_type attribute on the class
    transport_type_value = getattr(walker_cls, 'transport_type', None);

    if transport_type_value is not None {
        # Handle both string and enum values
        if isinstance(transport_type_value, str) {
            if transport_type_value.lower() == 'webhook' {
                return TransportType.WEBHOOK;
            }
        } elif hasattr(transport_type_value, 'value') {
            if transport_type_value.value == 'webhook' {
                return TransportType.WEBHOOK;
            }
        }
    }

    # Default to HTTP
    return TransportType.HTTP;
}
