"""Configuration and path management for jvm."""

import os
import platform
from pathlib import Path


def get_jvm_home() -> Path:
    """Get the jvm home directory (~/.jvm)."""
    return Path(os.environ.get("JVM_HOME", Path.home() / ".jvm"))


def get_versions_dir() -> Path:
    """Get the directory where jac versions are installed."""
    return get_jvm_home() / "versions"


def get_current_link() -> Path:
    """Get the path to the 'current' symlink."""
    return get_jvm_home() / "current"


def get_python_executable() -> str:
    """Get the Python executable to use for creating venvs."""
    custom = os.environ.get("JVM_PYTHON")
    if custom:
        return custom
    # Prefer python3.12+ since jaclang requires it
    import shutil

    for name in ("python3.12", "python3.13", "python3.14", "python3"):
        path = shutil.which(name)
        if path:
            return path
    return "python3"


def get_venv_python(version: str) -> Path:
    """Get the python executable inside a version's venv."""
    venv = get_versions_dir() / version
    if platform.system() == "Windows":
        return venv / "Scripts" / "python.exe"
    return venv / "bin" / "python"


def get_venv_bin(version: str) -> Path:
    """Get the bin directory inside a version's venv."""
    venv = get_versions_dir() / version
    if platform.system() == "Windows":
        return venv / "Scripts"
    return venv / "bin"


def ensure_dirs() -> None:
    """Create jvm directories if they don't exist."""
    get_versions_dir().mkdir(parents=True, exist_ok=True)
