"""Tests for GrafanaManager credential management."""

import json;
import from typing { Any, Callable }
import from jac_scale.admin.grafana_manager { GrafanaManager }
import from jac_scale.tests.scale_test_client {
    ScaleTestClient,
    make_client,
    extract_data
}

glob DEFAULT_ADMIN_PASSWORD: str = "changeme";

def _reset_grafana_manager -> None {
    import from jac_scale.admin { grafana_manager }
    grafana_manager._grafana_manager = None;
}

"""Create a mock Grafana API handler with configurable behavior."""
def _make_mock_api(
    user_exists: bool = False,
    user_id: int = 2,
    fail_create: bool = False,
    fail_password_update: bool = False
) -> tuple[Callable, list[str]] {
    call_log: list[str] = [];

    def mock_api_request(
        method: str,
        path: str,
        data: (dict | None) = None,
        auth_user: (str | None) = None,
        auth_password: (str | None) = None
    ) -> (dict | None) {
        call_log.append(f"{method} {path}");
        if path == '/api/health' {
            return {'database': 'ok', 'version': '10.0'};
        }
        if path == '/api/org' {
            return {'id': 1, 'name': 'Main Org.'};
        }
        if '/api/users/lookup' in path {
            if user_exists {
                return {'id': user_id, 'login': 'jac-monitor'};
            }
            return None;
        }
        if path == '/api/admin/users' and method == 'POST' {
            if fail_create {
                return None;
            }
            return {'id': user_id, 'message': 'User created'};
        }
        if '/api/org/users/' in path and method == 'PATCH' {
            return {'message': 'Organization user updated'};
        }
        if '/api/admin/users/' in path and '/password' in path and method == 'PUT' {
            if fail_password_update {
                return None;
            }
            return {'message': 'User password updated'};
        }
        return None;
    }

    return (mock_api_request, call_log);
}

"""Create and setup a GrafanaManager for testing."""
def _setup_manager(
    grafana_url: str = 'http://grafana:3000',
    admin_password: str = 'admin123',
    monitoring_user: str = 'jac-monitor',
    monitoring_password: str = 'mon123'
) -> GrafanaManager {
    _reset_grafana_manager();
    mgr = GrafanaManager.instance();
    mgr.setup(
        admin_password=admin_password,
        monitoring_user=monitoring_user,
        monitoring_password=monitoring_password,
        grafana_url=grafana_url
    );
    return mgr;
}

# ============================================================================
# GrafanaManager Core Tests
# ============================================================================
test "grafana_manager singleton and setup" {
    _reset_grafana_manager();
    mgr1 = GrafanaManager.instance();
    mgr2 = GrafanaManager.instance();
    assert mgr1 is mgr2;

    mgr1.setup(
        admin_password='testpass',
        monitoring_user='mon-user',
        monitoring_password='mon-pass',
        grafana_url='http://grafana:3000'
    );
    assert mgr1._admin_password == 'testpass';
    assert mgr1._monitoring_user == 'mon-user';
    assert mgr1._monitoring_password == 'mon-pass';
    assert mgr1._grafana_url == 'http://grafana:3000';
    assert mgr1._initialized;
    _reset_grafana_manager();
}

test "grafana_manager full sync creates monitoring user" {
    mgr = _setup_manager();
    (mock_api, call_log) = _make_mock_api(user_exists=False, user_id=5);
    setattr(mgr, '_api_request', mock_api);

    result = mgr.sync_credentials();

    assert result['grafana_reachable'];
    assert result['admin_auth_ok'];
    assert result['monitoring_user_synced'];
    assert 'GET /api/health' in call_log;
    assert 'GET /api/org' in call_log;
    assert 'POST /api/admin/users' in call_log;
    _reset_grafana_manager();
}

test "grafana_manager sync skips when no url or grafana unreachable" {
    _reset_grafana_manager();
    mgr = GrafanaManager.instance();
    mgr._initialized = True;

    # No URL
    mgr._grafana_url = None;
    result = mgr.sync_credentials();
    assert not result['grafana_reachable'];

    # Unreachable Grafana
    mgr._grafana_url = 'http://nonexistent:3000';
    mgr._admin_password = 'test';
    result = mgr.sync_credentials();
    assert not result['grafana_reachable'];
    _reset_grafana_manager();
}

test "grafana_manager sync skips existing monitoring user" {
    mgr = _setup_manager();
    mgr._in_memory_store['monitoring'] = {
        '_id': 'monitoring',
        'grafana_user': 'jac-monitor',
        'grafana_password': 'existing_pass',
        'grafana_user_id': 3
    };
    (mock_api, call_log) = _make_mock_api(user_exists=True, user_id=3);
    setattr(mgr, '_api_request', mock_api);

    result = mgr.sync_credentials();

    assert result['monitoring_user_synced'];
    assert 'POST /api/admin/users' not in call_log;
    _reset_grafana_manager();
}

test "grafana_manager admin password sync and persistence" {
    mgr = _setup_manager(admin_password='old_pass');
    (mock_api, call_log) = _make_mock_api();
    setattr(mgr, '_api_request', mock_api);

    # Sync succeeds
    assert mgr.sync_admin_password('new_pass');
    assert mgr._admin_password == 'new_pass';
    assert 'PUT /api/admin/users/1/password' in call_log;

    # Password persisted (encrypted)
    stored = mgr._load_credentials('admin');
    assert stored is not None;
    assert 'encrypted_password' in stored;

    # Fails when not initialised
    _reset_grafana_manager();
    mgr2 = GrafanaManager.instance();
    mgr2._initialized = False;
    assert not mgr2.sync_admin_password('x');
    _reset_grafana_manager();
}

test "grafana_manager rotate monitoring password" {
    mgr = _setup_manager();
    (mock_api, _) = _make_mock_api(user_exists=True, user_id=3);
    setattr(mgr, '_api_request', mock_api);

    result = mgr.rotate_monitoring_password();

    assert result['status'] == 'rotated';
    assert result['user_id'] == 3;
    assert len(result['password']) > 0;

    # Verify persisted
    stored = mgr._load_credentials('monitoring');
    assert stored is not None;
    assert stored['grafana_password'] == result['password'];
    _reset_grafana_manager();
}

test "grafana_manager credential persistence in memory" {
    _reset_grafana_manager();
    mgr = GrafanaManager.instance();
    mgr._db = None;

    # Store and load
    mgr._persist_credentials('test_key', {'user': 'test', 'pass': '123'});
    loaded = mgr._load_credentials('test_key');
    assert loaded is not None;
    assert loaded['user'] == 'test';

    # Missing key returns None
    assert mgr._load_credentials('nonexistent') is None;

    # get_monitoring_credentials returns None when empty
    assert mgr.get_monitoring_credentials() is None;

    # get_monitoring_credentials returns stored creds
    mgr._monitoring_user = 'jac-monitor';
    mgr._persist_credentials('monitoring', {
        'grafana_user': 'jac-monitor',
        'grafana_password': 'stored_pass',
        'grafana_user_id': 2,
        'created_at': '2026-01-01T00:00:00Z'
    });
    creds = mgr.get_monitoring_credentials();
    assert creds['username'] == 'jac-monitor';
    assert creds['password'] == 'stored_pass';
    _reset_grafana_manager();
}

# ============================================================================
# Admin Endpoint Tests
# ============================================================================
test "admin grafana endpoints require admin auth" {
    client = make_client();
    try {
        assert client.get("/admin/grafana/credentials").status_code == 403;
        assert client.post("/admin/grafana/sync").status_code == 403;
        assert client.post("/admin/grafana/credentials/rotate").status_code == 403;
    } finally {
        client.close();
    }
}

test "admin grafana credentials returns status when manager not init" {
    client = make_client();
    try {
        token = client.admin_login();
        response = client.get(
            "/admin/grafana/credentials", headers={"Authorization": f"Bearer {token}"}
        );
        # GrafanaManager not initialized in test mode
        assert response.status_code in [200, 503];
    } finally {
        client.close();
    }
}
