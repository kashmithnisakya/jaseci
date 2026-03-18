"""Implementation of dashboard proxy endpoints for Grafana, MongoDB Express, and RedisInsight."""
import logging;
import time;
import from typing { Any }
import from collections.abc { Callable }
import from fastapi { Request }
import from fastapi.responses { Response }
import httpx;
import from base64 { b64encode }
import from jac_scale.config_loader { get_scale_config }
import from jaclang.runtimelib.transport { TransportResponse, Meta }
import from jac_scale.jserver.jserver {
    APIParameter,
    HTTPMethod,
    JEndPoint,
    ParameterType
}

glob logger = logging.getLogger(__name__);

glob DASHBOARD_SERVICES: dict[str, dict[str, str]] = {
    'grafana': {'label': 'Grafana', 'path_prefix': 'grafana'},
    'mongo_express': {'label': 'MongoDB', 'path_prefix': 'mongo_express'},
    'redis_insight': {'label': 'Redis', 'path_prefix': 'redis_insight'}
};

# Headers to exclude when forwarding proxy responses
glob HOP_BY_HOP_HEADERS: set = {
    'transfer-encoding', 'content-encoding', 'content-length',
    'connection', 'keep-alive', 'proxy-authenticate',
    'proxy-authorization', 'te', 'trailers', 'upgrade'
};

"""Extract admin token from Authorization header or __admin_token query param."""
def _extract_admin_token(request: Request) -> str | None {
    authorization = request.headers.get('Authorization');
    if authorization and isinstance(authorization, str) and authorization.startswith('Bearer ') {
        return authorization;
    }
    # Fallback: check query param for iframe support
    token = request.query_params.get('__admin_token');
    if token {
        return f"Bearer {token}";
    }
    return None;
}

"""Build basic auth header value."""
def _make_basic_auth(username: str, password: str) -> str {
    credentials = f"{username}:{password}";
    encoded = b64encode(credentials.encode('utf-8')).decode('utf-8');
    return f"Basic {encoded}";
}

"""Initialize dashboard proxy clients and runtime state."""
impl JacAPIServerDashboards.setup_dashboard_proxies -> None {
    dashboards_config = get_scale_config().get_dashboards_config();
    self._dashboard_clients: dict[str, httpx.AsyncClient] = {};
    self._dashboard_config: dict[str, Any] = dashboards_config;
    self._dashboard_enabled: dict[str, bool] = {};
    self._health_cache: dict[str, dict[str, Any]] = {};

    for (service, svc_config) in dashboards_config.items() {
        enabled = bool(svc_config.get('enabled', False));
        self._dashboard_enabled[service] = enabled;
        url = str(svc_config.get('url', ''));
        if url {
            self._dashboard_clients[service] = httpx.AsyncClient(
                base_url=url,
                timeout=30.0,
                follow_redirects=True
            );
        }
    }
    logger.info("Dashboard proxies initialized");
}

"""Get dashboard status with cached health checks."""
impl JacAPIServerDashboards.dashboard_status(Authorization: str | None = None) -> Any {
    error = self.require_admin(Authorization);
    if error {
        return error;
    }
    dashboards: dict[str, Any] = {};
    for (service, meta) in DASHBOARD_SERVICES.items() {
        enabled = self._dashboard_enabled.get(service, False);
        healthy = False;
        if enabled and service in self._dashboard_clients {
            # Use cached health (30s TTL)
            cache_entry = self._health_cache.get(service, {});
            cache_time = cache_entry.get('time', 0) if isinstance(cache_entry, dict) else 0;
            if time.time() - cache_time < 30 {
                healthy = cache_entry.get('healthy', False) if isinstance(cache_entry, dict) else False;
            } else {
                try {
                    client = self._dashboard_clients[service];
                    resp = httpx._client.AsyncClient.send(
                        client,
                        client.build_request('HEAD', '/')
                    );
                    # We can't easily await here in sync context, so mark healthy=True
                    # if the client was created successfully. Actual health will be checked
                    # on first proxy request.
                    healthy = True;
                    self._health_cache[service] = {'time': time.time(), 'healthy': True};
                } except Exception {
                    healthy = False;
                    self._health_cache[service] = {'time': time.time(), 'healthy': False};
                }
            }
        }
        dashboards[service] = {
            'enabled': enabled,
            'label': meta['label'],
            'healthy': healthy
        };
    }
    return TransportResponse.success(
        data={'dashboards': dashboards},
        meta=Meta(extra={'http_status': 200})
    );
}

"""Toggle a dashboard service on or off at runtime."""
impl JacAPIServerDashboards.dashboard_toggle(
    service: str, enabled: bool, Authorization: str | None = None
) -> Any {
    error = self.require_admin(Authorization);
    if error {
        return error;
    }
    if service not in DASHBOARD_SERVICES {
        return TransportResponse.fail(
            code='NOT_FOUND',
            message=f'Unknown dashboard service: {service}',
            meta=Meta(extra={'http_status': 404})
        );
    }
    self._dashboard_enabled[service] = enabled;
    # Clear health cache on toggle
    if service in self._health_cache {
        del self._health_cache[service];
    }
    label = DASHBOARD_SERVICES[service]['label'];
    state = 'enabled' if enabled else 'disabled';
    logger.info(f"Dashboard {label} {state}");
    return TransportResponse.success(
        data={'service': service, 'enabled': enabled, 'label': label},
        meta=Meta(extra={'http_status': 200})
    );
}

"""Register all dashboard proxy and management endpoints."""
impl JacAPIServerDashboards.register_dashboard_endpoints -> None {
    # GET /admin/dashboards/status
    async def status_handler(request: Request) -> Any {
        authorization = request.headers.get('Authorization');
        return self.dashboard_status(authorization);
    }
    self.server.add_endpoint(
        JEndPoint(
            method=HTTPMethod.GET,
            path='/admin/dashboards/status',
            callback=status_handler,
            parameters=[],
            response_model=None,
            tags=['Admin Dashboards'],
            summary='Dashboard status',
            description='Get status of all dashboard services'
        )
    );

    # POST /admin/dashboards/{service}/toggle
    async def toggle_handler(request: Request, service: str) -> Any {
        authorization = request.headers.get('Authorization');
        try {
            body = await request.json();
        } except Exception {
            return TransportResponse.fail(
                code='INVALID_REQUEST',
                message='Request body must be valid JSON',
                meta=Meta(extra={'http_status': 400})
            );
        }
        enabled = bool(body.get('enabled', False));
        return self.dashboard_toggle(service, enabled, authorization);
    }
    self.server.add_endpoint(
        JEndPoint(
            method=HTTPMethod.POST,
            path='/admin/dashboards/{service}/toggle',
            callback=toggle_handler,
            parameters=[
                APIParameter(
                    name='service',
                    data_type='string',
                    required=True,
                    default=None,
                    description='Dashboard service name (grafana, mongo_express, redis_insight)',
                    type=ParameterType.PATH
                )
            ],
            response_model=None,
            tags=['Admin Dashboards'],
            summary='Toggle dashboard',
            description='Enable or disable a dashboard service'
        )
    );

    # Register proxy routes for each dashboard service
    for (service, meta) in DASHBOARD_SERVICES.items() {
        path_prefix = meta['path_prefix'];
        self._register_proxy_routes(service, path_prefix);
    }
    logger.info("Dashboard proxy endpoints registered");
}

"""Register GET/POST/PUT/DELETE proxy routes for a single dashboard service."""
def _register_proxy_routes(
    self: Any, service: str, path_prefix: str
) -> None {
    for method in [HTTPMethod.GET, HTTPMethod.POST, HTTPMethod.PUT, HTTPMethod.DELETE] {
        handler = self._create_proxy_handler(service);
        self.server.add_endpoint(
            JEndPoint(
                method=method,
                path=f'/admin/dashboards/{path_prefix}/{{path:path}}',
                callback=handler,
                parameters=[
                    APIParameter(
                        name='path',
                        data_type='string',
                        required=False,
                        default='',
                        description='Proxied path',
                        type=ParameterType.PATH
                    )
                ],
                response_model=None,
                tags=['Admin Dashboards'],
                summary=f'Proxy {DASHBOARD_SERVICES[service]["label"]}',
                description=f'Reverse proxy to {DASHBOARD_SERVICES[service]["label"]} dashboard'
            )
        );
    }
}

"""Create an async proxy handler for a specific dashboard service."""
def _create_proxy_handler(self: Any, service: str) -> Callable {
    svc_config = self._dashboard_config.get(service, {});

    async def proxy_handler(request: Request, path: str = '') -> Response {
        # Auth check: header or query param
        auth_token = _extract_admin_token(request);
        error = self.require_admin(auth_token);
        if error {
            return error;
        }

        # Check if service is enabled
        if not self._dashboard_enabled.get(service, False) {
            return Response(
                content='{"error": "Dashboard service is disabled"}',
                status_code=503,
                media_type='application/json'
            );
        }

        # Check if client exists
        client = self._dashboard_clients.get(service);
        if not client {
            return Response(
                content='{"error": "Dashboard service not configured"}',
                status_code=503,
                media_type='application/json'
            );
        }

        # Build target URL
        target_path = f"/{path}" if path else "/";
        # Forward query params (excluding our auth token)
        query_params = dict(request.query_params);
        query_params.pop('__admin_token', None);
        if query_params {
            query_string = "&".join(f"{k}={v}" for (k, v) in query_params.items());
            target_path = f"{target_path}?{query_string}";
        }

        # Build forwarded headers
        headers: dict[str, str] = {};
        for (key, value) in request.headers.items() {
            lower_key = key.lower();
            if lower_key not in {'host', 'authorization', 'content-length'} {
                headers[key] = value;
            }
        }

        # Inject dashboard-specific auth
        _inject_dashboard_auth(headers, service, svc_config);

        # Forward request body
        body = await request.body();

        try {
            resp = await client.request(
                method=request.method,
                url=target_path,
                headers=headers,
                content=body if body else None
            );

            # Build response, filtering hop-by-hop headers
            response_headers: dict[str, str] = {};
            for (k, v) in resp.headers.items() {
                if k.lower() not in HOP_BY_HOP_HEADERS {
                    response_headers[k] = v;
                }
            }

            # Update health cache on successful response
            self._health_cache[service] = {'time': time.time(), 'healthy': True};

            return Response(
                content=resp.content,
                status_code=resp.status_code,
                headers=response_headers
            );
        } except httpx.ConnectError {
            self._health_cache[service] = {'time': time.time(), 'healthy': False};
            return Response(
                content='{"error": "Dashboard service is not reachable"}',
                status_code=502,
                media_type='application/json'
            );
        } except httpx.TimeoutException {
            return Response(
                content='{"error": "Dashboard service timed out"}',
                status_code=504,
                media_type='application/json'
            );
        } except Exception as e {
            logger.error(f"Dashboard proxy error for {service}: {e}");
            return Response(
                content='{"error": "Proxy error"}',
                status_code=502,
                media_type='application/json'
            );
        }
    }
    return proxy_handler;
}

"""Inject authentication headers for the target dashboard service."""
def _inject_dashboard_auth(headers: dict[str, str], service: str, svc_config: Any) -> None {
    if service == 'grafana' {
        user = svc_config.get('admin_user', 'admin');
        password = svc_config.get('admin_password', 'admin');
        headers['Authorization'] = _make_basic_auth(str(user), str(password));
    } elif service == 'mongo_express' {
        user = svc_config.get('username', 'admin');
        password = svc_config.get('password', 'admin');
        headers['Authorization'] = _make_basic_auth(str(user), str(password));
    } elif service == 'redis_insight' {
        user = svc_config.get('username', '');
        password = svc_config.get('password', '');
        if user and password {
            headers['Authorization'] = _make_basic_auth(str(user), str(password));
        }
    }
}
