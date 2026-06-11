# Securing CrewAI with Okta — Findings & POC Guidance

This document distills what it takes to wire **CrewAI** to an Okta-governed
**MCP** environment, and turns it into reusable guidance for a *"Use Okta to
secure CrewAI"* proof-of-concept guide. It is grounded in empirical testing
against a reference MCP deployment; the auth-path findings (referenced as T1–T5
throughout) are summarized in the [appendix](#appendix--auth-path-test-matrix).
The runnable reference implementation is this repository.

---

## TL;DR

- CrewAI ships as **two surfaces** with **different MCP auth capabilities**, and
  they map to **two different Okta connection models**:
  - **Open-source `crewai-tools`** can only attach a **static bearer token** to an
    MCP server — it cannot run an OAuth flow. → Use the Okta **Resource Server**
    connection model: the crew authenticates as itself and calls the **backend
    MCP server directly** with a scoped token.
  - **CrewAI AMP** (the hosted platform) is a **full OAuth 2.0 client** —
    discovery, authorization code, refresh. → Use the Okta **MCP Server**
    connection model: AMP completes the **adapter's brokered OAuth**, acting as
    the signed-in user.
- **Do not point open-source CrewAI at the adapter.** The adapter only serves
  sessions it brokered itself; a pre-acquired token is rejected `401`. Verified.
- Okta governs the agent through **scopes**: the backend filters the tool list
  by the token's scopes, so a least-privileged agent literally cannot *see* the
  tools it isn't entitled to. This is the demonstrable security story.

---

## 1. The two Okta connection models for an AI agent

Okta for AI Agents models a "resource connection" as one of several resource
types. Two of them matter here, and they are **not** interchangeable:

| | **MCP Server connection** | **Resource Server connection** |
|---|---|---|
| What Okta expects | An MCP server with a **preregistered confidential OAuth client** using the **authorization-code** flow | A **custom API resource server** (custom authorization server + audience + scopes) |
| How the agent reaches it | Through a **brokered OAuth session** (a gateway/adapter in front of the MCP server) | The agent **holds a scoped access token** for the resource's audience and calls it **directly** |
| Identity | A **user** (interactive, PKCE + MFA) | The **agent itself** (client credentials) or a **user via token exchange** (XAA / ID-JAG) |
| Fits which CrewAI surface | **CrewAI AMP** (runs the OAuth flow) | **Open-source CrewAI** (passes a static bearer header) |

A typical MCP adapter/gateway **is** the MCP-Server-connection
front end: a confidential OIDC app doing brokered authorization-code OAuth for
interactive clients (Claude.ai, Claude Code, CrewAI AMP). A headless framework
doesn't need that broker — it uses the Resource-Server model.

> **POC-guide takeaway:** Frame the guide around *which CrewAI surface the
> customer is using*, then pick the connection model from this table. Don't
> present a single "connect CrewAI to MCP" path — there are two, and choosing
> wrong produces a `401` that looks like a misconfiguration.

---

## 2. Why open-source CrewAI must use the Resource-Server path (empirical)

`crewai-tools`' `MCPServerAdapter` connects to an MCP server over
`streamable-http` and lets you attach **static headers** — it passes a token you
already hold. It does **not** perform an OAuth authorization-code flow. That
single capability gap dictates the architecture, and the live tests confirm it:

- **The adapter rejects pre-acquired tokens.** `POST` to the adapter's MCP
  endpoint with an externally-minted Okta token → `401`, with
  `WWW-Authenticate: Bearer resource_metadata=...` pointing back at the
  adapter's own OAuth. It only serves sessions it brokered itself.
- **The backend MCP server accepts the token directly** and **filters tools by
  scope.** `POST` to the backend with a valid scoped token → the tool list,
  trimmed to what the token's scopes allow.

So for open-source CrewAI: **mint a scoped Okta token, then point
`MCPServerAdapter` at the backend MCP server** (not the adapter), passing the
token as `Authorization: Bearer …`.

```python
from crewai_tools import MCPServerAdapter

server_params = {
    "url": "https://<backend-mcp-host>/mcp",   # the resource server, NOT the adapter
    "transport": "streamable-http",
    "headers": {"Authorization": f"Bearer {token}"},
}
with MCPServerAdapter(server_params) as tools:
    ...  # `tools` is scope-filtered by Okta
```

---

## 3. The headless identity: client credentials + private_key_jwt

The crew authenticates as **itself** (no human in the loop) using the OAuth 2.0
**client-credentials** grant against the **custom authorization server** that
fronts the MCP backend.

Key findings that shape the Okta setup:

1. **Use a dedicated API Services app — not a "registered AI agent" client.**
   In testing, the registry agent's OIDC app supported only `authorization_code`
   + token-exchange, **not** `client_credentials`; a CC request returned
   `invalid_client`. A plain **API Services app** with the `client_credentials`
   grant works. (Auth-path tests T1 fail / T2 pass.)
2. **Prefer `private_key_jwt` over a client secret.** The agent signs a JWT
   client assertion with a private key whose public JWK is registered on the
   app — no shared secret to distribute. The reference implementation generates
   the keypair in Terraform (`tls` + `jwks` providers) and stores the private
   key in a secrets manager (AWS SSM), never in source.
3. **A `client_credentials` rule must exist on the auth server's access policy.**
   Deployments often ship without one (the interactive flows use
   `authorization_code`). The token request fails with *"policy evaluation
   failed"* until a CC rule grants the client its scopes.
4. **Mint a fresh token per run.** Client-credentials tokens have no refresh
   token and a short lifetime (≈1 hour). Long-running or scheduled crews should
   re-mint at the start of each pass.

Reference Terraform: a service app (`client_credentials` + `private_key_jwt`) and
a dedicated CC policy rule on the custom AS, granting exactly the scopes the job
needs — see
[`terraform/crewai_monitor.tf.example`](../terraform/crewai_monitor.tf.example).

---

## 4. Least privilege is the demonstrable security story

This is the part of a POC that lands with a customer: **the Okta scope on the
token is the ceiling on what the agent can do, and it's enforced server-side, not
in the agent's code.**

In the reference environment the backend exposes **14 tools** (7 Salesforce, 7
ServiceNow). The monitor's token is scoped to `sfdc:read sfdc:write snow:read` —
deliberately **not** `snow:write`. Result, verified live:

- The crew sees exactly **11 tools**. The three ServiceNow **write** tools
  (`create_incident`, `update_incident`, `add_work_note`) are **absent from the
  toolset** — not erroring, *absent*. The agent cannot invoke a tool it cannot
  see.
- If the agent **over-asks** for `snow:write` at token-mint time, Okta returns
  **`401 access_denied`** ("policy evaluation failed"). The **access policy**,
  not the agent code, is the ceiling.

This gives a POC two layers to show:

- **Hard boundary (Okta):** scopes determine the visible toolset. Change the
  scope on the policy → the agent's capabilities change, with no code change.
- **Soft boundary (app):** the reference crew runs **report-only** by default and
  only writes when explicitly run with `--act`. Useful to show defense-in-depth,
  but make clear the *hard* guarantee is the Okta scope.

> **POC validation scenarios (Layer 2):** run the same crew with a **read-only**
> token vs a **read+write** token and show the tool list — and the resulting
> actions — change purely because of the Okta scope. Then show the Okta System
> Log entry attributing the calls to the agent's client.

---

## 5. The user-delegated path (CrewAI AMP) — for completeness

When the customer uses **CrewAI AMP**, the crew can act **as the signed-in user**.
AMP is a full OAuth client, so it uses the **MCP Server** connection model and
goes **through the adapter**:

1. In AMP: **Tools & Integrations → Connections → Add Custom MCP Server**, URL =
   the **adapter's** MCP endpoint.
2. Choose **OAuth 2.0**. AMP can auto-discover endpoints; if not, fill them from
   the adapter's authorization-server metadata.
3. Add AMP's callback URI to the adapter's allowed redirect list, enter the
   client ID/scopes, and connect — AMP redirects through Okta (PKCE + MFA), and
   the tools are scoped by the **user's** group membership.

Caveats found in testing that a POC guide must call out:

- The adapter's **DCR redirect allowlist is loopback-only by default** — AMP's
  hosted callback is rejected until it's allowlisted. This is a required setup
  step, not optional.
- `/.well-known/openid-configuration` is **not exposed** on the adapter (it's
  intercepted by the MCP request router). Use the
  `/.well-known/oauth-authorization-server` metadata document instead; fill the
  endpoints manually if a client insists on OIDC discovery.
- DCR works at `/.well-known/oauth/registration` (not `/register`).

---

## 6. Security caveats to bake into the POC guide

1. **Standing privilege.** A client-credentials agent carries **its own**
   permissions continuously, with no user behind the calls. Keep scopes as narrow
   as the job allows, keep token lifetimes short, and prefer `private_key_jwt`
   with the key in a secrets manager.
2. **The backend trusts the token shape.** In the reference environment the
   backend **decodes** the JWT and reads `scp` but does **not verify the
   signature** ("we trust the adapter verified it"), and it **falls back to all
   scopes when the token is absent or malformed**. Consequence: *direct-to-backend
   is only safe if the backend is network-restricted (private subnet / the
   adapter in front) or hardened to fully validate tokens.* Do not expose a
   trust-the-shape backend to the open internet for headless traffic.
3. **Token exchange (XAA / ID-JAG) is the on-behalf-of evolution.** The
   Resource-Server model also supports the agent acting **as a user** by trading
   the user's ID token for a per-resource access token (RFC 8693 / Okta
   ID-JAG). This is the more advanced, more governable headless pattern — call it
   out as the "next step" beyond client credentials when the customer wants user
   attribution on agent actions.

---

## 7. Suggested POC-guide structure

A guide for *"secure CrewAI with Okta"* should split by connection flow and give
each its own Okta setup + validation:

- **Flow A — User-delegated (CrewAI AMP → adapter, MCP Server connection).**
  Okta: the adapter's confidential OIDC app, user groups → scopes, AMP callback
  on the redirect allowlist. Validate: connect as a read-only user vs a
  read+write user; tool list and actions change by **group membership**; System
  Log attributes calls to the **user**.
- **Flow C — Headless (open-source CrewAI → backend, Resource Server connection).**
  Okta: a dedicated API Services app (`client_credentials` + `private_key_jwt`),
  a CC rule on the custom AS granting the job's scopes. Validate: read-only vs
  read+write **token**; tool list/actions change by **scope**; over-ask → `401`;
  System Log attributes calls to the **agent client**.
- **Cross-cutting:** the least-privilege demonstration (Section 4), the security
  caveats (Section 6), and a note on XAA/token-exchange as the on-behalf-of
  upgrade path.

---

## 8. Reference implementation

- **Crew + CLI:** this repository — an autonomous "Account Risk Monitor"
  (Incident Watcher → Account Correlator → Risk Reporter) that runs headless on a
  schedule. See the [README](../README.md) and [RUNBOOK](../RUNBOOK.md).
- **Okta identity (Terraform):** [`terraform/crewai_monitor.tf.example`](../terraform/crewai_monitor.tf.example)
  — the API Services app + CC policy rule, scoped `sfdc:read sfdc:write snow:read`.
- **Auth-path evidence:** the [appendix](#appendix--auth-path-test-matrix) below
  — the T1–T5 findings behind every claim above.

---

## Appendix — auth-path test matrix

| Test | Question | Result | Implication |
|---|---|---|---|
| **T1** | Can a *registered AI agent* client mint `client_credentials`? | **No** — only `authorization_code`/token-exchange; CC → `invalid_client` | Headless must use a plain **API Services app** |
| **T2** | Can a plain **API Services app** mint a scoped CC token? | **Yes** | The headless identity for Flow C |
| **T3** | Does the **backend** accept an Okta token directly and scope-filter? | **Yes** — but decode-only, and no/garbage token → all tools | Direct-to-backend works, **but** the backend must be network-restricted |
| **T4** | Does the **adapter** accept an externally-minted token? | **No** — `401`, points at its own OAuth | Open-source CrewAI cannot use the adapter; target the backend |
| **T5** | Does the adapter expose OAuth discovery / DCR (for AMP)? | **Yes** — but redirect allowlist is loopback-only; `openid-configuration` not exposed | AMP path is real, with setup caveats |
