"""Grafana dashboard page."""

cl {
    import from react { useEffect }
    import from .DashboardIframePage { DashboardIframePage }
    import from ....context.AuthContext { useAuth }
    import from ....context.AlertContext { useAlert }
    import from ....services.dashboardService { getDashboardStatus, toggleDashboard }

    def:pub GrafanaPage -> JsxElement {
        has enabled: bool = False,
            healthy: bool = False,
            isLoading: bool = True;

        auth = useAuth();
        alert = useAlert();

        async def loadStatus -> None {
            result = await getDashboardStatus(auth["authToken"]);
            if result["ok"] and result["data"] and result["data"]["dashboards"] {
                info = result["data"]["dashboards"]["grafana"] or {};
                enabled = info["enabled"] or False;
                healthy = info["healthy"] or False;
            }
            isLoading = False;
        }

        async def handleToggle(service: str, newState: bool) -> None {
            result = await toggleDashboard(service, newState, auth["authToken"]);
            if result["ok"] {
                alert["showAlert"]("Grafana " + (if newState { "enabled" } else { "disabled" }), "success");
            } else {
                alert["showAlert"]("Failed to toggle Grafana", "error");
            }
            await loadStatus();
        }

        useEffect(lambda -> None { loadStatus(); }, []);

        if isLoading {
            return <div className="p-8 text-center text-slate-500">Loading...</div>;
        }

        return
            <DashboardIframePage
                serviceName="grafana"
                serviceLabel="Grafana"
                enabled={enabled}
                healthy={healthy}
                onToggle={handleToggle}
            />;
    }
}
