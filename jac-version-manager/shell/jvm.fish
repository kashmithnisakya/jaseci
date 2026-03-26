# Jac Version Manager (jvm) - Fish Shell Integration
#
# Add this to your ~/.config/fish/config.fish:
#   jvm init | source
#
# Or source this file directly:
#   source /path/to/jvm.fish

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
