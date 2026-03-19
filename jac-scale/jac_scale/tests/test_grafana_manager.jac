"""Tests for GrafanaManager credential management."""

import json;
import from typing { Any }
import from unittest.mock { patch, MagicMock }
import from jac_scale.admin.grafana_manager { GrafanaManager }
import from jac_scale.tests.scale_test_client {
    ScaleTestClient,
    make_client,
    extract_data
}

glob DEFAULT_ADMIN_PASSWORD: str = "changeme";

# ============================================================================
# Helper: reset GrafanaManager singleton between tests
# ============================================================================
def _reset_grafana_manager -> None {
    import from jac_scale.admin { grafana_manager }
    grafana_manager._grafana_manager = None;
}

# ============================================================================
# GrafanaManager Unit Tests (mocked HTTP)
# ============================================================================
test "grafana_manager singleton returns same instance" {
    _reset_grafana_manager();
    mgr1 = GrafanaManager.instance();
    mgr2 = GrafanaManager.instance();
    assert mgr1 is mgr2;
    _reset_grafana_manager();
}

test "grafana_manager setup stores config" {
    _reset_grafana_manager();
    mgr = GrafanaManager.instance();
    mgr.setup(
        admin_password='testpass',
        monitoring_user='mon-user',
        monitoring_password='mon-pass',
        grafana_url='http://grafana:3000'
    );
    assert mgr._admin_password == 'testpass';
    assert mgr._monitoring_user == 'mon-user';
    assert mgr._monitoring_password == 'mon-pass';
    assert mgr._grafana_url == 'http://grafana:3000';
    assert mgr._initialized is True;
    _reset_grafana_manager();
}

test "grafana_manager sync_credentials skips when no url" {
    _reset_grafana_manager();
    mgr = GrafanaManager.instance();
    mgr._initialized = True;
    mgr._grafana_url = None;
    result = mgr.sync_credentials();
    assert result['grafana_reachable'] is False;
    assert result['admin_auth_ok'] is False;
    assert result['monitoring_user_synced'] is False;
    _reset_grafana_manager();
}

test "grafana_manager sync_credentials handles unreachable grafana" {
    _reset_grafana_manager();
    mgr = GrafanaManager.instance();
    mgr._initialized = True;
    mgr._grafana_url = 'http://nonexistent:3000';
    mgr._admin_password = 'test';
    result = mgr.sync_credentials();
    assert result['grafana_reachable'] is False;
    _reset_grafana_manager();
}

test "grafana_manager sync_credentials full flow with mock" {
    _reset_grafana_manager();
    mgr = GrafanaManager.instance();
    mgr.setup(
        admin_password='admin123',
        monitoring_user='jac-monitor',
        monitoring_password='mon123',
        grafana_url='http://grafana:3000'
    );

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
            return {'commit': 'abc', 'database': 'ok', 'version': '10.0'};
        }
        if path == '/api/org' {
            return {'id': 1, 'name': 'Main Org.'};
        }
        if '/api/users/lookup' in path {
            return None;  # User doesn't exist yet

        }
        if path == '/api/admin/users' and method == 'POST' {
            return {'id': 2, 'message': 'User created'};
        }
        if '/api/org/users/' in path and method == 'PATCH' {
            return {'message': 'Organization user updated'};
        }
        return None;
    }

    mgr._api_request = mock_api_request;
    result = mgr.sync_credentials();

    assert result['grafana_reachable'] is True;
    assert result['admin_auth_ok'] is True;
    assert result['monitoring_user_synced'] is True;
    assert 'GET /api/health' in call_log;
    assert 'GET /api/org' in call_log;
    assert 'POST /api/admin/users' in call_log;
    _reset_grafana_manager();
}

test "grafana_manager sync_admin_password with mock" {
    _reset_grafana_manager();
    mgr = GrafanaManager.instance();
    mgr._initialized = True;
    mgr._grafana_url = 'http://grafana:3000';
    mgr._admin_password = 'old_pass';

    updated = False;
    def mock_api_request(
        method: str,
        path: str,
        data: (dict | None) = None,
        auth_user: (str | None) = None,
        auth_password: (str | None) = None
    ) -> (dict | None) {
        nonlocal updated;
        if path == '/api/admin/users/1/password' and method == 'PUT' {
            updated = True;
            return {'message': 'User password updated'};
        }
        return None;
    }

    mgr._api_request = mock_api_request;
    result = mgr.sync_admin_password('new_pass');
    assert result is True;
    assert updated is True;
    assert mgr._admin_password == 'new_pass';
    _reset_grafana_manager();
}

test "grafana_manager sync_admin_password fails when not initialised" {
    _reset_grafana_manager();
    mgr = GrafanaManager.instance();
    mgr._initialized = False;
    result = mgr.sync_admin_password('new_pass');
    assert result is False;
    _reset_grafana_manager();
}

test "grafana_manager ensure_monitoring_user creates user" {
    _reset_grafana_manager();
    mgr = GrafanaManager.instance();
    mgr._initialized = True;
    mgr._grafana_url = 'http://grafana:3000';
    mgr._monitoring_user = 'jac-monitor';
    mgr._monitoring_password = 'test_pass';

    def mock_api_request(
        method: str,
        path: str,
        data: (dict | None) = None,
        auth_user: (str | None) = None,
        auth_password: (str | None) = None
    ) -> (dict | None) {
        if '/api/users/lookup' in path {
            return None;  # User doesn't exist

        }
        if path == '/api/admin/users' and method == 'POST' {
            return {'id': 5, 'message': 'User created'};
        }
        if '/api/org/users/' in path and method == 'PATCH' {
            return {'message': 'Organization user updated'};
        }
        return None;
    }

    mgr._api_request = mock_api_request;
    result = mgr.ensure_monitoring_user();
    assert result['status'] == 'created';
    assert result['username'] == 'jac-monitor';
    assert result['password'] == 'test_pass';
    assert result['user_id'] == 5;
    _reset_grafana_manager();
}

test "grafana_manager ensure_monitoring_user skips when exists" {
    _reset_grafana_manager();
    mgr = GrafanaManager.instance();
    mgr._initialized = True;
    mgr._grafana_url = 'http://grafana:3000';
    mgr._monitoring_user = 'jac-monitor';

    # Pre-populate in-memory store so it thinks creds are stored
    mgr._in_memory_store['monitoring'] = {
        '_id': 'monitoring',
        'grafana_user': 'jac-monitor',
        'grafana_password': 'existing_pass',
        'grafana_user_id': 3
    };

    def mock_api_request(
        method: str,
        path: str,
        data: (dict | None) = None,
        auth_user: (str | None) = None,
        auth_password: (str | None) = None
    ) -> (dict | None) {
        if '/api/users/lookup' in path {
            return {'id': 3, 'login': 'jac-monitor'};  # User exists

        }
        return None;
    }

    mgr._api_request = mock_api_request;
    result = mgr.ensure_monitoring_user();
    assert result['status'] == 'existing';
    assert result['user_id'] == 3;
    _reset_grafana_manager();
}

test "grafana_manager rotate_monitoring_password" {
    _reset_grafana_manager();
    mgr = GrafanaManager.instance();
    mgr._initialized = True;
    mgr._grafana_url = 'http://grafana:3000';
    mgr._monitoring_user = 'jac-monitor';

    def mock_api_request(
        method: str,
        path: str,
        data: (dict | None) = None,
        auth_user: (str | None) = None,
        auth_password: (str | None) = None
    ) -> (dict | None) {
        if '/api/users/lookup' in path {
            return {'id': 3, 'login': 'jac-monitor'};
        }
        if '/api/admin/users/3/password' in path and method == 'PUT' {
            return {'message': 'User password updated'};
        }
        return None;
    }

    mgr._api_request = mock_api_request;
    result = mgr.rotate_monitoring_password();
    assert result['status'] == 'rotated';
    assert result['user_id'] == 3;
    assert len(result['password']) > 0;
    _reset_grafana_manager();
}

test "grafana_manager get_monitoring_credentials returns stored creds" {
    _reset_grafana_manager();
    mgr = GrafanaManager.instance();
    mgr._monitoring_user = 'jac-monitor';
    mgr._in_memory_store['monitoring'] = {
        '_id': 'monitoring',
        'grafana_user': 'jac-monitor',
        'grafana_password': 'stored_pass',
        'grafana_user_id': 2,
        'created_at': '2026-01-01T00:00:00Z'
    };

    creds = mgr.get_monitoring_credentials();
    assert creds is not None;
    assert creds['username'] == 'jac-monitor';
    assert creds['password'] == 'stored_pass';
    assert creds['user_id'] == 2;
    _reset_grafana_manager();
}

test "grafana_manager get_monitoring_credentials returns none when empty" {
    _reset_grafana_manager();
    mgr = GrafanaManager.instance();
    creds = mgr.get_monitoring_credentials();
    assert creds is None;
    _reset_grafana_manager();
}

test "grafana_manager persist and load in memory" {
    _reset_grafana_manager();
    mgr = GrafanaManager.instance();
    mgr._db = None;  # Force in-memory

    mgr._persist_credentials('test_key', {'user': 'test', 'pass': '123'});
    loaded = mgr._load_credentials('test_key');
    assert loaded is not None;
    assert loaded['user'] == 'test';
    assert loaded['pass'] == '123';

    missing = mgr._load_credentials('nonexistent');
    assert missing is None;
    _reset_grafana_manager();
}

test "grafana_manager auto_generates password when empty" {
    _reset_grafana_manager();
    mgr = GrafanaManager.instance();
    mgr._initialized = True;
    mgr._grafana_url = 'http://grafana:3000';
    mgr._monitoring_user = 'jac-monitor';
    mgr._monitoring_password = '';  # Empty — should auto-generate

    def mock_api_request(
        method: str,
        path: str,
        data: (dict | None) = None,
        auth_user: (str | None) = None,
        auth_password: (str | None) = None
    ) -> (dict | None) {
        if '/api/users/lookup' in path {
            return None;
        }
        if path == '/api/admin/users' and method == 'POST' {
            return {'id': 7, 'message': 'User created'};
        }
        if '/api/org/users/' in path {
            return {'message': 'ok'};
        }
        return None;
    }

    mgr._api_request = mock_api_request;
    result = mgr.ensure_monitoring_user();
    assert result['status'] == 'created';
    assert len(result['password']) == 16;  # generate_random_password(16)
    _reset_grafana_manager();
}

# ============================================================================
# Admin Endpoint Tests (via ScaleTestClient)
# ============================================================================
test "admin grafana credentials endpoint requires admin" {
    client = make_client();
    try {
        response = client.get("/admin/grafana/credentials");
        assert response.status_code == 403;
    } finally {
        client.close();
    }
}

test "admin grafana credentials returns not configured when manager not init" {
    client = make_client();
    try {
        token = client.admin_login();
        response = client.get(
            "/admin/grafana/credentials", headers={"Authorization": f"Bearer {token}"}
        );
        data = response.json();
        # GrafanaManager is not initialized in test mode (no monitoring enabled)
        # so it should return NOT_CONFIGURED or no credentials
        assert response.status_code in [200, 503];
    } finally {
        client.close();
    }
}

test "admin grafana sync endpoint requires admin" {
    client = make_client();
    try {
        response = client.post("/admin/grafana/sync");
        assert response.status_code == 403;
    } finally {
        client.close();
    }
}

test "admin grafana rotate endpoint requires admin" {
    client = make_client();
    try {
        response = client.post("/admin/grafana/credentials/rotate");
        assert response.status_code == 403;
    } finally {
        client.close();
    }
}
