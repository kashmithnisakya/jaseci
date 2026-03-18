"""Reusable iframe-based dashboard page component."""

cl {
    import from ....components.common.Button { Button }
    import from ....components.common.Card { Card, CardBody }
    import from ....context.AuthContext { useAuth }
    import from ....services.api { baseUrl }

    def:pub DashboardIframePage(
        serviceName: str,
        serviceLabel: str,
        enabled: bool = False,
        healthy: bool = False,
        onToggle: Any = None
    ) -> JsxElement {
        auth = useAuth();

        if not enabled {
            return
                <div className="bg-slate-900 border border-slate-800 rounded-lg p-8 text-center">
                    <div className="w-12 h-12 rounded-full bg-slate-800 flex items-center justify-center mx-auto mb-4">
                        <svg className="w-6 h-6 text-slate-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2"
                                d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728A9 9 0 015.636 5.636m12.728 12.728L5.636 5.636"/>
                        </svg>
                    </div>
                    <h2 className="text-sm font-medium text-white mb-2">
                        {serviceLabel + " Dashboard"}
                    </h2>
                    <p className="text-xs text-slate-500 mb-4">
                        This dashboard is currently disabled.
                    </p>
                    {onToggle and
                        <Button onClick={lambda -> None { onToggle(serviceName, True); }}>
                            Enable
                        </Button>
                    }
                </div>;
        }

        if not healthy {
            return
                <div className="bg-slate-900 border border-slate-800 rounded-lg p-8 text-center">
                    <div className="w-3 h-3 rounded-full bg-red-500 mx-auto mb-4"></div>
                    <h2 className="text-sm font-medium text-white mb-2">
                        {serviceLabel + " Dashboard"}
                    </h2>
                    <p className="text-xs text-slate-500 mb-2">
                        Service is not reachable. Check your configuration.
                    </p>
                    {onToggle and
                        <Button variant="secondary" onClick={lambda -> None { onToggle(serviceName, False); }}>
                            Disable
                        </Button>
                    }
                </div>;
        }

        iframeSrc = baseUrl + "/admin/dashboards/" + serviceName + "/?__admin_token=" + auth["authToken"];

        return
            <div className="h-[calc(100vh-160px)] bg-slate-900 border border-slate-800 rounded-lg overflow-hidden">
                <div className="flex items-center justify-between px-4 py-2 border-b border-slate-800">
                    <div className="flex items-center gap-2">
                        <div className="w-2 h-2 rounded-full bg-emerald-500"></div>
                        <span className="text-sm font-medium text-white">
                            {serviceLabel}
                        </span>
                    </div>
                    <div className="flex gap-2">
                        <Button variant="ghost"
                            onClick={lambda -> None {
                                window.open(iframeSrc, "_blank");
                            }}>
                            Open in New Tab
                        </Button>
                        {onToggle and
                            <Button variant="secondary"
                                onClick={lambda -> None { onToggle(serviceName, False); }}>
                                Disable
                            </Button>
                        }
                    </div>
                </div>
                <iframe
                    src={iframeSrc}
                    className="w-full h-full border-0"
                    title={serviceLabel + " Dashboard"}
                />
            </div>;
    }
}
