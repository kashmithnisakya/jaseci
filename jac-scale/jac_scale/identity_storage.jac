"""Identity-based user storage for MongoDB.

Users are stored with an array of identities (username, email, phone, SSO, etc.)
and an array of credentials (password, TOTP, etc.), enabling flexible
authentication without schema changes when new identity/credential types
are added. SSO accounts are stored as identities with type matching the
platform (google, apple, github).
"""
import from typing { Any }

obj IdentityStorage {
    has users_col: Any;

    # User lifecycle
    def create_user(
        identities: list[dict[str, Any]],
        credential: dict[str, Any]
    ) -> dict[str, Any];
    def get_user_by_id(user_id: str) -> dict[str, Any] | None;
    def user_exists_by_id(user_id: str) -> bool;
    def delete_user(user_id: str) -> bool;

    # Identity lookup
    def find_user_by_identity(value: str) -> dict[str, Any] | None;
    def identity_taken(value: str) -> bool;

    # Authentication
    def authenticate(identifier: str, password: str) -> dict[str, Any] | None;

    # Field updates
    def update_user_status(user_id: str, status: str) -> bool;
    def set_user_role(user_id: str, role: str) -> bool;
    def get_user_role(user_id: str) -> str | None;

    # Identity management
    def add_identity(user_id: str, identity: dict[str, Any]) -> dict[str, str];
    def remove_identity(user_id: str, identity_type: str, value: str) -> dict[str, str];
    def get_identities(user_id: str) -> list[dict[str, Any]];

    # Password management
    def update_password(
        user_id: str, current_password: str, new_password: str
    ) -> dict[str, str];

    # Listing
    def list_all_users(limit: int = 100, offset: int = 0) -> list[dict[str, Any]];

    # Backward compat helpers
    def get_root_id(user_id: str) -> str | None;
    def get_username(user_id: str) -> str | None;

    # Generic field update
    def update_user_fields(user_id: str, fields: dict[str, Any]) -> bool;

    # SSO (stored as identities with platform-specific types)
    def link_sso_account(
        user_id: str, platform: str, external_id: str, email: str
    ) -> dict[str, str];
    def unlink_sso_account(user_id: str, platform: str) -> dict[str, str];
    def get_sso_accounts(user_id: str) -> list[dict[str, str]];
    def get_user_by_sso(platform: str, external_id: str) -> dict[str, Any] | None;

    # Setup indexes
    def ensure_indexes -> None;
}
