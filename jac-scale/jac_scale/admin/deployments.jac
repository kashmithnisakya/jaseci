"""Deployments admin endpoints.

Exposes a non-technical-friendly view over the in-cluster Kubernetes
deployments by querying the Prometheus instance that jac-scale's monitoring
stack already provisions (kube-state-metrics + node-exporter + cAdvisor).

All endpoints are admin-only and translate raw PromQL output into friendly
status strings ('Healthy', 'Starting', 'Broken', 'Unstable') so the UI is
purely presentational.
"""
import from jaclang.runtimelib.transport { TransportResponse }

"""Deployments mixin providing /admin/deployments/* endpoints."""
obj JacAPIServerDeployments {
    def register_deployments_endpoints -> None;
    def admin_deployments_summary(
        Authorization: str | None = None
    ) -> TransportResponse;

    def admin_deployments_list(Authorization: str | None = None) -> TransportResponse;
    def admin_deployment_detail(
        name: str, Authorization: str | None = None
    ) -> TransportResponse;

    def admin_deployment_timeseries(
        name: str,
        metric: str = "cpu",
        range_minutes: int = 60,
        Authorization: str | None = None
    ) -> TransportResponse;
}
