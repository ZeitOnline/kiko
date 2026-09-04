#!/usr/bin/env bash

set -euo pipefail

IMAGE="kiko:latest"

self="$(basename "$0")"

die() {
    echo "$self: $*" >&2
    exit 2
}

usage() {
    cat <<EOF
usage: $self [--dir DIR[,DIR...]]... [--] [claude arguments...]

Runs Claude Code in an Apple 'container' sandbox with the current
directory mounted as /workspace.

  -d, --dir DIR[:ro|:rw]   also mount DIR as /workspace/<basename>,
                           read-only unless ':rw' is given; may be
                           repeated and may take a comma-separated list
      --sandbox-help       show this help

Everything else is passed through to 'claude'.
EOF
}

volumes=()
targets=" /workspace "

add_dir() {
    local spec="$1" path mode target

    mode=ro
    case "$spec" in
        *:ro) path="${spec%:ro}" ;;
        *:rw) path="${spec%:rw}" ; mode=rw ;;
        *)    path="$spec" ;;
    esac

    case "$path" in
        "~")   path="$HOME" ;;
        "~/"*) path="$HOME/${path#\~/}" ;;
    esac

    [ -n "$path" ] || die "empty directory in '$spec'"
    [ -d "$path" ] || die "not a directory: $path"

    # absolute, symlink-free, so the mount does not depend on $PWD
    path="$(cd "$path" && pwd -P)"
    target="/workspace/$(basename "$path")"

    [ "$path" != "$(pwd -P)" ] || die "$path is already mounted as /workspace"
    case "$targets" in
        *" $target "*) die "two directories would both mount as $target" ;;
    esac

    targets="$targets$target "
    volumes+=(--volume "$path:$target:$mode")
}

add_list() {
    local list="$1" specs spec
    IFS=',' read -r -a specs <<<"$list"
    for spec in ${specs[@]+"${specs[@]}"}; do
        add_dir "$spec"
    done
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dir|--dirs)
            [ $# -ge 2 ] || die "$1 requires an argument"
            add_list "$2"
            shift 2
            ;;
        -d=*|--dir=*|--dirs=*)
            add_list "${1#*=}"
            shift
            ;;
        --sandbox-help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            # not ours: this and everything after it belongs to claude
            break
            ;;
    esac
done

# set up symlink to keep claude config inside `~/.claude/`
mkdir -p "$HOME/.claude"
test -f "$HOME/.claude/claude.json" || echo '{}' >"$HOME/.claude/claude.json"

exec container run \
    --cap-drop ALL \
    --dns 1.1.1.1 \
    --init \
    --interactive \
    --rm \
    --tty \
    --volume "${PWD}:/workspace:rw" \
    --volume "${HOME}/.claude:/home/kiko/.claude:rw" \
    ${volumes[@]+"${volumes[@]}"} \
    --workdir /workspace \
    "$IMAGE" ${@+"$@"}
