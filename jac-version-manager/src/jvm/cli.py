"""CLI entry point for jvm (Jac Version Manager)."""

import argparse
import subprocess
import sys
from difflib import get_close_matches

from . import __version__

VALID_COMMANDS = [
    "install",
    "uninstall",
    "use",
    "deactivate",
    "current",
    "list",
    "ls",
    "list-remote",
    "ls-remote",
    "install-plugin",
    "uninstall-plugin",
    "plugins",
    "run",
    "init",
    "setup",
]


class _JvmArgumentParser(argparse.ArgumentParser):
    """Custom argument parser with friendly error messages."""

    def error(self, message: str) -> None:  # noqa: ANN101
        """Override to suggest similar commands on typos."""
        if "invalid choice" in message:
            # Extract the bad command from argparse's error
            import re

            match = re.search(r"invalid choice: '(\w+)'", message)
            if match:
                bad_cmd = match.group(1)
                suggestions = get_close_matches(
                    bad_cmd, VALID_COMMANDS, n=2, cutoff=0.4
                )
                msg = f"Unknown command: '{bad_cmd}'"
                if suggestions:
                    msg += "\n\nDid you mean?\n" + "\n".join(
                        f"  jvm {s}" for s in suggestions
                    )
                msg += "\n\nRun 'jvm --help' for a list of available commands."
                print(msg, file=sys.stderr)
                sys.exit(1)
        super().error(message)


def main(argv: list[str] | None = None) -> None:
    """Main CLI entry point."""
    parser = _JvmArgumentParser(
        prog="jvm",
        description="Jac Version Manager - Install and switch between multiple jaclang versions",
    )
    parser.add_argument("--version", action="version", version=f"jvm {__version__}")

    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # jvm install <version>
    p_install = subparsers.add_parser("install", help="Install a jac version")
    p_install.add_argument(
        "version",
        nargs="?",
        help="Version to install (e.g. 0.13.1). Defaults to latest.",
    )
    p_install.add_argument("--force", "-f", action="store_true", help="Force reinstall")

    # jvm uninstall <version>
    p_uninstall = subparsers.add_parser("uninstall", help="Uninstall a jac version")
    p_uninstall.add_argument("version", help="Version to uninstall")

    # jvm use <version>
    p_use = subparsers.add_parser("use", help="Switch to a jac version")
    p_use.add_argument("version", help="Version to activate")

    # jvm deactivate
    subparsers.add_parser("deactivate", help="Deactivate jvm (remove from PATH)")

    # jvm current
    subparsers.add_parser("current", help="Show the active jac version")

    # jvm list
    subparsers.add_parser("list", aliases=["ls"], help="List installed jac versions")

    # jvm list-remote
    subparsers.add_parser(
        "list-remote", aliases=["ls-remote"], help="List available jac versions on PyPI"
    )

    # jvm install-plugin <name>
    p_plugin = subparsers.add_parser(
        "install-plugin", help="Install a plugin into the active jac environment"
    )
    p_plugin.add_argument("plugin", help="Plugin package name (e.g. byllm, jac-scale)")
    p_plugin.add_argument("--plugin-version", help="Specific plugin version")

    # jvm uninstall-plugin <name>
    p_uninstall_plugin = subparsers.add_parser(
        "uninstall-plugin", help="Uninstall a plugin from the active jac environment"
    )
    p_uninstall_plugin.add_argument("plugin", help="Plugin package name")

    # jvm plugins
    subparsers.add_parser(
        "plugins", help="List installed jac plugins in the active environment"
    )

    # jvm run <args>
    p_run = subparsers.add_parser("run", help="Run jac with the active version")
    p_run.add_argument(
        "args", nargs=argparse.REMAINDER, help="Arguments to pass to jac"
    )

    # jvm init
    p_init = subparsers.add_parser("init", help="Print shell initialization script")
    p_init.add_argument(
        "--shell",
        choices=["bash", "zsh", "fish"],
        help="Shell type (auto-detected if omitted)",
    )

    # jvm setup
    subparsers.add_parser(
        "setup",
        help="Add jvm shell hook to your shell profile (~/.zshrc, ~/.bashrc, etc.)",
    )

    # jvm shell-hook (internal, used by shell function)
    p_hook = subparsers.add_parser("shell-hook", help=argparse.SUPPRESS)
    p_hook.add_argument("action", choices=["use", "deactivate"])
    p_hook.add_argument("version", nargs="?")

    args = parser.parse_args(argv)

    args = parser.parse_args(argv)

    if not args.command:
        parser.print_help()
        sys.exit(0)

    try:
        _dispatch(args)
    except RuntimeError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nAborted.")
        sys.exit(130)


def _dispatch(args: argparse.Namespace) -> None:
    """Dispatch to the appropriate command handler."""
    cmd = args.command

    if cmd == "install":
        _cmd_install(args)
    elif cmd == "uninstall":
        _cmd_uninstall(args)
    elif cmd in ("use",):
        _cmd_use(args)
    elif cmd == "deactivate":
        _cmd_deactivate(args)
    elif cmd == "current":
        _cmd_current(args)
    elif cmd in ("list", "ls"):
        _cmd_list(args)
    elif cmd in ("list-remote", "ls-remote"):
        _cmd_list_remote(args)
    elif cmd == "install-plugin":
        _cmd_install_plugin(args)
    elif cmd == "uninstall-plugin":
        _cmd_uninstall_plugin(args)
    elif cmd == "plugins":
        _cmd_plugins(args)
    elif cmd == "run":
        _cmd_run(args)
    elif cmd == "init":
        _cmd_init(args)
    elif cmd == "setup":
        _cmd_setup(args)
    elif cmd == "shell-hook":
        _cmd_shell_hook(args)


def _validate_version(version: str) -> None:
    """Validate version string format and availability on PyPI."""
    import re

    if not re.match(r"^\d+\.\d+(\.\d+)?([a-zA-Z]\w*)?$", version):
        raise RuntimeError(
            f"Invalid version format: '{version}'. Expected format like '0.13.1'."
        )

    from .pypi import fetch_versions

    available = fetch_versions()
    if version not in available:
        # Suggest close matches
        close = get_close_matches(version, available, n=3, cutoff=0.5)
        msg = f"Version '{version}' not found on PyPI."
        if close:
            msg += "\n\nAvailable versions:\n" + "\n".join(f"  {v}" for v in close)
        raise RuntimeError(msg)


def _cmd_install(args: argparse.Namespace) -> None:
    from .installer import install_version
    from .pypi import get_latest_version

    version = args.version
    if not version:
        print("Fetching latest version...")
        version = get_latest_version()
        print(f"Latest version: {version}")
    else:
        _validate_version(version)

    install_version(version, force=args.force)


def _cmd_uninstall(args: argparse.Namespace) -> None:
    from .installer import uninstall_version

    uninstall_version(args.version)


def _cmd_use(args: argparse.Namespace) -> None:
    from .installer import is_installed
    from .switcher import use_version

    if not is_installed(args.version):
        print(f"Version {args.version} is not installed.")
        answer = input("Would you like to install it? [y/N] ").strip().lower()
        if answer in ("y", "yes"):
            from .installer import install_version

            install_version(args.version)
        else:
            sys.exit(1)

    use_version(args.version)
    print(f"Now using jac {args.version}")
    if not _is_shell_hook_installed():
        print(
            "To use 'jac' directly, run 'jvm setup' to configure your shell (one-time)."
        )


def _cmd_deactivate(args: argparse.Namespace) -> None:
    from .config import get_current_link

    link = get_current_link()
    if link.exists() or link.is_symlink():
        link.unlink()
    print("Deactivated jvm. Restart your terminal to update PATH.")


def _cmd_current(args: argparse.Namespace) -> None:
    from .switcher import get_active_version

    active = get_active_version()
    if active:
        print(f"jac {active}")
    else:
        print("No active jac version. Run 'jvm use <version>' to activate one.")


def _cmd_list(args: argparse.Namespace) -> None:
    from .installer import list_installed
    from .switcher import get_active_version

    versions = list_installed()
    active = get_active_version()

    if not versions:
        print("No jac versions installed. Run 'jvm install <version>' to install one.")
        return

    for v in versions:
        marker = " *" if v == active else ""
        print(f"  {v}{marker}")

    if active:
        print("\n* = currently active")


def _cmd_list_remote(args: argparse.Namespace) -> None:
    from .installer import list_installed
    from .pypi import fetch_versions

    print("Fetching available versions from PyPI...")
    versions = fetch_versions()
    installed = set(list_installed())

    for v in versions:
        marker = " (installed)" if v in installed else ""
        print(f"  {v}{marker}")

    print(f"\n{len(versions)} versions available")


def _cmd_install_plugin(args: argparse.Namespace) -> None:
    from .installer import install_plugin

    install_plugin(args.plugin, version=args.plugin_version)


def _cmd_uninstall_plugin(args: argparse.Namespace) -> None:
    from .installer import uninstall_plugin

    uninstall_plugin(args.plugin)


def _cmd_plugins(args: argparse.Namespace) -> None:
    from .installer import list_plugins

    packages = list_plugins()
    if not packages:
        print("No jac-related packages found in the active environment.")
        return

    for pkg in packages:
        print(f"  {pkg['name']} {pkg['version']}")


def _cmd_run(args: argparse.Namespace) -> None:
    from .config import get_venv_bin
    from .switcher import get_active_version

    active = get_active_version()
    if not active:
        raise RuntimeError("No active jac version. Run 'jvm use <version>' first.")

    jac_bin = get_venv_bin(active) / "jac"
    if not jac_bin.exists():
        raise RuntimeError(f"jac executable not found in version {active}.")

    # Pass through to jac
    run_args = args.args
    # Remove leading '--' if present (argparse REMAINDER artifact)
    if run_args and run_args[0] == "--":
        run_args = run_args[1:]

    result = subprocess.run([str(jac_bin)] + run_args)
    sys.exit(result.returncode)


def _is_shell_hook_installed() -> bool:
    """Check if the jvm shell hook is already in the user's shell profile."""
    import os
    from pathlib import Path

    shell = os.environ.get("SHELL", "")
    profiles = []
    if "zsh" in shell:
        profiles.append(Path.home() / ".zshrc")
    elif "bash" in shell:
        profiles.extend([Path.home() / ".bashrc", Path.home() / ".bash_profile"])
    elif "fish" in shell:
        profiles.append(Path.home() / ".config" / "fish" / "config.fish")
    else:
        profiles.append(Path.home() / ".zshrc")
        profiles.append(Path.home() / ".bashrc")

    for profile in profiles:
        if profile.exists():
            content = profile.read_text()
            if "jvm init" in content:
                return True
    return False


def _cmd_setup(args: argparse.Namespace) -> None:
    """Add jvm shell hook to the user's shell profile."""
    import os
    from pathlib import Path

    shell = os.environ.get("SHELL", "")
    if "zsh" in shell:
        profile = Path.home() / ".zshrc"
        hook_line = 'eval "$(jvm init)"'
    elif "bash" in shell:
        profile = Path.home() / ".bashrc"
        hook_line = 'eval "$(jvm init)"'
    elif "fish" in shell:
        profile = Path.home() / ".config" / "fish" / "config.fish"
        hook_line = "jvm init | source"
    else:
        profile = Path.home() / ".zshrc"
        hook_line = 'eval "$(jvm init)"'

    if profile.exists():
        content = profile.read_text()
        if "jvm init" in content:
            print(f"Shell hook already configured in {profile}")
            return
    else:
        profile.parent.mkdir(parents=True, exist_ok=True)

    with open(profile, "a") as f:
        f.write(f"\n# Jac Version Manager\n{hook_line}\n")

    print(f"Added jvm shell hook to {profile}")
    print(f"Run 'source {profile}' or open a new terminal to activate.")


def _cmd_init(args: argparse.Namespace) -> None:
    from .shell import get_init_script

    print(get_init_script(shell=args.shell))


def _cmd_shell_hook(args: argparse.Namespace) -> None:
    """Internal command used by the shell function to modify PATH."""
    from .installer import is_installed
    from .switcher import get_shell_hook_deactivate, get_shell_hook_use, use_version

    if args.action == "use":
        if not args.version:
            print("Error: version required", file=sys.stderr)
            sys.exit(1)
        if not is_installed(args.version):
            print(
                f"Error: Version {args.version} is not installed. Run 'jvm install {args.version}' first.",
                file=sys.stderr,
            )
            sys.exit(1)
        # Update symlink
        use_version(args.version)
        # Output shell commands to stdout (eval'd by shell function)
        print(get_shell_hook_use(args.version))

    elif args.action == "deactivate":
        from .config import get_current_link

        link = get_current_link()
        if link.exists() or link.is_symlink():
            link.unlink()
        print(get_shell_hook_deactivate())


if __name__ == "__main__":
    main()
