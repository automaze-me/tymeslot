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
  - [Proving the environment reached the container](#proving-the-environment-reached-the-container)
- [Step 5 — First account](#step-5--first-account)
- [Email](#email)
- [Calendar OAuth callbacks](#calendar-oauth-callbacks)
- [Keeping the fork current](#keeping-the-fork-current)
  - [Keeping the pass-through list current](#keeping-the-pass-through-list-current)
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
Five variables are required regardless of how you send mail; the rest depend on
your mail provider, plus optional OAuth.

```dotenv
# --- required, whatever mail provider you use ---
PHX_HOST=booking.example.com
SECRET_KEY_BASE=
DATA_ENCRYPTION_KEY=
POSTGRES_PASSWORD=
EMAIL_FROM_ADDRESS=hello@example.com
# EMAIL_FROM_NAME defaults to "Tymeslot"

# --- mail: pick ONE provider ---

# (a) an API provider — recommended, credentials are checked at boot
EMAIL_ADAPTER=mailgun
MAILGUN_API_KEY=
MAILGUN_DOMAIN=mg.example.com
# MAILGUN_BASE_URL=https://api.eu.mailgun.net/v3   # EU accounts only

# (b) or SMTP — the default when EMAIL_ADAPTER is unset
# SMTP_HOST=smtp.example.com
# SMTP_USERNAME=
# SMTP_PASSWORD=
```

`postmark`, `sendgrid` and `ahasend` work the same way as (a), with their own
key variables.

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

### How variables reach the container — and how they silently don't

This is the part that bites in Compose deployments, so it is worth
understanding rather than trusting.

Setting a variable on Dokploy's Environment tab makes it available to the
**Compose CLI**. It does **not** put it inside the container. Only two things
do that: an entry in the service's `environment:` list, or an `env_file`. A
variable that is set in Dokploy but named nowhere in the compose file
interpolates nowhere and is simply absent at runtime — no error, no warning,
and the app behaves as though you never set it.

`docker-compose.dokploy.yml` therefore names **every** environment variable
Tymeslot reads, extracted from the codebase rather than assembled by hand:

- A `KEY=value` entry sets the value in the file, with `${KEY:-default}` so you
  can still override it from Dokploy.
- A bare `KEY` entry passes through whatever Dokploy supplied.

The bare form matters for a second reason. An unset bare key is **omitted from
the container environment entirely**, rather than being set to an empty string.
An earlier draft of this file wrote `GOOGLE_CLIENT_ID: ${GOOGLE_CLIENT_ID:-}`,
which injects `""` — and because an empty string is truthy in Elixir, that
sails straight past the app's `System.get_env("GOOGLE_CLIENT_ID") || raise`
guard and configures OAuth with an empty client id instead of failing loudly.
Bare keys avoid the whole class of problem.

There is also an `env_file` entry pointing at `.env`, marked `required: false`
so it is a no-op when absent. It is a second net for variables a future
upstream version reads that are not yet in the list — worth having on a fork
that rebases indefinitely. `environment:` takes precedence over it, so the
derived values stay authoritative.

One naming collision to be aware of: Dokploy's own `${{project.VAR}}` and
`${{environment.VAR}}` template syntax is substituted by **Dokploy**, into the
values it hands to Compose. Compose's `${VAR}` is a different mechanism at a
different layer. Both can be in play; don't confuse one for the other when
something fails to resolve.

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

### Proving the environment reached the container

Don't infer it from the app working — check. From Dokploy's terminal for the
service, or over SSH on the VPS:

```bash
docker compose -f docker-compose.dokploy.yml exec tymeslot env | sort
```

Every variable you set should appear. A variable you set that is **missing**
from that output was not named in the compose file's `environment:` list — add
it as a bare key and redeploy.

Before deploying, the same thing can be checked without running anything, which
is faster and safer:

```bash
docker compose -f docker-compose.dokploy.yml config
```

In that output, a variable resolved to `null` is one that is named in the file
but currently unset — it will be absent from the container, which is correct. A
variable you expected to see but which appears nowhere at all is the failure
case.

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

`SMTP_HOST` is therefore required *only when the SMTP adapter is in use*. The
compose file deliberately does not demand it, so that `EMAIL_ADAPTER=mailgun`
and friends deploy without inventing an SMTP host they will never contact.

### Prefer an API provider over SMTP

Tymeslot supports `mailgun`, `postmark`, `sendgrid` and `ahasend` natively, and
there is a concrete operational reason to choose one: **their credentials are
validated at boot.** `Tymeslot.Mailer.ApiProbe` calls the provider — for Mailgun,
`{base_url}/domains/{domain}` — so a wrong key or domain fails visibly at
startup. The SMTP path structurally cannot do this; `Tymeslot.Mailer.HealthCheck`
states it outright: *"Not tested: SMTP authentication, which is validated on
first email send."* A bad SMTP password therefore surfaces only as failed jobs
and an open circuit breaker, long after the deploy looked healthy.

EU-hosted Mailgun accounts need `MAILGUN_BASE_URL=https://api.eu.mailgun.net/v3`;
the probe honours it too, so an EU account is not validated against the US
endpoint.

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

### Keeping the pass-through list current

An upstream release can add an environment variable, and the compose file will
not know about it — the symptom being a setting that appears to do nothing.
After a rebase, run this from the repository root. It prints the variables
Tymeslot reads that the compose file does not name; empty output means complete
coverage:

```bash
reads=$(
  {
    grep -rh 'get_env\|fetch_env' lib config --include=*.ex --include=*.exs |
      grep -o '"[A-Z][A-Z0-9_]\{2,\}"'
    grep -rho '"[A-Z][A-Z0-9_]\{2,\}"' \
      lib/tymeslot/mailer/providers.ex \
      lib/tymeslot/infrastructure/database_config.ex
  } | tr -d '"' | sort -u |
    grep -vE '^(CLOUDRON_|MIX_|TEST_)' |
    grep -vE '^(DB_SUFFIX|DEV_CALENDAR|DEV_EMPTY_CALENDAR|E2E|RELEASE_ROOT|PHX_SERVER|LOG_FILE_PATH|SMTP)$'
)
named=$(
  grep -oE '^      - [A-Z][A-Z0-9_]*(=|$)' docker-compose.dokploy.yml |
    sed 's/^      - //; s/=$//' | sort -u
)
comm -23 <(echo "$reads") <(echo "$named")
```

Add anything it prints to the pass-through section of the compose file as a
bare key. The exclusions are deliberate: `CLOUDRON_*` belongs to a different
deployment target, `MIX_*` and `TEST_*` are build and test concerns, and
`PHX_SERVER` is set by the entrypoint.

This check is how `AHASEND_ACCOUNT_ID` and `AHASEND_API_KEY` were found — a
mail provider a hand-written list had missed.

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
| A variable set in Dokploy has no effect | It is not named in the compose file's `environment:` list, so it never reached the container. Confirm with `exec tymeslot env`, then add it as a bare key. |
| A feature behaves as though a secret were set to nonsense | Something injected an empty string rather than leaving the variable unset. Check for a `${VAR:-}` entry; use a bare key instead. |
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
`postgres://tymeslot:<password>@postgres:5432/tymeslot`, an operator-supplied
`DATABASE_URL` overrides it, `dokploy-network` resolves as external, and the
volumes namespace per project rather than colliding with upstream's pinned
names.

The environment pass-through was verified by running a container, not only by
reading the spec. With `environment: [SET_VAR, UNSET_VAR, EMPTY_VAR=]` and only
`SET_VAR` set, the container's own `env` showed `SET_VAR=hello` and
`EMPTY_VAR=` but no `UNSET_VAR` at all — confirming that a bare unset key is
omitted rather than blanked, which is the property the list relies on.

The pass-through list covers every variable read by `lib/` and `config/`, plus
`lib/tymeslot/mailer/providers.ex` and
`lib/tymeslot/infrastructure/database_config.ex`, checked by the script under
[Keeping the pass-through list current](#keeping-the-pass-through-list-current);
it currently reports no gaps.

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
