"""Tests for the admin /deployments endpoints.

These tests run without a real Prometheus instance, so they exercise the
graceful-degradation path (metrics_available: false) and the admin-auth gate.
The PromQL projection logic is covered separately via the helper unit tests.
"""

import from jac_scale.tests.scale_test_client { make_client, extract_data }

# ============================================================================
# Endpoint auth gating
# ============================================================================
test "deployments summary requires admin" {
    client = make_client();
    try {
        response = client.get("/admin/deployments");
        assert response.status_code == 403;
    } finally {
        client.close();
    }
}

test "deployments list requires admin" {
    client = make_client();
    try {
        response = client.get("/admin/deployments/list");
        assert response.status_code == 403;
    } finally {
        client.close();
    }
}

test "deployment detail requires admin" {
    client = make_client();
    try {
        response = client.get("/admin/deployments/jac-app");
        assert response.status_code == 403;
    } finally {
        client.close();
    }
}

test "deployment timeseries requires admin" {
    client = make_client();
    try {
        response = client.get("/admin/deployments/jac-app/timeseries");
        assert response.status_code == 403;
    } finally {
        client.close();
    }
}

# ============================================================================
# Graceful degradation when Prometheus is not reachable
# ============================================================================
test "deployments summary returns metrics_available false when no prometheus" {
    client = make_client();
    try {
        token = client.admin_login();
        # Without K8S_APP_NAME or PROMETHEUS_URL in env, resolve_prometheus_url()
        # returns None and the handler should report metrics_available: false
        # instead of erroring.
        response = client.get(
            "/admin/deployments", headers={"Authorization": f"Bearer {token}"}
        );
        assert response.status_code == 200;
        data = extract_data(response.json());
        assert data["metrics_available"] is False;
        assert "reason" in data;
    } finally {
        client.close();
    }
}

test "deployments list returns empty array when no prometheus" {
    client = make_client();
    try {
        token = client.admin_login();
        response = client.get(
            "/admin/deployments/list", headers={"Authorization": f"Bearer {token}"}
        );
        assert response.status_code == 200;
        data = extract_data(response.json());
        assert data["metrics_available"] is False;
        assert data["deployments"] == [];
    } finally {
        client.close();
    }
}

# ============================================================================
# Phase → status translation
# ============================================================================
test "phase to status: all running is Healthy" {
    assert _phase_to_status(3, 0, 0, 0) == "Healthy";
}

test "phase to status: pending only is Starting" {
    assert _phase_to_status(0, 2, 0, 0) == "Starting";
}

test "phase to status: any failed is Broken" {
    assert _phase_to_status(2, 0, 1, 0) == "Broken";
}

test "phase to status: running with recent restarts is Unstable" {
    assert _phase_to_status(2, 0, 0, 3) == "Unstable";
}

test "phase to status: nothing running is Unknown" {
    assert _phase_to_status(0, 0, 0, 0) == "Unknown";
}

# ============================================================================
# Monitoring stack filtering
# ============================================================================
test "monitoring stack pods are hidden" {
    assert _is_monitoring_stack("jac-app-prometheus") is True;
    assert _is_monitoring_stack("jac-app-grafana") is True;
    assert _is_monitoring_stack("jac-app-kube-state-metrics") is True;
    assert _is_monitoring_stack("jac-app-node-exporter") is True;
}

test "user deployments are not filtered" {
    assert _is_monitoring_stack("jac-app") is False;
    assert _is_monitoring_stack("jac-app-worker") is False;
    assert _is_monitoring_stack("jac-scheduler") is False;
}

# ============================================================================
# Pod-name to deployment-name rollup
# ============================================================================
test "pod name strips replicaset and pod hashes" {
    assert _deployment_name_from_pod("jac-app-7d9b5f8c4d-xk2p9") == "jac-app";
    assert _deployment_name_from_pod("my-worker-abc123-def456") == "my-worker";
}

test "pod name with few segments returns input" {
    assert _deployment_name_from_pod("short") == "short";
    assert _deployment_name_from_pod("") == "";
}
