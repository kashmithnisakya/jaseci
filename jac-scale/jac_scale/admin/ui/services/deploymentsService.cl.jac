"""Deployments service: thin wrappers over /admin/deployments/* endpoints."""

cl {
    import from .api { get }

    async def:pub getDeploymentsSummary(token: str) -> dict {
        return await get("/admin/deployments", token);
    }

    async def:pub getDeploymentsList(token: str) -> dict {
        return await get("/admin/deployments/list", token);
    }

    async def:pub getDeploymentDetail(token: str, name: str) -> dict {
        return await get("/admin/deployments/" + name, token);
    }

    async def:pub getDeploymentTimeseries(
        token: str, name: str, metric: str = "cpu", rangeMinutes: int = 60
    ) -> dict {
        path = "/admin/deployments/" + name + "/timeseries"
            + "?metric=" + metric
            + "&range_minutes=" + str(rangeMinutes);
        return await get(path, token);
    }
}
