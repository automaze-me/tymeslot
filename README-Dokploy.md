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
- [Step 1 — Create the Compose service](#step-1--create-the-compose-service)
- [Step 2 — Environment variables](#step-2--environment-variables)
- [Step 3 — Domain and TLS](#step-3--domain-and-tls)
- [Step 4 — Deploy and verify](#step-4--deploy-and-verify)
- [Step 5 — First account](#step-5--first-account)
- [Email](#email)
- [Calendar OAuth callbacks](#calendar-oauth-callbacks)
- [Keeping the fork current](#keeping-the-fork-current)
- [Backups](#backups)
- [Troubleshooting](#troubleshooting)
- [Appendix — the Application route](#appendix--the-application-route)
- [Appendix — running the same file without Dokploy](#appendix--running-the-same-file-without-dokploy)

---

## Which shape to deploy

The published image ships **with PostgreSQL inside the container**, because the
upstream quick-start is a single `docker run`. That is the wrong shape here:
Dokploy manages databases as services with their own lifecycle, and a database
inside the app container cannot be backed up or restarted independently of it.

`Dockerfile.docker` is multi-stage and already provides the right target:

| Target | Contains | Use here |
| --- | --- | --- |
| `release-slim` | The app only, no database server | **Yes** |
| `release` | `release-slim` plus an embedded PostgreSQL | No |

This fork ships **`docker-compose.dokploy.yml`**, which wires up the whole
deployment: the app built from the `release-slim` target, its own PostgreSQL on
a private network, both volumes, a healthcheck gating the app's first boot on
the database being ready, and the `dokploy-network` attachment Traefik routes
over.

```
Dokploy Compose service
├── tymeslot   built from Dockerfile.docker, target release-slim
│                on dokploy-network (Traefik) + internal
└── postgres   postgres:17-alpine, on internal only — never reachable
                 from Traefik or from other Dokploy projects
```

Everything that can be derived, is. The database user and name are fixed as
`tymeslot`, the host is the compose service name, and `DATABASE_URL` is built
from those plus one password variable. Migrations run automatically on every
boot, so a redeploy after a schema change needs no manual step.

If you would rather use a Dokploy-managed database and a plain Application
instead of Compose, see [the appendix](#appendix--the-application-route).

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

## Step 1 — Create the Compose service

1. Create a Dokploy **project**, e.g. `tymeslot`.
2. Inside it, create a **Compose** service.
3. Point it at this fork:

| Field | Value |
| --- | --- |
| Repository | `https://github.com/automaze-me/tymeslot` |
| Branch | `main`, or `feature/travel-periods` to run the travel-periods work |
| Compose Path | `docker-compose.dokploy.yml` |

Use Dokploy's **Docker Compose** mode rather than Docker Stack: the file builds
from source, and `build` is unavailable under Stack.

There is nothing to configure for storage. The compose file declares both
volumes, and Dokploy namespaces them per project — which is deliberate, because
upstream's own compose files pin the names `tymeslot_data` and `tymeslot_pg`,
and reusing those would hand `postgres:17-alpine` a data directory created by a
different PostgreSQL packaging, which it refuses to open.

## Step 2 — Environment variables

Paste this into the Compose service's Environment tab and fill in the values.
Five variables are genuinely required; the rest are email and optional OAuth.

```dotenv
# --- required ---
PHX_HOST=booking.example.com
SECRET_KEY_BASE=
DATA_ENCRYPTION_KEY=
POSTGRES_PASSWORD=
SMTP_HOST=smtp.example.com

# --- email: the From address must be on a domain your relay may send for ---
EMAIL_FROM_ADDRESS=hello@example.com
# EMAIL_FROM_NAME defaults to "Tymeslot"
SMTP_USERNAME=
SMTP_PASSWORD=
```

Generate the secrets:

```bash
openssl rand -base64 64 | tr -d '\n'   # SECRET_KEY_BASE
openssl rand -base64 48 | tr -d '\n'   # DATA_ENCRYPTION_KEY
openssl rand -hex 32                    # POSTGRES_PASSWORD
```

**Use hex for `POSTGRES_PASSWORD`.** It is interpolated into `DATABASE_URL`, and
hex is URL-safe by construction — a base64 password can contain `/` or `+`,
which corrupt a connection URL and produce a confusing authentication failure.
If you must use a password with URL-special characters, the compose file carries
a commented block of discrete `DATABASE_HOST`/`POSTGRES_*` variables that need
no escaping; swap to those and delete the `DATABASE_URL` line.

**`PHX_HOST` must match the Domain's Host exactly** — hostname only, no scheme,
no trailing slash. Phoenix builds every absolute URL from it: booking links,
email links, OAuth redirect URIs. Get it wrong and the site loads while every
link it emits points somewhere else.

**`DATA_ENCRYPTION_KEY` must stay stable for the life of the deployment.** It
encrypts stored calendar credentials — OAuth tokens, CalDAV and Exchange
passwords. Omit it and the app warns on every boot and derives the key from
`SECRET_KEY_BASE`, permanently coupling the two so you could never rotate the
cookie secret without destroying every stored credential. **Losing it makes
those credentials permanently undecryptable**, so back it up with the database,
not with your config. Adding it to an instance that has run without it requires
the re-encryption sweep in README-Docker.md under "Data-at-rest encryption".

Everything else the app needs is set in the compose file and should not be
duplicated here: `DEPLOYMENT_TYPE`, `TYMESLOT_EMBEDDED_DB`, `DATABASE_URL`,
`SMTP_PORT` (587), `EMAIL_FROM_NAME`, and the Postgres user and database name.

### Optional — calendar OAuth

Needed only for Google Calendar and Microsoft 365 connections. Exchange (EWS),
CalDAV, Nextcloud, Radicale, Baikal, Zimbra, mailbox.org, Apple and ICS feeds
need none of these and are configured entirely in the app's UI.

```dotenv
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
GOOGLE_STATE_SECRET=
OUTLOOK_CLIENT_ID=
OUTLOOK_CLIENT_SECRET=
OUTLOOK_STATE_SECRET=
```

The two `*_STATE_SECRET` values are yours to generate, not issued by Google or
Microsoft: `openssl rand -base64 32 | tr -d '\n'`.

Do **not** set the generic `OAUTH_*` variables unless you want OIDC single
sign-on for logging into Tymeslot itself. They are unrelated to calendars, and
`ENABLE_OAUTH_AUTH=true` with an incomplete set raises at boot.

## Step 3 — Domain and TLS

On the Compose service's Domains tab:

| Field | Value |
| --- | --- |
| Service Name | `tymeslot` |
| Host | `booking.example.com` — must match `PHX_HOST` |
| Path | `/` |
| Container Port | `4000` |
| HTTPS | enabled |
| Certificate | `Let's Encrypt` |

Dokploy implements Compose domains as Traefik Docker labels rather than as
hot-reloaded configuration, so **redeploy after changing anything here** — a
domain edit alone does not take effect.

The compose file uses `expose` rather than `ports` on purpose: the app is
reachable over `dokploy-network` for Traefik and is never published on the
host. The database is not on that network at all.

## Step 4 — Deploy and verify

Deploy, then read the logs. A healthy first boot shows, in order:

1. The `postgres` service passing its healthcheck. The app waits on it, so
   nothing else happens until it does.
2. `✓ External database detected via DATABASE_URL: postgres://***:***@postgres:5432/tymeslot`
   followed by `Skipping embedded PostgreSQL initialization` — this confirms the
   slim target is in use and found the database. If you instead see PostgreSQL
   initialising, the build target is not `release-slim`. The credentials in that
   line are redacted by the entrypoint, not by you.
3. Migration output. On a fresh database this is the full migration history and
   takes a little while.
4. Phoenix starting and listening on port 4000.

Then load `https://booking.example.com`.

## Step 5 — First account

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

With the `SMTP_*` variables from [Step 2](#step-2--environment-variables) set,
send yourself a test booking before you consider the instance live.

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
| `network dokploy-network declared as external, but could not be found` | Dokploy's shared network is missing or named differently on your install. Check `docker network ls` on the VPS and correct the name at the bottom of the compose file. |
| `build` ignored, or "unsupported" on deploy | The service is running in Docker Stack mode. The file builds from source, so it needs Docker Compose mode. |
| Domain change had no effect | Compose domains are Traefik labels, not hot-reloaded. Redeploy. |
| Postgres authentication failures with a base64 password | `/` or `+` in the password corrupted `DATABASE_URL`. Use `openssl rand -hex 32`, or switch to the discrete variables. |
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
Certificate — are taken from Dokploy's documentation, as is the requirement to
join `dokploy-network` and to prefer `expose` over `ports`. Dokploy moves
quickly, so if a field has been renamed in your version, the value to supply is
still the one in the tables above.

`docker-compose.dokploy.yml` was validated with `docker compose config`: the
derived `DATABASE_URL` interpolates to
`postgres://tymeslot:<password>@postgres:5432/tymeslot`, `dokploy-network`
resolves as external, and the volumes namespace per project rather than
colliding with upstream's pinned names.

---

## Appendix — the Application route

If you prefer a Dokploy-managed database with its own backup UI, and a plain
Application rather than Compose, the same deployment works without the compose
file.

1. Create a **PostgreSQL** database service in the project. Note the database
   name, user, password and the **internal** host Dokploy reports on the
   database's own page — the app reaches it over Dokploy's network, so it needs
   no published port.

2. Create an **Application** pointing at this fork, and set:

| Field | Value |
| --- | --- |
| Build Type | `Dockerfile` |
| Dockerfile Path | `Dockerfile.docker` |
| Docker Context Path | `.` |
| Docker Build Stage | `release-slim` |

The build stage is the important one. Leave it blank and you get the `release`
target, which starts an embedded PostgreSQL alongside the managed one.

3. Set the variables from [Step 2](#step-2--environment-variables), and
   additionally — since no compose file is deriving them:

| Variable | Value |
| --- | --- |
| `DEPLOYMENT_TYPE` | `docker` |
| `TYMESLOT_EMBEDDED_DB` | `false` |
| `DATABASE_HOST` | the internal host from step 1 |
| `DATABASE_PORT` | `5432` |
| `POSTGRES_DB` | your database name |
| `POSTGRES_USER` | your database user |
| `POSTGRES_PASSWORD` | your database password |
| `SMTP_PORT` | `587` |
| `EMAIL_FROM_NAME` | `Tymeslot` |

A single `DATABASE_URL` works in place of the five database variables and takes
precedence over them.

4. Add a **volume mount** at `/app/data`. Without it every deployment starts
   with an empty data directory.

5. Domain and TLS as in [Step 3](#step-3--domain-and-tls), except that an
   Application has no Service Name field and its Traefik configuration is
   hot-reloaded, so a domain change needs no redeploy.

## Appendix — running the same file without Dokploy

`docker-compose.dokploy.yml` is usable on a plain Docker host with two changes:

1. Remove the `dokploy-network` entry from the `tymeslot` service's `networks`
   list and from the top-level `networks` block — there is no Dokploy network to
   join, and Compose fails on a missing external network.
2. Replace `expose` with a published port, so something can reach it:

```yaml
    ports:
      - "4000:4000"
```

Then supply the variables from Step 2 in a `.env` file beside the compose file
and run:

```bash
docker compose -f docker-compose.dokploy.yml up -d --build
```

Put a TLS-terminating reverse proxy in front of it; the app expects to be
reached over HTTPS at `PHX_HOST`. For a plain-Docker deployment upstream's
`docker-compose.with-postgres.yml` is the better starting point, since it uses
the published image rather than building from source.
