"""Tests for schedule walkers - runs both without and with MongoDB."""

import contextlib;
import gc;
import glob;
import json;
import os;
import socket;
import subprocess;
import sys;
import time;
import uuid;
import shutil;
import requests;
import from pathlib { Path }
import from typing { Any, cast }
import from datetime { datetime, timedelta }

import from testcontainers.mongodb { MongoDbContainer }

"""Get a free port by binding to port 0 and releasing it."""
def get_free_port -> int {
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s {
        s.bind(("", 0));
        s.listen(1);
        port = s.getsockname()[1];
    }
    return port;
}

"""Extract data from TransportResponse envelope format."""
def _extract_data(
    json_response: dict[str, Any] | list[Any]
) -> dict[str, Any] | list[Any] {
    if isinstance(json_response, list) and len(cast(list, json_response)) == 2 {
        body: dict[str, Any] = json_response[1];
        json_response = body;
    }

    if (
        isinstance(json_response, dict)
        and "ok" in json_response
        and "data" in json_response
    ) {
        if json_response.get("ok") and json_response.get("data") is not None {
            return json_response["data"];
        } elif not json_response.get("ok") and json_response.get("error") {
            error_info = json_response["error"];
            result: dict[str, Any] = {
                "error": error_info.get("message", "Unknown error")
            };
            if "code" in error_info {
                result["error_code"] = error_info["code"];
            }
            if "details" in error_info {
                result["error_details"] = error_info["details"];
            }
            return result;
        }
    }

    return json_response;
}

"""Delete SQLite database files and legacy shelf files."""
def _cleanup_db_files(fixtures_dir: Path) -> None {
    for pattern in [
        "*.db",
        "*.db-wal",
        "*.db-shm",
        "anchor_store.db.dat",
        "anchor_store.db.bak",
        "anchor_store.db.dir"
    ] {
        for db_file in glob.glob(pattern) {
            with contextlib.suppress(Exception) {
                Path(db_file).unlink();
            }
        }
    }

    for pattern in ["*.db", "*.db-wal", "*.db-shm"] {
        for db_file in glob.glob(str(fixtures_dir / pattern)) {
            with contextlib.suppress(Exception) {
                Path(db_file).unlink();
            }
        }
    }

    client_build_dir = fixtures_dir / ".jac";
    if client_build_dir.exists() {
        with contextlib.suppress(Exception) {
            shutil.rmtree(client_build_dir);
        }
    }
}

"""Start the jac-scale server in a subprocess."""
def _start_server(
    fixtures_dir: Path,
    test_file: Path,
    port: int,
    base_url: str,
    env: dict | None = None
) -> subprocess.Popen {
    jac_executable = Path(sys.executable).parent / "jac";

    cmd = [str(jac_executable), "start", test_file.name, "--port", str(port)];

    proc_env = os.environ.copy();
    if env {
        proc_env.update(env);
    }

    server_process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        cwd=str(fixtures_dir),
        env=proc_env
    );

    max_attempts = 50;
    server_ready = False;

    for _ in range(max_attempts) {
        if server_process.poll() is not None {
            (stdout, stderr) = server_process.communicate();
            raise RuntimeError(
                f"Server process terminated unexpectedly.\n"
                f"STDOUT: {stdout}\nSTDERR: {stderr}"
            ) ;
        }

        try {
            response = requests.get(f"{base_url}/docs", timeout=2);
            if response.status_code in (200, 404) {
                print(f"Server started successfully on port {port}");
                server_ready = True;
                break;
            }
        } except (requests.ConnectionError, requests.Timeout) {
            time.sleep(2);
        }
    }

    if not (server_ready) {
        server_process.terminate();
        try {
            (stdout, stderr) = server_process.communicate(timeout=2);
        } except subprocess.TimeoutExpired {
            server_process.kill();
            (stdout, stderr) = server_process.communicate();
        }
        raise RuntimeError(
            f"Server failed to start after {max_attempts} attempts.\n"
            f"STDOUT: {stdout}\nSTDERR: {stderr}"
        ) ;
    }

    return server_process;
}

"""Stop the server process."""
def _stop_server(server_process: subprocess.Popen | None) -> None {
    if server_process {
        server_process.terminate();
        try {
            server_process.wait(timeout=5);
        } except subprocess.TimeoutExpired {
            server_process.kill();
            server_process.wait();
        }
    }
    time.sleep(0.5);
    gc.collect();
}

# =========================================================================
# Shared schedule test functions
# =========================================================================
"""Register a user and return auth token."""
def _get_auth_token(base_url: str) -> str {
    username = f"sched_{uuid.uuid4().hex[:8]}";
    response = requests.post(
        f"{base_url}/user/register",
        json={"username": username, "password": "testpass"},
        timeout=10
    );
    assert response.status_code == 201;
    return _extract_data(response.json())["token"];
}

"""Test listing schedules returns static schedules from @restspec."""
def run_schedule_list_test(base_url: str) -> None {
    token = _get_auth_token(base_url);
    response = requests.get(
        f"{base_url}/schedule/list",
        headers={"Authorization": f"Bearer {token}"},
        timeout=10
    );
    assert response.status_code == 200 , (
        f"Expected 200, got {response.status_code}: {response.text}"
    );
    data = response.json();
    assert data["ok"] is True;
    assert isinstance(data["data"], list);
}

"""Test creating an interval schedule via API."""
def run_schedule_create_interval_test(base_url: str) -> None {
    token = _get_auth_token(base_url);
    response = requests.post(
        f"{base_url}/schedule/create",
        json={"walker_name": "regular_task", "trigger": "interval", "seconds": 60},
        headers={"Authorization": f"Bearer {token}"},
        timeout=10
    );
    assert response.status_code == 201 , (
        f"Expected 201, got {response.status_code}: {response.text}"
    );
    data = response.json();
    assert data["ok"] is True;
    assert "id" in data["data"];
}

"""Test creating a cron schedule via API."""
def run_schedule_create_cron_test(base_url: str) -> None {
    token = _get_auth_token(base_url);
    response = requests.post(
        f"{base_url}/schedule/create",
        json={"walker_name": "regular_task", "trigger": "cron", "cron": "0 * * * *"},
        headers={"Authorization": f"Bearer {token}"},
        timeout=10
    );
    assert response.status_code == 201;
    data = response.json();
    assert data["ok"] is True;
}

"""Test creating a one-time date schedule via API."""
def run_schedule_create_date_test(base_url: str) -> None {
    token = _get_auth_token(base_url);
    future_date = (datetime.now() + timedelta(hours=1)).isoformat();
    response = requests.post(
        f"{base_url}/schedule/create",
        json={
            "walker_name": "regular_task",
            "trigger": "date",
            "run_date": future_date
        },
        headers={"Authorization": f"Bearer {token}"},
        timeout=10
    );
    assert response.status_code == 201;
    data = response.json();
    assert data["ok"] is True;
}

"""Test getting a specific schedule by ID."""
def run_schedule_get_by_id_test(base_url: str) -> None {
    token = _get_auth_token(base_url);
    create_response = requests.post(
        f"{base_url}/schedule/create",
        json={"walker_name": "regular_task", "trigger": "interval", "minutes": 10},
        headers={"Authorization": f"Bearer {token}"},
        timeout=10
    );
    schedule_id = create_response.json()["data"]["id"];

    response = requests.get(
        f"{base_url}/schedule/{schedule_id}",
        headers={"Authorization": f"Bearer {token}"},
        timeout=10
    );
    assert response.status_code == 200;
    data = response.json();
    assert data["ok"] is True;
    assert data["data"]["id"] == schedule_id;
}

"""Test updating a schedule."""
def run_schedule_update_test(base_url: str) -> None {
    token = _get_auth_token(base_url);
    create_response = requests.post(
        f"{base_url}/schedule/create",
        json={"walker_name": "regular_task", "trigger": "interval", "seconds": 30},
        headers={"Authorization": f"Bearer {token}"},
        timeout=10
    );
    schedule_id = create_response.json()["data"]["id"];

    response = requests.put(
        f"{base_url}/schedule/{schedule_id}",
        json={"is_active": False},
        headers={"Authorization": f"Bearer {token}"},
        timeout=10
    );
    assert response.status_code == 200;
    data = response.json();
    assert data["ok"] is True;
}

"""Test deleting a schedule."""
def run_schedule_delete_test(base_url: str) -> None {
    token = _get_auth_token(base_url);
    create_response = requests.post(
        f"{base_url}/schedule/create",
        json={"walker_name": "regular_task", "trigger": "interval", "seconds": 30},
        headers={"Authorization": f"Bearer {token}"},
        timeout=10
    );
    schedule_id = create_response.json()["data"]["id"];

    response = requests.delete(
        f"{base_url}/schedule/{schedule_id}",
        headers={"Authorization": f"Bearer {token}"},
        timeout=10
    );
    assert response.status_code == 200;
    data = response.json();
    assert data["ok"] is True;
}

"""Test getting a schedule that doesn't exist."""
def run_schedule_get_nonexistent_test(base_url: str) -> None {
    token = _get_auth_token(base_url);
    response = requests.get(
        f"{base_url}/schedule/nonexistent-id",
        headers={"Authorization": f"Bearer {token}"},
        timeout=10
    );
    assert response.status_code == 404;
}

"""Test that schedule endpoints require authentication."""
def run_schedule_requires_auth_test(base_url: str) -> None {
    response = requests.get(f"{base_url}/schedule/list", timeout=10);
    assert response.status_code in (401, 422);
}

# =========================================================================
# Globals
# =========================================================================
glob sched_fixtures_dir:
         Path = Path(__file__).parent / "fixtures",
     sched_test_file: Path = sched_fixtures_dir / "test_api.jac";

# =========================================================================
# Test class 1: Schedule tests WITHOUT MongoDB (file-based storage)
# =========================================================================
test "schedule without mongo - list endpoint" {
    port = get_free_port();
    base_url = f"http://localhost:{port}";
    original_mongodb_uri = os.environ.pop("MONGODB_URI", None);
    _cleanup_db_files(sched_fixtures_dir);
    sp = _start_server(sched_fixtures_dir, sched_test_file, port, base_url);
    try {
        run_schedule_list_test(base_url);
    } finally {
        _stop_server(sp);
        _cleanup_db_files(sched_fixtures_dir);
        if original_mongodb_uri is not None {
            os.environ["MONGODB_URI"] = original_mongodb_uri;
        }
    }
}

test "schedule without mongo - create interval" {
    port = get_free_port();
    base_url = f"http://localhost:{port}";
    original_mongodb_uri = os.environ.pop("MONGODB_URI", None);
    _cleanup_db_files(sched_fixtures_dir);
    sp = _start_server(sched_fixtures_dir, sched_test_file, port, base_url);
    try {
        run_schedule_create_interval_test(base_url);
    } finally {
        _stop_server(sp);
        _cleanup_db_files(sched_fixtures_dir);
        if original_mongodb_uri is not None {
            os.environ["MONGODB_URI"] = original_mongodb_uri;
        }
    }
}

test "schedule without mongo - create cron" {
    port = get_free_port();
    base_url = f"http://localhost:{port}";
    original_mongodb_uri = os.environ.pop("MONGODB_URI", None);
    _cleanup_db_files(sched_fixtures_dir);
    sp = _start_server(sched_fixtures_dir, sched_test_file, port, base_url);
    try {
        run_schedule_create_cron_test(base_url);
    } finally {
        _stop_server(sp);
        _cleanup_db_files(sched_fixtures_dir);
        if original_mongodb_uri is not None {
            os.environ["MONGODB_URI"] = original_mongodb_uri;
        }
    }
}

test "schedule without mongo - create date" {
    port = get_free_port();
    base_url = f"http://localhost:{port}";
    original_mongodb_uri = os.environ.pop("MONGODB_URI", None);
    _cleanup_db_files(sched_fixtures_dir);
    sp = _start_server(sched_fixtures_dir, sched_test_file, port, base_url);
    try {
        run_schedule_create_date_test(base_url);
    } finally {
        _stop_server(sp);
        _cleanup_db_files(sched_fixtures_dir);
        if original_mongodb_uri is not None {
            os.environ["MONGODB_URI"] = original_mongodb_uri;
        }
    }
}

test "schedule without mongo - get by id" {
    port = get_free_port();
    base_url = f"http://localhost:{port}";
    original_mongodb_uri = os.environ.pop("MONGODB_URI", None);
    _cleanup_db_files(sched_fixtures_dir);
    sp = _start_server(sched_fixtures_dir, sched_test_file, port, base_url);
    try {
        run_schedule_get_by_id_test(base_url);
    } finally {
        _stop_server(sp);
        _cleanup_db_files(sched_fixtures_dir);
        if original_mongodb_uri is not None {
            os.environ["MONGODB_URI"] = original_mongodb_uri;
        }
    }
}

test "schedule without mongo - update" {
    port = get_free_port();
    base_url = f"http://localhost:{port}";
    original_mongodb_uri = os.environ.pop("MONGODB_URI", None);
    _cleanup_db_files(sched_fixtures_dir);
    sp = _start_server(sched_fixtures_dir, sched_test_file, port, base_url);
    try {
        run_schedule_update_test(base_url);
    } finally {
        _stop_server(sp);
        _cleanup_db_files(sched_fixtures_dir);
        if original_mongodb_uri is not None {
            os.environ["MONGODB_URI"] = original_mongodb_uri;
        }
    }
}

test "schedule without mongo - delete" {
    port = get_free_port();
    base_url = f"http://localhost:{port}";
    original_mongodb_uri = os.environ.pop("MONGODB_URI", None);
    _cleanup_db_files(sched_fixtures_dir);
    sp = _start_server(sched_fixtures_dir, sched_test_file, port, base_url);
    try {
        run_schedule_delete_test(base_url);
    } finally {
        _stop_server(sp);
        _cleanup_db_files(sched_fixtures_dir);
        if original_mongodb_uri is not None {
            os.environ["MONGODB_URI"] = original_mongodb_uri;
        }
    }
}

test "schedule without mongo - get nonexistent" {
    port = get_free_port();
    base_url = f"http://localhost:{port}";
    original_mongodb_uri = os.environ.pop("MONGODB_URI", None);
    _cleanup_db_files(sched_fixtures_dir);
    sp = _start_server(sched_fixtures_dir, sched_test_file, port, base_url);
    try {
        run_schedule_get_nonexistent_test(base_url);
    } finally {
        _stop_server(sp);
        _cleanup_db_files(sched_fixtures_dir);
        if original_mongodb_uri is not None {
            os.environ["MONGODB_URI"] = original_mongodb_uri;
        }
    }
}

test "schedule without mongo - requires auth" {
    port = get_free_port();
    base_url = f"http://localhost:{port}";
    original_mongodb_uri = os.environ.pop("MONGODB_URI", None);
    _cleanup_db_files(sched_fixtures_dir);
    sp = _start_server(sched_fixtures_dir, sched_test_file, port, base_url);
    try {
        run_schedule_requires_auth_test(base_url);
    } finally {
        _stop_server(sp);
        _cleanup_db_files(sched_fixtures_dir);
        if original_mongodb_uri is not None {
            os.environ["MONGODB_URI"] = original_mongodb_uri;
        }
    }
}

# =========================================================================
# Test class 2: Schedule tests WITH MongoDB (via testcontainers)
# =========================================================================
test "schedule with mongo - list endpoint" {
    port = get_free_port();
    base_url = f"http://localhost:{port}";
    mongo_container = MongoDbContainer("mongo:latest");
    mongo_container.start();
    mongo_uri = mongo_container.get_connection_url();
    os.environ["MONGODB_URI"] = mongo_uri;
    _cleanup_db_files(sched_fixtures_dir);
    sp = _start_server(sched_fixtures_dir, sched_test_file, port, base_url);
    try {
        run_schedule_list_test(base_url);
    } finally {
        _stop_server(sp);
        os.environ.pop("MONGODB_URI", None);
        mongo_container.stop();
        _cleanup_db_files(sched_fixtures_dir);
    }
}

test "schedule with mongo - create interval" {
    port = get_free_port();
    base_url = f"http://localhost:{port}";
    mongo_container = MongoDbContainer("mongo:latest");
    mongo_container.start();
    mongo_uri = mongo_container.get_connection_url();
    os.environ["MONGODB_URI"] = mongo_uri;
    _cleanup_db_files(sched_fixtures_dir);
    sp = _start_server(sched_fixtures_dir, sched_test_file, port, base_url);
    try {
        run_schedule_create_interval_test(base_url);
    } finally {
        _stop_server(sp);
        os.environ.pop("MONGODB_URI", None);
        mongo_container.stop();
        _cleanup_db_files(sched_fixtures_dir);
    }
}

test "schedule with mongo - create cron" {
    port = get_free_port();
    base_url = f"http://localhost:{port}";
    mongo_container = MongoDbContainer("mongo:latest");
    mongo_container.start();
    mongo_uri = mongo_container.get_connection_url();
    os.environ["MONGODB_URI"] = mongo_uri;
    _cleanup_db_files(sched_fixtures_dir);
    sp = _start_server(sched_fixtures_dir, sched_test_file, port, base_url);
    try {
        run_schedule_create_cron_test(base_url);
    } finally {
        _stop_server(sp);
        os.environ.pop("MONGODB_URI", None);
        mongo_container.stop();
        _cleanup_db_files(sched_fixtures_dir);
    }
}

test "schedule with mongo - create date" {
    port = get_free_port();
    base_url = f"http://localhost:{port}";
    mongo_container = MongoDbContainer("mongo:latest");
    mongo_container.start();
    mongo_uri = mongo_container.get_connection_url();
    os.environ["MONGODB_URI"] = mongo_uri;
    _cleanup_db_files(sched_fixtures_dir);
    sp = _start_server(sched_fixtures_dir, sched_test_file, port, base_url);
    try {
        run_schedule_create_date_test(base_url);
    } finally {
        _stop_server(sp);
        os.environ.pop("MONGODB_URI", None);
        mongo_container.stop();
        _cleanup_db_files(sched_fixtures_dir);
    }
}

test "schedule with mongo - get by id" {
    port = get_free_port();
    base_url = f"http://localhost:{port}";
    mongo_container = MongoDbContainer("mongo:latest");
    mongo_container.start();
    mongo_uri = mongo_container.get_connection_url();
    os.environ["MONGODB_URI"] = mongo_uri;
    _cleanup_db_files(sched_fixtures_dir);
    sp = _start_server(sched_fixtures_dir, sched_test_file, port, base_url);
    try {
        run_schedule_get_by_id_test(base_url);
    } finally {
        _stop_server(sp);
        os.environ.pop("MONGODB_URI", None);
        mongo_container.stop();
        _cleanup_db_files(sched_fixtures_dir);
    }
}

test "schedule with mongo - update" {
    port = get_free_port();
    base_url = f"http://localhost:{port}";
    mongo_container = MongoDbContainer("mongo:latest");
    mongo_container.start();
    mongo_uri = mongo_container.get_connection_url();
    os.environ["MONGODB_URI"] = mongo_uri;
    _cleanup_db_files(sched_fixtures_dir);
    sp = _start_server(sched_fixtures_dir, sched_test_file, port, base_url);
    try {
        run_schedule_update_test(base_url);
    } finally {
        _stop_server(sp);
        os.environ.pop("MONGODB_URI", None);
        mongo_container.stop();
        _cleanup_db_files(sched_fixtures_dir);
    }
}

test "schedule with mongo - delete" {
    port = get_free_port();
    base_url = f"http://localhost:{port}";
    mongo_container = MongoDbContainer("mongo:latest");
    mongo_container.start();
    mongo_uri = mongo_container.get_connection_url();
    os.environ["MONGODB_URI"] = mongo_uri;
    _cleanup_db_files(sched_fixtures_dir);
    sp = _start_server(sched_fixtures_dir, sched_test_file, port, base_url);
    try {
        run_schedule_delete_test(base_url);
    } finally {
        _stop_server(sp);
        os.environ.pop("MONGODB_URI", None);
        mongo_container.stop();
        _cleanup_db_files(sched_fixtures_dir);
    }
}

test "schedule with mongo - get nonexistent" {
    port = get_free_port();
    base_url = f"http://localhost:{port}";
    mongo_container = MongoDbContainer("mongo:latest");
    mongo_container.start();
    mongo_uri = mongo_container.get_connection_url();
    os.environ["MONGODB_URI"] = mongo_uri;
    _cleanup_db_files(sched_fixtures_dir);
    sp = _start_server(sched_fixtures_dir, sched_test_file, port, base_url);
    try {
        run_schedule_get_nonexistent_test(base_url);
    } finally {
        _stop_server(sp);
        os.environ.pop("MONGODB_URI", None);
        mongo_container.stop();
        _cleanup_db_files(sched_fixtures_dir);
    }
}

test "schedule with mongo - requires auth" {
    port = get_free_port();
    base_url = f"http://localhost:{port}";
    mongo_container = MongoDbContainer("mongo:latest");
    mongo_container.start();
    mongo_uri = mongo_container.get_connection_url();
    os.environ["MONGODB_URI"] = mongo_uri;
    _cleanup_db_files(sched_fixtures_dir);
    sp = _start_server(sched_fixtures_dir, sched_test_file, port, base_url);
    try {
        run_schedule_requires_auth_test(base_url);
    } finally {
        _stop_server(sp);
        os.environ.pop("MONGODB_URI", None);
        mongo_container.stop();
        _cleanup_db_files(sched_fixtures_dir);
    }
}
