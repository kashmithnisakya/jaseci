"""Shell integration for jvm."""

BASH_ZSH_HOOK = r"""# Jac Version Manager (jvm)
# Add this to your ~/.bashrc or ~/.zshrc:
#   eval "$(jvm init)"

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
"""

FISH_HOOK = r"""# Jac Version Manager (jvm)
# Add this to your ~/.config/fish/config.fish:
#   jvm init | source

function jvm
    if test (count $argv) -eq 0
        command jvm --help
        return
    end

    switch $argv[1]
        case use deactivate
            set -l output (command jvm shell-hook $argv 2>&1)
            set -l exit_code $status
            if test $exit_code -eq 0
                eval $output
            else
                echo $output >&2
                return $exit_code
            end
        case '*'
            command jvm $argv
    end
end

# Auto-activate if a version was previously set
if test -L "$HOME/.jvm/current"
    set -l _jvm_bin "$HOME/.jvm/current/bin"
    if test -d "$_jvm_bin"
        set -gx PATH "$_jvm_bin" $PATH
        set -gx JVM_ACTIVE_VERSION (basename (readlink "$HOME/.jvm/current"))
    end
end
"""


def get_init_script(shell: str | None = None) -> str:
    """Get the shell initialization script.

    Args:
        shell: Shell type ('bash', 'zsh', 'fish'). Auto-detected if None.
    """
    if shell is None:
        import os

        shell_path = os.environ.get("SHELL", "")
        shell = "fish" if "fish" in shell_path else "bash"

    if shell == "fish":
        return FISH_HOOK
    return BASH_ZSH_HOOK
