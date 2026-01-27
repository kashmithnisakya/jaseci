"""Webhook support for Jac Scale.

This module provides webhook-related functionality including:
- API key generation and management
- HMAC-SHA256 signature verification for webhook security
- Webhook configuration and utilities

API keys are generated per-user and can be used to authenticate webhook calls.
The API key is wrapped in a JWT for secure storage and validation.
"""
import hmac;
import hashlib;
import secrets;
import jwt;
import from datetime { UTC, datetime, timedelta }
import from typing { Any }
import from pydantic { BaseModel, Field }
import from jaclang.runtimelib.transport { TransportResponse, Meta }
import from jac_scale.config_loader { get_scale_config }

# Load webhook configuration
glob _webhook_config = get_scale_config().get_webhook_config(),
     WEBHOOK_SECRET = _webhook_config['secret'],
     WEBHOOK_SIGNATURE_HEADER = _webhook_config['signature_header'],
     WEBHOOK_VERIFY_SIGNATURE = _webhook_config['verify_signature'],
     WEBHOOK_API_KEY_EXPIRY_DAYS = _webhook_config['api_key_expiry_days'];

"""Pydantic model for API key creation request."""
class CreateApiKeyRequest(BaseModel) {
    has name: str = Field(..., description='A friendly name for the API key'),
        expiry_days: int | None = Field(
            None, description='Number of days until expiry (default from config)'
        );
}

"""Pydantic model for API key response."""
class ApiKeyResponse(BaseModel) {
    has api_key: str = Field(..., description='The generated API key'),
        api_key_id: str = Field(..., description='Unique identifier for the API key'),
        name: str = Field(..., description='Friendly name for the API key'),
        created_at: str = Field(..., description='ISO timestamp of creation'),
        expires_at: str | None = Field(
            None, description='ISO timestamp of expiry, or null if no expiry'
        );
}

"""Webhook utilities for signature generation and verification."""
obj WebhookUtils {
    """Generate HMAC-SHA256 signature for webhook payload.

    Args:
        payload: The raw request body bytes
        secret: The webhook secret key

    Returns:
        Hex-encoded HMAC-SHA256 signature
    """
    static def generate_signature(payload: bytes, secret: str) -> str;

    """Verify HMAC-SHA256 signature for webhook payload.

    Args:
        payload: The raw request body bytes
        signature: The signature from the request header
        secret: The webhook secret key

    Returns:
        True if signature is valid, False otherwise
    """
    static def verify_signature(payload: bytes, signature: str, secret: str) -> bool;

    """Generate a new API key.

    Creates a cryptographically secure random API key.

    Returns:
        A 32-character hex string API key
    """
    static def generate_api_key -> str;

    """Create a JWT-wrapped API key token.

    The API key is embedded in a JWT for secure validation and expiry management.

    Args:
        api_key_id: Unique identifier for this API key
        username: The user who owns this API key
        name: Friendly name for the API key
        expiry_days: Number of days until expiry (None for no expiry)

    Returns:
        JWT token containing the API key information
    """
    static def create_api_key_token(
        api_key_id: str, username: str, name: str, expiry_days: int | None = None
    ) -> str;

    """Validate an API key token and extract user information.

    Args:
        api_key: The API key token to validate

    Returns:
        Dict with 'username', 'api_key_id', 'name' if valid, None otherwise
    """
    static def validate_api_key(api_key: str) -> dict[str, str] | None;

    """Extract signature from request header value.

    Handles various signature formats like:
    - Plain signature: "abc123..."
    - Prefixed signature: "sha256=abc123..."

    Args:
        header_value: The raw header value

    Returns:
        The extracted signature string
    """
    static def extract_signature(header_value: str) -> str;
}

"""Manager for API keys associated with users."""
obj ApiKeyManager {
    has _api_keys: dict[str, dict[str, Any]] = {},  # api_key_id -> key info
        _user_keys: dict[str, list[str]] = {};  # username -> list of api_key_ids

    """Create a new API key for a user.

    Args:
        username: The user to create the key for
        name: Friendly name for the API key
        expiry_days: Number of days until expiry (None for default from config)

    Returns:
        TransportResponse with API key details
    """
    def create_api_key(
        username: str, name: str, expiry_days: int | None = None
    ) -> TransportResponse;

    """List all API keys for a user.

    Args:
        username: The user to list keys for

    Returns:
        TransportResponse with list of API key metadata (not the keys themselves)
    """
    def list_api_keys(username: str) -> TransportResponse;

    """Revoke an API key.

    Args:
        username: The user who owns the key
        api_key_id: The ID of the key to revoke

    Returns:
        TransportResponse indicating success or failure
    """
    def revoke_api_key(username: str, api_key_id: str) -> TransportResponse;

    """Validate an API key and return the associated username.

    Args:
        api_key: The API key to validate

    Returns:
        The username if valid, None otherwise
    """
    def validate_api_key(api_key: str) -> str | None;

    """Check if an API key ID exists and is not revoked.

    Args:
        api_key_id: The API key ID to check

    Returns:
        True if the key exists and is active, False otherwise
    """
    def is_key_active(api_key_id: str) -> bool;
}
