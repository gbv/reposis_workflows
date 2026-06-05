#!/usr/bin/env bash
# parse.sh — extracts and validates 'deploy.name' from $PAYLOAD.
# See ../action.yml for the full contract (inputs/outputs/behavior).
set -euo pipefail

if [[ "${DEBUG:-}" == "true" ]]; then
  echo "Payload:"
  echo "$PAYLOAD" | head -c 500
fi

NAME=$(echo "$PAYLOAD" \
  | sed -n 's/^deploy\.name:[[:space:]]*//p' \
  | head -1)

NAME=$(printf "%s" "$NAME" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

if [ -z "$NAME" ]; then
  echo "No deploy.name found" >&2
  exit 1
fi

if [[ ! "$NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  printf "Invalid deploy.name: %q\n" "$NAME" >&2
  exit 1
fi

echo "name=$NAME" >> "$GITHUB_OUTPUT"
