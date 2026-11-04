#!/usr/bin/env bash

set -euo pipefail

IMAGE="kiko:latest"

self="$(basename "$0")"

die() {
    echo "$self: $*" >&2
    exit 2
}

warn() {
    echo "$self: warning: $*" >&2
}

# directories the current directory is allowed to live in, space-separated
allowed_dirs="${KIKO_ALLOWED_DIRS-~/work/}"

expand_home() {
    case "$1" in
        "~")   printf '%s\n' "$HOME" ;;
        "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
        *)     printf '%s\n' "$1" ;;
    esac
}

# absolute and symlink-free, so mounts and comparisons do not depend on $PWD
resolve() {
    local path
    path="$(expand_home "$1")"
    [ -d "$path" ] || return 1
    (cd "$path" && pwd -P)
}

# macOS compares paths case-insensitively, so `cd ~/Work/proj` has to
# count as being inside ~/work/ -- fold the case away before comparing
lower() {
    printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

is_allowed() {
    local dir roots root
    dir="$(lower "$1")"
    IFS=' ' read -r -a roots <<<"$allowed_dirs"
    for root in ${roots[@]+"${roots[@]}"}; do
        root="$(resolve "$root")" || continue
        root="$(lower "$root")"
        # a root of "/" would otherwise only ever match "/" itself
        [ "$root" != / ] || root=""
        if [ "$dir" = "$root" ] || [ "${dir#"$root"/}" != "$dir" ]; then
            return 0
        fi
    done
    return 1
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

The current directory is only mounted if it lies inside one of the
directories in \$KIKO_ALLOWED_DIRS (space-separated, currently
'$allowed_dirs'); otherwise a warning is printed and /workspace
stays empty.

Variables named \$KIKO_ENV_FOO are passed into the container as FOO.
\$KIKO_PROXY sets the proxy variables inside it, \$KIKO_NO_PROXY the
exceptions (default 'localhost,127.0.0.1').

Everything else is passed through to 'claude'.
EOF
}

volumes=()
targets=" /workspace "

cwd="$(pwd -P)"
workspace=mounted

is_allowed "$cwd" || workspace=skipped

# name the container after the calling directory, so `container ls` stays
# readable; deliberately not made unique, so a second run from the same
# directory is refused by the runtime
name="$(basename "$cwd")"
name="${name//[^A-Za-z0-9_.-]/-}"
case "$name" in
    *[A-Za-z0-9]*) ;;
    *) name=workspace ;;
esac

# hand KIKO_ENV_FOO=bar to the container as FOO=bar, so the environment
# it sees has to be opted into one variable at a time
envs=()
for var in ${!KIKO_ENV_@}; do
    [ "$var" != KIKO_ENV_ ] || continue
    envs+=(--env "${var#KIKO_ENV_}=${!var}")
done

# the container's traffic leaves through vmnet's NAT and does not follow a
# VPN on the host, so route it through a proxy there instead (see README)
if [ -n "${KIKO_PROXY-}" ]; then
    for var in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy; do
        envs+=(--env "$var=$KIKO_PROXY")
    done
    for var in NO_PROXY no_proxy; do
        envs+=(--env "$var=${KIKO_NO_PROXY-localhost,127.0.0.1}")
    done
fi

add_dir() {
    local spec="$1" path resolved mode target

    mode=ro
    case "$spec" in
        *:ro) path="${spec%:ro}" ;;
        *:rw) path="${spec%:rw}" ; mode=rw ;;
        *)    path="$spec" ;;
    esac

    [ -n "$path" ] || die "empty directory in '$spec'"

    resolved="$(resolve "$path")" || die "not a directory: $path"
    path="$resolved"
    target="/workspace/$(basename "$path")"

    if [ "$workspace" = mounted ] && [ "$(lower "$path")" = "$(lower "$cwd")" ]; then
        die "$path is already mounted as /workspace"
    fi
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

workspace_volume=()
if [ "$workspace" = skipped ]; then
    warn "$cwd is not inside any of the allowed directories ($allowed_dirs)"
    warn "not mounting it as /workspace; set \$KIKO_ALLOWED_DIRS to allow it"
else
    workspace_volume=(--volume "$cwd:/workspace:rw")
fi

# set up symlink to keep claude config inside `~/.claude/`
mkdir -p "$HOME/.claude"
test -f "$HOME/.claude/claude.json" || echo '{}' >"$HOME/.claude/claude.json"

exec container run \
    --cap-drop ALL \
    --dns 1.1.1.1 \
    --memory 2G \
    --init \
    --interactive \
    --name "$name" \
    --rm \
    --tty \
    ${envs[@]+"${envs[@]}"} \
    ${workspace_volume[@]+"${workspace_volume[@]}"} \
    --volume "${HOME}/.claude:/home/kiko/.claude:rw" \
    ${volumes[@]+"${volumes[@]}"} \
    --workdir /workspace \
    "$IMAGE" ${@+"$@"}
