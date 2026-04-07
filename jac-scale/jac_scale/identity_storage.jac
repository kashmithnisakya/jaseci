"""Identity-based user storage.

Users are stored with an array of identities (username, email, phone, SSO, etc.)
and an array of credentials (password, TOTP, etc.), enabling flexible
authentication without schema changes when new identity/credential types
are added. SSO accounts are stored as identities with type matching the
platform (google, apple, github).

Two implementations:
- IdentityStorage: MongoDB-backed (uses users_col pymongo collection)
- SqliteIdentityStorage: SQLite-backed (uses db_path file path)
"""
import from typing { Any }
import bcrypt;
import uuid;
import json;
import sqlite3;
import from datetime { datetime, UTC }
import from jaclang.jac0core.constant { Constants as Con }

def hash_password(password: str) -> str {
    return str(bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8'));
}

def verify_password(password: str, password_hash: str) -> bool {
    return bool(bcrypt.checkpw(password.encode('utf-8'), password_hash.encode('utf-8')));
}

obj IdentityStorage {
    has users_col: Any;

    # User lifecycle
    def create_user(
        identities: list[dict[str, Any]], credential: dict[str, Any]
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
    def set_user_role(user_id: str, role: str) -> bool;
    def get_user_role(user_id: str) -> str | None;
    # Password management
    def update_password(
        user_id: str, current_password: str, new_password: str
    ) -> dict[str, str];

    # Listing
    def list_all_users(limit: int = 100, offset: int = 0) -> list[dict[str, Any]];
    # User data helpers
    def get_root_id(user_id: str) -> str | None;
    def get_username(user_id: str) -> str | None;
    # Generic field update
    def update_user_fields(user_id: str, fields: dict[str, Any]) -> bool;
    # SSO (stored as identities with platform-specific types)
    def link_sso_account(
        user_id: str, platform: str, external_id: str
    ) -> dict[str, str];

    def unlink_sso_account(user_id: str, platform: str) -> dict[str, str];
    def get_sso_accounts(user_id: str) -> list[dict[str, str]];
    def get_user_by_sso(platform: str, external_id: str) -> dict[str, Any] | None;
    # Setup indexes
    def ensure_indexes -> None;
}

"""SQLite-backed identity storage with the same interface as IdentityStorage."""
obj SqliteIdentityStorage {
    has db_path: str,
        _conn: (Any | None) = None;

    def postinit -> None;
    def _get_conn -> Any;
    # Same interface as IdentityStorage
    def create_user(
        identities: list[dict[str, Any]], credential: dict[str, Any]
    ) -> dict[str, Any];

    def get_user_by_id(user_id: str) -> dict[str, Any] | None;
    def user_exists_by_id(user_id: str) -> bool;
    def delete_user(user_id: str) -> bool;
    def find_user_by_identity(value: str) -> dict[str, Any] | None;
    def identity_taken(value: str) -> bool;
    def authenticate(identifier: str, password: str) -> dict[str, Any] | None;
    def set_user_role(user_id: str, role: str) -> bool;
    def get_user_role(user_id: str) -> str | None;
    def update_password(
        user_id: str, current_password: str, new_password: str
    ) -> dict[str, str];

    def list_all_users(limit: int = 100, offset: int = 0) -> list[dict[str, Any]];
    def get_root_id(user_id: str) -> str | None;
    def get_username(user_id: str) -> str | None;
    def update_user_fields(user_id: str, fields: dict[str, Any]) -> bool;
    def link_sso_account(
        user_id: str, platform: str, external_id: str
    ) -> dict[str, str];

    def unlink_sso_account(user_id: str, platform: str) -> dict[str, str];
    def get_sso_accounts(user_id: str) -> list[dict[str, str]];
    def get_user_by_sso(platform: str, external_id: str) -> dict[str, Any] | None;
    def ensure_indexes -> None;
}
