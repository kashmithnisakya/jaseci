"""Tests for the jac-scale scheduling feature.

Covers:
  1. Endpoint filtering  — scheduled walkers/functions absent from OpenAPI docs
  2. Non-scheduled items — regular walkers/functions present in OpenAPI docs
  3. /jobs CRUD          — create, list, get, update, delete dynamic jobs
  4. Validation          — proper 400/401/404 responses for invalid inputs
  5. System user         — __system__ user is created and accessible at startup
"""
import contextlib;
import gc;
import glob;
import json;
import shutil;
import socket;
import subprocess;
import sys;
import time;
import requests;
import from pathlib { Path }
import from typing { Any }

# =============================================================================
# Helpers (mirrors pattern from test_restspec.jac)
# =============================================================================
"""Get a free port."""
def get_free_port -> int {
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s {
        s.bind(("", 0));
        s.listen(1);
        port = s.getsockname()[1];
    }
    return port;
}

"""Unwrap a TransportResponse envelope and return the inner data."""
def _data(resp: dict[str, Any]) -> Any {
    if isinstance(resp, dict) and "data" in resp {
        return resp["data"];
    }
    return resp;
}

"""Unwrap a TransportResponse error."""
def _err(resp: dict[str, Any]) -> dict[str, Any] | None {
    if isinstance(resp, dict) and not resp.get("ok") {
        return resp.get("error") or resp;
    }
    return None;
}

"""Delete SQLite and shelf artefacts left by a test run."""
def _cleanup(fixtures_dir: Path) -> None {
    for pattern in ["*.db", "*.db-wal", "*.db-shm", "anchor_store*"] {
        for f in glob.glob(pattern) {
            with contextlib.suppress(Exception) {
                Path(f).unlink();
            }
        }
    }
    for pattern in ["*.db", "*.db-wal", "*.db-shm"] {
        for f in glob.glob(str(fixtures_dir / pattern)) {
            with contextlib.suppress(Exception) {
                Path(f).unlink();
            }
        }
    }
    jac_dir = fixtures_dir / ".jac";
    if jac_dir.exists() {
        with contextlib.suppress(Exception) {
            shutil.rmtree(jac_dir);
        }
    }
}

"""Start the jac server serving the scheduling fixture."""
def _start_server(fixtures_dir: Path, port: int) -> subprocess.Popen {
    base_url = f"http://localhost:{port}";
    jac_exe = Path(sys.executable).parent / "jac";
    cmd = [str(jac_exe), "start", "test_api.jac", "--port", str(port)];
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        cwd=str(fixtures_dir)
    );
    for _ in range(60) {
        if proc.poll() is not None {
            (out, err) = proc.communicate();
            raise RuntimeError(f"Server died.\nSTDOUT: {out}\nSTDERR: {err}") ;
        }
        try {
            r = requests.get(f"{base_url}/docs", timeout=2);
            if r.status_code in (200, 404) {
                return proc;
            }
        } except requests.RequestException {
            time.sleep(0.5);
        }
    }
    proc.terminate();
    proc.wait();
    raise RuntimeError("Server failed to start within 30 s") ;
}

"""Stop server and clean up."""
def _stop_server(proc: subprocess.Popen | None) -> None {
    if proc {
        proc.terminate();
        try {
            proc.wait(timeout=5);
        } except subprocess.TimeoutExpired {
            proc.kill();
            proc.wait();
        }
    }
    time.sleep(0.2);
    gc.collect();
}

"""Register a user and return their auth token."""
def _get_token(
    base_url: str, username: str = "testuser", password: str = "testpass"
) -> str {
    requests.post(
        f"{base_url}/user/register",
        json={"username": username, "password": password},
        timeout=5
    );
    resp = requests.post(
        f"{base_url}/user/login",
        json={"username": username, "password": password},
        timeout=5
    ).json();
    return _data(resp)["token"];
}

# =============================================================================
# Shared state
# =============================================================================
glob _fixtures_dir: Path = Path(__file__).parent / "fixtures",
     _port: int = get_free_port(),
     _base_url: str = f"http://localhost:{_port}";

"""Start one server shared across all scheduling tests."""
def _setup -> subprocess.Popen {
    _cleanup(_fixtures_dir);
    return _start_server(_fixtures_dir, _port);
}

"""Stop the shared server and clean up."""
def _teardown(proc: subprocess.Popen | None) -> None {
    _stop_server(proc);
    _cleanup(_fixtures_dir);
}

# =============================================================================
# 1. Endpoint Filtering Tests
# =============================================================================
test "scheduled walkers not in openapi docs" {
    sp = _setup();
    try {
        spec = requests.get(f"{_base_url}/openapi.json", timeout=5).json();
        paths = spec.get("paths", {});

        # Scheduled walkers must NOT appear as /walker/* endpoints
        assert "/walker/StaticScheduledWalker" not in paths , (
            "StaticScheduledWalker (STATIC) must not be an HTTP endpoint"
        );
        assert "/walker/StaticScheduledWalker/{nd}" not in paths , (
            "StaticScheduledWalker (STATIC) with node param must not be an HTTP endpoint"
        );
        assert "/walker/DynamicScheduledWalker" not in paths , (
            "DynamicScheduledWalker (DYNAMIC) must not be an HTTP endpoint"
        );
        assert "/walker/DynamicScheduledWalker/{nd}" not in paths , (
            "DynamicScheduledWalker (DYNAMIC) with node param must not be an HTTP endpoint"
        );
    } finally {
        _teardown(sp);
    }
}

test "scheduled functions not in openapi docs" {
    sp = _setup();
    try {
        spec = requests.get(f"{_base_url}/openapi.json", timeout=5).json();
        paths = spec.get("paths", {});

        # Scheduled functions must NOT appear as /function/* endpoints
        assert "/function/static_scheduled_func" not in paths , (
            "static_scheduled_func (STATIC) must not be an HTTP endpoint"
        );
        assert "/function/dynamic_scheduled_func" not in paths , (
            "dynamic_scheduled_func (DYNAMIC) must not be an HTTP endpoint"
        );
    } finally {
        _teardown(sp);
    }
}

test "non-scheduled walker still accessible as endpoint" {
    sp = _setup();
    try {
        spec = requests.get(f"{_base_url}/openapi.json", timeout=5).json();
        paths = spec.get("paths", {});

        # Regular walker must still appear
        assert "/walker/NormalWalker" in paths , (
            "NormalWalker (no schedule) must appear as an HTTP endpoint"
        );

        # And the endpoint must be functional
        resp = requests.post(f"{_base_url}/walker/NormalWalker", timeout=5);
        assert resp.status_code == 200;
        data = _data(resp.json());
        assert data["reports"][0]["message"] == "normal walker endpoint";
    } finally {
        _teardown(sp);
    }
}

test "non-scheduled function still accessible as endpoint" {
    sp = _setup();
    try {
        spec = requests.get(f"{_base_url}/openapi.json", timeout=5).json();
        paths = spec.get("paths", {});

        # Regular function must still appear
        assert "/function/normal_func" in paths , (
            "normal_func (no schedule) must appear as an HTTP endpoint"
        );
    } finally {
        _teardown(sp);
    }
}

# =============================================================================
# 2. Authentication Guard on /jobs
# =============================================================================
test "jobs endpoints require authentication" {
    sp = _setup();
    try {
        # GET /jobs without token → 401
        r = requests.get(f"{_base_url}/jobs", timeout=5);
        body = r.json();
        assert not body.get("ok") , "GET /jobs without auth should return ok=false";
        err = _err(body);
        assert err is not None;
        assert err.get("code") == "UNAUTHORIZED"
        or r.status_code == 401
        or "Unauthorized" in str(err);

        # POST /jobs without token → 401
        r = requests.post(
            f"{_base_url}/jobs",
            json={
                "walker_or_function": "DynamicScheduledWalker",
                "trigger": "interval",
                "interval": 60
            },
            timeout=5
        );
        body = r.json();
        assert not body.get("ok") , "POST /jobs without auth should return ok=false";
    } finally {
        _teardown(sp);
    }
}

# =============================================================================
# 3. /jobs CRUD Tests
# =============================================================================
test "create dynamic job via POST /jobs" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "creator", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        resp = requests.post(
            f"{_base_url}/jobs",
            json={
                "walker_or_function": "DynamicScheduledWalker",
                "trigger": "interval",
                "interval": 60
            },
            headers=headers,
            timeout=5
        );
        body = resp.json();
        assert body.get("ok") , f"POST /jobs failed: {body}";
        job = _data(body);
        assert job["name"] == "DynamicScheduledWalker";
        assert job["trigger"] == "interval";
        assert job["interval"] == 60;
        assert "_id" in job;
        assert job["status"] == "active";
        assert job["created_by"] == "creator";
    } finally {
        _teardown(sp);
    }
}

test "list jobs via GET /jobs" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "lister", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        # Create two jobs
        requests.post(
            f"{_base_url}/jobs",
            json={
                "walker_or_function": "DynamicScheduledWalker",
                "trigger": "interval",
                "interval": 30
            },
            headers=headers,
            timeout=5
        );
        requests.post(
            f"{_base_url}/jobs",
            json={
                "walker_or_function": "dynamic_scheduled_func",
                "trigger": "interval",
                "interval": 45
            },
            headers=headers,
            timeout=5
        );

        resp = requests.get(f"{_base_url}/jobs", headers=headers, timeout=5);
        body = resp.json();
        assert body.get("ok") , f"GET /jobs failed: {body}";
        result = _data(body);
        assert "jobs" in result;
        assert "count" in result;
        assert result["count"] >= 2;
        names = [j["name"] for j in result["jobs"]];
        assert "DynamicScheduledWalker" in names;
        assert "dynamic_scheduled_func" in names;
    } finally {
        _teardown(sp);
    }
}

test "get specific job via GET /jobs/{job_id}" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "getter", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        # Create a job
        create_resp = requests.post(
            f"{_base_url}/jobs",
            json={
                "walker_or_function": "DynamicScheduledWalker",
                "trigger": "interval",
                "interval": 120
            },
            headers=headers,
            timeout=5
        ).json();
        job_id = _data(create_resp)["_id"];

        # Get the specific job
        resp = requests.get(f"{_base_url}/jobs/{job_id}", headers=headers, timeout=5);
        body = resp.json();
        assert body.get("ok") , f"GET /jobs/{{job_id}} failed: {body}";
        job = _data(body);
        assert job["_id"] == job_id;
        assert job["name"] == "DynamicScheduledWalker";
        assert job["interval"] == 120;
    } finally {
        _teardown(sp);
    }
}

test "get non-existent job returns 404" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "getter2", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        resp = requests.get(
            f"{_base_url}/jobs/nonexistent-job-id-12345", headers=headers, timeout=5
        );
        body = resp.json();
        assert not body.get("ok") , "GET /jobs/{bad_id} should return ok=false";
        err = _err(body);
        assert err is not None;
        assert err.get("code") == "NOT_FOUND";
    } finally {
        _teardown(sp);
    }
}

test "update job schedule via PUT /jobs/{job_id}" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "updater", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        # Create a job with 60s interval
        create_resp = requests.post(
            f"{_base_url}/jobs",
            json={
                "walker_or_function": "DynamicScheduledWalker",
                "trigger": "interval",
                "interval": 60
            },
            headers=headers,
            timeout=5
        ).json();
        job_id = _data(create_resp)["_id"];

        # Update to 120s interval
        update_resp = requests.put(
            f"{_base_url}/jobs/{job_id}",
            json={"trigger": "interval", "interval": 120},
            headers=headers,
            timeout=5
        );
        body = update_resp.json();
        assert body.get("ok") , f"PUT /jobs/{{job_id}} failed: {body}";
        updated = _data(body);
        assert updated["interval"] == 120;
        assert updated["trigger"] == "interval";
    } finally {
        _teardown(sp);
    }
}

test "update non-existent job returns 404" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "updater2", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        resp = requests.put(
            f"{_base_url}/jobs/nonexistent-job-id-99999",
            json={"trigger": "interval", "interval": 60},
            headers=headers,
            timeout=5
        );
        body = resp.json();
        assert not body.get("ok") , "PUT /jobs/{bad_id} should return ok=false";
        err = _err(body);
        assert err is not None;
        assert err.get("code") == "NOT_FOUND";
    } finally {
        _teardown(sp);
    }
}

test "delete job via DELETE /jobs/{job_id}" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "deleter", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        # Create a job
        create_resp = requests.post(
            f"{_base_url}/jobs",
            json={
                "walker_or_function": "DynamicScheduledWalker",
                "trigger": "interval",
                "interval": 60
            },
            headers=headers,
            timeout=5
        ).json();
        job_id = _data(create_resp)["_id"];

        # Delete it
        del_resp = requests.delete(
            f"{_base_url}/jobs/{job_id}", headers=headers, timeout=5
        );
        body = del_resp.json();
        assert body.get("ok") , f"DELETE /jobs/{{job_id}} failed: {body}";
        result = _data(body);
        assert result.get("deleted") == True;
        assert result.get("job_id") == job_id;

        # Verify it's gone — GET should return 404
        get_resp = requests.get(
            f"{_base_url}/jobs/{job_id}", headers=headers, timeout=5
        );
        get_body = get_resp.json();
        assert not get_body.get("ok");
        err = _err(get_body);
        assert err is not None;
        assert err.get("code") == "NOT_FOUND";
    } finally {
        _teardown(sp);
    }
}

test "delete non-existent job returns 404" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "deleter2", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        resp = requests.delete(
            f"{_base_url}/jobs/nonexistent-job-id-77777", headers=headers, timeout=5
        );
        body = resp.json();
        assert not body.get("ok") , "DELETE /jobs/{bad_id} should return ok=false";
        err = _err(body);
        assert err is not None;
        assert err.get("code") == "NOT_FOUND";
    } finally {
        _teardown(sp);
    }
}

# =============================================================================
# 4. Validation Tests
# =============================================================================
test "reject schedule request for non-existent walker" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "v_user1", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        resp = requests.post(
            f"{_base_url}/jobs",
            json={
                "walker_or_function": "NonExistentWalker",
                "trigger": "interval",
                "interval": 60
            },
            headers=headers,
            timeout=5
        );
        body = resp.json();
        assert not body.get("ok") , "Scheduling a non-existent walker should fail";
        err = _err(body);
        assert err is not None;
        assert err.get("code") == "NOT_FOUND";
    } finally {
        _teardown(sp);
    }
}

test "reject schedule request for walker without schedule decorator" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "v_user2", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        # NormalWalker has no @schedule decorator at all
        resp = requests.post(
            f"{_base_url}/jobs",
            json={
                "walker_or_function": "NormalWalker",
                "trigger": "interval",
                "interval": 60
            },
            headers=headers,
            timeout=5
        );
        body = resp.json();
        assert not body.get("ok") , "Scheduling a non-decorated walker should fail";
        err = _err(body);
        assert err is not None;
        assert err.get("code") == "INVALID_REQUEST";
    } finally {
        _teardown(sp);
    }
}

test "reject schedule request for STATIC-trigger walker" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "v_user3", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        # StaticScheduledWalker has @schedule(trigger=STATIC), not DYNAMIC
        resp = requests.post(
            f"{_base_url}/jobs",
            json={
                "walker_or_function": "StaticScheduledWalker",
                "trigger": "interval",
                "interval": 60
            },
            headers=headers,
            timeout=5
        );
        body = resp.json();
        assert not body.get("ok") , "Scheduling a STATIC-trigger walker via /jobs should fail";
        err = _err(body);
        assert err is not None;
        assert err.get("code") == "INVALID_REQUEST";
    } finally {
        _teardown(sp);
    }
}

test "reject schedule request with missing trigger field" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "v_user4", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        # Missing trigger field
        resp = requests.post(
            f"{_base_url}/jobs",
            json={"walker_or_function": "DynamicScheduledWalker"},
            headers=headers,
            timeout=5
        );
        body = resp.json();
        assert not body.get("ok") , "Request without trigger should fail";
        err = _err(body);
        assert err is not None;
        assert err.get("code") == "INVALID_REQUEST";
    } finally {
        _teardown(sp);
    }
}

test "reject interval job with missing interval value" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "v_user5", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        # trigger=interval but no interval value
        resp = requests.post(
            f"{_base_url}/jobs",
            json={
                "walker_or_function": "DynamicScheduledWalker",
                "trigger": "interval"
            },
            headers=headers,
            timeout=5
        );
        body = resp.json();
        assert not body.get("ok") , "interval trigger without interval value should fail";
        err = _err(body);
        assert err is not None;
        assert err.get("code") == "INVALID_REQUEST";
    } finally {
        _teardown(sp);
    }
}

test "reject cron job with missing cron expression" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "v_user6", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        # trigger=cron but no cron expression
        resp = requests.post(
            f"{_base_url}/jobs",
            json={"walker_or_function": "DynamicScheduledWalker", "trigger": "cron"},
            headers=headers,
            timeout=5
        );
        body = resp.json();
        assert not body.get("ok") , "cron trigger without cron expression should fail";
        err = _err(body);
        assert err is not None;
        assert err.get("code") == "INVALID_REQUEST";
    } finally {
        _teardown(sp);
    }
}

test "reject date job with missing date value" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "v_user7", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        resp = requests.post(
            f"{_base_url}/jobs",
            json={"walker_or_function": "DynamicScheduledWalker", "trigger": "date"},
            headers=headers,
            timeout=5
        );
        body = resp.json();
        assert not body.get("ok") , "date trigger without date value should fail";
        err = _err(body);
        assert err is not None;
        assert err.get("code") == "INVALID_REQUEST";
    } finally {
        _teardown(sp);
    }
}

test "reject job with unknown trigger type" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "v_user8", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        resp = requests.post(
            f"{_base_url}/jobs",
            json={
                "walker_or_function": "DynamicScheduledWalker",
                "trigger": "once_a_year"
            },
            headers=headers,
            timeout=5
        );
        body = resp.json();
        assert not body.get("ok") , "Unknown trigger type should fail";
        err = _err(body);
        assert err is not None;
        assert err.get("code") == "INVALID_REQUEST";
    } finally {
        _teardown(sp);
    }
}

# =============================================================================
# 5. Cron-trigger Dynamic Job
# =============================================================================
test "create cron-trigger dynamic job" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "cron_user", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        resp = requests.post(
            f"{_base_url}/jobs",
            json={
                "walker_or_function": "DynamicScheduledWalker",
                "trigger": "cron",
                "cron": "0 * * * *"  # every hour at minute 0
            },
            headers=headers,
            timeout=5
        );
        body = resp.json();
        assert body.get("ok") , f"POST /jobs cron failed: {body}";
        job = _data(body);
        assert job["trigger"] == "cron";
        assert job["cron"] == "0 * * * *";
        assert "_id" in job;
    } finally {
        _teardown(sp);
    }
}

# =============================================================================
# 6. /jobs Endpoints Appear in OpenAPI
# =============================================================================
test "jobs endpoints appear in openapi spec" {
    sp = _setup();
    try {
        spec = requests.get(f"{_base_url}/openapi.json", timeout=5).json();
        paths = spec.get("paths", {});

        assert "/jobs" in paths , "/jobs must be a registered endpoint";
        assert "post" in paths["/jobs"] , "POST /jobs must be registered";
        assert "get" in paths["/jobs"] , "GET /jobs must be registered";

        assert "/jobs/{job_id}" in paths , "/jobs/{job_id} must be a registered endpoint";
        assert "get" in paths["/jobs/{job_id}"] , "GET /jobs/{job_id} must be registered";
        assert "put" in paths["/jobs/{job_id}"] , "PUT /jobs/{job_id} must be registered";
        assert "delete" in paths["/jobs/{job_id}"] , "DELETE /jobs/{job_id} must be registered";
    } finally {
        _teardown(sp);
    }
}

# =============================================================================
# 7. System User Created at Startup
# =============================================================================
test "system user exists and can authenticate" {
    sp = _setup();
    try {
        # The __system__ user is created with the default password from config
        resp = requests.post(
            f"{_base_url}/user/login",
            json={"username": "__system__", "password": "system_secret"},
            timeout=5
        );
        body = resp.json();
        assert body.get("ok") , (
            "__system__ user must exist and be authenticatable after server startup"
        );
        token = _data(body).get("token");
        assert token is not None and len(token) > 10;
    } finally {
        _teardown(sp);
    }
}

# =============================================================================
# 8. Dynamic Function Scheduling
# =============================================================================
test "create dynamic job for function" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "func_user", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        resp = requests.post(
            f"{_base_url}/jobs",
            json={
                "walker_or_function": "dynamic_scheduled_func",
                "trigger": "interval",
                "interval": 90
            },
            headers=headers,
            timeout=5
        );
        body = resp.json();
        assert body.get("ok") , f"POST /jobs for function failed: {body}";
        job = _data(body);
        assert job["name"] == "dynamic_scheduled_func";
        assert job["trigger"] == "interval";
        assert job["interval"] == 90;
    } finally {
        _teardown(sp);
    }
}

test "reject STATIC-trigger function via /jobs" {
    sp = _setup();
    try {
        token = _get_token(_base_url, "func_user2", "pass123");
        headers = {"Authorization": f"Bearer {token}"};

        resp = requests.post(
            f"{_base_url}/jobs",
            json={
                "walker_or_function": "static_scheduled_func",
                "trigger": "interval",
                "interval": 60
            },
            headers=headers,
            timeout=5
        );
        body = resp.json();
        assert not body.get("ok") , "STATIC-trigger function must be rejected by /jobs";
        err = _err(body);
        assert err is not None;
        assert err.get("code") == "INVALID_REQUEST";
    } finally {
        _teardown(sp);
    }
}

# =============================================================================
# 9. Update Job with auth required
# =============================================================================
test "update and delete operations require authentication" {
    sp = _setup();
    try {
        # PUT without token
        r = requests.put(
            f"{_base_url}/jobs/some-id",
            json={"trigger": "interval", "interval": 30},
            timeout=5
        );
        body = r.json();
        assert not body.get("ok") , "PUT /jobs/{id} without auth must fail";

        # DELETE without token
        r = requests.delete(f"{_base_url}/jobs/some-id", timeout=5);
        body = r.json();
        assert not body.get("ok") , "DELETE /jobs/{id} without auth must fail";

        # GET /jobs/{id} without token
        r = requests.get(f"{_base_url}/jobs/some-id", timeout=5);
        body = r.json();
        assert not body.get("ok") , "GET /jobs/{id} without auth must fail";
    } finally {
        _teardown(sp);
    }
}
