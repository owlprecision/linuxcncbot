#!/usr/bin/env bash
# Git commit all changes from a ralph loop iteration
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

# Accept optional commit message argument
TASK_ID="${1:-}"
DESCRIPTION="${2:-ralph loop iteration}"

if [ -z "$TASK_ID" ]; then
    COMMIT_MSG="ralph: $DESCRIPTION"
else
    COMMIT_MSG="ralph[$TASK_ID]: $DESCRIPTION"
fi

# Check if there are changes to commit
if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    echo '{"status": "skip", "message": "No changes to commit"}'
    exit 0
fi

# Stage all changes
git add -A

# Commit with Co-authored-by trailer
git commit -m "$COMMIT_MSG

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"

COMMIT_SHA=$(git rev-parse --short HEAD)
echo "{\"status\": \"committed\", \"sha\": \"$COMMIT_SHA\", \"message\": \"$COMMIT_MSG\"}"
