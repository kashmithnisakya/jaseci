"""Webhook data models for jac-scale.

Defines the core data structures for webhook registration, delivery,
audit logging, and dead letter queue management.
"""
import from datetime { datetime, UTC }
import from typing { Any }
import from pydantic { BaseModel, Field }
import from enum { StrEnum }
import from uuid { uuid4 }

"""Webhook event direction - inbound (receive) or outbound (send)."""
class WebhookDirection(StrEnum) {
    has INBOUND: str = 'inbound',    # External service calls our webhook
        OUTBOUND: str = 'outbound';  # We call external service's webhook
}

"""Webhook delivery status."""
class DeliveryStatus(StrEnum) {
    has PENDING: str = 'pending',
        SUCCESS: str = 'success',
        FAILED: str = 'failed',
        RETRYING: str = 'retrying',
        DEAD_LETTER: str = 'dead_letter';
}

"""Retry policy for webhook deliveries."""
class RetryPolicy(BaseModel) {
    has max_retries: int = Field(default=3, description='Maximum number of retry attempts'),
        initial_backoff_seconds: int = Field(default=60, description='Initial backoff in seconds'),
        backoff_multiplier: float = Field(default=2.0, description='Multiplier for exponential backoff'),
        max_backoff_seconds: int = Field(default=3600, description='Maximum backoff in seconds');
}

"""Webhook registration for a walker.

Stores configuration for both inbound and outbound webhooks.
"""
class WebhookRegistration(BaseModel) {
    has id: str = Field(default_factory=lambda: str(uuid4()), description='Unique webhook ID'),
        walker_name: str = Field(..., description='Associated walker name'),
        direction: str = Field(default='outbound', description='Webhook direction: inbound or outbound'),
        url: str = Field(default='', description='Target URL for outbound, empty for inbound'),
        api_key: (str | None) = Field(default=None, description='API key for authentication'),
        api_key_header: str = Field(default='X-API-Key', description='Header name for API key'),
        secret: (str | None) = Field(default=None, description='Secret for HMAC signature'),
        custom_headers: dict[str, str] = Field(default_factory=dict, description='Additional headers'),
        retry_policy: (RetryPolicy | None) = Field(default_factory=RetryPolicy, description='Retry configuration'),
        is_active: bool = Field(default=True, description='Whether webhook is active'),
        created_at: str = Field(default_factory=lambda: datetime.now(UTC).isoformat(), description='Creation timestamp'),
        updated_at: str = Field(default_factory=lambda: datetime.now(UTC).isoformat(), description='Last update timestamp'),
        created_by: (str | None) = Field(default=None, description='Username who created the webhook'),
        metadata: dict[str, Any] = Field(default_factory=dict, description='Additional metadata');

    """Update the updated_at timestamp."""
    def touch(self: WebhookRegistration) -> None {
        self.updated_at = datetime.now(UTC).isoformat();
    }
}

"""Payload structure for webhook deliveries."""
class WebhookPayload(BaseModel) {
    has event: str = Field(..., description='Event/walker name'),
        webhook_id: str = Field(..., description='Associated webhook registration ID'),
        direction: str = Field(..., description='Webhook direction'),
        data: Any = Field(default=None, description='Payload data'),
        timestamp: str = Field(default_factory=lambda: datetime.now(UTC).isoformat(), description='Event timestamp'),
        signature: (str | None) = Field(default=None, description='HMAC signature if secret configured');
}

"""Webhook delivery log entry for audit trail."""
class WebhookDeliveryLog(BaseModel) {
    has id: str = Field(default_factory=lambda: str(uuid4()), description='Unique log entry ID'),
        webhook_id: str = Field(..., description='Associated webhook registration ID'),
        walker_name: str = Field(..., description='Walker that triggered the delivery'),
        direction: str = Field(..., description='Webhook direction'),
        url: str = Field(default='', description='Target URL'),
        status: str = Field(default='pending', description='Delivery status'),
        request_payload: (dict[str, Any] | None) = Field(default=None, description='Request payload sent'),
        request_headers: (dict[str, str] | None) = Field(default=None, description='Request headers sent'),
        response_status_code: (int | None) = Field(default=None, description='HTTP response status code'),
        response_body: (str | None) = Field(default=None, description='Response body (truncated)'),
        error_message: (str | None) = Field(default=None, description='Error message if failed'),
        attempt_number: int = Field(default=1, description='Current attempt number'),
        next_retry_at: (str | None) = Field(default=None, description='Next retry timestamp'),
        created_at: str = Field(default_factory=lambda: datetime.now(UTC).isoformat(), description='Log entry timestamp'),
        completed_at: (str | None) = Field(default=None, description='Completion timestamp'),
        duration_ms: (int | None) = Field(default=None, description='Request duration in milliseconds');
}

"""Dead letter queue entry for failed deliveries."""
class DeadLetterEntry(BaseModel) {
    has id: str = Field(default_factory=lambda: str(uuid4()), description='Unique DLQ entry ID'),
        webhook_id: str = Field(..., description='Associated webhook registration ID'),
        walker_name: str = Field(..., description='Walker that triggered the delivery'),
        direction: str = Field(..., description='Webhook direction'),
        url: str = Field(default='', description='Target URL'),
        payload: dict[str, Any] = Field(default_factory=dict, description='Original payload'),
        headers: dict[str, str] = Field(default_factory=dict, description='Original headers'),
        last_error: str = Field(default='', description='Last error message'),
        total_attempts: int = Field(default=0, description='Total delivery attempts'),
        first_attempted_at: str = Field(default_factory=lambda: datetime.now(UTC).isoformat(), description='First attempt timestamp'),
        last_attempted_at: str = Field(default_factory=lambda: datetime.now(UTC).isoformat(), description='Last attempt timestamp'),
        created_at: str = Field(default_factory=lambda: datetime.now(UTC).isoformat(), description='DLQ entry creation timestamp'),
        can_retry: bool = Field(default=True, description='Whether manual retry is allowed');
}

"""API key registration for inbound webhook authentication."""
class WebhookApiKey(BaseModel) {
    has id: str = Field(default_factory=lambda: str(uuid4()), description='Unique API key ID'),
        key_hash: str = Field(..., description='Hashed API key (never store plain text)'),
        key_prefix: str = Field(..., description='First 8 chars of key for identification'),
        webhook_id: str = Field(..., description='Associated webhook registration ID'),
        name: str = Field(default='', description='Human-readable key name'),
        is_active: bool = Field(default=True, description='Whether key is active'),
        created_at: str = Field(default_factory=lambda: datetime.now(UTC).isoformat(), description='Creation timestamp'),
        expires_at: (str | None) = Field(default=None, description='Expiration timestamp'),
        last_used_at: (str | None) = Field(default=None, description='Last usage timestamp'),
        created_by: (str | None) = Field(default=None, description='Username who created the key');
}

"""Result of a webhook delivery attempt."""
class WebhookDeliveryResult(BaseModel) {
    has success: bool = Field(..., description='Whether delivery was successful'),
        webhook_id: str = Field(..., description='Webhook ID'),
        log_id: str = Field(..., description='Delivery log entry ID'),
        status_code: (int | None) = Field(default=None, description='HTTP status code'),
        error: (str | None) = Field(default=None, description='Error message if failed'),
        duration_ms: (int | None) = Field(default=None, description='Request duration');
}
