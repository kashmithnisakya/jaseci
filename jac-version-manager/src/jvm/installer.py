"""Install and uninstall jac versions."""

import shutil
import subprocess
import sys
import venv

from .config import ensure_dirs, get_python_executable, get_venv_bin, get_venv_python, get_versions_dir


def list_installed() -> list[str]:
    """List all installed jac versions."""
    versions_dir = get_versions_dir()
    if not versions_dir.exists():
        return []
    versions = []
    for p in sorted(versions_dir.iterdir()):
        if p.is_dir() and not p.name.startswith("."):
            versions.append(p.name)
    return versions


def is_installed(version: str) -> bool:
    """Check if a version is installed."""
    return (get_versions_dir() / version).exists()


def install_version(version: str, force: bool = False) -> None:
    """Install a specific jaclang version.

    Creates a Python venv and installs jaclang==version into it.
    """
    ensure_dirs()
    venv_path = get_versions_dir() / version

    if venv_path.exists():
        if force:
            shutil.rmtree(venv_path)
        else:
            raise RuntimeError(
                f"Version {version} is already installed. Use --force to reinstall."
            )

    python = get_python_executable()

    # Verify Python version >= 3.12
    try:
        result = subprocess.run(
            [python, "-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"],
            capture_output=True,
            text=True,
        )
        py_version = result.stdout.strip()
        major, minor = map(int, py_version.split("."))
        if major < 3 or (major == 3 and minor < 12):
            raise RuntimeError(
                f"jaclang requires Python >= 3.12, but found {py_version}. "
                f"Set JVM_PYTHON env var to point to Python 3.12+."
            )
    except (ValueError, FileNotFoundError) as e:
        raise RuntimeError(f"Could not detect Python version: {e}") from e

    print(f"Creating environment for jac {version}...")
    # Create venv
    venv.create(str(venv_path), with_pip=True, clear=True)

    # Upgrade pip and setuptools first to avoid build issues
    venv_python = get_venv_python(version)
    print("Upgrading pip and setuptools...")
    subprocess.run(
        [str(venv_python), "-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"],
        capture_output=True,
        text=True,
    )

    # Install jaclang (prefer binary wheels to avoid build failures)
    pip = get_venv_bin(version) / "pip"
    print(f"Installing jaclang=={version}...")
    result = subprocess.run(
        [str(pip), "install", "--prefer-binary", f"jaclang=={version}"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        # Cleanup on failure
        shutil.rmtree(venv_path, ignore_errors=True)
        raise RuntimeError(
            f"Failed to install jaclang=={version}:\n{result.stderr}"
        )

    print(f"Successfully installed jac {version}")


def uninstall_version(version: str) -> None:
    """Remove an installed jac version."""
    from .switcher import get_active_version

    venv_path = get_versions_dir() / version
    if not venv_path.exists():
        raise RuntimeError(f"Version {version} is not installed.")

    active = get_active_version()
    if active == version:
        raise RuntimeError(
            f"Version {version} is currently active. Switch to another version first."
        )

    shutil.rmtree(venv_path)
    print(f"Uninstalled jac {version}")


def install_plugin(plugin: str, version: str | None = None) -> None:
    """Install a plugin into the active jac environment."""
    from .switcher import get_active_version

    active = get_active_version()
    if not active:
        raise RuntimeError("No active jac version. Run 'jvm use <version>' first.")

    pip = get_venv_bin(active) / "pip"
    pkg = f"{plugin}=={version}" if version else plugin
    print(f"Installing {pkg} into jac {active} environment...")

    result = subprocess.run(
        [str(pip), "install", pkg],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Failed to install {pkg}:\n{result.stderr}")

    print(f"Successfully installed {pkg}")


def uninstall_plugin(plugin: str) -> None:
    """Uninstall a plugin from the active jac environment."""
    from .switcher import get_active_version

    active = get_active_version()
    if not active:
        raise RuntimeError("No active jac version. Run 'jvm use <version>' first.")

    pip = get_venv_bin(active) / "pip"
    print(f"Uninstalling {plugin} from jac {active} environment...")

    result = subprocess.run(
        [str(pip), "uninstall", "-y", plugin],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Failed to uninstall {plugin}:\n{result.stderr}")

    print(f"Successfully uninstalled {plugin}")


def list_plugins() -> list[dict]:
    """List installed packages in the active jac environment."""
    from .switcher import get_active_version

    active = get_active_version()
    if not active:
        raise RuntimeError("No active jac version. Run 'jvm use <version>' first.")

    pip = get_venv_bin(active) / "pip"
    result = subprocess.run(
        [str(pip), "list", "--format=json"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return []

    import json

    try:
        packages = json.loads(result.stdout)
    except json.JSONDecodeError:
        return []

    # Filter to jac-related packages
    jac_packages = [
        p
        for p in packages
        if p["name"].startswith("jac") or p["name"] in ("jaclang", "byllm", "jaseci")
    ]
    return jac_packages
