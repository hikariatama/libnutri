#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
npm --prefix backend run typecheck
backend/node_modules/.bin/prettier --check .
npm --prefix backend test
if command -v swift >/dev/null 2>&1; then
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/libnutri-core.XXXXXX")
  trap 'rm -rf "$scratch"' EXIT HUP INT TERM
  swift test --package-path app/ClientCore --scratch-path "$scratch"
  swift format lint --strict --recursive app/App app/ClientCore/Sources app/ClientCore/Tests app/DeviceTests
fi
if ! command -v gitleaks >/dev/null 2>&1; then
  echo 'Install gitleaks to complete the secret scan.' >&2
  exit 1
fi
gitleaks dir . --redact --no-banner
