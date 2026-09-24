# Quả Cà Chua

A rewards platform built with Next.js and Supabase. Users complete shortlink tasks,
surveys and offerwall campaigns to earn an in-app currency ("Cam"), then redeem it
for phone/game cards or bank transfers.

> **Status:** this project is no longer actively maintained. It is published as-is
> for reference and learning purposes.

## Features

- **Earn** — shortlink tasks across multiple providers, with signed per-user links,
  Turnstile verification and anti-fraud timing checks
- **Surveys** — CPX Research and AdGem offerwall integration via server-side postbacks
- **Wallet** — double-entry style `cam_transactions` ledger with balance snapshots
- **Redeem** — phone cards, game cards and bank transfers with an admin approval queue
- **Referrals** — commission tracking with anti-abuse suspension rules
- **Admin** — user management, withdrawal approval, provider config, bulk revoke/restore
- **Minigame** — Battleship, running on a separate Cloudflare Worker

## Tech stack

| Layer | Choice |
|---|---|
| Framework | Next.js 14 (App Router, Server Actions) |
| Database | Supabase (PostgreSQL + Row Level Security) |
| Auth | Supabase Auth |
| Rate limiting | Upstash Redis (in-memory fallback for dev) |
| Bot protection | Cloudflare Turnstile |
| Styling | Plain CSS with design tokens (no framework) |

## Getting started

```bash
git clone https://github.com/ducknogit/quacachua.git
cd quacachua
npm install

cp .env.example .env.local   # then fill in your own keys
```

Apply the database schema to your Supabase project, in this order:

```
database.sql              # core tables
cam_engine.sql            # ledger + balance functions
security_hardening.sql
security_hardening_v2.sql
redeem_rules.sql
storage_bucket.sql
```

Then apply any `migration_*.sql` files you need.

```bash
npm run dev     # http://localhost:3000
npm run build
npm run start
```

## Configuration

All configuration is via environment variables — see [`.env.example`](.env.example)
for the full list. The minimum needed to boot:

- `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY` (a `sb_secret_...` key — server-side only)
- `NEXT_PUBLIC_CF_TURNSTILE_SITE_KEY`, `CF_TURNSTILE_SECRET_KEY`
- `TOKEN_MASTER_SECRET` (≥ 32 hex characters)

Surveys, offerwall and the minigame are optional and stay disabled if left blank.

## Security notes

If you deploy this yourself:

- Keep the Supabase secret key, postback keys, Redis token and Turnstile secret
  server-side only. Never expose them to the browser.
- Set `TRUSTED_PROXY_HEADERS=true` **only** when your reverse proxy overwrites
  `X-Forwarded-For` / `-Proto` / `-Host`. Never forward client-supplied values.
- Use a persistent Redis instance in production — the in-memory fallback is
  development-only and resets on restart.
- Provider API tokens live in the `earn_providers` table, not in source. The
  values in `migration_*.sql` are placeholders.
- Run behind TLS terminated at the reverse proxy, as an unprivileged user.

## License

[MIT](LICENSE)
