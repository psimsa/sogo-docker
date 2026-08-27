#!/usr/bin/env bash
#
# Run a command with the SOGo/GNUstep runtime environment set up.
# Used by the in-container cron jobs; also handy for manual invocations:
#
#   docker exec -it <container> with-sogo-env sogo-tool checkup <user>

set -Eeuo pipefail

export HOME="${HOME:-/var/lib/sogo}"
export LANG="${LANG:-C.UTF-8}"
export LD_LIBRARY_PATH="/usr/local/lib/sogo:/usr/local/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

if [[ "${SOGO_PRELOAD_SSL:-1}" != "0" && -z "${LD_PRELOAD:-}" ]]; then
    _libssl="$(ldconfig -p | awk '/libssl\.so\.3/{print $NF; exit}')"
    if [[ -n "${_libssl}" ]]; then
        export LD_PRELOAD="${_libssl}"
    fi
fi

set +u
# shellcheck disable=SC1091
. /usr/share/GNUstep/Makefiles/GNUstep.sh
set -u

exec "$@"
