//! Shell completion script generation for zindeks.
//!
//! Generates completion scripts for bash, zsh, and fish shells.
//! Commands: index, search, serve, update, help, completions

const std = @import("std");

/// Generate bash completion script.
pub fn generateBash(writer: anytype) !void {
    try writer.writeAll(
        \\_zindeks_completion() {
        \\    local cur prev words cword
        \\    _init_completion || return
        \\
        \\    case "$prev" in
        \\        completions)
        \\            COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur"))
        \\            return
        \\            ;;
        \\        index|search|serve|update|help)
        \\            return
        \\            ;;
        \\    esac
        \\
        \\    if [[ "$cur" == -* ]]; then
        \\        COMPREPLY=($(compgen -W "--help --version --no-color --config --store-root --index-dir" -- "$cur"))
        \\        return
        \\    fi
        \\
        \\    COMPREPLY=($(compgen -W "index search serve update help completions" -- "$cur"))
        \\}
        \\
        \\complete -F _zindeks_completion zindeks
        \\
    );
}

/// Generate zsh completion script.
pub fn generateZsh(writer: anytype) !void {
    try writer.writeAll(
        \\#compdef zindeks
        \\
        \\_zindeks() {
        \\    local -a commands
        \\    commands=(
        \\        'index:Index a repository'
        \\        'search:Search indexed code'
        \\        'serve:Start MCP JSON-RPC server'
        \\        'update:Update zindeks to latest version'
        \\        'help:Show help'
        \\        'completions:Generate shell completions'
        \\    )
        \\
        \\    local -a global_opts
        \\    global_opts=(
        \\        '--help[Show help]'
        \\        '(-v)--version[Print version]'
        \\        '--no-color[Disable colored output]'
        \\        '--config[Specify config file]:file:_files'
        \\        '--store-root[Custom index store root]:dir:_files -/'
        \\        '--index-dir[Explicit index directory]:dir:_files -/'
        \\    )
        \\
        \\    _arguments -C $global_opts \
        \\        '1: :{_describe command commands}' \
        \\        '*:: :->args'
        \\
        \\    case "$state" in
        \\        args)
        \\            case "$words[1]" in
        \\                completions)
        \\                    _values 'shell' 'bash' 'zsh' 'fish'
        \\                    ;;
        \\            esac
        \\            ;;
        \\    esac
        \\}
        \\
        \\_zindeks
        \\
    );
}

/// Generate fish completion script.
pub fn generateFish(writer: anytype) !void {
    try writer.writeAll(
        \\# Fish shell completions for zindeks
        \\
        \\# Global options
        \\complete -c zindeks -l help -d "Show help"
        \\complete -c zindeks -s v -l version -d "Print version"
        \\complete -c zindeks -l no-color -d "Disable colored output"
        \\complete -c zindeks -l config -d "Specify config file" -r
        \\complete -c zindeks -l store-root -d "Custom index store root" -r
        \\complete -c zindeks -l index-dir -d "Explicit index directory" -r
        \\
        \\# Subcommands
        \\complete -c zindeks -n "__fish_use_subcommand" -a index -d "Index a repository"
        \\complete -c zindeks -n "__fish_use_subcommand" -a search -d "Search indexed code"
        \\complete -c zindeks -n "__fish_use_subcommand" -a serve -d "Start MCP JSON-RPC server"
        \\complete -c zindeks -n "__fish_use_subcommand" -a update -d "Update zindeks to latest version"
        \\complete -c zindeks -n "__fish_use_subcommand" -a help -d "Show help"
        \\complete -c zindeks -n "__fish_use_subcommand" -a completions -d "Generate shell completions"
        \\
        \\# Completions subcommand options
        \\complete -c zindeks -n "__fish_seen_subcommand_from completions" -a bash -d "Bash completion"
        \\complete -c zindeks -n "__fish_seen_subcommand_from completions" -a zsh -d "Zsh completion"
        \\complete -c zindeks -n "__fish_seen_subcommand_from completions" -a fish -d "Fish completion"
        \\
    );
}
