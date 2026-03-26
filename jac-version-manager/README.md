# jvm - Jac Version Manager

Install and manage multiple [jaclang](https://pypi.org/project/jaclang/) versions. Switch between them instantly.

## Installation

```bash
pip install jac-version-manager
```

## Quick Start

```bash
# Install a jac version
jvm install 0.13.1

# Set up shell integration (one-time)
jvm setup

# Open a new terminal or reload your shell
source ~/.zshrc

# Switch to the installed version
jvm use 0.13.1

# Verify
jac --version

# Install plugins into the active environment
jvm install-plugin byllm
jvm install-plugin jac-scale
```

## Commands

| Command | Description |
|---------|-------------|
| `jvm install [version]` | Install a jac version (latest if omitted) |
| `jvm uninstall <version>` | Remove an installed version |
| `jvm use <version>` | Switch to an installed version |
| `jvm current` | Show the active version |
| `jvm list` | List installed versions (active marked with `*`) |
| `jvm list-remote` | List all available versions on PyPI |
| `jvm install-plugin <name>` | Install a plugin into the active environment |
| `jvm uninstall-plugin <name>` | Remove a plugin from the active environment |
| `jvm plugins` | List jac packages in the active environment |
| `jvm setup` | Auto-configure shell integration (one-time) |

## How It Works

Each jac version lives in an isolated Python virtual environment under `~/.jvm/versions/<version>/`.
Switching versions updates a `~/.jvm/current` symlink and modifies your shell's `PATH`.

```text
~/.jvm/
  versions/
    0.12.0/      # venv with jaclang 0.12.0
    0.13.0/      # venv with jaclang 0.13.0
    0.13.1/      # venv with jaclang 0.13.1
  current -> versions/0.13.1
```

Plugins (byllm, jac-scale, jac-client, etc.) are installed per-environment,
so different jac versions can have different plugin sets.

## Error Handling

jvm provides helpful error messages for common mistakes:

- **Typos**: `jvm instal` suggests `jvm install`, `jvm uninstall`
- **Invalid versions**: `jvm install abc` rejects with format hint
- **Unknown versions**: `jvm install 0.13.9` shows close matches from PyPI
- **Network errors**: Clear messages when PyPI is unreachable

## Environment Variables

| Variable | Description |
|----------|-------------|
| `JVM_HOME` | Override jvm home directory (default: `~/.jvm`) |
| `JVM_PYTHON` | Override Python executable for creating venvs |
| `JVM_ACTIVE_VERSION` | Set automatically when a version is active |

## Requirements

- Python >= 3.12 (required by jaclang)
- No external dependencies (uses only Python stdlib)
