#!/usr/bin/env bash
# Print the container runtime this project should use, using the same rules as setup.sh:
#   1. CONTAINER_RUNTIME env override (podman|docker) — trusted as-is
#   2. podman, if `podman info` works
#   3. docker, if `docker info` works
# Prints nothing and exits 1 when no runtime is usable. Shared by setup.sh and the Makefile
# so `make teardown` drives Kind with the same provider that created the cluster.
if [ -n "${CONTAINER_RUNTIME:-}" ]; then
  echo "$CONTAINER_RUNTIME"
  exit 0
fi
if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
  echo "podman"
  exit 0
fi
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  echo "docker"
  exit 0
fi
exit 1
