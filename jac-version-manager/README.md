# jvm - Jac Version Manager

Install and manage multiple [jaclang](https://pypi.org/project/jaclang/) versions. Switch between them instantly.

## Installation

```bash
pip install jac-version-manager
```

Then add the shell hook to your profile:

**Bash / Zsh** — add to `~/.bashrc` or `~/.zshrc`:
```bash
eval "$(jvm init)"
```

**Fish** — add to `~/.config/fish/config.fish`:
```fish
jvm init | source
```

## Quick Start

```bash
# Install a jac version
jvm install 0.13.1

# Switch to it
jvm use 0.13.1

# Verify
jac --version

# Install plugins
jvm install-plugin byllm
jvm install-plugin jac-scale
```

## Commands

| Command | Description |
|---------|-------------|
| `jvm install [version]` | Install a jac version (latest if omitted) |
| `jvm use <version>` | Switch to an installed version |
| `jvm current` | Show the active version |
| `jvm list` | List installed versions |
| `jvm list-remote` | List all available versions on PyPI |
| `jvm uninstall <version>` | Remove an installed version |
| `jvm install-plugin <name>` | Install a plugin into the active environment |
| `jvm uninstall-plugin <name>` | Remove a plugin from the active environment |
| `jvm plugins` | List jac-related packages in the active environment |
| `jvm run [args...]` | Run jac with the active version |
| `jvm deactivate` | Deactivate jvm (remove from PATH) |
| `jvm init` | Print shell initialization script |

## How It Works

Each jac version lives in an isolated Python virtual environment under `~/.jvm/versions/<version>/`. Switching versions updates a `~/.jvm/current` symlink and modifies your shell's `PATH`.

```
~/.jvm/
├── versions/
│   ├── 0.12.0/      # venv with jaclang 0.12.0
│   ├── 0.13.0/      # venv with jaclang 0.13.0
│   └── 0.13.1/      # venv with jaclang 0.13.1
└── current -> versions/0.13.1
```

Plugins (byllm, jac-scale, jac-client, etc.) are installed per-environment, so different jac versions can have different plugin sets.

## Environment Variables

| Variable | Description |
|----------|-------------|
| `JVM_HOME` | Override jvm home directory (default: `~/.jvm`) |
| `JVM_PYTHON` | Override Python executable for creating venvs |
| `JVM_ACTIVE_VERSION` | Set automatically — shows the active jac version |

## Requirements

- Python >= 3.12 (required by jaclang)
- No external dependencies (uses only Python stdlib)
