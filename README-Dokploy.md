# Deploying the automaze fork on Dokploy

A deployment guide for [Dokploy](https://dokploy.com) — the self-hosted PaaS —
covering this fork (`automaze-me/tymeslot`) specifically.

Upstream ships [README-Docker.md](README-Docker.md) and
[README-Cloudron.md](README-Cloudron.md). This file is a fork-only addition: it
is not upstream, and it adds to this fork's diff. Nothing in it changes
application behaviour.

## Contents

- [Which shape to deploy](#which-shape-to-deploy)
- [Prerequisites](#prerequisites)
- [Step 1 — Create the project and the database](#step-1--create-the-project-and-the-database)
- [Step 2 — Create the application](#step-2--create-the-application)
- [Step 3 — Environment variables](#step-3--environment-variables)
- [Step 4 — Persistent storage](#step-4--persistent-storage)
- [Step 5 — Domain and TLS](#step-5--domain-and-tls)
- [Step 6 — Deploy and verify](#step-6--deploy-and-verify)
- [Step 7 — First account](#step-7--first-account)
- [Email](#email)
- [Calendar OAuth callbacks](#calendar-oauth-callbacks)
- [Keeping the fork current](#keeping-the-fork-current)
- [Backups](#backups)
- [Troubleshooting](#troubleshooting)

---

## Which shape to deploy

The published image ships **with PostgreSQL inside the container**, because the
upstream quick-start is a single `docker run`. That is the wrong shape on
Dokploy, which manages databases as first-class services with their own backups
and lifecycle.

`Dockerfile.docker` is multi-stage and already provides the right target:

| Target | Contains | Use on Dokploy |
| --- | --- | --- |
| `release-slim` | The app only, no database server | **Yes** — pair with a Dokploy Postgres |
| `release` | `release-slim` plus an embedded PostgreSQL | No |

Dokploy's Dockerfile build type has a **Docker Build Stage** field, so selecting
`release-slim` needs no changes to the repo.

The rest of this guide deploys:

```
Dokploy project "tymeslot"
├── Postgres service   (Dokploy-managed, backed up by Dokploy)
└── Application        (this fork, built from Dockerfile.docker, target release-slim)
```

Migrations run automatically on every boot — `start-docker.sh` runs
`Ecto.Migrator` before starting the web server, so a redeploy after a schema
change needs no manual step.

## Prerequisites

- A VPS with Dokploy installed, Traefik healthy, ports 80 and 443 reachable.
- **At least 2 GB RAM for the build.** Dokploy builds on the same host, and this
  is an Elixir release plus an asset pipeline — a 1 GB box will OOM during
  `mix assets.deploy` or `mix release`. Runtime is far lighter; 1 GB is enough
  once built. Consider building elsewhere and deploying a pre-built image if
  your VPS is small.
- A DNS `A` record for your chosen hostname pointing at the VPS, resolving
  **before** you request a certificate.
- Read access to `automaze-me/tymeslot`. It is a public fork, so no deploy key
  is needed; add one in Dokploy's Git settings if you later make it private.

## Step 1 — Create the project and the database

1. Create a Dokploy **project**, e.g. `tymeslot`.
2. Inside it, create a **PostgreSQL** database service. Postgres 14 or newer;
   17 matches what upstream's own compose file uses.
3. Note the database name, user and password, and the **internal** host Dokploy
   reports for the service. Dokploy shows the connection details on the
   database's own page — use the internal/private values, not the public ones:
   the app reaches Postgres over Dokploy's Docker network, so the database never
   needs a published port.

Leaving the database unexposed to the internet is the single biggest security
win of this shape over the embedded one. Don't add a public port unless you
genuinely need external access for backups.

## Step 2 — Create the application

Create an **Application** in the same project.

**Source:**

| Field | Value |
| --- | --- |
| Repository | `https://github.com/automaze-me/tymeslot` |
| Branch | `main`, or `feature/travel-periods` to run the travel-periods work |

**Build:**

| Field | Value |
| --- | --- |
| Build Type | `Dockerfile` |
| Dockerfile Path | `Dockerfile.docker` |
| Docker Context Path | `.` |
| Docker Build Stage | `release-slim` |

The build stage is the important one. Leave it blank and you get the `release`
target, which starts an embedded PostgreSQL alongside the external one — two
databases, one of them ignored, and a confusing log.

## Step 3 — Environment variables

Set these on the application's Environment tab.

### Required — the app refuses to boot without them

| Variable | Value | Notes |
| --- | --- | --- |
| `SECRET_KEY_BASE` | 64 random bytes, base64 | `openssl rand -base64 64 \| tr -d '\n'` |
| `PHX_HOST` | `booking.example.com` | Hostname only — no scheme, no trailing slash |
| `EMAIL_FROM_ADDRESS` | `hello@example.com` | Raises at boot if missing |
| `EMAIL_FROM_NAME` | `Tymeslot` | Raises at boot if missing |
| `SMTP_HOST` | your SMTP host | Required in practice — see [Email](#email) |

### Database

| Variable | Value |
| --- | --- |
| `DATABASE_HOST` | the internal host from Step 1 |
| `DATABASE_PORT` | `5432` |
| `POSTGRES_DB` | your database name |
| `POSTGRES_USER` | your database user |
| `POSTGRES_PASSWORD` | your database password |
| `TYMESLOT_EMBEDDED_DB` | `false` |

`DATABASE_URL=postgres://user:password@host:5432/dbname` works instead of the
five discrete variables and takes precedence over them.

`TYMESLOT_EMBEDDED_DB=false` is not strictly required, but set it. On the slim
target there is no bundled database to fall back to, and this makes a
misconfiguration fail with an explicit "no database configured" message instead
of a confusing PostgreSQL initialisation error.

### Strongly recommended

| Variable | Value | Notes |
| --- | --- | --- |
| `DATA_ENCRYPTION_KEY` | 48 random bytes, base64 | `openssl rand -base64 48 \| tr -d '\n'` |
| `DEPLOYMENT_TYPE` | `docker` | |
| `PORT` | `4000` | Only if you want something other than the default |

**`DATA_ENCRYPTION_KEY` deserves care.** It encrypts stored credentials —
calendar OAuth tokens, CalDAV and Exchange passwords. Omit it and the app warns
at boot and falls back to a key derived from `SECRET_KEY_BASE`, which means you
can never rotate `SECRET_KEY_BASE` without destroying every stored credential.
Set it from the start. **Losing it makes stored credentials permanently
undecryptable** — treat it like a database backup, not like a config value. If
you add it to an instance that has been running without it, run the
re-encryption sweep described in README-Docker.md under "Data-at-rest
encryption".

### Email

| Variable | Value | Notes |
| --- | --- | --- |
| `SMTP_HOST` | your SMTP host | Required; raises if absent |
| `SMTP_PORT` | `587` | Optional, defaults to 587 |
| `SMTP_USERNAME` | your SMTP user | Must be set together with the password |
| `SMTP_PASSWORD` | your SMTP password | Must be set together with the username |
| `SMTP_SSL` | `true` | Only for implicit TLS, usually port 465. Left unset, the port decides |
| `SMTP_TLS_VERIFY` | `none` | Last resort for a self-signed relay certificate. Defaults to verifying |
| `SMTP_CACERTFILE` | path to a CA bundle | Preferable to `SMTP_TLS_VERIFY=none` for a private CA |

Setting a username without a password, or the reverse, raises at boot rather
than sending unauthenticated.

### Optional — calendar OAuth

Only needed for Google Calendar and Microsoft 365 connections. Exchange (EWS),
CalDAV, Nextcloud, Radicale, Baikal, Zimbra, mailbox.org, Apple and ICS feeds
need none of these and are configured entirely in the app's UI.

| Variable | Notes |
| --- | --- |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_STATE_SECRET` | The state secret is yours to generate, not Google's |
| `OUTLOOK_CLIENT_ID`, `OUTLOOK_CLIENT_SECRET`, `OUTLOOK_STATE_SECRET` | Serves both Outlook Calendar and Teams |

Do **not** set the generic `OAUTH_*` variables unless you want OIDC single
sign-on for logging into Tymeslot itself. They are unrelated to calendars, and
`ENABLE_OAUTH_AUTH=true` with an incomplete set raises at boot.

## Step 4 — Persistent storage

Add a **volume mount** on the application:

| Field | Value |
| --- | --- |
| Mount path | `/app/data` |

This holds operator state that must outlive a redeploy. Without it, every
deployment starts with an empty data directory.

The database needs no mount here — Dokploy manages the Postgres service's own
storage.

## Step 5 — Domain and TLS

On the application's Domains tab:

| Field | Value |
| --- | --- |
| Host | `booking.example.com` — must match `PHX_HOST` exactly |
| Path | `/` |
| Container Port | `4000` (or your `PORT`) |
| HTTPS | enabled |
| Certificate | `Let's Encrypt` |

A mismatch between `Host` and `PHX_HOST` is the most common cause of a working
site that generates broken links: Phoenix builds absolute URLs — booking links,
email links, OAuth redirect URIs — from `PHX_HOST`, not from the request.

The app listens on all interfaces by default (`LISTEN_IP` defaults to `::`), so
Traefik reaches it without further configuration.

## Step 6 — Deploy and verify

Deploy, then read the logs. A healthy first boot shows, in order:

1. `✓ External database detected: <host>:5432` followed by
   `Skipping embedded PostgreSQL initialization` — confirms the slim target
   found your Dokploy Postgres. If you instead see PostgreSQL initialising, the
   Docker Build Stage is not `release-slim`, or the database variables did not
   reach the container.
2. Migration output. On a fresh database this is the full migration history and
   takes a little while.
3. Phoenix starting and listening on your `PORT`.

Then load `https://booking.example.com`.

## Step 7 — First account

**The first account created becomes the administrator.** Register yours
immediately after the first successful deploy, before the instance is
discoverable, so nobody else claims it.

If you would rather nobody else register at all, turn registration off in the
admin settings once your account exists.

## Email

Email is not optional, and not only because the product needs it. The mailer
**defaults to SMTP** when `EMAIL_ADAPTER` is unset, and the SMTP configuration
**raises at boot when `SMTP_HOST` is absent**. An instance with no mail
configuration at all does not start.

Booking confirmations, cancellations, reschedules and password resets all depend
on it working, so this is a good default to have been given.

**The trap:** `.env.example` ships `EMAIL_ADAPTER=test`, which silently discards
every message. Do not copy that value into Dokploy. Either leave `EMAIL_ADAPTER`
unset, which defaults to SMTP, or set it to a real provider. A development-only
adapter raises at boot in production, but `test` is accepted and drops
everything — a working deploy that sends nothing.

With the `SMTP_*` variables from Step 3 set, send yourself a test booking before
you consider the instance live.

## Calendar OAuth callbacks

If you set the Google or Outlook variables, register these redirect URIs with
the providers, substituting your host:

```
https://booking.example.com/auth/google/calendar/callback
https://booking.example.com/auth/outlook/calendar/callback
https://booking.example.com/auth/teams/video/callback
```

For Microsoft, register the app as **"Accounts in any organizational directory
and personal Microsoft accounts"**. The app authorises against
`login.microsoftonline.com/common`, so a single-tenant registration rejects
accounts from other tenants — which defeats connecting calendars across
tenants. Both the Outlook Calendar and the Teams redirect URIs belong on the
same registration; they share one client ID.

## Keeping the fork current

Upstream releases regularly, and this fork carries local changes, so expect to
rebase rather than merge:

```bash
git fetch upstream
git checkout main
git rebase upstream/main
git push --force-with-lease origin main
```

For the feature branch:

```bash
git checkout feature/travel-periods
git rebase upstream/main
git push --force-with-lease origin feature/travel-periods
```

Then redeploy in Dokploy. Enable Dokploy's auto-deploy webhook on the branch if
you want a push to deploy itself — reasonable for a personal instance, less so
if the instance takes real bookings, since a failed rebase would deploy itself
too.

Rebasing is also why this fork's code changes are deliberately concentrated in
new files: see
`docs/superpowers/specs/2026-09-18-travel-periods-design.md`.

**Before any upgrade**, take a database backup (see below). Migrations run
automatically on boot and are not reversible in place.

## Backups

Use Dokploy's backup feature on the Postgres service — that is most of what
matters, and it is the main reason for not using the embedded database.

Back up separately, and keep somewhere safe:

- `DATA_ENCRYPTION_KEY` and `SECRET_KEY_BASE`. A database backup is useless
  without the encryption key: stored calendar credentials cannot be decrypted
  without it.
- The `/app/data` volume.

Test a restore at least once. An untested backup is a hypothesis.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Build killed, no clear error | Out of memory. Needs ~2 GB for `mix release` and asset compilation. |
| Logs show PostgreSQL initialising | Docker Build Stage is not `release-slim`, or the database variables did not reach the container. |
| `no database configured` and exit | `TYMESLOT_EMBEDDED_DB=false` with no reachable database. Check `DATABASE_HOST` against Dokploy's internal host. |
| `environment variable PHX_HOST is missing` | Exactly that. It has no default. |
| `environment variable EMAIL_FROM_ADDRESS is missing` | Set `EMAIL_FROM_ADDRESS` and `EMAIL_FROM_NAME`. |
| `SMTP host is required (set SMTP_HOST environment variable)` | The mailer defaults to SMTP and needs a host. |
| `SMTP username is required when a password is set` | Set both, or neither. |
| Site loads; emails and booking links use the wrong host | `PHX_HOST` does not match the Domain's Host. |
| No email arrives, no error in the logs | `EMAIL_ADAPTER=test` discards everything. Unset it or name a real provider. |
| Certificate never issues | DNS not resolving to the VPS yet, or port 80 blocked so Let's Encrypt cannot validate. |
| OAuth returns `redirect_uri_mismatch` | The registered URI does not match `PHX_HOST` exactly, including scheme and absence of a trailing slash. |
| Calendar connections fail after rotating `SECRET_KEY_BASE` | Stored credentials were encrypted with a key derived from the old value. This is what `DATA_ENCRYPTION_KEY` prevents. |
| Warning about a missing data encryption key on every boot | `DATA_ENCRYPTION_KEY` is unset. Set it, then run the re-encryption sweep. |

## Verified against this repository

The application-side facts above were read from the code rather than assumed:

- Build targets `release-slim` and `release` — `Dockerfile.docker:79,133`
- External-database detection and skipping the embedded server —
  `start-docker.sh:191-201`
- The "no database configured" guard — `start-docker.sh:203-224`
- Automatic migrations on boot — `start-docker.sh:481`
- `SECRET_KEY_BASE`, `PHX_HOST`, `EMAIL_FROM_ADDRESS`, `EMAIL_FROM_NAME`
  raising when absent — `config/runtime.exs:125,153,415,424`
- `PORT` defaulting to 4000 and `LISTEN_IP` to `::` —
  `config/runtime.exs:157,209`
- `EMAIL_ADAPTER` defaulting to SMTP, and `test` discarding mail —
  `config/runtime.exs:308-338`
- `DATA_ENCRYPTION_KEY` optional with a boot warning —
  `config/runtime.exs:137-149`
- `SMTP_HOST` required, `SMTP_PORT` defaulting to 587, username and password
  required together — `lib/tymeslot/mailer/smtp_config.ex:102-199`
- Microsoft `/common` authorisation —
  `lib/tymeslot/integrations/calendar/auth/helpers/outlook_oauth_helper.ex:28`

Dokploy's field names — Build Type, Dockerfile Path, Docker Context Path, Docker
Build Stage, and the Domain fields Host, Path, Container Port, HTTPS,
Certificate — are taken from Dokploy's documentation. Dokploy moves quickly, so
if a field has been renamed in your version, the value to supply is still the
one in the tables above.
