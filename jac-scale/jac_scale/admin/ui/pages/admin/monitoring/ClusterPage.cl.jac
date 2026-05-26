"""Cluster overview page — KPI tiles + tables backed by Grafana proxy."""

cl {
    import from react { useEffect }
    import from ....components.common.Button { Button }
    import from ....context.AuthContext { useAuth }
    import from ....services.clusterService {
        getHealth, getPods, getNodes, getDeployments, getNodeUsage
    }

    def:pub ClusterPage -> JsxElement {
        has isLoading: bool = True,
            errorMsg: str = "",
            health: dict = {},
            pods: dict = {},
            nodes: list = [],
            deployments: dict = {},
            nodeUsage: list = [],
            autoRefresh: bool = True;

        auth = useAuth();

        async def loadAll {
            token = auth["authToken"];
            results = await Promise.all([
                getHealth(token),
                getPods(token),
                getNodes(token),
                getDeployments(token),
                getNodeUsage(token)
            ]);
            firstError = "";
            for r in results {
                if not r["ok"] {
                    err = r["error"] or {};
                    firstError = err["message"] or "unknown error";
                    break;
                }
            }
            errorMsg = firstError;
            if not firstError {
                health = (results[0]["data"] or {});
                pods = (results[1]["data"] or {}).get("phases", {});
                nodes = (results[2]["data"] or {}).get("nodes", []);
                deployments = (results[3]["data"] or {});
                nodeUsage = (results[4]["data"] or {}).get("nodes", []);
            }
            isLoading = False;
        }

        useEffect(lambda { loadAll(); }, []);

        useEffect(
            lambda -> any {
                if not autoRefresh {
                    return undefined;
                }
                interval = setInterval(lambda { loadAll(); }, 5000);
                return lambda { clearInterval(interval); };
            },
            [autoRefresh]
        );

        def tileClass(value: any, ok: bool) -> str {
            base = "text-4xl font-bold font-mono ";
            return base + (ok and "text-lime-400" or "text-orange-400");
        }

        def phaseBadge(phase: str, count: int) -> str {
            color = "bg-slate-700 text-slate-300";
            if phase == "Running" {
                color = "bg-lime-500/30 text-lime-300 border border-lime-500/50";
            } elif phase == "Pending" {
                color = "bg-cyan-500/30 text-cyan-300 border border-cyan-500/50";
            } elif phase == "Failed" {
                color = "bg-red-500/30 text-red-300 border border-red-500/50";
            } elif phase == "Succeeded" {
                color = "bg-teal-500/30 text-teal-300 border border-teal-500/50";
            }
            return "px-2 py-0.5 rounded text-xs font-bold " + color;
        }

        runningPods = pods.get("Running", 0);
        pendingPods = pods.get("Pending", 0);
        failedPods = pods.get("Failed", 0);
        readyNodes = sum((1 for n in nodes if n["ready"]));
        totalNodes = len(nodes);
        healthyDeps = deployments.get("healthy", 0);
        totalDeps = deployments.get("total", 0);
        avgCpu = 0.0;
        if len(nodeUsage) > 0 {
            avgCpu = sum((n["cpu_percent"] for n in nodeUsage)) / len(nodeUsage);
        }

        return
            <div
                className="min-h-screen bg-gradient-to-br from-slate-950 via-slate-900 to-slate-950 p-6 space-y-6"
            >
                <div className="flex items-center justify-between mb-2">
                    <div className="flex items-center gap-4">
                        <div
                            className="w-3 h-3 rounded-full bg-teal-400 animate-pulse shadow-lg shadow-teal-400/50"
                        ></div>
                        <h1 className="text-2xl font-bold text-white tracking-wider">
                            CLUSTER
                        </h1>
                    </div>
                    <div className="flex items-center gap-4">
                        <label
                            className="flex items-center gap-2 text-xs text-slate-400 font-mono"
                        >
                            <input
                                type="checkbox"
                                checked={autoRefresh}
                                onChange={lambda e: any { autoRefresh = e.target.checked; }}
                                className="rounded border-teal-500/50 bg-slate-800 text-teal-500 focus:ring-teal-500/50"
                            />
                            LIVE SYNC
                        </label>
                        <Button variant="secondary" onClick={lambda { loadAll(); }}>
                            REFRESH
                        </Button>
                    </div>
                </div>

                {errorMsg
                and <div
                    className="bg-red-500/10 border border-red-500/30 rounded-lg p-3 text-sm text-red-300 font-mono"
                >
                    {errorMsg}
                </div>}

                <div className="grid grid-cols-4 gap-4">
                    <div
                        className="bg-gradient-to-br from-slate-900/80 to-slate-950/80 backdrop-blur-xl border border-teal-500/20 rounded-2xl p-5 shadow-xl text-center"
                    >
                        <div className={tileClass(runningPods, failedPods == 0)}>
                            {runningPods}
                        </div>
                        <div className="text-xs text-slate-500 font-mono mt-2">
                            PODS RUNNING
                        </div>
                    </div>
                    <div
                        className="bg-gradient-to-br from-slate-900/80 to-slate-950/80 backdrop-blur-xl border border-teal-500/20 rounded-2xl p-5 shadow-xl text-center"
                    >
                        <div className={tileClass(readyNodes, readyNodes == totalNodes and totalNodes > 0)}>
                            {readyNodes}<span className="text-slate-500 text-2xl">/{totalNodes}</span>
                        </div>
                        <div className="text-xs text-slate-500 font-mono mt-2">
                            NODES READY
                        </div>
                    </div>
                    <div
                        className="bg-gradient-to-br from-slate-900/80 to-slate-950/80 backdrop-blur-xl border border-teal-500/20 rounded-2xl p-5 shadow-xl text-center"
                    >
                        <div className={tileClass(healthyDeps, healthyDeps == totalDeps and totalDeps > 0)}>
                            {healthyDeps}<span className="text-slate-500 text-2xl">/{totalDeps}</span>
                        </div>
                        <div className="text-xs text-slate-500 font-mono mt-2">
                            DEPLOYMENTS HEALTHY
                        </div>
                    </div>
                    <div
                        className="bg-gradient-to-br from-slate-900/80 to-slate-950/80 backdrop-blur-xl border border-teal-500/20 rounded-2xl p-5 shadow-xl text-center"
                    >
                        <div className={tileClass(avgCpu, avgCpu < 80)}>
                            {round(avgCpu, 1)}<span className="text-slate-500 text-2xl">%</span>
                        </div>
                        <div className="text-xs text-slate-500 font-mono mt-2">
                            AVG NODE CPU
                        </div>
                    </div>
                </div>

                <div
                    className="bg-gradient-to-br from-slate-900/80 to-slate-950/80 backdrop-blur-xl border border-teal-500/20 rounded-2xl p-5 shadow-xl"
                >
                    <div className="flex items-center gap-2 mb-4">
                        <div className="w-2 h-2 rounded-full bg-teal-400"></div>
                        <span className="text-sm font-bold text-white tracking-wide">
                            POD PHASES
                        </span>
                    </div>
                    <div className="flex flex-wrap gap-3">
                        {[
                            <div
                                key={phase}
                                className="flex items-center gap-2"
                            >
                                <span className={phaseBadge(phase, pods.get(phase, 0))}>
                                    {phase.upper()}
                                </span>
                                <span className="text-2xl font-bold text-slate-200 font-mono">
                                    {pods.get(phase, 0)}
                                </span>
                            </div> for phase in ["Running", "Pending", "Failed", "Succeeded", "Unknown"]
                        ]}
                    </div>
                </div>

                <div className="grid grid-cols-2 gap-6">
                    <div
                        className="bg-gradient-to-br from-slate-900/80 to-slate-950/80 backdrop-blur-xl border border-teal-500/20 rounded-2xl p-5 shadow-xl"
                    >
                        <div className="flex items-center gap-2 mb-4">
                            <div className="w-2 h-2 rounded-full bg-cyan-400"></div>
                            <span className="text-sm font-bold text-white tracking-wide">
                                NODES ({len(nodes)})
                            </span>
                        </div>
                        <div className="space-y-2 max-h-72 overflow-y-auto pr-2">
                            {[
                                <div
                                    key={(n["instance"] or n["node"] or "?") + str(idx)}
                                    className="flex items-center gap-3 text-xs py-1 border-b border-slate-800/60 last:border-0"
                                >
                                    <span
                                        className={(
                                            n["ready"]
                                            and "px-2 py-0.5 rounded text-xs font-bold bg-lime-500/30 text-lime-300 border border-lime-500/50"
                                            or "px-2 py-0.5 rounded text-xs font-bold bg-red-500/30 text-red-300 border border-red-500/50"
                                        )}
                                    >
                                        {n["ready"] and "READY" or "NOT READY"}
                                    </span>
                                    <span className="font-mono text-teal-300 flex-1 truncate">
                                        {n["node"] or "?"}
                                    </span>
                                </div> for (idx, n) in enumerate(nodes)
                            ]}
                            {[
                                <div
                                    key={"usage-" + str(idx)}
                                    className="flex items-center gap-3 text-xs py-1 border-t border-slate-700/40 first:border-t-0"
                                >
                                    <span className="font-mono text-slate-400 flex-1 truncate">
                                        {n["instance"] or "?"}
                                    </span>
                                    <span className="font-mono text-cyan-300 w-20 text-right">
                                        CPU {n["cpu_percent"]}%
                                    </span>
                                    <span className="font-mono text-teal-300 w-20 text-right">
                                        MEM {n["memory_percent"]}%
                                    </span>
                                </div> for (idx, n) in enumerate(nodeUsage)
                            ]}
                        </div>
                    </div>

                    <div
                        className="bg-gradient-to-br from-slate-900/80 to-slate-950/80 backdrop-blur-xl border border-teal-500/20 rounded-2xl p-5 shadow-xl"
                    >
                        <div className="flex items-center gap-2 mb-4">
                            <div className="w-2 h-2 rounded-full bg-lime-400"></div>
                            <span className="text-sm font-bold text-white tracking-wide">
                                DEPLOYMENTS ({deployments.get("total", 0)})
                            </span>
                        </div>
                        <div className="space-y-2 max-h-72 overflow-y-auto pr-2">
                            {[
                                <div
                                    key={d["name"]}
                                    className="flex items-center gap-3 text-xs py-1 border-b border-slate-800/60 last:border-0"
                                >
                                    <span
                                        className={(
                                            d["healthy"]
                                            and "px-2 py-0.5 rounded text-xs font-bold bg-lime-500/30 text-lime-300 border border-lime-500/50"
                                            or "px-2 py-0.5 rounded text-xs font-bold bg-orange-500/30 text-orange-300 border border-orange-500/50"
                                        )}
                                    >
                                        {d["healthy"] and "OK" or "DEGRADED"}
                                    </span>
                                    <span className="font-mono text-slate-300 flex-1 truncate">
                                        {d["name"]}
                                    </span>
                                    <span className="font-mono text-teal-300">
                                        {d["available"]}/{d["desired"]}
                                    </span>
                                </div> for d in (deployments.get("deployments", []) or [])
                            ]}
                        </div>
                    </div>
                </div>

                {(not health.get("grafana_reachable", False))
                and not errorMsg
                and not isLoading
                and <div
                    className="bg-orange-500/10 border border-orange-500/30 rounded-lg p-3 text-sm text-orange-300 font-mono"
                >
                    Monitoring is not enabled for this deployment. Add
                    [plugins.scale.monitoring] enabled = true to jac.toml and redeploy.
                </div>}
            </div>;
    }
}
