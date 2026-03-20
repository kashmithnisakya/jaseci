"""Grafana credential manager for JAC-Scale.

Manages Grafana users and credentials via the Grafana HTTP API.
Ensures monitoring users have Viewer-only access and admin credentials
stay in sync between jac-scale and Grafana.
"""
import logging;
import json;
import from typing { Any }
import from jac_scale.config_loader { get_scale_config }
import from jac_scale.db { Db, get_mongo_client }

glob _grafana_manager: (GrafanaManager | None) = None,
     logger = logging.getLogger(__name__);

"""Singleton manager for Grafana credential synchronisation."""
obj GrafanaManager {
    has _grafana_url: (str | None) = None,
        _admin_user: str = 'admin',
        _admin_password: str = '',
        _monitoring_user: str = 'jac-monitor',
        _monitoring_password: str = '',
        _collection: str = 'grafana_credentials',
        _db: (Any | None) = None,
        _in_memory_store: dict[str, Any] = {},
        _initialized: bool = False;

    def postinit -> None;
    static def instance -> GrafanaManager;
    def setup(
        admin_password: str,
        monitoring_user: str = 'jac-monitor',
        monitoring_password: str = '',
        grafana_url: (str | None) = None
    ) -> None;

    # Core operations
    def sync_credentials -> dict[str, Any];
    def sync_admin_password(new_password: str) -> bool;
    def ensure_monitoring_user -> dict[str, Any];
    def rotate_monitoring_password -> dict[str, Any];
    def get_monitoring_credentials -> (dict[str, Any] | None);
    # Grafana HTTP API helpers
    def _api_request(
        method: str,
        path: str,
        data: (dict | None) = None,
        auth_user: (str | None) = None,
        auth_password: (str | None) = None
    ) -> (dict | None);

    def _check_health -> bool;
    def _verify_admin_auth -> bool;
    def _get_grafana_user(username: str) -> (dict | None);
    def _create_grafana_user(
        username: str, password: str, role: str = 'Admin'
    ) -> (dict | None);

    def _update_grafana_user_password(user_id: int, password: str) -> bool;
    def _update_grafana_admin_password(new_password: str) -> bool;
    # Persistence
    def _decrypt_persisted_admin_password -> (str | None);
    def _persist_credentials(key: str, data: dict) -> None;
    def _load_credentials(key: str) -> (dict | None);
}
