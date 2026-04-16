"""Prometheus metrics for the WebSocket layer."""
import logging;
import from typing { Any }

glob logger = logging.getLogger(__name__),
     _enabled: bool = False,
     _connections_active: Any = None,
     _auth_failures: Any = None,
     _broadcasts_total: Any = None;

"""Initialize Prometheus metric handles. Idempotent; safe if already called."""
def setup_ws_metrics(enabled: bool = True, namespace: str = 'jac_scale') -> None {
    global _enabled,_connections_active,_auth_failures,_broadcasts_total;
    if not enabled {
        _enabled = False;
        return;
    }
    if _connections_active is not None {
        _enabled = True;
        return;
    }
    try {
        import from prometheus_client { Counter, Gauge }
    } except ImportError {
        logger.debug('prometheus_client not installed; WS metrics disabled');
        _enabled = False;
        return;
    }
    _connections_active = Gauge(
        f"{namespace}_ws_connections_active",
        'Active WebSocket connections',
        ['kind', 'name']
    );
    _auth_failures = Counter(
        f"{namespace}_ws_auth_failures_total", 'WebSocket auth failures', ['reason']
    );
    _broadcasts_total = Counter(
        f"{namespace}_ws_broadcasts_total",
        'WebSocket broadcast publishes',
        ['kind', 'name']
    );
    _enabled = True;
}

def connection_opened(kind: str, name: str) {
    if _enabled and _connections_active is not None {
        try {
            _connections_active.labels(kind=kind, name=name).inc();
        } except Exception as e {
            logger.debug(f"WS metric inc failed: {e}");
        }
    }
}

def connection_closed(kind: str, name: str) {
    if _enabled and _connections_active is not None {
        try {
            _connections_active.labels(kind=kind, name=name).dec();
        } except Exception as e {
            logger.debug(f"WS metric dec failed: {e}");
        }
    }
}

def auth_failure(reason: str) {
    if _enabled and _auth_failures is not None {
        try {
            _auth_failures.labels(reason=reason).inc();
        } except Exception as e {
            logger.debug(f"WS metric inc failed: {e}");
        }
    }
}

def broadcast_published(kind: str, name: str) {
    if _enabled and _broadcasts_total is not None {
        try {
            _broadcasts_total.labels(kind=kind, name=name).inc();
        } except Exception as e {
            logger.debug(f"WS metric inc failed: {e}");
        }
    }
}
