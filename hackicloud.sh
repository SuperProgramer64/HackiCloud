#!/bin/bash
set -eu
TASK_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$TASK_ROOT"
if ! command -v python3 >/dev/null 2>&1; then
  echo "HackiCloud necesita Python 3.9 o posterior. Instálalo desde python.org." >&2
  exit 1
fi
export PYTHONDONTWRITEBYTECODE=1
exec python3 -m hackicloud.cli "$@"
