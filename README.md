# CrewAI Account Risk Monitor

An open-source, headless multi-agent crew that runs on a schedule, finds open P1/P2 ServiceNow incidents, correlates them to at-risk Salesforce accounts and pipeline, and emits a ranked risk briefing. Built with [CrewAI](https://docs.crewai.com).

This demo illustrates the **Resource Server** connection model for AI agents under Okta: the crew authenticates as itself (Okta `client_credentials` + `private_key_jwt`), receives a scoped bearer token, and calls the backend MCP server directly — with no human in the loop and no browser-based OAuth flow.

> **Running on a Mac?** Use [`MAC-QUICKSTART.md`](./MAC-QUICKSTART.md) — `./setup.sh` builds the venv, installs the package, and scaffolds `.env`. Then `account-risk-monitor --once`.

---

## Install

**Primary path — clone and bootstrap:**

```bash
git clone https://github.com/joevanhorn/okta-ai-agents-crewai.git
cd okta-ai-agents-crewai
./setup.sh                 # creates .venv, installs the package, copies .env.example -> .env
```

**Alternative — pipx (no local clone needed):**

```bash
pipx install "git+https://github.com/joevanhorn/okta-ai-agents-crewai.git"
```

Installing provides two console commands: **`account-risk-monitor`** (the crew) and **`account-risk-monitor-smoke`** (a free access check). A `./monitor` wrapper runs them without activating the venv (`./monitor smoke`, `./monitor --once`).

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Okta Custom Authorization Server                    │
│  (<auth-server-id>)                                  │
│                                                      │
│  client_credentials + private_key_jwt                │
│  Scopes granted: sfdc:read sfdc:write snow:read      │
│  Scope ceiling enforced by policy → NOT snow:write   │
└───────────────────┬─────────────────────────────────┘
                    │ scoped access token
                    ▼
┌─────────────────────────────────────────────────────┐
│  CrewAI Account Risk Monitor (this repo)             │
│                                                      │
│  Sequential crew:                                    │
│    1. Incident Watcher   (snow:read)                 │
│    2. Account Correlator (sfdc:read)                 │
│    3. Risk Reporter      (sfdc:write / report-only)  │
└───────────────────┬─────────────────────────────────┘
                    │ Authorization: Bearer <token>
                    ▼
┌─────────────────────────────────────────────────────┐
│  Backend MCP Server                                  │
│  https://your-mcp-backend.example.com/mcp            │
│  (JSON-RPC over streamable-http)                     │
│                                                      │
│  tools/list filtered by token scopes → 11 tools     │
│  snow:write tools never appear in toolset            │
└─────────────────────────────────────────────────────┘

  ✗ MCP OAuth Adapter is BYPASSED
    — it only serves sessions it brokered itself and
      returns 401 on pre-acquired tokens.
      See docs/SECURING-CREWAI-WITH-OKTA.md for the
      full auth-path analysis.
```

---

## Connection model: Resource Server, not MCP Server

Okta supports two ways a CrewAI agent can reach MCP tools:

| Model | How it works | When to use |
|---|---|---|
| **MCP Server connection** | Brokered OAuth through an Okta MCP adapter; the adapter handles the full OIDC/OAuth flow and issues a session | Interactive clients (Claude.ai, CrewAI AMP) where a human or host can participate in the browser-based OAuth flow |
| **Resource Server connection** | The agent mints its own scoped access token via `client_credentials` and passes it as a `Bearer` header directly to the backend MCP server | Headless, scheduled agents — no human, no browser, no adapter |

This demo uses the **Resource Server** model. An MCP OAuth adapter is deliberately bypassed: it only serves OAuth sessions it brokered itself and rejects any pre-acquired token with a 401. The full analysis of why headless agents must use this path is in [`docs/SECURING-CREWAI-WITH-OKTA.md`](./docs/SECURING-CREWAI-WITH-OKTA.md).

Open-source CrewAI can pass a static `Authorization: Bearer` header to an MCP server but cannot execute a full browser-based OAuth flow. The Resource Server model is the correct architecture for this use case.

---

## Prerequisites

- Python 3.10+
- The agent's RSA private key (provisioned from your Okta API Services app — see [Credentials](#credentials) below and `terraform/crewai_monitor.tf.example`)
- An `ANTHROPIC_API_KEY` **or** a LiteLLM gateway key for the LLM reasoning step (not needed for the smoke test)
- Network access to `https://your-mcp-backend.example.com` and `https://your-org.okta.com`

---

## Configure

### 1. Create your `.env` file

```bash
cp .env.example .env
```

Do **not** commit `.env` — it is gitignored. The table below maps every variable from `.env.example`:

| Variable | Description |
|---|---|
| `MONITOR_LLM` | LiteLLM model string, e.g. `anthropic/claude-haiku-4-5-20251001` or `openai/gpt-4o-mini` |
| `LITELLM_API_BASE` | LiteLLM proxy URL (Option A — gateway path) |
| `LITELLM_API_KEY` | LiteLLM virtual key (Option A) |
| `ANTHROPIC_API_KEY` | Direct Anthropic key (Option B — direct path) |
| `OKTA_CLIENT_ID` | Client ID of your Okta API Services app |
| `OKTA_KEY_ID` | Key ID registered in the Okta JWKS (`<your-key-id>`) |
| `OKTA_TOKEN_URL` | `https://your-org.okta.com/oauth2/<auth-server-id>/v1/token` |
| `OKTA_PRIVATE_KEY_FILE` | Path to PEM file on disk (highest priority) |
| `OKTA_PRIVATE_KEY_PEM` | Inline PEM string (second priority) |
| `OKTA_PRIVATE_KEY_SSM_PARAM` | SSM parameter name for the private key (third priority) |
| `AWS_PROFILE` | AWS profile to use when reading from SSM |
| `AWS_REGION` | AWS region for SSM (e.g. `us-east-2`) |
| `MCP_BACKEND_URL` | `https://your-mcp-backend.example.com/mcp` |
| `MONITOR_SCOPES` | Space-separated scopes to request (default: `sfdc:read sfdc:write snow:read`) |
| `WATCH_INTERVAL` | Seconds between passes in `--watch` mode (default: `300`) |

### 2. Credentials

The crew's Okta identity is an **API Services** application (machine-to-machine, no user). Provision one using `terraform/crewai_monitor.tf.example` or manually in the Okta Admin Console. The app must be assigned to the custom authorization server that fronts your MCP backend.

The agent's RSA private key is **not** shipped in this repo. Provide it using one of three methods (evaluated in priority order):

**Option A — Key file on disk (simplest for laptops)**

```dotenv
OKTA_PRIVATE_KEY_FILE=/path/to/agent-private-key.pem
```

**Option B — Inline PEM in `.env`**

```dotenv
OKTA_PRIVATE_KEY_PEM=<the PEM contents, newlines escaped as \n>
```

**Option C — AWS SSM Parameter Store**

```dotenv
OKTA_PRIVATE_KEY_SSM_PARAM=/your-path/agent-private-key
AWS_PROFILE=<your-aws-profile>
AWS_REGION=us-east-2
```

When `OKTA_PRIVATE_KEY_FILE` and `OKTA_PRIVATE_KEY_PEM` are both unset, `okta_auth.py` falls through to SSM automatically using the parameter name in `OKTA_PRIVATE_KEY_SSM_PARAM`.

### 3. LLM

**Option A — LiteLLM proxy/gateway (recommended for shared environments)**

```dotenv
LITELLM_API_BASE=https://your-litellm-proxy.example.com
LITELLM_API_KEY=sk-your-litellm-virtual-key
MONITOR_LLM=openai/claude-haiku-4-5-20251001
```

LiteLLM proxies are OpenAI-compatible; use the `openai/` prefix and adjust the model name to match what your proxy exposes.

**Option B — Direct provider key**

```dotenv
ANTHROPIC_API_KEY=sk-ant-...
MONITOR_LLM=anthropic/claude-haiku-4-5-20251001
```

Leave `LITELLM_API_BASE` and `LITELLM_API_KEY` unset.

---

## Running

### Smoke test (no LLM required)

Verifies that the token mints correctly, granted scopes match the policy, the backend MCP server is reachable, and the `snow:write` tools are absent from the toolset. **No LLM call is made.**

```bash
account-risk-monitor-smoke
# or:  ./monitor smoke
```

Expected output summary:

```
Granted scopes: ['sfdc:write', 'sfdc:read', 'snow:read']
Total tools: 11
✓ PASS: snow:write tools absent (policy working)
✓ Smoke test PASSED
```

### Single monitoring pass

```bash
account-risk-monitor --once
# or:  ./monitor --once
```

Runs the full sequential crew (Incident Watcher → Account Correlator → Risk Reporter) and prints a risk briefing. Report-only by default — no writes occur.

### Enable the one write action

```bash
account-risk-monitor --once --act
```

Authorises the Risk Reporter to call `log_activity` once on the highest-risk Salesforce account. All other write tools remain off-limits regardless of this flag.

### Continuous watch loop

```bash
account-risk-monitor --watch --interval 300
```

Loops indefinitely. Re-mints the Okta token and re-opens the MCP connection on every pass. Press `Ctrl+C` to stop cleanly. The default interval is 300 seconds (also settable via `WATCH_INTERVAL` in `.env`).

---

## Scheduling

### Built-in watch loop

The simplest option for a demo or development environment:

```bash
account-risk-monitor --watch --interval 900
```

### Cron (quick deployment)

```cron
*/15 * * * * cd /path/to/okta-ai-agents-crewai && .venv/bin/account-risk-monitor --once >> monitor.log 2>&1
```

Each cron invocation is independent; the token is minted fresh on every pass (`client_credentials` tokens have a 1-hour lifetime; there is no refresh token in this flow, so re-minting each pass is the correct pattern).

### Production options

For production, prefer a **systemd timer** (on a VM or bare-metal host) or an **ECS scheduled task** (on AWS) over a raw cron job — both provide restart-on-failure semantics, structured logging, and IAM-scoped execution roles.

---

## How least privilege works here

The crew's Okta identity carries exactly three scopes: `sfdc:read`, `sfdc:write`, `snow:read`. The scope ceiling is enforced by a dedicated client-credentials policy on the custom authorization server (`<auth-server-id>`).

**What this means in practice:**

1. **Tool visibility is scope-filtered.** The backend MCP server inspects the token scopes and returns only the tools the token is authorised for. With the three granted scopes the toolset contains **11 tools**. The three ServiceNow-write tools (`create_incident`, `update_incident`, `add_work_note`) that require `snow:write` are **never present** in `tools/list` — the crew cannot even attempt to call them.

2. **Over-asking is rejected at token mint.** If `MONITOR_SCOPES` were modified to include `snow:write`, Okta would return `401 access_denied` immediately — before any MCP call is made. The policy is the ceiling; the code cannot override it.

3. **The `--act` flag controls a single authorised write.** With `snow:write` absent, the only write available to the crew is `log_activity` (Salesforce activity log), which is gated by `sfdc:write`. Even this write is opt-in via `--act`; by default the crew is fully read-only.

The smoke test asserts this boundary on every run (`[6] Verifying snow:write tool gating`).

---

## Security notes

- **Standing privilege.** A `client_credentials` agent holds long-lived identity credentials (the RSA private key). Unlike a user session, there is no MFA, no step-up, and no revocation via logout. Treat the private key as a high-value secret and rotate it if compromised.
- **Network restriction.** The backend MCP server trusts the token's scope claims. Keep the agent host on a restricted network or VPC where possible — the backend may not have additional per-caller network allowlisting out of the box.
- **Keep scopes minimal.** The current policy deliberately excludes `snow:write`. Do not add scopes without reviewing what additional tools they unlock.
- **Key storage.** Do not check the PEM into source control — `.env` is gitignored. Use a secrets manager (SSM, Vault, etc.) for production deployments.

Both standing-privilege and network-restriction caveats are discussed further in [`docs/SECURING-CREWAI-WITH-OKTA.md`](./docs/SECURING-CREWAI-WITH-OKTA.md).

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `401 access_denied` at token mint | Requested a scope the policy does not grant (e.g. `snow:write`) | Request only the granted scopes (`sfdc:read sfdc:write snow:read`). The Okta policy is the ceiling — the code cannot override it. |
| `401 invalid_client` at token mint | Wrong `client_id` or key, or key does not match the one registered in Okta | Check `OKTA_CLIENT_ID` and `OKTA_KEY_ID` in `.env`; verify the private key matches the JWK registered on the Okta app. |
| `MCPServerAdapter` lists 0 tools | Token has no recognised tool scopes | Check `MONITOR_SCOPES` in `.env` and confirm the access policy on the Okta auth server grants those scopes to this client. |
| `401 invalid_token` when pointing at an OAuth adapter URL | The adapter rejects pre-acquired tokens — it only serves sessions it brokered itself | Target the backend directly: `MCP_BACKEND_URL=https://your-mcp-backend.example.com/mcp`. See [`docs/SECURING-CREWAI-WITH-OKTA.md`](./docs/SECURING-CREWAI-WITH-OKTA.md) for the auth-path analysis. |
| Crew fails with an LLM error | `ANTHROPIC_API_KEY` or `LITELLM_API_KEY` not set | Add the relevant key to `.env`. |
| Tool calls fail mid-run on a long `--watch` pass | Token expired (1-hour lifetime) during a very long reasoning step | `--watch` mode re-mints on each pass. Shorten `--interval` or reduce crew verbosity to keep individual passes short. |
| `Failed to load private key from SSM` | AWS credentials not configured, wrong profile, or `OKTA_PRIVATE_KEY_SSM_PARAM` not set | Set `AWS_PROFILE=<your-aws-profile>` and `OKTA_PRIVATE_KEY_SSM_PARAM` in `.env`. |
| `setup.sh` says Python 3.10+ is required | Python version too old | Install Python 3.10 or later (e.g. `brew install python@3.12` on Mac). |

---

## References

- **Mac quickstart:** [`MAC-QUICKSTART.md`](./MAC-QUICKSTART.md) — shortest path on a Mac
- **Operator runbook:** [`RUNBOOK.md`](./RUNBOOK.md) — step-by-step run guide including the LiteLLM path
- **Architecture & security analysis:** [`docs/SECURING-CREWAI-WITH-OKTA.md`](./docs/SECURING-CREWAI-WITH-OKTA.md) — the two connection models, why headless agents must use the Resource Server path, and how to build a "secure CrewAI with Okta" POC
- **Okta identity (Terraform):** [`terraform/crewai_monitor.tf.example`](./terraform/crewai_monitor.tf.example) — provision the API Services app and register the JWK
- [CrewAI MCP documentation](https://docs.crewai.com/en/mcp/overview)
