# Mac Quickstart — Account Risk Monitor

Get the Okta-governed CrewAI monitor running on a Mac in a few minutes. For the
full reference see [`README.md`](./README.md) and [`RUNBOOK.md`](./RUNBOOK.md).

---

## What you need first

- **Python 3.10+** — check with `python3 --version`. If older:
  `brew install python@3.12`.
- **The agent's private key** (`agent-private-key.pem`) — this is the RSA key
  registered in your Okta API Services app. It is **not** shipped in this repo.
  Provision the app using `terraform/crewai_monitor.tf.example`, then export the
  private key to a file. If someone else set up the demo, ask them for the PEM file
  or the SSM parameter path.
- **An LLM key** reachable from your Mac — a LiteLLM gateway key or a direct
  Anthropic key (`sk-ant-...`).

---

## Install — clone and bootstrap

```bash
git clone https://github.com/joevanhorn/okta-ai-agents-crewai.git
cd okta-ai-agents-crewai
./setup.sh                                         # makes .venv, installs, creates .env
```

`setup.sh` gives you the `account-risk-monitor` and `account-risk-monitor-smoke`
commands inside `.venv`. You still need to fill in `.env` before running.

> **Alternative:** If you prefer not to clone, you can install directly with pipx:
> ```bash
> pipx install "git+https://github.com/joevanhorn/okta-ai-agents-crewai.git"
> ```
> With pipx you get the same console commands but skip the local clone. You will
> still need a `.env` file — copy `.env.example` from the repo as a starting point.

---

## Configure

Edit `.env` (created by `setup.sh` in the repo root) and fill in these values:

```ini
# ── Okta identity ─────────────────────────────────────────────────────────
OKTA_CLIENT_ID=<your-client-id>
OKTA_KEY_ID=<your-key-id>
OKTA_TOKEN_URL=https://your-org.okta.com/oauth2/<auth-server-id>/v1/token

# Key file (simplest on a Mac — point at your downloaded PEM):
OKTA_PRIVATE_KEY_FILE=/Users/you/agent-private-key.pem

# ── MCP backend ───────────────────────────────────────────────────────────
MCP_BACKEND_URL=https://your-mcp-backend.example.com/mcp
MONITOR_SCOPES=sfdc:read sfdc:write snow:read

# ── LLM — pick ONE option ─────────────────────────────────────────────────
# Option A — LiteLLM gateway:
LITELLM_API_BASE=https://your-litellm-proxy.example.com
LITELLM_API_KEY=sk-your-litellm-key
MONITOR_LLM=openai/your-proxy-model

# Option B — direct Anthropic key:
# ANTHROPIC_API_KEY=sk-ant-...
# MONITOR_LLM=anthropic/claude-haiku-4-5-20251001
```

`OKTA_PRIVATE_KEY_FILE` takes highest priority. The SSM path (`OKTA_PRIVATE_KEY_SSM_PARAM`)
also works on a Mac if you have AWS credentials configured, but the key file is
the simplest option for a local workstation.

---

## Run

```bash
source .venv/bin/activate              # activate the venv

account-risk-monitor-smoke             # 1) free check: token + scope-filtered tools, no LLM
account-risk-monitor --once            # 2) one monitoring pass (uses the LLM)
account-risk-monitor --once --act      # 3) allow the one Salesforce activity write
account-risk-monitor --watch --interval 300   # 4) autonomous loop
```

Or, without activating the venv, use the `./monitor` wrapper from the repo root:

```bash
./monitor smoke
./monitor --once
./monitor --once --act
```

---

## Expected smoke-test output

```
[3] Decoding token and verifying granted scopes...
  Granted scopes: ['sfdc:write', 'sfdc:read', 'snow:read']
  ✓ Decoded 3 scopes

[5] Enumerating MCP tools...
  Total tools: 11

[6] Verifying snow:write tool gating...
  ✓ PASS: snow:write tools absent (policy working)

✓ Smoke test PASSED
```

If you see that, Okta auth and least-privilege filtering are working and the
crew is ready to run. Then try `account-risk-monitor --once` for the full pass.

---

## If something breaks

| Symptom | Fix |
|---|---|
| `setup.sh` says Python 3.10+ is required | `brew install python@3.12`, re-run `./setup.sh` |
| `401 access_denied` minting the token | You requested a scope the policy doesn't grant (e.g. `snow:write`). Keep `MONITOR_SCOPES` at the default. |
| `401 invalid_client` | Wrong `OKTA_CLIENT_ID` / `OKTA_KEY_ID`, or the key file isn't the one registered in Okta. |
| Can't read the key | Check that `OKTA_PRIVATE_KEY_FILE` points to the correct path and the file is readable. |
| `0 tools` listed | The token carries no recognised tool scopes — check `MONITOR_SCOPES` in `.env`. |
| LLM error on `--once` | `LITELLM_API_KEY` (or `ANTHROPIC_API_KEY`) not set, or the gateway isn't reachable from your Mac. |

For more detail see the [full troubleshooting table in README.md](./README.md#troubleshooting) and the architecture explanation in [`docs/SECURING-CREWAI-WITH-OKTA.md`](./docs/SECURING-CREWAI-WITH-OKTA.md).
