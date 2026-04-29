#!/bin/sh
# Symlink every hook in scripts/hooks/ into .git/hooks/, replacing whatever
# is there. Idempotent: re-runs are safe.
set -e

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    printf 'install-hooks: not inside a git work tree\n' >&2
    exit 1
}

SRC_DIR="${REPO_ROOT}/scripts/hooks"
DST_DIR="${REPO_ROOT}/.git/hooks"

[ -d "$SRC_DIR" ] || {
    printf 'install-hooks: %s does not exist\n' "$SRC_DIR" >&2
    exit 1
}

mkdir -p "$DST_DIR"

found=0
for src in "$SRC_DIR"/*; do
    [ -f "$src" ] || continue
    found=1
    name=$(basename "$src")
    dst="$DST_DIR/$name"
    ln -sfn "../../scripts/hooks/$name" "$dst"
    chmod +x "$src"
    printf 'install-hooks: %s -> scripts/hooks/%s\n' "$dst" "$name"
done

if [ "$found" -eq 0 ]; then
    printf 'install-hooks: no hooks found in %s\n' "$SRC_DIR" >&2
    exit 1
fi
