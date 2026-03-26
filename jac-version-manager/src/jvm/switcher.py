"""Version switching via symlinks and shell hooks."""

from .config import get_current_link, get_venv_bin, get_versions_dir


def get_active_version() -> str | None:
    """Get the currently active jac version."""
    link = get_current_link()
    if not link.exists():
        return None
    if link.is_symlink():
        target = link.resolve()
        return target.name
    return None


def use_version(version: str) -> None:
    """Set the active jac version by updating the 'current' symlink."""
    venv_path = get_versions_dir() / version
    if not venv_path.exists():
        raise RuntimeError(
            f"Version {version} is not installed. Run 'jvm install {version}' first."
        )

    link = get_current_link()

    # Remove existing symlink
    if link.exists() or link.is_symlink():
        link.unlink()

    # Create new symlink
    link.symlink_to(venv_path)
    print(f"Now using jac {version}")


def get_shell_hook_use(version: str) -> str:
    """Generate shell commands to activate a jac version in the current shell."""
    venv_path = get_versions_dir() / version
    bin_dir = get_venv_bin(version)

    lines = []

    # Remove any existing jvm paths from PATH
    lines.append(
        'export PATH=$(echo "$PATH" | tr ":" "\\n" | grep -v "\\.jvm/versions/" | tr "\\n" ":")'
    )

    # Prepend new version's bin to PATH
    lines.append(f'export PATH="{bin_dir}:$PATH"')

    # Set version env var
    lines.append(f'export JVM_ACTIVE_VERSION="{version}"')

    return "\n".join(lines)


def get_shell_hook_deactivate() -> str:
    """Generate shell commands to deactivate jvm from the current shell."""
    lines = [
        'export PATH=$(echo "$PATH" | tr ":" "\\n" | grep -v "\\.jvm/versions/" | tr "\\n" ":")',
        "unset JVM_ACTIVE_VERSION",
    ]
    return "\n".join(lines)
