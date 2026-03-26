"""CLI entry point for jvm (Jac Version Manager)."""

import argparse
import subprocess
import sys

from . import __version__


def main(argv: list[str] | None = None) -> None:
    """Main CLI entry point."""
    parser = argparse.ArgumentParser(
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

    # jvm shell-hook (internal, used by shell function)
    p_hook = subparsers.add_parser("shell-hook", help=argparse.SUPPRESS)
    p_hook.add_argument("action", choices=["use", "deactivate"])
    p_hook.add_argument("version", nargs="?")

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
    elif cmd == "shell-hook":
        _cmd_shell_hook(args)


def _cmd_install(args: argparse.Namespace) -> None:
    from .installer import install_version
    from .pypi import get_latest_version

    version = args.version
    if not version:
        print("Fetching latest version...")
        version = get_latest_version()
        print(f"Latest version: {version}")

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
    print(
        "Run 'eval \"$(jvm init)\"' in your shell or restart your terminal to update PATH."
    )


def _cmd_deactivate(args: argparse.Namespace) -> None:
    from .config import get_current_link

    link = get_current_link()
    if link.exists() or link.is_symlink():
        link.unlink()
    print(
        "Deactivated jvm. Restart your terminal or run 'eval \"$(jvm init)\"' to update PATH."
    )


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
