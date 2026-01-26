import logging;
import mimetypes;
import from collections.abc { Callable }
import from datetime { UTC, datetime, timedelta }
import from pathlib { Path }
import from pydantic { BaseModel, Field }
import from typing { Any }
import jwt;
import from os { getenv }
import from fastapi.middleware.cors { CORSMiddleware }
import from fastapi.responses { HTMLResponse, JSONResponse, Response, RedirectResponse }
import from jac_scale.jserver.jfast_api { JFastApiServer }
import from jac_scale.jserver.jserver {
    APIParameter,
    HTTPMethod,
    JEndPoint,
    ParameterType
}
import from jaclang.pycore.runtime { JacRuntime as Jac }
import from jaclang.runtimelib.server { JacAPIServer as JServer }
import from jaclang.runtimelib.server { JsonValue }
import from jaclang.runtimelib.transport { TransportResponse, Meta, MessageType }
import from enum { StrEnum }
import from fastapi_sso.sso.google { GoogleSSO }
import from jac_scale.utils { generate_random_password }
import from jac_scale.config_loader { get_scale_config }

# Load configuration from jac.toml with env var overrides
glob _jwt_config = get_scale_config().get_jwt_config(),
     _sso_config = get_scale_config().get_sso_config(),
     JWT_SECRET = _jwt_config['secret'],
     JWT_ALGORITHM = _jwt_config['algorithm'],
     JWT_EXP_DELTA_DAYS = _jwt_config['exp_delta_days'],
     SSO_HOST = _sso_config['host'],
     logger = logging.getLogger(__name__);

enum Platforms ( StrEnum ) { GOOGLE = 'google' }

enum Operations ( StrEnum ) { LOGIN = 'login', REGISTER = 'register' }

"""Transport type for walkers - determines how the walker is exposed."""
class TransportType(StrEnum) {
    has HTTP: str = 'http',
        WEBHOOK: str = 'webhook';
}

obj JacAPIServer(JServer) {
    # HMR (Hot Module Replacement) support fields
    has _hmr_pending: bool = False,
        _hot_reloader: Any | None = None,
        webhook_manager: WebhookManager | None = None;

    def postinit -> None;
    def login(username: str, password: str) -> TransportResponse;
    def register_login_endpoint -> None;
    def update_username(
        current_username: str, new_username: str, Authorization: (str | None) = None
    ) -> TransportResponse;

    def update_password(
        username: str,
        current_password: str,
        new_password: str,
        Authorization: (str | None) = None
    ) -> TransportResponse;

    def register_update_username_endpoint -> None;
    def register_update_password_endpoint -> None;
    def create_user(username: str, password: str) -> TransportResponse;
    def refresh_token(token: (str | None) = None) -> TransportResponse;
    def register_create_user_endpoint -> None;
    def register_refresh_token_endpoint -> None;
    def register_sso_endpoints -> None;
    def create_walker_callback(
        walker_name: str, has_node_param: bool = False
    ) -> Callable[..., TransportResponse];

    def create_walker_parameters(
        walker_name: str, invoke_on_root: bool
    ) -> list[APIParameter];

    def register_walkers_endpoints -> None;
    def create_function_callback(func_name: str) -> Callable[..., TransportResponse];
    def create_function_parameters(func_name: str) -> list[APIParameter];
    def register_functions_endpoints -> None;
    def render_page_callback -> Callable[..., HTMLResponse];
    def render_base_route_callback(app_name: str) -> Callable[..., HTMLResponse];
    def register_page_endpoint -> None;
    def serve_client_js_callback -> Callable[..., Response];
    def register_client_js_endpoint -> None;
    def register_static_file_endpoint -> None;
    def serve_static_file(file_path: str) -> Response;
    def register_root_asset_endpoint -> None;
    def serve_root_asset(file_path: str) -> Response;
    def _configure_openapi_security -> None;
    def start(dev: bool = False) -> None;
    # HMR (Hot Module Replacement) dynamic routing methods
    def enable_hmr(hot_reloader: Any) -> None;
    def register_dynamic_walker_endpoint -> None;
    def register_dynamic_function_endpoint -> None;
    def register_dynamic_introspection_endpoints -> None;
    # Webhook endpoint registration methods
    def register_webhook_endpoints -> None;
    def register_webhook_inbound_endpoint -> None;
}

class UpdateUsernameRequest(BaseModel) {
    has current_username: str = Field(..., description='Current username'),
        new_username: str = Field(..., description='New username');
}

class UpdatePasswordRequest(BaseModel) {
    has username: str = Field(..., description='Username'),
        current_password: str = Field(..., description='Current password'),
        new_password: str = Field(..., description='New password');
}

# =============================================================================
# Webhook Request/Response Models
# =============================================================================
class CreateWebhookRequest(BaseModel) {
    has walker_name: str = Field(
        ..., description='Walker name to associate with webhook'
    ),
        direction: str = Field(
            default='outbound', description='Webhook direction: inbound or outbound'
        ),
        url: str = Field(default='', description='Target URL for outbound webhooks'),
        api_key: (str | None) = Field(
            default=None, description='API key for outbound webhook auth'
        ),
        api_key_header: str = Field(
            default='X-API-Key', description='Header name for API key'
        ),
        secret: (str | None) = Field(
            default=None, description='Secret for HMAC signature'
        ),
        custom_headers: dict[str, str] = Field(
            default_factory=dict, description='Additional headers'
        ),
        retry_max_retries: int = Field(default=3, description='Max retry attempts'),
        retry_initial_backoff: int = Field(
            default=60, description='Initial backoff in seconds'
        ),
        metadata: dict[str, Any] = Field(
            default_factory=dict, description='Additional metadata'
        );
}

class UpdateWebhookRequest(BaseModel) {
    has url: (str | None) = Field(default=None, description='Target URL'),
        api_key: (str | None) = Field(default=None, description='API key'),
        secret: (str | None) = Field(default=None, description='HMAC secret'),
        custom_headers: (dict[str, str] | None) = Field(
            default=None, description='Custom headers'
        ),
        is_active: (bool | None) = Field(
            default=None, description='Whether webhook is active'
        ),
        metadata: (dict[str, Any] | None) = Field(
            default=None, description='Additional metadata'
        );
}

class CreateApiKeyRequest(BaseModel) {
    has webhook_id: str = Field(..., description='Webhook ID to create key for'),
        name: str = Field(default='', description='Human-readable key name'),
        expires_in_days: (int | None) = Field(
            default=None, description='Key expiration in days'
        );
}

class RetryDeadLetterRequest(BaseModel) {
    has entry_id: str = Field(..., description='Dead letter entry ID to retry');
}

# =============================================================================
# Webhook Manager - Manages webhook lifecycle and operations
# =============================================================================
"""Manager for webhook operations - registration, delivery, and inbound handling."""
class WebhookManager {
    has repository: Any = None,
        dispatcher: Any = None,
        _initialized: bool = False;

    def init(self: WebhookManager) -> None;
    def ensure_initialized(self: WebhookManager) -> None;
    # Webhook CRUD
    def create_webhook(
        self: WebhookManager, request: CreateWebhookRequest, username: str
    ) -> TransportResponse;

    def get_webhook(self: WebhookManager, webhook_id: str) -> TransportResponse;
    def list_webhooks(
        self: WebhookManager,
        direction: (str | None) = None,
        is_active: (bool | None) = None,
        limit: int = 100,
        offset: int = 0
    ) -> TransportResponse;

    def update_webhook(
        self: WebhookManager, webhook_id: str, request: UpdateWebhookRequest
    ) -> TransportResponse;

    def delete_webhook(self: WebhookManager, webhook_id: str) -> TransportResponse;
    # API Key management
    def create_api_key(
        self: WebhookManager, request: CreateApiKeyRequest, username: str
    ) -> TransportResponse;

    def list_api_keys(self: WebhookManager, webhook_id: str) -> TransportResponse;
    def revoke_api_key(self: WebhookManager, key_id: str) -> TransportResponse;
    # Delivery and DLQ
    async def dispatch_webhook(
        self: WebhookManager,
        walker_name: str,
        data: Any,
        username: (str | None) = None
    ) -> TransportResponse;

    def get_webhook_stats(self: WebhookManager, webhook_id: str) -> TransportResponse;
    def get_delivery_logs(
        self: WebhookManager, webhook_id: str, limit: int = 50, offset: int = 0
    ) -> TransportResponse;

    def list_dead_letters(
        self: WebhookManager,
        webhook_id: (str | None) = None,
        limit: int = 50,
        offset: int = 0
    ) -> TransportResponse;

    async def retry_dead_letter(
        self: WebhookManager, entry_id: str
    ) -> TransportResponse;

    def remove_dead_letter(self: WebhookManager, entry_id: str) -> TransportResponse;
    # Inbound webhook handling
    async def handle_inbound_webhook(
        self: WebhookManager,
        walker_name: str,
        api_key: str,
        payload: dict[str, Any],
        execution_manager: Any,
        walkers: dict[str, Any]
    ) -> TransportResponse;

    # Introspection helpers
    def get_walker_transport_type(
        self: WebhookManager, walker_cls: type, introspector: Any
    ) -> TransportType;
}
