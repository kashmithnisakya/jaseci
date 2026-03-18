"""Dashboard service functions for admin dashboard."""

cl {
    import from .api { get, post }

    async def:pub getDashboardStatus(token: str) -> dict {
        return await get("/admin/dashboards/status", token);
    }

    async def:pub toggleDashboard(service: str, enabled: bool, token: str) -> dict {
        return await post(
            "/admin/dashboards/" + service + "/toggle",
            {"enabled": enabled},
            token
        );
    }
}
