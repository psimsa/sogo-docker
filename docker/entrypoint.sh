#!/usr/bin/env bash
#
# SOGo container entrypoint.
#
# Runs — as the unprivileged "sogo" user:
#   - nginx          : serves the static web UI resources and reverse-proxies
#                      everything else to sogod (listens on 8080)
#   - busybox crond  : runs SOGo's periodic maintenance jobs (optional)
#   - sogod          : the SOGo backend (localhost:20000)
#
# The container exits as soon as any of these processes dies, so that the
# container engine's restart policy recovers it.

set -Eeuo pipefail

log() { printf '[sogo-entrypoint] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
export HOME="${HOME:-/var/lib/sogo}"
export LANG="${LANG:-C.UTF-8}"
export LD_LIBRARY_PATH="/usr/local/lib/sogo:/usr/local/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

# SOGo/SOPE on OpenSSL 3 can crash in the mail module unless the system
# libssl is loaded first. Preload it by default; set SOGO_PRELOAD_SSL=0 to
# disable.
if [[ "${SOGO_PRELOAD_SSL:-1}" != "0" && -z "${LD_PRELOAD:-}" ]]; then
    _libssl="$(ldconfig -p | awk '/libssl\.so\.3/{print $NF; exit}')"
    if [[ -n "${_libssl}" ]]; then
        export LD_PRELOAD="${_libssl}"
    fi
fi

# GNUstep runtime environment (GNUSTEP_* variables, PATH, ...)
# GNUstep.sh probes e.g. $ZSH_VERSION which trips `set -u`, so relax nounset
# around the sourcing.
set +u
# shellcheck disable=SC1091
. /usr/share/GNUstep/Makefiles/GNUstep.sh
set -u

SOGO_WORKERS="${SOGO_WORKERS:-8}"
SOGO_CRON_ENABLED="${SOGO_CRON_ENABLED:-1}"

# ---------------------------------------------------------------------------
# Directories & initial configuration
# ---------------------------------------------------------------------------
install -d -m 0750 /tmp/nginx \
    "${HOME}/GNUstep/Defaults" \
    /var/spool/sogo \
    /var/log/sogo \
    /var/spool/cron/crontabs

if [[ ! -f /etc/sogo/sogo.conf ]]; then
    if cp /etc/sogo/sogo.conf.default /etc/sogo/sogo.conf 2>/dev/null; then
        log "installed default /etc/sogo/sogo.conf — replace it with your own"
    else
        log "ERROR: /etc/sogo/sogo.conf is missing and /etc/sogo is not"
        log "       writable. Mount your sogo.conf at /etc/sogo/sogo.conf."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Process supervision (with signal handling)
# ---------------------------------------------------------------------------
pids=()

shutdown() {
    trap - TERM INT
    if ((${#pids[@]})); then
        kill "${pids[@]}" 2>/dev/null || true
    fi
    wait 2>/dev/null || true
    exit 0
}
trap shutdown TERM INT

# nginx.conf already contains "daemon off;", so a bare invocation stays in
# the foreground as a supervised child.
nginx & pids+=("$!")

if [[ "${SOGO_CRON_ENABLED}" != "0" ]]; then
    if [[ -f /var/spool/cron/crontabs/sogo ]]; then
        busybox crond -f -l 8 \
            -c /var/spool/cron/crontabs \
            -L /var/log/sogo/crond.log & pids+=("$!")
        log "cron: started (enable jobs in /var/spool/cron/crontabs/sogo)"
    else
        log "cron: no crontab found, skipping"
    fi
fi

log "starting sogod with ${SOGO_WORKERS} workers on 127.0.0.1:20000"
/usr/local/sbin/sogod \
    -WONoDetach YES \
    -WOPidFile /tmp/sogod.pid \
    -WOLogFile - \
    -WOPort 127.0.0.1:20000 \
    -WOWorkersCount "${SOGO_WORKERS}" & pids+=("$!")

# Exit (and let the restart policy kick in) as soon as any process dies.
wait -n "${pids[@]}"
log "a managed process exited unexpectedly (status $?), shutting down"
shutdown
