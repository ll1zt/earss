# Security

Earss is a single-operator self-hosted service. This document covers the
threat model for **public exposure** (Tailscale Funnel), the built-in
protections, and the deployment checklist you should follow before exposing
it.

## Threat model

Exposed behind Tailscale Funnel, the `.ts.net` URL is reachable by anyone on
the internet (TLS terminates at the Tailscale edge; the app itself receives
plain HTTP from the funnel proxy over the tailnet). The attacker can:

- probe every endpoint and brute-force credentials
- subscribe control: if they get admin/session/API access, they own the app
- make the app fetch attacker-controlled URLs (feeds you subscribed to, or
  feeds that redirect) — a vector into your tailnet
- serve malicious feed content that your reader clients render

The operator's own tailnet devices are inside the same trust zone as the
app — which is why outbound fetch restrictions matter.

## Built-in protections

| Area | Mechanism |
|------|-----------|
| Credential checks | Constant-time comparison (`Plug.Crypto.secure_compare`) for the admin password and the Fever key |
| Brute force | `Earss.RateLimit` — sliding window (10 req/min per route+client IP) on admin login, API login, Fever, GReader ClientLogin; 5 auth failures lock the client for 5 min. Client identity: first `X-Forwarded-For` hop (Funnel sets it), else `remote_ip`. Fails open if the limiter process is down (never locks the operator out). Config: `config :earss, :rate_limit` |
| SSRF | Fetching follows redirects manually (max 5 hops); every hop must pass `HTTP.safe_redirect_target?/1` — `http(s)` only, literal IPs in private / loopback / link-local / CGNAT (`100.64/10`, the tailnet range) / multicast / reserved ranges rejected (IPv4 + IPv6 + IPv4-mapped). Response bodies are streamed with a hard cap (25 MB default). |
| XSS (feed content) | `Earss.Feeds.HTMLSanitize` strips script/iframe/svg/math trees and event-handler attributes; URL schemes are checked after entity decoding and control-character stripping (`javascript&#58;`-style obfuscation is neutralized) |
| Sessions | Cookie store, `http_only: true`, `SameSite=Lax`, 14-day expiry, session id renewed on login (fixation protection), dropped on logout. `Secure` flag opt-in via `HTTP_COOKIE_SECURE=1` |
| CSRF | `Plug.CSRFProtection` on all admin POSTs; API/auth use Bearer tokens (no cookie → no CSRF surface) |
| Token auth | API/GReader tokens are HMAC-signed (`SECRET_KEY_BASE`), 30-day TTL (GReader edit tokens 24 h) |
| Node hygiene | `RELEASE_DISTRIBUTION=none` — no EPMD, no distribution ports, no remote-shell surface |
| Error responses | Bandit sends empty 500s; stack traces go to logs only |
| Uploads | OPML import limited by Plug.Parsers (8 MB default) |
| Dependencies | `mix hex.audit` clean (bandit 1.12.4, postgrex 0.22.4, decimal 3.1.1 cleared the 2026 advisories) |

## Public-exposure checklist (Tailscale Funnel)

1. **Strong credentials** — `ADMIN_PASSWORD` ≥ 16 random chars;
   `FEVER_API_KEY` a random hex string (e.g.
   `openssl rand -hex 24`). Both live in the operator env
   (`earss.env` / systemd `EnvironmentFile`), never in git.
2. **Enable the Secure cookie flag** — set `HTTP_COOKIE_SECURE=1` so
   browsers only send the session cookie over the funnel's HTTPS.
3. **Scope the funnel by path** — serve only what public clients need and
   keep the console on the private tailnet:
   ```
   tailscale funnel --bg 443        # decide node-side
   # public:  /fever/, /api/greader.php, /api/*, /static/*
   # private: /admin, /health (tailnet-only via `tailscale serve`)
   ```
   The funnel proxy itself also supports per-path serving (`--set-path`);
   prefer exposing the protocol endpoints and keeping `/admin` tailnet-only.
4. **Protect `SECRET_KEY_BASE`** — it signs sessions and API/GReader tokens;
   treat it as a root key. If it leaks, rotate it (sessions/tokens all
   invalidate — that's the desired outcome) and rotate the credentials.
5. **Keep an eye on `/admin/metrics`** — fetch failure spikes are usually a
   subscribed feed breaking, but an unexpected stream of failures from one
   host is worth investigating.
6. **Update via the flake input** — security fixes land on `main`; redeploy
   with `nix flake update earss && nixos-rebuild switch` after pushing.
7. **Re-run `mix hex.audit`** when bumping dependencies.

## Known residual risks

- **DNS rebinding** — `safe_redirect_target?/1` validates literal IPs, but a
  hostname can resolve to an internal address at connect time. Mitigation:
  subscribe only to hosts you trust (the operator controls the subscription
  list — it is a single-operator system).
- **Token revocation** — API/GReader tokens are valid until TTL (30 d); no
  server-side revocation table. Rotate `SECRET_KEY_BASE` to invalidate all
  tokens immediately.
- **X-Forwarded-For trust** — the rate limiter uses the first XFF hop. Behind
  Funnel this is set by the proxy (safe). If you also expose the app directly
  to the tailnet, tailnet members could spoof XFF to evade limits — they are
  already authorized tailnet members, so the residual risk is low.
- **Fever API key has no lockout semantics in clients** — NNW may retry in
  the background; the rate limiter could lock a client that keeps sending a
  stale key. If that happens, fix the key in the client and the lock clears
  after the cool-down.
