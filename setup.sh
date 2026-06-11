#!/usr/bin/env bash
# ABOUTME: One-shot bootstrap for the Account Risk Monitor demo (macOS/Linux).
# ABOUTME: Finds a Python >=3.10, builds a venv, installs the package, scaffolds .env.
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Account Risk Monitor — setup"

# --- 1. Find a Python >= 3.10 ---------------------------------------------------
PYBIN=""
for c in python3.13 python3.12 python3.11 python3.10 python3; do
  if command -v "$c" >/dev/null 2>&1; then
    if "$c" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
      PYBIN="$c"; break
    fi
  fi
done
if [ -z "$PYBIN" ]; then
  echo "ERROR: need Python >= 3.10. On macOS:  brew install python@3.12" >&2
  exit 1
fi
echo "==> Using $($PYBIN --version) ($PYBIN)"

# --- 2. Virtual environment -----------------------------------------------------
if [ ! -d .venv ]; then
  echo "==> Creating virtual environment (.venv)"
  "$PYBIN" -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install --quiet --upgrade pip

# --- 3. Install the package + dependencies -------------------------------------
echo "==> Installing dependencies (this can take a minute on a cold cache)…"
pip install --quiet -e .
echo "==> Installed. Console commands: account-risk-monitor, account-risk-monitor-smoke"

# --- 4. Scaffold .env -----------------------------------------------------------
if [ ! -f .env ]; then
  cp .env.example .env
  echo "==> Created .env from .env.example — edit it before running (see below)."
else
  echo "==> .env already exists — leaving it untouched."
fi

cat <<'NEXT'

Next steps
----------
1. Edit .env and set:
     - your LLM:   LITELLM_API_BASE / LITELLM_API_KEY / MONITOR_LLM=openai/<model>
                   (or ANTHROPIC_API_KEY + MONITOR_LLM=anthropic/claude-haiku-4-5-20251001)
     - the Okta monitor private key:  OKTA_PRIVATE_KEY_FILE=/full/path/to/crewai-monitor.pem
       (OKTA_CLIENT_ID and OKTA_KEY_ID are already filled in)

2. Activate the environment in new shells:   source .venv/bin/activate

3. Verify access (free, no LLM):             account-risk-monitor-smoke
4. Run one monitoring pass:                  account-risk-monitor --once
   …or the convenience wrapper (no activate needed):   ./monitor --once

See MAC-QUICKSTART.md for the full walkthrough.
NEXT
