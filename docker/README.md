# SOGo Docker Image

A **multi-stage, rootless** Docker image that builds [SOGo](https://www.sogo.nu)
(groupware backend + web UI) from the `sogo/` and `sope/` source trees in this
repository and runs it behind a small built-in **nginx** that serves the static
web UI resources and reverse-proxies everything else to `sogod`.

Built on **Ubuntu 24.04**, using the distro's GNUstep packages (no third-party
apt repositories) — the same recipe as the official SOGo devcontainer.

## What's in the image — and what isn't

| Included | Not included (configure as external services) |
|---|---|
| `sogod` (SOGo backend, built from your sources) | Database (PostgreSQL / MySQL / MariaDB) |
| SOGo web UI + its static resources, served by nginx | memcached (strongly recommended) |
| ActiveSync (EAS) bundle, SAML2 and MFA/TOTP support | IMAP / SMTP / Sieve servers |
| `sogo-tool`, `sogo-ealarms-notify`, `sogo-backup` | LDAP / Active Directory |
| busybox `crond` for SOGo's periodic jobs | Apache (replaced by the built-in nginx) |

Everything runs as the unprivileged **`sogo`** user (fixed uid/gid 1000 by
default). nginx listens on **8080**; `sogod` only listens on `127.0.0.1:20000`
inside the container.

## Files

```
build.sh                   clones the submodules + builds the image
.gitmodules                pins the SOGo and SOPE sources (git submodules)
docker/
├── Dockerfile              multi-stage build (builder + runtime)
├── nginx.conf              rootless main nginx config
├── sogo-site.conf          SOGo vhost: static files, proxy, reverse-proxy headers
├── sogo-proxy-params.conf  shared proxy header settings (included by sogo-site.conf)
├── entrypoint.sh           starts nginx + crond + sogod, supervises them
├── with-sogo-env.sh        runs a command with the SOGo/GNUstep environment
├── crontab                 SOGo periodic jobs (all commented out)
├── sogo.conf.default       template for /etc/sogo/sogo.conf
├── docker-compose.yml      sample stack: sogo + postgres + memcached, Traefik labels
└── .env.example            environment variables for the sample stack
```

## Building

The SOGo and SOPE sources are git submodules. From the **repository root**:

```sh
./build.sh
```

This fetches the submodules and builds the image tagged
`docker.io/psimsa/sogo:latest` (override with `IMAGE=... ./build.sh`).

To build directly instead (context must be the repository root, which
contains both `sogo/` and `sope/`):

```sh
git submodule update --init
docker build -f docker/Dockerfile -t docker.io/psimsa/sogo:latest .
```

Build arguments:

| Arg | Default | Description |
|---|---|---|
| `UBUNTU_VERSION` | `24.04` | Base image for **both** stages — the GNUstep library versions must match between builder and runtime |
| `SOGO_CONFIGURE_FLAGS` | `--enable-saml2 --enable-mfa` | SOGo `./configure` flags (mirrors the official Debian packaging); add `--enable-debug` for troubleshooting builds |
| `SOGO_UID` / `SOGO_GID` | `1000` / `1000` | uid/gid of the `sogo` user in the image |

Notes:

- The build compiles SOPE first, then SOGo, then the ActiveSync bundle (it is
  *not* part of SOGo's top-level `SUBPROJECTS` and must be built separately).
- The pre-built minified JS/CSS committed in
  `sogo/UI/WebServerResources/` are used as-is; no Node.js/npm/grunt is
  involved (the `angular-material` git submodule is not required).
- First build takes roughly 20–40 minutes.

## Running

### Quick start with the sample compose file

```sh
cd docker/
cp .env.example .env          # then edit it
cp sogo.conf.default sogo.conf # then edit it: DB, mail servers, user source
docker compose up -d --build
```

The sample stack starts three services:

- `sogo` — this image, published to your Traefik;
- `db` — PostgreSQL 16 (SOGo creates its schema lazily, nothing to run by hand);
- `memcached` — SOGo's cache.

Replace `db`/`memcached` with your existing infrastructure by pointing the URLs
in `sogo.conf` at your services and removing the helper services.

### Standalone (for testing, without a reverse proxy)

```sh
docker run -d --name sogo \
  -p 127.0.0.1:8080:8080 \
  -v ./sogo.conf:/etc/sogo/sogo.conf:ro \
  docker.io/psimsa/sogo:latest
```

> The port is bound to `127.0.0.1` only — bind to a public interface (or, better,
> put it behind your reverse proxy) only if you intend to expose it.

Then open <http://localhost:8080/SOGo> — links and redirects are generated
correctly because the built-in nginx falls back to the request's own scheme
and host when no `X-Forwarded-*` headers are present.

## Configuration

### `sogo.conf`

SOGo's main configuration lives at `/etc/sogo/sogo.conf` (OpenStep plist
format). Mount your own file there:

```yaml
volumes:
  - ./sogo.conf:/etc/sogo/sogo.conf:ro
```

`docker/sogo.conf.default` documents the essential entries for a
fully-external-dependencies deployment (database URLs, memcached host, mail
servers, user source). The full parameter reference is the
[SOGo Installation and Configuration Guide](https://www.sogo.nu/support.html#/documentation).

> Do **not** set `WOPort` or `WOWorkersCount` in `sogo.conf` — the container
> controls them.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `SOGO_WORKERS` | `8` | Number of `sogod` worker processes. ActiveSync needs roughly one worker per concurrently syncing device. |
| `SOGO_CRON_ENABLED` | `1` | Set `0` to disable the in-container crond (e.g. when running jobs externally). |
| `SOGO_PRELOAD_SSL` | `1` | Preloads the system `libssl.so.3` (`LD_PRELOAD`) to work around an OpenSSL 3 crash in the mail module. Set `0` to disable. |
| `TZ` | `Etc/UTC` | Container timezone (should match `SOGoTimeZone` in `sogo.conf`). |
| `HOME`, `LANG` | fixed | Kept at the correct values for GNUstep; don't override. |

### Volumes

| Path | Purpose |
|---|---|
| `/etc/sogo/sogo.conf` | Main configuration (bind-mount the file) |
| `/var/lib/sogo` | GNUstep defaults and `sogo-backup` output (`/var/lib/sogo/backups`) |
| `/var/spool/cron/crontabs/sogo` | Crontab (mount your own to replace the shipped one) |

If you bind-mount host directories instead of named volumes, make their
ownership match `SOGO_UID`/`SOGO_GID` (default `1000:1000`).

### Periodic jobs (cron)

SOGo needs periodic jobs for email alarms, session expiry, vacation-message
expiration and backups. The shipped `docker/crontab` (installed at
`/var/spool/cron/crontabs/sogo`) contains all of them **commented out** —
enable what you need:

```sh
docker compose exec sogo sed -i 's/^#\(\* \* \* \* \* .*ealarms-notify.*\)/\1/' \
  /var/spool/cron/crontabs/sogo
docker compose restart sogo
```

(or mount a crontab file at that path). Job output goes to
`/var/log/sogo/cron.log` inside the container.

If you prefer to run the jobs from outside the container
(Kubernetes CronJob, host cron, ...), set `SOGO_CRON_ENABLED=0` and invoke
`with-sogo-env sogo-ealarms-notify` etc. via `docker exec`.

## Reverse proxy

The container speaks plain HTTP on port **8080** and relies on standard
forwarded headers. Requirements for whatever sits in front of it:

1. **TLS termination happens outside the container** (this is the intended
   deployment — the container never sees certificates);
2. Forward the original **`Host`** header unchanged;
3. Set **`X-Forwarded-Proto`** (and ideally `X-Forwarded-Port`) to what the
   browser used;
4. Forward `X-Forwarded-For` for correct client IPs.

The built-in nginx turns those into the `x-webobjects-*` headers SOGo needs to
generate correct absolute URLs (links in invitation emails, redirects, DAV
principal URLs, ...), and serves `/SOGo{,.woa}/WebServerResources/` directly
from disk with one-year cache headers.

### Traefik (primary supported setup)

The sample `docker-compose.yml` contains the labels:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=traefik"
  - "traefik.http.routers.sogo.rule=Host(`mail.example.com`)"
  - "traefik.http.routers.sogo.entrypoints=websecure"
  - "traefik.http.routers.sogo.tls=true"
  - "traefik.http.routers.sogo.tls.certresolver=letsencrypt"
  - "traefik.http.services.sogo.loadbalancer.server.port=8080"
```

Assumes an existing Traefik with a `websecure` entrypoint, a certificate
resolver, and a shared `traefik` docker network — adjust the names to your
setup. No special Traefik middleware is required; Traefik sets
`X-Forwarded-Proto`/`X-Forwarded-Port` automatically.

No lock-in: point any other proxy at `http://<container>:8080`.

### Generic nginx (external)

```nginx
server {
    listen 443 ssl;
    server_name mail.example.com;
    # ssl_certificate ...; ssl_certificate_key ...;

    location / {
        proxy_pass http://sogo:8080;         # your container address
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Port $server_port;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # ActiveSync clients hold requests open for a long time:
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        # mail attachments:
        client_max_body_size 0;
    }
}
```

### Caddy

```caddyfile
mail.example.com {
    reverse_proxy sogo:8080
}
```

## ActiveSync (EAS)

The ActiveSync bundle is built into the image, and the built-in nginx already
maps `/Microsoft-Server-ActiveSync` → `sogod` with one-hour timeouts. To use
it:

- raise `SOGO_WORKERS` — one worker per concurrently syncing device;
- point Outlook/mobile clients at `https://<your-host>/Microsoft-Server-ActiveSync`.

## CalDAV / CardDAV

The built-in nginx redirects `/.well-known/caldav` and `/.well-known/carddav`
to `/SOGo/dav` for Apple autoconfiguration. DAV endpoints:

- CalDAV: `https://<host>/SOGo/dav/`
- CardDAV: `https://<host>/SOGo/dav/<user>/contacts/`

## Operation

### Logs

- `sogod` and nginx log to the container's stdout/stderr → `docker logs sogo`;
- cron job output → `/var/log/sogo/cron.log` in the container.

### Health

The image's healthcheck curls `http://127.0.0.1:8080/SOGo/` — which only
succeeds when **both** nginx and `sogod` (all the way through the proxy) are
up:

```sh
docker inspect --format '{{.State.Health.Status}}' sogo
```

### Common tools

```sh
docker compose exec sogo with-sogo-env sogo-tool checkup someuser
docker compose exec sogo with-sogo-env sogo-tool expire-sessions 60
docker compose exec sogo with-sogo-env sogo-backup --help
```

(`with-sogo-env` sets up the GNUstep/SOGo environment around the command.)

### Upgrading

Rebuild the image from updated sources and restart. Consult the
*Upgrading* chapter of the SOGo installation guide — some versions need SQL
update scripts (see `sogo/Scripts/sql-update-*.sh` in the sources; run them
against your database before pointing the new container at it).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Mail module crashes (`SIGSEGV` when opening a message) | OpenSSL 3 quirk — `SOGO_PRELOAD_SSL` is on by default (`LD_PRELOAD=libssl.so.3`); if you disabled it, re-enable. |
| Web UI loads without styling / 404s on JS+CSS | The static aliases expect the standard install path — don't relocate `/usr/local/lib/GNUstep`. |
| Redirects/links point to `http://` or wrong host | Your proxy must set `X-Forwarded-Proto` and preserve `Host` (see the reverse-proxy requirements above). |
| "Permission denied" on `/var/lib/sogo` | Bind-mounted volume owned by a different uid — chown to `SOGO_UID`/`SOGO_GID` (default 1000) or rebuild with matching build args. |
| sogod crash-loops | Check `docker logs` — usually a syntax error in `sogo.conf` or an unreachable database. |
| Sessions not expiring / no alarm emails | The cron jobs are commented out by default — enable them (see *Periodic jobs*). |

## Security notes

- Nothing runs as root; the container needs no capabilities.
- The built-in nginx strips incoming `x-webobjects-remote-user` /
  `x-webobjects-auth-type` / `x-webobjects-remote-host` headers, so clients
  cannot forge authentication through the proxy chain.
- `client_max_body_size` is unlimited inside the container — enforce upload
  limits at your reverse proxy if you need them.
- Add `security_opt: [no-new-privileges:true]` (the sample compose file
  already does) and, for extra hardening, run with a read-only rootfs plus
  tmpfs mounts for `/tmp` and `/var/log/sogo`.
