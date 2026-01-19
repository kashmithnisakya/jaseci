"""Tests for file upload functionality in jac serve."""

import contextlib
import json
import socket
import threading
import time
from collections.abc import Generator
from http.client import HTTPConnection
from http.server import HTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest

from jaclang import JacRuntime as Jac
from jaclang.runtimelib.server import JacAPIServer, UploadFile
from tests.conftest import proc_file_sess
from tests.runtimelib.conftest import fixture_abs_path


@pytest.fixture
def reset_machine(tmp_path: Path) -> Generator[None, None, None]:
    """Reset Jac machine before and after each test for session isolation.

    Note: This fixture is not auto-used. Only tests that need Jac machine
    should request it explicitly via the file_upload_fixture.
    """
    # Use tmp_path for session isolation in parallel tests
    if hasattr(Jac, "reset_machine"):
        Jac.reset_machine(base_path=str(tmp_path))  # type: ignore[attr-defined]
    yield
    if hasattr(Jac, "reset_machine"):
        Jac.reset_machine(base_path=str(tmp_path))  # type: ignore[attr-defined]


def get_free_port() -> int:
    """Get a free port by binding to port 0 and releasing it."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("", 0))
        s.listen(1)
        port = s.getsockname()[1]
    return port


class FileUploadServerFixture:
    """Server fixture helper class for file upload tests."""

    def __init__(
        self, request: pytest.FixtureRequest, tmp_path: Path | None = None
    ) -> None:
        """Initialize server fixture."""
        self.server: JacAPIServer | None = None
        self.server_thread: threading.Thread | None = None
        self.httpd: HTTPServer | None = None
        try:
            self.port = get_free_port()
        except PermissionError:
            pytest.skip("Socket operations are not permitted in this environment")
        self.base_url = f"http://localhost:{self.port}"
        test_name = request.node.name
        if tmp_path:
            self.session_dir = tmp_path
            self.session_file = str(tmp_path / f"test_file_upload_{test_name}.session")
        else:
            self.session_dir = Path(fixture_abs_path(""))
            self.session_file = fixture_abs_path(
                f"test_file_upload_{test_name}.session"
            )

    def start_server(self, api_file: str = "file_upload_api.jac") -> None:
        """Start the API server in a background thread."""
        base, mod, mach = proc_file_sess(
            fixture_abs_path(api_file), str(self.session_dir)
        )
        Jac.jac_import(
            target=mod,
            base_path=base,
            override_name="__main__",
            lng="jac",
        )

        self.server = JacAPIServer(
            module_name="__main__",
            port=self.port,
            base_path=str(self.session_dir),
        )

        # Use the HTTPServer created by JacAPIServer
        self.httpd = self.server.server

        # Start server in thread
        def run_server() -> None:
            try:
                if self.server:
                    self.server.load_module()
                if self.httpd:
                    self.httpd.serve_forever()
            except Exception:
                pass

        self.server_thread = threading.Thread(target=run_server, daemon=True)
        self.server_thread.start()

        # Wait for server to be ready
        max_attempts = 50
        for _ in range(max_attempts):
            try:
                self.request_json("GET", "/", timeout=10)
                break
            except Exception:
                time.sleep(0.1)

    def request_json(
        self,
        method: str,
        path: str,
        data: dict | None = None,
        token: str | None = None,
        timeout: int = 5,
    ) -> dict:
        """Make JSON HTTP request to server."""
        url = f"{self.base_url}{path}"
        headers = {"Content-Type": "application/json"}

        if token:
            headers["Authorization"] = f"Bearer {token}"

        body = json.dumps(data).encode() if data else None
        request = Request(url, data=body, headers=headers, method=method)

        try:
            with urlopen(request, timeout=timeout) as response:
                return json.loads(response.read().decode())
        except HTTPError as e:
            return json.loads(e.read().decode())

    def request_multipart(
        self,
        path: str,
        files: dict[str, tuple[str, bytes, str]],
        fields: dict[str, str] | None = None,
        token: str | None = None,
        timeout: int = 10,
    ) -> dict:
        """Make multipart/form-data HTTP request for file uploads.

        Args:
            path: The URL path
            files: Dict of field_name -> (filename, content, content_type)
            fields: Dict of regular form fields
            token: Optional auth token
            timeout: Request timeout
        """
        boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
        body_parts = []

        # Add regular form fields
        if fields:
            for name, value in fields.items():
                body_parts.append(f"--{boundary}\r\n".encode())
                body_parts.append(
                    f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode()
                )
                body_parts.append(f"{value}\r\n".encode())

        # Add file fields
        for field_name, (filename, content, content_type) in files.items():
            body_parts.append(f"--{boundary}\r\n".encode())
            body_parts.append(
                f'Content-Disposition: form-data; name="{field_name}"; filename="{filename}"\r\n'.encode()
            )
            body_parts.append(f"Content-Type: {content_type}\r\n\r\n".encode())
            body_parts.append(content)
            body_parts.append(b"\r\n")

        body_parts.append(f"--{boundary}--\r\n".encode())
        body = b"".join(body_parts)

        headers = {
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Content-Length": str(len(body)),
        }
        if token:
            headers["Authorization"] = f"Bearer {token}"

        # Use http.client for more control over multipart requests
        conn = HTTPConnection("localhost", self.port, timeout=timeout)
        try:
            conn.request("POST", path, body=body, headers=headers)
            response = conn.getresponse()
            response_body = response.read().decode()
            return json.loads(response_body)
        finally:
            conn.close()

    def register_user(
        self, username: str = "testuser", password: str = "testpass"
    ) -> str:
        """Register a user and return the auth token."""
        result = self.request_json(
            "POST",
            "/user/register",
            {"username": username, "password": password},
        )
        data = result.get("data", result)
        return data.get("token", "")

    def cleanup(self) -> None:
        """Clean up server resources."""
        # Close user manager if it exists
        if self.server and hasattr(self.server, "user_manager"):
            with contextlib.suppress(Exception):
                self.server.user_manager.close()

        # Stop server if running
        if self.httpd:
            with contextlib.suppress(Exception):
                self.httpd.shutdown()
                self.httpd.server_close()

        if self.server_thread and self.server_thread.is_alive():
            self.server_thread.join(timeout=2)


@pytest.fixture
def file_upload_fixture(
    request: pytest.FixtureRequest,
    tmp_path: Path,
    reset_machine: None,  # Ensure Jac machine is reset for API tests
) -> Generator[FileUploadServerFixture, None, None]:
    """Pytest fixture for file upload server setup and teardown."""
    fixture = FileUploadServerFixture(request, tmp_path)
    yield fixture
    fixture.cleanup()


# ============================================================================
# UploadFile Object Tests
# ============================================================================


class TestUploadFileObject:
    """Tests for the UploadFile object."""

    def test_upload_file_creation(self) -> None:
        """Test creating an UploadFile from bytes."""
        content = b"Hello, World!"
        upload = UploadFile.from_bytes(
            filename="test.txt",
            data=content,
            content_type="text/plain",
        )

        assert upload.filename == "test.txt"
        assert upload.content == content
        assert upload.content_type == "text/plain"
        assert upload.size == len(content)

    def test_upload_file_read_text(self) -> None:
        """Test reading UploadFile content as text."""
        content = "Hello, World! こんにちは"
        upload = UploadFile.from_bytes(
            filename="test.txt",
            data=content.encode("utf-8"),
            content_type="text/plain",
        )

        assert upload.read_text() == content

    def test_upload_file_save(self, tmp_path: Path) -> None:
        """Test saving UploadFile to disk."""
        content = b"File content to save"
        upload = UploadFile.from_bytes(
            filename="saved.txt",
            data=content,
            content_type="text/plain",
        )

        save_path = tmp_path / "uploads" / "saved.txt"
        upload.save(str(save_path))

        assert save_path.exists()
        assert save_path.read_bytes() == content

    def test_upload_file_binary_content(self) -> None:
        """Test UploadFile with binary content."""
        # Create some binary data (like a small image header)
        content = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        upload = UploadFile.from_bytes(
            filename="image.png",
            data=content,
            content_type="image/png",
        )

        assert upload.filename == "image.png"
        assert upload.content == content
        assert upload.content_type == "image/png"
        assert upload.size == 8


# ============================================================================
# File Upload API Tests
# ============================================================================


class TestFileUploadAPI:
    """Tests for file upload via REST API."""

    def test_single_file_upload(
        self, file_upload_fixture: FileUploadServerFixture
    ) -> None:
        """Test uploading a single file."""
        file_upload_fixture.start_server()
        token = file_upload_fixture.register_user()

        content = b"This is a test file content"
        result = file_upload_fixture.request_multipart(
            "/walker/UploadDocument",
            files={"file": ("test.txt", content, "text/plain")},
            fields={"description": "Test upload"},
            token=token,
        )

        # Check response structure
        assert result.get("ok") is True
        data = result.get("data", {})
        reports = data.get("reports", [])
        assert len(reports) > 0

        report = reports[0]
        assert report["filename"] == "test.txt"
        assert report["size"] == len(content)
        assert report["description"] == "Test upload"

    def test_file_upload_with_default_description(
        self, file_upload_fixture: FileUploadServerFixture
    ) -> None:
        """Test file upload with default description field."""
        file_upload_fixture.start_server()
        token = file_upload_fixture.register_user()

        content = b"File with default description"
        result = file_upload_fixture.request_multipart(
            "/walker/UploadDocument",
            files={"file": ("doc.txt", content, "text/plain")},
            token=token,
        )

        assert result.get("ok") is True
        data = result.get("data", {})
        reports = data.get("reports", [])
        assert len(reports) > 0

        report = reports[0]
        assert report["filename"] == "doc.txt"
        assert report["description"] == ""  # Default value

    def test_multiple_file_upload(
        self, file_upload_fixture: FileUploadServerFixture
    ) -> None:
        """Test uploading multiple files in one request."""
        file_upload_fixture.start_server()
        token = file_upload_fixture.register_user()

        content1 = b"Content of file 1"
        content2 = b"Content of file 2, slightly longer"

        result = file_upload_fixture.request_multipart(
            "/walker/UploadMultipleFiles",
            files={
                "file1": ("first.txt", content1, "text/plain"),
                "file2": ("second.txt", content2, "text/plain"),
            },
            fields={"label": "batch_upload"},
            token=token,
        )

        assert result.get("ok") is True
        data = result.get("data", {})
        reports = data.get("reports", [])
        assert len(reports) > 0

        report = reports[0]
        assert report["file1"]["filename"] == "first.txt"
        assert report["file1"]["size"] == len(content1)
        assert report["file2"]["filename"] == "second.txt"
        assert report["file2"]["size"] == len(content2)
        assert report["label"] == "batch_upload"

    def test_binary_file_upload(
        self, file_upload_fixture: FileUploadServerFixture
    ) -> None:
        """Test uploading a binary file."""
        file_upload_fixture.start_server()
        token = file_upload_fixture.register_user()

        # Create binary content (simulating a small image)
        binary_content = bytes(range(256))

        result = file_upload_fixture.request_multipart(
            "/walker/UploadDocument",
            files={"file": ("binary.bin", binary_content, "application/octet-stream")},
            fields={"description": "Binary file test"},
            token=token,
        )

        assert result.get("ok") is True
        data = result.get("data", {})
        reports = data.get("reports", [])
        assert len(reports) > 0

        report = reports[0]
        assert report["filename"] == "binary.bin"
        assert report["size"] == 256

    def test_walker_without_file_still_works(
        self, file_upload_fixture: FileUploadServerFixture
    ) -> None:
        """Test that walkers without file parameters still work normally."""
        file_upload_fixture.start_server()
        token = file_upload_fixture.register_user()

        result = file_upload_fixture.request_json(
            "POST",
            "/walker/SimpleGreet",
            data={"name": "FileTest"},
            token=token,
        )

        assert result.get("ok") is True
        data = result.get("data", {})
        reports = data.get("reports", [])
        assert len(reports) > 0
        assert reports[0]["message"] == "Hello, FileTest!"

    def test_large_file_upload(
        self, file_upload_fixture: FileUploadServerFixture
    ) -> None:
        """Test uploading a larger file."""
        file_upload_fixture.start_server()
        token = file_upload_fixture.register_user()

        # Create a 100KB file
        large_content = b"X" * (100 * 1024)

        result = file_upload_fixture.request_multipart(
            "/walker/UploadDocument",
            files={"file": ("large.dat", large_content, "application/octet-stream")},
            fields={"description": "Large file test"},
            token=token,
        )

        assert result.get("ok") is True
        data = result.get("data", {})
        reports = data.get("reports", [])
        assert len(reports) > 0

        report = reports[0]
        assert report["filename"] == "large.dat"
        assert report["size"] == 100 * 1024

    def test_file_upload_content_types(
        self, file_upload_fixture: FileUploadServerFixture
    ) -> None:
        """Test various file types can be uploaded."""
        file_upload_fixture.start_server()
        token = file_upload_fixture.register_user()

        test_cases = [
            ("document.pdf", b"%PDF-1.4"),
            ("image.jpg", b"\xff\xd8\xff\xe0"),
            ("data.json", b'{"key": "value"}'),
        ]

        for filename, content in test_cases:
            result = file_upload_fixture.request_multipart(
                "/walker/UploadDocument",
                files={"file": (filename, content, "application/octet-stream")},
                token=token,
            )

            assert result.get("ok") is True, f"Failed for {filename}"
            data = result.get("data", {})
            reports = data.get("reports", [])
            assert len(reports) > 0

            report = reports[0]
            assert report["filename"] == filename
            assert report["size"] == len(content)
