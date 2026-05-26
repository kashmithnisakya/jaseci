"""Unit tests for the Grafana proxy parsers in admin_portal.impl.jac."""

import os;
import uuid;
import from unittest.mock { patch, MagicMock }

import from jac_scale.tests.scale_test_client {
    ScaleTestClient,
    make_client,
    extract_data
}


"""Build a MagicMock that imitates a successful Grafana datasource-proxy reply."""
def _grafana_response(result: list) -> any {
    resp = MagicMock();
    resp.status_code = 200;
    resp.json = MagicMock(
        return_value={
            'status': 'success',
            'data': {'resultType': 'vector', 'result': result}
        }
    );
    return resp;
}


def _with_grafana_env -> dict {
    return {
        'GRAFANA_INTERNAL_URL': 'http://stub-grafana:3000',
        'GRAFANA_USERNAME': 'admin',
        'GRAFANA_PASSWORD': 'test-pw'
    };
}


test "cluster/pods parses kube_pod_status_phase into per-phase counts" {
    client = make_client();
    try {
        token = client.admin_login();
        fake = _grafana_response(
            [
                {'metric': {'phase': 'Running'}, 'value': [1.0, '12']},
                {'metric': {'phase': 'Pending'}, 'value': [1.0, '2']},
                {'metric': {'phase': 'Failed'}, 'value': [1.0, '0']}
            ]
        );
        with patch.dict(os.environ, _with_grafana_env(), clear=False) {
            with patch('requests.get', return_value=fake) {
                response = client.get(
                    "/admin/cluster/pods",
                    headers={"Authorization": f"Bearer {token}"}
                );
            }
        }
        assert response.status_code == 200;
        data = extract_data(response.json());
        phases = data["phases"];
        assert phases["Running"] == 12;
        assert phases["Pending"] == 2;
        assert phases["Failed"] == 0;
        # Unmentioned phases default to 0 in the parser
        assert phases["Succeeded"] == 0;
    } finally {
        client.close();
    }
}


test "cluster/nodes flattens condition vector into ready bools" {
    client = make_client();
    try {
        token = client.admin_login();
        fake = _grafana_response(
            [
                {'metric': {'node': 'k3d-jac-server-0'}, 'value': [1.0, '1']},
                {'metric': {'node': 'k3d-jac-agent-0'}, 'value': [1.0, '0']}
            ]
        );
        with patch.dict(os.environ, _with_grafana_env(), clear=False) {
            with patch('requests.get', return_value=fake) {
                response = client.get(
                    "/admin/cluster/nodes",
                    headers={"Authorization": f"Bearer {token}"}
                );
            }
        }
        assert response.status_code == 200;
        data = extract_data(response.json());
        assert data["total"] == 2;
        ready_by_name = {n["node"]: n["ready"] for n in data["nodes"]};
        assert ready_by_name["k3d-jac-server-0"] is True;
        assert ready_by_name["k3d-jac-agent-0"] is False;
    } finally {
        client.close();
    }
}


test "cluster/deployments joins desired+available with healthy flag" {
    client = make_client();
    try {
        token = client.admin_login();
        # Two queries are made in sequence; side_effect returns each in turn
        desired = _grafana_response(
            [
                {
                    'metric': {'namespace': 'default', 'deployment': 'jaseci'},
                    'value': [1.0, '3']
                },
                {
                    'metric': {
                        'namespace': 'default',
                        'deployment': 'jaseci-grafana'
                    },
                    'value': [1.0, '1']
                }
            ]
        );
        available = _grafana_response(
            [
                {
                    'metric': {'namespace': 'default', 'deployment': 'jaseci'},
                    'value': [1.0, '2']
                },
                {
                    'metric': {
                        'namespace': 'default',
                        'deployment': 'jaseci-grafana'
                    },
                    'value': [1.0, '1']
                }
            ]
        );
        with patch.dict(os.environ, _with_grafana_env(), clear=False) {
            with patch('requests.get', side_effect=[desired, available]) {
                response = client.get(
                    "/admin/cluster/deployments",
                    headers={"Authorization": f"Bearer {token}"}
                );
            }
        }
        assert response.status_code == 200;
        data = extract_data(response.json());
        assert data["total"] == 2;
        assert data["healthy"] == 1 , "Only grafana matches desired=available";
        by_name = {d["name"]: d for d in data["deployments"]};
        assert by_name["default/jaseci"]["desired"] == 3;
        assert by_name["default/jaseci"]["available"] == 2;
        assert by_name["default/jaseci"]["healthy"] is False;
        assert by_name["default/jaseci-grafana"]["healthy"] is True;
    } finally {
        client.close();
    }
}


test "cluster/health flags grafana_reachable + ksm_up" {
    client = make_client();
    try {
        token = client.admin_login();
        fake = _grafana_response(
            [
                {'metric': {'job': 'kube-state-metrics'}, 'value': [1.0, '1']}
            ]
        );
        with patch.dict(os.environ, _with_grafana_env(), clear=False) {
            with patch('requests.get', return_value=fake) {
                response = client.get(
                    "/admin/cluster/health",
                    headers={"Authorization": f"Bearer {token}"}
                );
            }
        }
        assert response.status_code == 200;
        data = extract_data(response.json());
        assert data["grafana_reachable"] is True;
        assert data["kube_state_metrics_up"] is True;
        assert data["targets_seen"] == 1;
    } finally {
        client.close();
    }
}
