#!/usr/bin/env bash
#
# Clone the SOGo/SOPE submodules and build the SOGo Docker image.
#
# Usage:
#   ./build.sh                        # builds docker.io/psimsa/sogo:latest
#   IMAGE=my/sogo:v1.2 ./build.sh     # builds a different tag
#
# The build context is the repository root (it contains both sogo/ and sope/).

set -Eeuo pipefail

cd "$(dirname "$0")"

IMAGE="${IMAGE:-docker.io/psimsa/sogo:latest}"

# 1. Fetch the SOGo and SOPE sources.
#    SOGo's nested "angular-material" submodule is intentionally NOT
#    initialized (no --recursive): the web UI's compiled assets are already
#    committed, so it is not required to build the image.
echo "==> Fetching SOGo/SOPE submodules"
git submodule update --init

# 2. Build the image.
echo "==> Building image: ${IMAGE}"
docker build -f docker/Dockerfile -t "${IMAGE}" .

echo "==> Done: ${IMAGE}"
