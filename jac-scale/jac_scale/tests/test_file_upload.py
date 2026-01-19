"""Tests for file upload functionality in jac-scale serve."""

import contextlib
import gc
import glob
import io
import socket
import subprocess
import time
from pathlib import Path
from typing import Any

import requests


def get_free_port() -> int:
    """Get a free port by binding to port 0 and releasing it."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("", 0))
        s.listen(1)
        port = s.getsockname()[1]
    return port


class TestJacScaleFileUpload:
    """Test jac-scale file upload functionality."""

    fixtures_dir: Path
    test_file: Path
    port: int
    base_url: str
    server_process: subprocess.Popen[str] | None = None

    @classmethod
    def setup_class(cls) -> None:
        """Set up test class - runs once for all tests."""
        cls.fixtures_dir = Path(__file__).parent / "fixtures"
        cls.test_file = cls.fixtures_dir / "file_upload_api.jac"

        if not cls.test_file.exists():
            raise FileNotFoundError(f"Test fixture not found: {cls.test_file}")

        cls.port = get_free_port()
        cls.base_url = f"http://localhost:{cls.port}"

        cls._cleanup_db_files()
        cls.server_process = None
        cls._start_server()

    @classmethod
    def teardown_class(cls) -> None:
        """Tear down test class - runs once after all tests."""
        if cls.server_process:
            cls.server_process.terminate()
            try:
                cls.server_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cls.server_process.kill()
                cls.server_process.wait()

        time.sleep(0.5)
        gc.collect()
        cls._cleanup_db_files()

    @classmethod
    def _start_server(cls) -> None:
        """Start the jac-scale server in a subprocess."""
        import sys

        jac_executable = Path(sys.executable).parent / "jac"

        cmd = [
            str(jac_executable),
            "start",
            str(cls.test_file),
            "--port",
            str(cls.port),
        ]

        cls.server_process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        max_attempts = 50
        server_ready = False

        for _ in range(max_attempts):
            if cls.server_process.poll() is not None:
                stdout, stderr = cls.server_process.communicate()
                raise RuntimeError(
                    f"Server process terminated unexpectedly.\n"
                    f"STDOUT: {stdout}\nSTDERR: {stderr}"
                )

            try:
                response = requests.get(f"{cls.base_url}/docs", timeout=2)
                if response.status_code in (200, 404):
                    print(f"Server started successfully on port {cls.port}")
                    server_ready = True
                    break
            except (requests.ConnectionError, requests.Timeout):
                time.sleep(2)

        if not server_ready:
            cls.server_process.terminate()
            try:
                stdout, stderr = cls.server_process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                cls.server_process.kill()
                stdout, stderr = cls.server_process.communicate()

            raise RuntimeError(
                f"Server failed to start after {max_attempts} attempts.\n"
                f"STDOUT: {stdout}\nSTDERR: {stderr}"
            )

    @classmethod
    def _cleanup_db_files(cls) -> None:
        """Delete SQLite database files and legacy shelf files."""
        import shutil

        for pattern in [
            "*.db",
            "*.db-wal",
            "*.db-shm",
            "anchor_store.db.dat",
            "anchor_store.db.bak",
            "anchor_store.db.dir",
        ]:
            for db_file in glob.glob(pattern):
                with contextlib.suppress(Exception):
                    Path(db_file).unlink()

        for pattern in ["*.db", "*.db-wal", "*.db-shm"]:
            for db_file in glob.glob(str(cls.fixtures_dir / pattern)):
                with contextlib.suppress(Exception):
                    Path(db_file).unlink()

        client_build_dir = cls.fixtures_dir / ".jac"
        if client_build_dir.exists():
            with contextlib.suppress(Exception):
                shutil.rmtree(client_build_dir)

    @staticmethod
    def _extract_transport_response_data(
        json_response: dict[str, Any] | list[Any],
    ) -> dict[str, Any] | list[Any]:
        """Extract data from TransportResponse envelope format."""
        if isinstance(json_response, list) and len(json_response) == 2:
            body: dict[str, Any] = json_response[1]
            json_response = body

        if (
            isinstance(json_response, dict)
            and "ok" in json_response
            and "data" in json_response
        ):
            if json_response.get("ok") and json_response.get("data") is not None:
                return json_response["data"]
            elif not json_response.get("ok") and json_response.get("error"):
                error_info = json_response["error"]
                result: dict[str, Any] = {
                    "error": error_info.get("message", "Unknown error")
                }
                if "code" in error_info:
                    result["error_code"] = error_info["code"]
                if "details" in error_info:
                    result["error_details"] = error_info["details"]
                return result

        return json_response

    def _request_json(
        self,
        method: str,
        path: str,
        data: dict[str, Any] | None = None,
        token: str | None = None,
        timeout: int = 5,
    ) -> dict[str, Any]:
        """Make JSON HTTP request to server."""
        url = f"{self.base_url}{path}"
        headers = {"Content-Type": "application/json"}

        if token:
            headers["Authorization"] = f"Bearer {token}"

        response = requests.request(
            method=method,
            url=url,
            json=data,
            headers=headers,
            timeout=timeout,
        )

        json_response: Any = response.json()
        return self._extract_transport_response_data(json_response)  # type: ignore[return-value]

    def _request_multipart(
        self,
        path: str,
        files: dict[str, tuple[str, bytes, str]],
        fields: dict[str, str] | None = None,
        token: str | None = None,
        timeout: int = 10,
    ) -> dict[str, Any]:
        """Make multipart/form-data HTTP request for file uploads.

        Args:
            path: The URL path
            files: Dict of field_name -> (filename, content, content_type)
            fields: Dict of regular form fields
            token: Optional auth token
            timeout: Request timeout
        """
        url = f"{self.base_url}{path}"
        headers = {}

        if token:
            headers["Authorization"] = f"Bearer {token}"

        # Prepare files for requests library
        files_param = {
            name: (filename, io.BytesIO(content), content_type)
            for name, (filename, content, content_type) in files.items()
        }

        # Prepare form data
        data_param = fields or {}

        response = requests.post(
            url,
            files=files_param,
            data=data_param,
            headers=headers,
            timeout=timeout,
        )

        json_response: Any = response.json()
        return self._extract_transport_response_data(json_response)  # type: ignore[return-value]

    # ========================================================================
    # File Upload Tests
    # ========================================================================

    def test_single_file_upload(self) -> None:
        """Test uploading a single file."""
        content = b"This is a test file content for jac-scale"

        result = self._request_multipart(
            "/walker/UploadDocument",
            files={"file": ("test.txt", content, "text/plain")},
            fields={"description": "Test upload"},
        )

        assert "reports" in result
        reports = result["reports"]
        assert len(reports) > 0

        report = reports[0]
        assert report["filename"] == "test.txt"
        assert report["content_type"] == "text/plain"
        assert report["size"] == len(content)
        assert report["description"] == "Test upload"

    def test_file_upload_with_default_description(self) -> None:
        """Test file upload with default description field."""
        content = b"File with default description"

        result = self._request_multipart(
            "/walker/UploadDocument",
            files={"file": ("doc.txt", content, "text/plain")},
        )

        assert "reports" in result
        reports = result["reports"]
        assert len(reports) > 0

        report = reports[0]
        assert report["filename"] == "doc.txt"
        assert report["description"] == ""  # Default value

    def test_multiple_file_upload(self) -> None:
        """Test uploading multiple files in one request."""
        content1 = b"Content of file 1"
        content2 = b"Content of file 2, slightly longer"

        result = self._request_multipart(
            "/walker/UploadMultipleFiles",
            files={
                "file1": ("first.txt", content1, "text/plain"),
                "file2": ("second.txt", content2, "text/plain"),
            },
            fields={"label": "batch_upload"},
        )

        assert "reports" in result
        reports = result["reports"]
        assert len(reports) > 0

        report = reports[0]
        assert report["file1"]["filename"] == "first.txt"
        assert report["file1"]["size"] == len(content1)
        assert report["file2"]["filename"] == "second.txt"
        assert report["file2"]["size"] == len(content2)
        assert report["label"] == "batch_upload"

    def test_binary_file_upload(self) -> None:
        """Test uploading a binary file."""
        binary_content = bytes(range(256))

        result = self._request_multipart(
            "/walker/UploadDocument",
            files={"file": ("binary.bin", binary_content, "application/octet-stream")},
            fields={"description": "Binary file test"},
        )

        assert "reports" in result
        reports = result["reports"]
        assert len(reports) > 0

        report = reports[0]
        assert report["filename"] == "binary.bin"
        assert report["content_type"] == "application/octet-stream"
        assert report["size"] == 256

    def test_walker_without_file_still_works(self) -> None:
        """Test that walkers without file parameters still work normally."""
        result = self._request_json(
            "POST",
            "/walker/SimpleGreet",
            data={"name": "FileTest"},
        )

        assert "reports" in result
        reports = result["reports"]
        assert len(reports) > 0
        assert reports[0]["message"] == "Hello, FileTest!"

    def test_large_file_upload(self) -> None:
        """Test uploading a larger file."""
        large_content = b"X" * (100 * 1024)  # 100KB

        result = self._request_multipart(
            "/walker/UploadDocument",
            files={"file": ("large.dat", large_content, "application/octet-stream")},
            fields={"description": "Large file test"},
        )

        assert "reports" in result
        reports = result["reports"]
        assert len(reports) > 0

        report = reports[0]
        assert report["filename"] == "large.dat"
        assert report["size"] == 100 * 1024

    def test_file_upload_content_types(self) -> None:
        """Test various content types are preserved."""
        test_cases = [
            ("document.pdf", b"%PDF-1.4", "application/pdf"),
            ("image.jpg", b"\xff\xd8\xff\xe0", "image/jpeg"),
            ("data.json", b'{"key": "value"}', "application/json"),
        ]

        for filename, content, content_type in test_cases:
            result = self._request_multipart(
                "/walker/UploadDocument",
                files={"file": (filename, content, content_type)},
            )

            assert "reports" in result, f"Failed for {filename}"
            reports = result["reports"]
            assert len(reports) > 0

            report = reports[0]
            assert report["filename"] == filename
            assert report["content_type"] == content_type

    def test_file_upload_unicode_content(self) -> None:
        """Test file upload with unicode content."""
        unicode_content = "Hello, World! 你好世界 🌍".encode()

        result = self._request_multipart(
            "/walker/UploadDocument",
            files={
                "file": ("unicode.txt", unicode_content, "text/plain; charset=utf-8")
            },
            fields={"description": "Unicode test"},
        )

        assert "reports" in result
        reports = result["reports"]
        assert len(reports) > 0

        report = reports[0]
        assert report["filename"] == "unicode.txt"
        assert report["size"] == len(unicode_content)

    def test_openapi_schema_has_file_upload(self) -> None:
        """Test that the OpenAPI schema correctly shows file upload support."""
        response = requests.get(f"{self.base_url}/openapi.json", timeout=5)
        assert response.status_code == 200

        schema = response.json()
        paths = schema.get("paths", {})

        # Check that UploadDocument endpoint exists
        assert "/walker/UploadDocument" in paths

        # Check that it accepts multipart/form-data
        post_spec = paths["/walker/UploadDocument"]["post"]
        request_body = post_spec.get("requestBody", {})
        content = request_body.get("content", {})
        assert "multipart/form-data" in content

    def test_empty_file_upload(self) -> None:
        """Test uploading an empty file."""
        empty_content = b""

        result = self._request_multipart(
            "/walker/UploadDocument",
            files={"file": ("empty.txt", empty_content, "text/plain")},
            fields={"description": "Empty file"},
        )

        assert "reports" in result
        reports = result["reports"]
        assert len(reports) > 0

        report = reports[0]
        assert report["filename"] == "empty.txt"
        assert report["size"] == 0
