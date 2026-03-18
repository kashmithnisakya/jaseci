"""Dashboard proxy mixin for embedding Grafana, MongoDB, and Redis dashboards."""
import from collections.abc { Callable }
import from typing { Any }

"""Mixin providing reverse proxy endpoints for external dashboards."""
obj JacAPIServerDashboards {
    def setup_dashboard_proxies -> None;
    def register_dashboard_endpoints -> None;
    def dashboard_status(Authorization: str | None = None) -> Any;
    def dashboard_toggle(service: str, enabled: bool, Authorization: str | None = None) -> Any;
}
