#!/usr/bin/env bash
# Jac Version Manager (jvm) - Shell Integration
#
# Add this to your ~/.bashrc or ~/.zshrc:
#   eval "$(jvm init)"
#
# Or source this file directly:
#   source /path/to/jvm.sh

jvm() {
    if [ "$#" -eq 0 ]; then
        command jvm --help
        return
    fi

    case "$1" in
        use|deactivate)
            # These commands need to modify the current shell's PATH
            local output
            output="$(command jvm shell-hook "$@" 2>&1)"
            local exit_code=$?
            if [ $exit_code -eq 0 ]; then
                eval "$output"
            else
                echo "$output" >&2
                return $exit_code
            fi
            ;;
        *)
            # All other commands run as normal subprocesses
            command jvm "$@"
            ;;
    esac
}

# Auto-activate if a version was previously set
if [ -L "$HOME/.jvm/current" ]; then
    _jvm_bin="$HOME/.jvm/current/bin"
    if [ -d "$_jvm_bin" ]; then
        export PATH="$_jvm_bin:$PATH"
        _jvm_version="$(basename "$(readlink "$HOME/.jvm/current")")"
        export JVM_ACTIVE_VERSION="$_jvm_version"
    fi
    unset _jvm_bin _jvm_version
fi
