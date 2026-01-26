"""Webhook Dispatcher Implementation.

Handles the actual HTTP delivery of webhooks with retry logic,
HMAC signing, and dead letter queue management.
"""
import logging;
import hmac;
import hashlib;
import time;
import asyncio;
import secrets;
import json;
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

glob logger = logging.getLogger(__name__);

impl WebhookDispatcher.postinit -> None {
    """Initialize the HTTP client."""
    try {
        import aiohttp;
        # Client will be created per request for safety
        self._http_client = None;
    } except ImportError {
        logger.warning("aiohttp not installed, webhook delivery disabled");
    }
}

impl WebhookDispatcher.sign_payload(payload: str, secret: str) -> str {
    """Sign a payload using HMAC-SHA256."""
    signature = hmac.new(
        secret.encode('utf-8'),
        payload.encode('utf-8'),
        hashlib.sha256
    ).hexdigest();
    return f"sha256={signature}";
}

impl WebhookDispatcher.hash_api_key(api_key: str) -> str {
    """Hash an API key for storage using SHA256."""
    return hashlib.sha256(api_key.encode('utf-8')).hexdigest();
}

impl WebhookDispatcher.generate_api_key(
    webhook_id: str,
    name: str = '',
    expires_in_days: (int | None) = None,
    created_by: (str | None) = None
) -> tuple[str, WebhookApiKey] {
    """Generate a new API key for inbound webhook authentication.

    Returns a tuple of (plaintext_key, WebhookApiKey record).
    The plaintext key should be shown to the user once and never stored.
    """
    # Generate a secure random key (32 bytes = 64 hex chars)
    plaintext_key = f"whk_{secrets.token_hex(32)}";
    key_hash = self.hash_api_key(plaintext_key);
    key_prefix = plaintext_key[:12];  # "whk_" + first 8 chars

    expires_at: (str | None) = None;
    if expires_in_days is not None {
        expires_at = (datetime.now(UTC) + timedelta(days=expires_in_days)).isoformat();
    }

    api_key_record = WebhookApiKey(
        key_hash=key_hash,
        key_prefix=key_prefix,
        webhook_id=webhook_id,
        name=name,
        expires_at=expires_at,
        created_by=created_by
    );

    # Store the hashed key
    self.repository.create_api_key(api_key_record);

    return (plaintext_key, api_key_record);
}

impl WebhookDispatcher.validate_api_key(api_key: str, webhook_id: str) -> bool {
    """Validate an API key for inbound webhook authentication."""
    key_hash = self.hash_api_key(api_key);
    api_key_record = self.repository.find_api_key_by_hash(key_hash);

    if not api_key_record {
        return False;
    }

    # Check if key belongs to the webhook
    if api_key_record.webhook_id != webhook_id {
        return False;
    }

    # Check if key is active
    if not api_key_record.is_active {
        return False;
    }

    # Check expiration
    if api_key_record.expires_at {
        expires = datetime.fromisoformat(api_key_record.expires_at);
        if datetime.now(UTC) > expires {
            return False;
        }
    }

    # Update last used timestamp
    self.repository.touch_api_key(api_key_record.id);

    return True;
}

async impl WebhookDispatcher.dispatch(
    walker_name: str,
    data: Any,
    username: (str | None) = None
) -> list[WebhookDeliveryResult] {
    """Dispatch webhook to all registered outbound URLs for a walker."""
    webhooks = self.repository.get_active_outbound_webhooks(walker_name);

    if not webhooks {
        logger.debug(f"No active outbound webhooks for walker: {walker_name}");
        return [];
    }

    # Dispatch to all webhooks concurrently
    tasks = [
        self.dispatch_single(webhook, data, username)
        for webhook in webhooks
    ];

    results = await asyncio.gather(*tasks, return_exceptions=True);

    # Convert exceptions to failed results
    final_results: list[WebhookDeliveryResult] = [];
    for (i, result) in enumerate(results) {
        if isinstance(result, Exception) {
            final_results.append(WebhookDeliveryResult(
                success=False,
                webhook_id=webhooks[i].id,
                log_id='',
                error=str(result)
            ));
        } else {
            final_results.append(result);
        }
    }

    return final_results;
}

async impl WebhookDispatcher.dispatch_single(
    webhook: WebhookRegistration,
    data: Any,
    username: (str | None) = None
) -> WebhookDeliveryResult {
    """Dispatch to a single webhook with retry logic."""
    import aiohttp;

    start_time = time.time();

    # Build payload
    payload = WebhookPayload(
        event=webhook.walker_name,
        webhook_id=webhook.id,
        direction='outbound',
        data=data
    );

    payload_json = json.dumps(payload.model_dump(), default=str);

    # Sign payload if secret configured
    signature: (str | None) = None;
    if webhook.secret {
        signature = self.sign_payload(payload_json, webhook.secret);
        payload.signature = signature;
        payload_json = json.dumps(payload.model_dump(), default=str);
    }

    # Build headers
    headers = {
        'Content-Type': 'application/json',
        'User-Agent': 'JacScale-Webhook/1.0',
        'X-Webhook-ID': webhook.id,
        'X-Webhook-Timestamp': payload.timestamp
    };

    if signature {
        headers['X-Jac-Signature'] = signature;
    }

    if webhook.api_key {
        headers[webhook.api_key_header] = webhook.api_key;
    }

    # Add custom headers
    headers.update(webhook.custom_headers);

    # Create delivery log
    log = WebhookDeliveryLog(
        webhook_id=webhook.id,
        walker_name=webhook.walker_name,
        direction='outbound',
        url=webhook.url,
        status='pending',
        request_payload=payload.model_dump(),
        request_headers={k: v for (k, v) in headers.items() if k != webhook.api_key_header}
    );
    log = self.repository.create_delivery_log(log);

    try {
        async with aiohttp.ClientSession() as session {
            async with session.post(
                webhook.url,
                data=payload_json,
                headers=headers,
                timeout=aiohttp.ClientTimeout(total=self.default_timeout)
            ) as response {
                duration_ms = int((time.time() - start_time) * 1000);
                response_body = await response.text();

                # Truncate response body
                if len(response_body) > self.max_response_size {
                    response_body = response_body[:self.max_response_size] + '... (truncated)';
                }

                if response.status >= 200 and response.status < 300 {
                    # Success!
                    self.repository.update_delivery_log(log.id, {
                        'status': 'success',
                        'response_status_code': response.status,
                        'response_body': response_body,
                        'completed_at': datetime.now(UTC).isoformat(),
                        'duration_ms': duration_ms
                    });

                    logger.debug(f"Webhook delivered successfully: {webhook.id} -> {webhook.url}");

                    return WebhookDeliveryResult(
                        success=True,
                        webhook_id=webhook.id,
                        log_id=log.id,
                        status_code=response.status,
                        duration_ms=duration_ms
                    );
                } else {
                    # Failed - schedule retry or move to DLQ
                    return await self._handle_failed_delivery(
                        webhook, log, response.status, response_body, duration_ms
                    );
                }
            }
        }
    } except asyncio.TimeoutError {
        duration_ms = int((time.time() - start_time) * 1000);
        return await self._handle_failed_delivery(
            webhook, log, None, 'Request timed out', duration_ms
        );
    } except Exception as e {
        duration_ms = int((time.time() - start_time) * 1000);
        return await self._handle_failed_delivery(
            webhook, log, None, str(e), duration_ms
        );
    }
}

async def _handle_failed_delivery(
    self: WebhookDispatcher,
    webhook: WebhookRegistration,
    log: WebhookDeliveryLog,
    status_code: (int | None),
    error_message: str,
    duration_ms: int
) -> WebhookDeliveryResult {
    """Handle failed delivery - retry or move to dead letter queue."""
    retry_policy = webhook.retry_policy;
    max_retries = retry_policy.max_retries if retry_policy else 3;

    if log.attempt_number >= max_retries {
        # Move to dead letter queue
        self.repository.update_delivery_log(log.id, {
            'status': 'dead_letter',
            'response_status_code': status_code,
            'error_message': error_message,
            'completed_at': datetime.now(UTC).isoformat(),
            'duration_ms': duration_ms
        });

        # Create DLQ entry
        dlq_entry = DeadLetterEntry(
            webhook_id=webhook.id,
            walker_name=webhook.walker_name,
            direction='outbound',
            url=webhook.url,
            payload=log.request_payload or {},
            headers=log.request_headers or {},
            last_error=error_message,
            total_attempts=log.attempt_number
        );
        self.repository.add_to_dead_letter(dlq_entry);

        logger.warning(
            f"Webhook delivery exhausted retries, moved to DLQ: {webhook.id} -> {webhook.url}"
        );

        return WebhookDeliveryResult(
            success=False,
            webhook_id=webhook.id,
            log_id=log.id,
            status_code=status_code,
            error=f"Moved to dead letter queue after {max_retries} attempts: {error_message}",
            duration_ms=duration_ms
        );
    } else {
        # Schedule retry
        initial_backoff = retry_policy.initial_backoff_seconds if retry_policy else 60;
        multiplier = retry_policy.backoff_multiplier if retry_policy else 2.0;
        max_backoff = retry_policy.max_backoff_seconds if retry_policy else 3600;

        backoff = min(initial_backoff * (multiplier ** (log.attempt_number - 1)), max_backoff);
        next_retry = datetime.now(UTC) + timedelta(seconds=backoff);

        self.repository.update_delivery_log(log.id, {
            'status': 'retrying',
            'response_status_code': status_code,
            'error_message': error_message,
            'attempt_number': log.attempt_number + 1,
            'next_retry_at': next_retry.isoformat(),
            'duration_ms': duration_ms
        });

        logger.info(
            f"Webhook delivery failed, retry scheduled for {next_retry}: "
            f"{webhook.id} -> {webhook.url}"
        );

        return WebhookDeliveryResult(
            success=False,
            webhook_id=webhook.id,
            log_id=log.id,
            status_code=status_code,
            error=f"Retry scheduled (attempt {log.attempt_number + 1}/{max_retries}): {error_message}",
            duration_ms=duration_ms
        );
    }
}

async impl WebhookDispatcher.retry_dead_letter(entry_id: str) -> WebhookDeliveryResult {
    """Retry a failed delivery from the dead letter queue."""
    entry = self.repository.get_dead_letter(entry_id);
    if not entry {
        return WebhookDeliveryResult(
            success=False,
            webhook_id='',
            log_id='',
            error='Dead letter entry not found'
        );
    }

    if not entry.can_retry {
        return WebhookDeliveryResult(
            success=False,
            webhook_id=entry.webhook_id,
            log_id='',
            error='Entry marked as non-retryable'
        );
    }

    webhook = self.repository.get_webhook(entry.webhook_id);
    if not webhook {
        return WebhookDeliveryResult(
            success=False,
            webhook_id=entry.webhook_id,
            log_id='',
            error='Associated webhook not found'
        );
    }

    # Attempt redelivery
    result = await self.dispatch_single(webhook, entry.payload.get('data'));

    if result.success {
        # Remove from DLQ on success
        self.repository.remove_dead_letter(entry_id);
        logger.info(f"Successfully retried dead letter entry: {entry_id}");
    } else {
        # Update attempt count
        self.repository.update_delivery_log(result.log_id, {
            'attempt_number': entry.total_attempts + 1
        });
    }

    return result;
}

async impl WebhookDispatcher.process_pending_retries -> list[WebhookDeliveryResult] {
    """Process all pending retries that are due.

    This should be called periodically (e.g., every minute) by a background task.
    """
    now = datetime.now(UTC).isoformat();
    pending_logs = self.repository.get_pending_retries(now);

    if not pending_logs {
        return [];
    }

    results: list[WebhookDeliveryResult] = [];

    for log in pending_logs {
        webhook = self.repository.get_webhook(log.webhook_id);
        if not webhook {
            # Webhook deleted, mark log as failed
            self.repository.update_delivery_log(log.id, {
                'status': 'failed',
                'error_message': 'Associated webhook not found',
                'completed_at': datetime.now(UTC).isoformat()
            });
            continue;
        }

        if not webhook.is_active {
            # Webhook disabled, mark log as failed
            self.repository.update_delivery_log(log.id, {
                'status': 'failed',
                'error_message': 'Webhook disabled',
                'completed_at': datetime.now(UTC).isoformat()
            });
            continue;
        }

        # Extract original data from log
        original_data = log.request_payload.get('data') if log.request_payload else None;

        # Update log with current attempt
        self.repository.update_delivery_log(log.id, {
            'status': 'pending'
        });

        result = await self.dispatch_single(webhook, original_data);
        results.append(result);

    }

    logger.info(f"Processed {len(results)} pending webhook retries");
    return results;
}

async impl WebhookDispatcher.close -> None {
    """Shutdown the dispatcher and close HTTP client."""
    if self._http_client {
        await self._http_client.close();
        self._http_client = None;
    }
