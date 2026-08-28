#!/usr/bin/env bash

set -euo pipefail

IMAGE="kiko:latest"

mkdir -p $HOME/.claude
exec container run \
    --cap-drop ALL \
    --dns 1.1.1.1 \
    --init \
    --interactive \
    --rm \
    --tty \
    --volume "${PWD}:/workspace:rw" \
    --volume "${HOME}/.claude:/home/kiko/.claude:rw" \
    --workdir /workspace \
    "$IMAGE" "$@"
