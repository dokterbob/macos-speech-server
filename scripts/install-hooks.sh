#!/usr/bin/env bash
# Installs the project's git hooks by symlinking them into .git/hooks/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/.git/hooks"

if [[ ! -d "$HOOKS_DIR" ]]; then
    echo "Error: $HOOKS_DIR not found. Are you in a git repository?"
    exit 1
fi

chmod +x "$SCRIPT_DIR/pre-commit"
ln -sf "$SCRIPT_DIR/pre-commit" "$HOOKS_DIR/pre-commit"

echo "Installed pre-commit hook -> .git/hooks/pre-commit"
