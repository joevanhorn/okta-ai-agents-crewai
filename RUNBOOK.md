# CrewAI Account Risk Monitor — Operator Runbook

Step-by-step instructions for getting the demo running. Copy-paste-able commands throughout.

**Overview**: See [README.md](README.md)
**Architecture & security analysis**: See [docs/SECURING-CREWAI-WITH-OKTA.md](./docs/SECURING-CREWAI-WITH-OKTA.md)

---

## Prerequisites

- Python 3.10+
- The agent's RSA private key — provisioned from your Okta API Services app (see Step 3 and `terraform/crewai_monitor.tf.example`)
- Network access to `https://your-mcp-backend.example.com` and `https://your-org.okta.com`
- A LiteLLM gateway key **or** a direct provider API key (see Step 4)

---

## Step 1 — Clone and bootstrap

```bash
git clone https://github.com/joevanhorn/okta-ai-agents-crewai.git
cd okta-ai-agents-crewai
./setup.sh
```

`setup.sh` creates `.venv`, installs the package (providing the `account-risk-monitor` and `account-risk-monitor-smoke` console commands), and copies `.env.example` to `.env`.

To install into an existing venv instead:

```bash
pip install -e .
```

---

## Step 2 — Create your `.env` file

```bash
cp .env.example .env
```

Do **not** commit `.env` — it is gitignored. Fill it in using Steps 3 and 4 below.

---

## Step 3 — Configure Okta credentials

The crew authenticates as itself using an Okta **API Services** application (client_credentials + private_key_jwt). Provision the app using `terraform/crewai_monitor.tf.example` or manually in the Okta Admin Console.

Three options are supported for the private key; **key file on disk** is simplest for a laptop and **SSM** is recommended for a server or CI host.

### Option 1 — Key file on disk (primary, laptop-friendly)

Save the private key PEM to a file, then set:

```dotenv
OKTA_CLIENT_ID=<your-client-id>
OKTA_KEY_ID=<your-key-id>
OKTA_TOKEN_URL=https://your-org.okta.com/oauth2/<auth-server-id>/v1/token
OKTA_PRIVATE_KEY_FILE=/path/to/agent-private-key.pem
```

`OKTA_PRIVATE_KEY_FILE` takes highest priority. If set, SSM and inline PEM are ignored.

### Option 2 — Inline PEM in `.env`

Paste the PEM block directly:

```dotenv
OKTA_CLIENT_ID=<your-client-id>
OKTA_KEY_ID=<your-key-id>
OKTA_TOKEN_URL=https://your-org.okta.com/oauth2/<auth-server-id>/v1/token
OKTA_PRIVATE_KEY_PEM=<the PEM contents, newlines escaped as \n>
```

### Option 3 — AWS SSM Parameter Store (recommended for server/CI hosts)

Store the private key as an SSM SecureString. Then set:

```dotenv
OKTA_CLIENT_ID=<your-client-id>
OKTA_KEY_ID=<your-key-id>
OKTA_TOKEN_URL=https://your-org.okta.com/oauth2/<auth-server-id>/v1/token
OKTA_PRIVATE_KEY_SSM_PARAM=/your-path/agent-private-key
AWS_PROFILE=<your-aws-profile>
AWS_REGION=us-east-2
# Leave OKTA_PRIVATE_KEY_PEM and OKTA_PRIVATE_KEY_FILE unset —
# okta_auth.py will pull the key from SSM automatically.
```

To fetch values from SSM interactively:

```bash
aws --profile <your-aws-profile> ssm get-parameter \
  --region us-east-2 \
  --name /your-path/agent-client-id \
  --query Parameter.Value --output text

# The private key is a SecureString — always use --with-decryption
aws --profile <your-aws-profile> ssm get-parameter \
  --region us-east-2 \
  --name /your-path/agent-private-key \
  --with-decryption \
  --query Parameter.Value --output text
```

### Private key loading priority

`okta_auth.py` loads the private key in this order:

1. `OKTA_PRIVATE_KEY_FILE` (path to a PEM file on disk)
2. `OKTA_PRIVATE_KEY_PEM` (inline PEM string in the environment)
3. SSM Parameter Store (`OKTA_PRIVATE_KEY_SSM_PARAM`) — requires AWS credentials

---

## Step 4 — Configure the LLM

### Option A — LiteLLM proxy/gateway (PRIMARY path)

This is the recommended path for shared or operator environments. CrewAI uses LiteLLM under the hood, so setting `LITELLM_API_BASE` and `LITELLM_API_KEY` routes every LLM call through your gateway without changing any code.

```dotenv
LITELLM_API_BASE=https://your-litellm-proxy.example.com
LITELLM_API_KEY=sk-your-litellm-virtual-key
MONITOR_LLM=openai/claude-haiku-4-5-20251001
# LiteLLM proxies are OpenAI-compatible. Use the openai/ prefix and
# adjust the model name to match what your proxy exposes
# (e.g. openai/gpt-4o-mini, openai/claude-3-5-haiku, etc.).
```

### Option B — Direct provider key (fallback)

```dotenv
ANTHROPIC_API_KEY=sk-ant-...
MONITOR_LLM=anthropic/claude-haiku-4-5-20251001
# Leave LITELLM_API_BASE and LITELLM_API_KEY unset.
```

---

## Complete example `.env` (LiteLLM path)

Copy this block into `.env` and replace the placeholder values:

```dotenv
# ── Okta identity (key file — simplest for a laptop) ─────────────────────
OKTA_CLIENT_ID=<your-client-id>
OKTA_KEY_ID=<your-key-id>
OKTA_PRIVATE_KEY_FILE=/path/to/agent-private-key.pem
# OKTA_PRIVATE_KEY_PEM=    # alternative: paste inline PEM
# OKTA_PRIVATE_KEY_SSM_PARAM=  # alternative: SSM parameter name
# AWS_PROFILE=<your-aws-profile>
# AWS_REGION=us-east-2

# ── Okta token endpoint ───────────────────────────────────────────────────
OKTA_TOKEN_URL=https://your-org.okta.com/oauth2/<auth-server-id>/v1/token

# ── MCP backend ───────────────────────────────────────────────────────────
MCP_BACKEND_URL=https://your-mcp-backend.example.com/mcp

# ── Scopes — DO NOT add snow:write; Okta policy will reject it ────────────
MONITOR_SCOPES=sfdc:read sfdc:write snow:read

# ── LLM — LiteLLM proxy (PRIMARY) ────────────────────────────────────────
LITELLM_API_BASE=https://your-litellm-proxy.example.com
LITELLM_API_KEY=sk-your-litellm-virtual-key
MONITOR_LLM=openai/claude-haiku-4-5-20251001

# ── Watch mode interval (seconds, used by --watch) ───────────────────────
WATCH_INTERVAL=300
```

---

## Step 5 — Verify access without spending LLM tokens

Run the smoke test first. It mints a token, decodes granted scopes, connects to the MCP backend, enumerates tools, and asserts that `snow:write` tools are absent. **No LLM call is made.**

```bash
account-risk-monitor-smoke
# or without activating the venv:
./monitor smoke
```

### Expected output

```
======================================================================
CrewAI Account Risk Monitor - Smoke Test
======================================================================

[1] Loading configuration...
  OKTA_TOKEN_URL: https://your-org.okta.com/oauth2/<auth-server-id>/v1/token
  OKTA_CLIENT_ID: <your-client-id>
  MCP_BACKEND_URL: https://your-mcp-backend.example.com/mcp
  Requested scopes: sfdc:read sfdc:write snow:read

[2] Minting access token via private_key_jwt...
  ✓ Token minted (NNN chars)

[3] Decoding token and verifying granted scopes...
  Granted scopes: ['sfdc:write', 'sfdc:read', 'snow:read']
  ✓ Decoded 3 scopes

[4] Connecting to MCP backend...
  ✓ Connected to MCP backend

[5] Enumerating MCP tools...
  Total tools: 11
    - create_activity
    - create_opportunity
    - get_account_details
    - get_incident
    - list_contacts
    - list_my_incidents
    - log_activity
    - search_accounts
    - search_incidents
    - search_opportunities
    - update_opportunity

[6] Verifying snow:write tool gating...
  ✓ PASS: snow:write tools absent (policy working)

======================================================================
✓ Smoke test PASSED
======================================================================
```

Key things to confirm:

- Granted scopes include `sfdc:write`, `sfdc:read`, `snow:read` — nothing more.
- Exactly 11 tools are visible.
- `create_incident`, `update_incident`, `add_work_note` are **not** in the list.

---

## Step 6 — Single monitoring pass (calls the LLM)

```bash
account-risk-monitor --once
# or without activating the venv:
./monitor --once
```

Runs the full sequential crew (Incident Watcher → Account Correlator → Risk Reporter) and prints a risk briefing. Default is **report-only** — no writes occur.

---

## Step 7 — Allow the one write action

```bash
account-risk-monitor --once --act
```

Same as `--once` but authorises the Risk Reporter to call `log_activity` once on the highest-risk Salesforce account after generating the briefing. All other write tools remain off-limits regardless of this flag. `snow:write` tools are still absent — the policy ceiling is enforced at token mint, not at call time.

---

## Step 8 — Autonomous watch loop

```bash
account-risk-monitor --watch --interval 300
```

Loops indefinitely. On each pass: re-mints the Okta token, re-opens the MCP connection, and runs the full crew. Press `Ctrl+C` to stop cleanly. Interval is in seconds; default is `300` (also settable via `WATCH_INTERVAL` in `.env`).

---

## Scheduling

### Built-in watch loop

The simplest option:

```bash
account-risk-monitor --watch --interval 900
```

### Cron (quick deployment)

Replace `<abs-dir>` with the absolute path to the `okta-ai-agents-crewai/` directory:

```cron
*/15 * * * * cd <abs-dir> && .venv/bin/account-risk-monitor --once >> monitor.log 2>&1
```

Each cron invocation is fully independent. The token is minted fresh on every pass — `client_credentials` tokens have a 1-hour lifetime and there is no refresh token in this flow, so re-minting each pass is the correct pattern.

### Production options

For production, prefer a **systemd timer** (on a VM/bare-metal host) or an **ECS scheduled task** (on AWS) over a raw cron job — both provide restart-on-failure semantics, structured logging, and IAM-scoped execution roles.

---

## Quick troubleshooting

See [README.md](README.md) for the full troubleshooting table. Common issues:

| Symptom | Cause | Fix |
|---|---|---|
| `401 access_denied` at token mint | Requested a scope the policy does not grant (e.g. `snow:write`) | Set `MONITOR_SCOPES=sfdc:read sfdc:write snow:read` — do not add `snow:write`. |
| `401 invalid_client` at token mint | Wrong `client_id` or key mismatch | Check `OKTA_CLIENT_ID` and `OKTA_KEY_ID`; confirm the private key matches the JWK registered on the Okta app. |
| `Failed to load private key from SSM` | Wrong AWS profile or `OKTA_PRIVATE_KEY_SSM_PARAM` not set | Set `AWS_PROFILE=<your-aws-profile>` and `OKTA_PRIVATE_KEY_SSM_PARAM` in `.env`. |
| LLM/auth error at crew kickoff | `LITELLM_API_KEY` or `ANTHROPIC_API_KEY` not set, or proxy unreachable | Confirm the LLM env vars are set and the proxy URL is reachable from the demo host. |
| 0 tools visible | Token has no recognised tool scopes | Check `MONITOR_SCOPES` in `.env` and confirm the access policy on the Okta auth server grants those scopes to this client. |

---

## Verification checklist

Run through these before a demo:

- [ ] `account-risk-monitor-smoke` exits 0 with "Smoke test PASSED"
- [ ] Smoke test reports exactly 3 granted scopes: `sfdc:read`, `sfdc:write`, `snow:read`
- [ ] Smoke test reports 11 visible tools
- [ ] Smoke test confirms `snow:write` tools (`create_incident`, `update_incident`, `add_work_note`) are absent
- [ ] `account-risk-monitor --once` completes and prints a risk briefing
- [ ] Adding `snow:write` to `MONITOR_SCOPES` returns `401 access_denied` at token mint (demonstrable over-ask rejection — restore the correct scopes afterwards)
