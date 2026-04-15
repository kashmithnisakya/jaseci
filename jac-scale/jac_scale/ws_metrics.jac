"""Prometheus metrics for the WebSocket layer.

Designed to degrade gracefully: if `prometheus_client` isn't installed, every
record_* call is a no-op. The handler can always call these; deployments
without Prometheus just pay the cost of a no-op call.

Metrics exposed (when enabled):
* `ws_connections_active{kind,name}`       (Gauge)
* `ws_messages_received_total{kind,name}`  (Counter)
* `ws_messages_sent_total{kind,name}`      (Counter)
* `ws_auth_failures_total{reason}`         (Counter)
* `ws_target_duration_seconds{kind,name}`  (Histogram)
* `ws_broadcasts_total{kind,name}`         (Counter)
"""
import logging;
import from typing { Any }

glob logger = logging.getLogger(__name__);
glob _enabled: bool = False;
glob _namespace: str = 'jac_scale';
glob _connections_active: Any = None;
glob _messages_received: Any = None;
glob _messages_sent: Any = None;
glob _auth_failures: Any = None;
glob _target_duration: Any = None;
glob _broadcasts_total: Any = None;

"""Initialize Prometheus metric handles. Idempotent; safe if already called."""
def setup_ws_metrics(enabled: bool = True, namespace: str = 'jac_scale') -> None {
    global _enabled, _namespace, _connections_active, _messages_received,
        _messages_sent, _auth_failures, _target_duration, _broadcasts_total;
    if not enabled {
        _enabled = False;
        return;
    }
    if _connections_active is not None {
        _enabled = True;
        return;
    }
    try {
        import from prometheus_client { Counter, Gauge, Histogram }
    } except ImportError {
        logger.debug('prometheus_client not installed; WS metrics disabled');
        _enabled = False;
        return;
    }
    _namespace = namespace;
    _connections_active = Gauge(
        f"{namespace}_ws_connections_active",
        'Active WebSocket connections',
        ['kind', 'name']
    );
    _messages_received = Counter(
        f"{namespace}_ws_messages_received_total",
        'WebSocket messages received',
        ['kind', 'name']
    );
    _messages_sent = Counter(
        f"{namespace}_ws_messages_sent_total",
        'WebSocket messages sent',
        ['kind', 'name']
    );
    _auth_failures = Counter(
        f"{namespace}_ws_auth_failures_total",
        'WebSocket auth failures',
        ['reason']
    );
    _target_duration = Histogram(
        f"{namespace}_ws_target_duration_seconds",
        'WebSocket walker/function execution duration',
        ['kind', 'name']
    );
    _broadcasts_total = Counter(
        f"{namespace}_ws_broadcasts_total",
        'WebSocket broadcast publishes',
        ['kind', 'name']
    );
    _enabled = True;
}

def connection_opened(kind: str, name: str) -> None {
    if _enabled and _connections_active is not None {
        try {
            _connections_active.labels(kind=kind, name=name).inc();
        } except Exception as e {
            logger.debug(f"WS metric inc failed: {e}");
        }
    }
}

def connection_closed(kind: str, name: str) -> None {
    if _enabled and _connections_active is not None {
        try {
            _connections_active.labels(kind=kind, name=name).dec();
        } except Exception as e {
            logger.debug(f"WS metric dec failed: {e}");
        }
    }
}

def message_received(kind: str, name: str) -> None {
    if _enabled and _messages_received is not None {
        try {
            _messages_received.labels(kind=kind, name=name).inc();
        } except Exception as e {
            logger.debug(f"WS metric inc failed: {e}");
        }
    }
}

def message_sent(kind: str, name: str) -> None {
    if _enabled and _messages_sent is not None {
        try {
            _messages_sent.labels(kind=kind, name=name).inc();
        } except Exception as e {
            logger.debug(f"WS metric inc failed: {e}");
        }
    }
}

def auth_failure(reason: str) -> None {
    if _enabled and _auth_failures is not None {
        try {
            _auth_failures.labels(reason=reason).inc();
        } except Exception as e {
            logger.debug(f"WS metric inc failed: {e}");
        }
    }
}

def observe_target_duration(kind: str, name: str, seconds: float) -> None {
    if _enabled and _target_duration is not None {
        try {
            _target_duration.labels(kind=kind, name=name).observe(seconds);
        } except Exception as e {
            logger.debug(f"WS metric observe failed: {e}");
        }
    }
}

def broadcast_published(kind: str, name: str) -> None {
    if _enabled and _broadcasts_total is not None {
        try {
            _broadcasts_total.labels(kind=kind, name=name).inc();
        } except Exception as e {
            logger.debug(f"WS metric inc failed: {e}");
        }
    }
}
