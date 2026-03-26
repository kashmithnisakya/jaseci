"""PyPI version discovery for jaclang."""

import json
import urllib.error
import urllib.request

PYPI_URL = "https://pypi.org/pypi/jaclang/json"


def fetch_versions() -> list[str]:
    """Fetch all available jaclang versions from PyPI.

    Returns versions sorted newest first.
    """
    try:
        req = urllib.request.Request(PYPI_URL, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.URLError as e:
        raise RuntimeError(
            f"Could not connect to PyPI. Check your internet connection.\n  Details: {e}"
        ) from e
    except TimeoutError as e:
        raise RuntimeError("Connection to PyPI timed out. Try again later.") from e
    except Exception as e:
        raise RuntimeError(f"Failed to fetch versions from PyPI: {e}") from e

    versions = list(data.get("releases", {}).keys())
    # Filter out versions with no files (yanked/empty)
    versions = [
        v
        for v in versions
        if data["releases"][v]  # has at least one file
    ]
    versions.sort(key=_version_key, reverse=True)
    return versions


def get_latest_version() -> str:
    """Get the latest stable jaclang version."""
    versions = fetch_versions()
    # Filter pre-releases
    stable = [v for v in versions if _is_stable(v)]
    if stable:
        return stable[0]
    if versions:
        return versions[0]
    raise RuntimeError("No jaclang versions found on PyPI")


def _is_stable(version: str) -> bool:
    """Check if a version string is a stable release."""
    return all(tag not in version for tag in ("a", "b", "rc", "dev", "alpha", "beta"))


def _version_key(version: str) -> tuple[tuple[int, int | str], ...]:
    """Create a sortable key from a version string."""
    parts: list[tuple[int, int | str]] = []
    for part in version.split("."):
        try:
            parts.append((0, int(part)))
        except ValueError:
            parts.append((1, part))
    return tuple(parts)
