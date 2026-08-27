# syntax=docker/dockerfile:1
#
# Multi-stage, rootless Docker image for SOGo (backend + web UI).
#
# Build from the repository root — the directory that contains both sogo/
# and sope/:
#
#   docker build -f docker/Dockerfile -t sogo:local .
#
# What's inside:
#   - sogod (SOGo backend) + sogo-tool, sogo-ealarms-notify, sogo-backup
#     compiled from the local sources (SOPE first, then SOGo)
#   - nginx running unprivileged, which serves the static web UI resources
#     (WebServerResources) and reverse-proxies everything else to sogod
#   - busybox crond for SOGo's periodic jobs
#
# What's deliberately NOT inside (configure via /etc/sogo/sogo.conf):
#   database, memcached, IMAP/SMTP/LDAP servers, Apache — all external.

ARG UBUNTU_VERSION=24.04

###############################################################################
# Stage 1 — builder: compile SOPE and SOGo from sources
###############################################################################

FROM ubuntu:${UBUNTU_VERSION} AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=Etc/UTC

# Build dependencies. GNUstep comes from the Ubuntu archive (same packages
# the official SOGo devcontainer uses), so no third-party apt repository is
# needed. libwbxml2-dev provides the WBXML library needed for ActiveSync
# (available in noble/universe; SOGo needs >= 0.11.2).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        g++ \
        gobjc \
        gnustep-base-runtime \
        gnustep-make \
        libcurl4-openssl-dev \
        libgnustep-base-dev \
        liblasso3-dev \
        libldap2-dev \
        libmemcached-dev \
        libmysqlclient-dev \
        liboath-dev \
        libpq-dev \
        libsodium-dev \
        libssl-dev \
        libwbxml2-dev \
        libxml2-dev \
        libytnef0-dev \
        libzip-dev \
        make \
        pkg-config \
        postgresql-server-dev-all \
        python-is-python3 \
        tzdata \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# --- SOPE: the application server / foundation libraries --------------------
# ./configure sources GNUstep.sh itself, so no extra environment setup is
# needed. Install goes to the GNUstep LOCAL domain under /usr/local.
COPY sope/ /src/sope/
RUN cd /src/sope \
    && ./configure --with-gnustep \
    && make \
    && make install

# --- SOGo --------------------------------------------------------------------
# Configure flags mirror the official Debian packaging
# (packaging/debian/rules). Append --enable-debug to SOGO_CONFIGURE_FLAGS
# for a troubleshooting build.
ARG SOGO_CONFIGURE_FLAGS="--enable-saml2 --enable-mfa"
COPY sogo/ /src/sogo/
RUN cd /src/sogo \
    && ./configure ${SOGO_CONFIGURE_FLAGS} \
    && make \
    && make install \
    # The ActiveSync (EAS) bundle is NOT part of the top-level SUBPROJECTS —
    # it must be built and installed separately.
    && cd ActiveSync \
    && make \
    && make install \
    && cd .. \
    # sogo-backup is a plain shell script, not installed by "make install"
    && install -m 0755 Scripts/sogo-backup.sh /usr/local/sbin/sogo-backup

# Register the SOGo/SOPE libraries with the dynamic linker and strip the
# debug symbols to keep the runtime image small.
RUN echo "/usr/local/lib/sogo" > /etc/ld.so.conf.d/sogo.conf \
    && ldconfig \
    && find /usr/local -type f \
        \( -name '*.so' -o -name '*.so.*' -o -path '*/sbin/*' \) \
        -exec strip --strip-unneeded {} + 2>/dev/null || true

###############################################################################
# Stage 2 — runtime: only what is needed to RUN SOGo
###############################################################################

FROM ubuntu:${UBUNTU_VERSION} AS runtime

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=Etc/UTC

# Runtime packages only — no compilers, no -dev packages. gnustep-make is
# included because /usr/share/GNUstep/Makefiles/GNUstep.sh must be sourced
# to set up the GNUstep runtime environment.
RUN apt-get update && apt-get install -y --no-install-recommends \
        busybox-static \
        ca-certificates \
        curl \
        gnustep-base-runtime \
        gnustep-make \
        libcurl4t64 \
        liblasso3 \
        libldap2 \
        libmemcached11 \
        libmysqlclient21 \
        liboath0 \
        libpq5 \
        libsodium23 \
        libwbxml2-1 \
        libxml2 \
        libytnef0 \
        libzip4t64 \
        nginx \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# --- SOGo + SOPE as built in stage 1 -----------------------------------------
COPY --from=builder /usr/local/ /usr/local/
RUN echo "/usr/local/lib/sogo" > /etc/ld.so.conf.d/sogo.conf \
    && ldconfig \
    && rm -rf /usr/local/include \
    # upstream scripts and docs expect the admin tools in /usr/sbin
    && ln -s /usr/local/sbin/sogo-tool         /usr/sbin/sogo-tool \
    && ln -s /usr/local/sbin/sogo-ealarms-notify /usr/sbin/sogo-ealarms-notify \
    && ln -s /usr/local/sbin/sogo-backup       /usr/sbin/sogo-backup \
    && ln -s /usr/local/sbin/sogod             /usr/sbin/sogod

# --- unprivileged runtime user ------------------------------------------------
# Predictable uid/gid so that bind-mounted volumes can be chowned on the host.
ARG SOGO_UID=1000
ARG SOGO_GID=1000
RUN if getent passwd ubuntu >/dev/null 2>&1; then userdel --remove ubuntu; fi \
    && groupadd --gid "${SOGO_GID}" sogo \
    && useradd --uid "${SOGO_UID}" --gid "${SOGO_GID}" \
               --home-dir /var/lib/sogo --create-home \
               --shell /usr/sbin/nologin \
               --comment "SOGo groupware server" sogo \
    && install -d -o sogo -g sogo -m 0750 \
        /etc/sogo \
        /var/spool/sogo \
        /var/log/sogo \
        /var/lib/sogo/GNUstep/Defaults \
    && install -d -o sogo -g sogo -m 0700 /var/spool/cron/crontabs

# --- configuration files -------------------------------------------------------
COPY docker/nginx.conf             /etc/nginx/nginx.conf
COPY docker/sogo-site.conf         /etc/nginx/conf.d/sogo.conf
COPY docker/sogo-proxy-params.conf /etc/nginx/sogo-proxy-params.conf
COPY docker/sogo.conf.default      /etc/sogo/sogo.conf.default
COPY --chown=sogo:sogo --chmod=0600 docker/crontab /var/spool/cron/crontabs/sogo
COPY --chmod=0755 docker/entrypoint.sh    /usr/local/bin/entrypoint.sh
COPY --chmod=0755 docker/with-sogo-env.sh /usr/local/bin/with-sogo-env

ENV HOME=/var/lib/sogo \
    SOGO_WORKERS=8 \
    SOGO_PRELOAD_SSL=1 \
    SOGO_CRON_ENABLED=1

USER sogo

EXPOSE 8080

# nginx (which proxies to sogod) answering on /SOGo/ means both processes
# are alive.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD curl -fsS -o /dev/null http://127.0.0.1:8080/SOGo/ || exit 1

STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
