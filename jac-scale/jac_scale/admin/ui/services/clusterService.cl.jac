"""Cluster-metrics service: thin wrappers over /admin/cluster/* endpoints."""

cl {
    import from .api { get }

    async def:pub getHealth(token: str) -> dict {
        return await get("/admin/cluster/health", token);
    }

    async def:pub getPods(token: str) -> dict {
        return await get("/admin/cluster/pods", token);
    }

    async def:pub getNodes(token: str) -> dict {
        return await get("/admin/cluster/nodes", token);
    }

    async def:pub getDeployments(token: str) -> dict {
        return await get("/admin/cluster/deployments", token);
    }

    async def:pub getNodeUsage(token: str) -> dict {
        return await get("/admin/cluster/node-usage", token);
    }
}
