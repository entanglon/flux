# Flux Backend (Cloudflare Workers + D1)

Zero-cost backend for Flux accounts: email/password auth + per-user library sync
(watchlist, history, collections, settings) as a JSON blob.

## One-time setup

```bash
cd backend

# 1. Authenticate (opens browser)
wrangler login

# 2. Create the D1 database — copy the database_id it prints
wrangler d1 create flux

# 3. Paste that id into wrangler.toml → [[d1_databases]] database_id

# 4. Create tables
wrangler d1 execute flux --remote --file=schema.sql

# 5. Deploy
wrangler deploy
```

Wrangler prints the deployed URL (e.g. `https://flux-backend.<your-subdomain>.workers.dev`).
Put it into the Swift app: `flux/Services/FluxCloud.swift` → `FluxCloudConfig.baseURL`
(you can also set `UserDefaults` key `cloudBaseURL` to override without a rebuild).

## API

| Method | Path | Auth | Body | Notes |
|---|---|---|---|---|
| POST | `/v1/signup` | – | `{email, pass}` | `pass` = client-derived PBKDF2 hex |
| POST | `/v1/login` | – | `{email, pass}` | Rate-limited: 8 fails / 15 min / email+ip |
| POST | `/v1/logout` | Bearer | – | invalidates session |
| GET | `/v1/me` | Bearer | – | session check |
| GET | `/v1/data` | Bearer | – | `{notFound:true}` when never synced |
| PUT | `/v1/data` | Bearer | `{payload, updatedAt}` | rejects if server copy is newer (`superseded:true`) |

## Security notes

- Passwords never leave the device raw: the client sends `PBKDF2-SHA256(pw,
  SHA256(email), 250k)`; the server stores one more cheap PBKDF2 round on top.
- Sessions are opaque random tokens; only their SHA-256 is stored server-side.
- All failures are logged per email+IP for throttling.
