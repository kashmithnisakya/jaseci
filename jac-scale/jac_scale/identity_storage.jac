"""Identity-based user storage.

Users are stored with an array of identities (username, email, phone, SSO, etc.)
and an array of credentials (password, TOTP, etc.), enabling flexible
authentication without schema changes when new identity/credential types
are added. SSO accounts are stored as identities with type matching the
platform (google, apple, github).

Architecture:
- IdentityStorage: Abstract base with shared business logic
- MongoIdentityStorage: MongoDB-backed (uses users_col pymongo collection)
- SqliteIdentityStorage: SQLite-backed (uses db_path file path)
"""
import from typing { Any }
import bcrypt;
import uuid;
import json;
import from datetime { datetime, UTC }
import from sqlalchemy {
    create_engine,
    MetaData,
    Table,
    Column,
    String,
    Integer,
    JSON,
    select,
    delete,
    update,
    insert,
    text
}
import from jaclang.jac0core.constant { Constants as Con }

"""Abstract base for identity storage backends.

Subclasses implement storage primitives (_store_user, _find_by_id, etc.).
Shared business logic (create_user, authenticate, etc.) lives here.
"""
obj IdentityStorage {
    # Password helpers
    static def hash_password(password: str) -> str;
    static def verify_password(password: str, password_hash: str) -> bool;
    # Abstract storage primitives (subclasses must implement)
    def _store_user(user_doc: dict[str, Any]) -> None;
    def _update_fields(user_id: str, fields: dict[str, Any]) -> bool;
    def _get_credentials(user_id: str) -> list[dict[str, Any]];
    def _update_credentials(user_id: str, credentials: list[dict[str, Any]]) -> None;
    def _get_identities(user_id: str) -> list[dict[str, Any]];
    def _add_identity(user_id: str, identity: dict[str, Any]) -> bool;
    def _remove_sso_identity(user_id: str, platform: str) -> bool;
    def _find_sso_link(platform: str, external_id: str) -> dict[str, Any] | None;
    def ensure_indexes -> None;
    # Public methods implemented by subclasses directly
    def get_user_by_id(user_id: str) -> dict[str, Any] | None;
    def delete_user(user_id: str) -> bool;
    def find_user_by_identity(value: str) -> dict[str, Any] | None;
    def identity_taken(value: str) -> bool;
    def list_all_users(limit: int = 100, offset: int = 0) -> list[dict[str, Any]];
    def get_user_by_sso(platform: str, external_id: str) -> dict[str, Any] | None;
    # Concrete public methods (shared business logic in base impl)
    def create_user(
        identities: list[dict[str, Any]], credential: dict[str, Any]
    ) -> dict[str, Any];

    def user_exists_by_id(user_id: str) -> bool;
    def authenticate(identifier: str, password: str) -> dict[str, Any] | None;
    def set_user_role(user_id: str, role: str) -> bool;
    def get_user_role(user_id: str) -> str | None;
    def update_password(
        user_id: str, current_password: str, new_password: str
    ) -> dict[str, str];

    def get_root_id(user_id: str) -> str | None;
    def get_username(user_id: str) -> str | None;
    def update_user_fields(user_id: str, fields: dict[str, Any]) -> bool;
    def link_sso_account(
        user_id: str, platform: str, external_id: str
    ) -> dict[str, str];

    def unlink_sso_account(user_id: str, platform: str) -> dict[str, str];
    def get_sso_accounts(user_id: str) -> list[dict[str, str]];
}

"""MongoDB-backed identity storage."""
obj MongoIdentityStorage(IdentityStorage) {
    has users_col: Any;

    # Abstract primitives
    def _store_user(user_doc: dict[str, Any]) -> None;
    def _update_fields(user_id: str, fields: dict[str, Any]) -> bool;
    def _get_credentials(user_id: str) -> list[dict[str, Any]];
    def _update_credentials(user_id: str, credentials: list[dict[str, Any]]) -> None;
    def _get_identities(user_id: str) -> list[dict[str, Any]];
    def _add_identity(user_id: str, identity: dict[str, Any]) -> bool;
    def _remove_sso_identity(user_id: str, platform: str) -> bool;
    def _find_sso_link(platform: str, external_id: str) -> dict[str, Any] | None;
    def ensure_indexes -> None;
    # Public methods implemented directly
    def get_user_by_id(user_id: str) -> dict[str, Any] | None;
    def delete_user(user_id: str) -> bool;
    def find_user_by_identity(value: str) -> dict[str, Any] | None;
    def identity_taken(value: str) -> bool;
    def list_all_users(limit: int = 100, offset: int = 0) -> list[dict[str, Any]];
    def get_user_by_sso(platform: str, external_id: str) -> dict[str, Any] | None;
}

"""SQLite-backed identity storage."""
obj SqliteIdentityStorage(IdentityStorage) {
    has db_path: str,
        _engine: Any by postinit,
        _table: Any by postinit;

    def postinit -> None;
    # Abstract primitives
    def _store_user(user_doc: dict[str, Any]) -> None;
    def _update_fields(user_id: str, fields: dict[str, Any]) -> bool;
    def _get_credentials(user_id: str) -> list[dict[str, Any]];
    def _update_credentials(user_id: str, credentials: list[dict[str, Any]]) -> None;
    def _get_identities(user_id: str) -> list[dict[str, Any]];
    def _add_identity(user_id: str, identity: dict[str, Any]) -> bool;
    def _remove_sso_identity(user_id: str, platform: str) -> bool;
    def _find_sso_link(platform: str, external_id: str) -> dict[str, Any] | None;
    def ensure_indexes -> None;
    # Public methods implemented directly
    def get_user_by_id(user_id: str) -> dict[str, Any] | None;
    def delete_user(user_id: str) -> bool;
    def find_user_by_identity(value: str) -> dict[str, Any] | None;
    def identity_taken(value: str) -> bool;
    def list_all_users(limit: int = 100, offset: int = 0) -> list[dict[str, Any]];
    def get_user_by_sso(platform: str, external_id: str) -> dict[str, Any] | None;
}
