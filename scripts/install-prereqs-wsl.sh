#!/usr/bin/env bash
# Install the CLI prerequisites for this demo inside a WSL2 (Ubuntu) shell, without sudo.
# Installs kind, kubectl, helm and jq as official release binaries into $INSTALL_DIR.
# Idempotent: tools already on PATH are skipped unless FORCE=1.
#
# Usage: scripts/install-prereqs-wsl.sh
#        FORCE=1 INSTALL_DIR=/some/dir scripts/install-prereqs-wsl.sh
#
# Not needed on macOS — use the brew instructions in README.md instead.
set -euo pipefail

KIND_VERSION="v0.27.0"
HELM_VERSION="v3.17.1"
JQ_VERSION="jq-1.7.1"
KUBECTL_VERSION_URL="https://dl.k8s.io/release/stable.txt"

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
FORCE="${FORCE:-0}"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "    ${GREEN}✓${NC} $*"; }
info() { echo -e "    ${CYAN}->${NC} $*"; }
warn() { echo -e "    ${YELLOW}!${NC} $*"; }
err()  { echo -e "    ${RED}✗${NC} $*" >&2; }

case "$(uname -m)" in
  x86_64)        ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) err "unsupported architecture: $(uname -m)"; exit 1 ;;
esac

command -v curl >/dev/null 2>&1 || { err "curl is required (sudo apt-get install -y curl)"; exit 1; }

mkdir -p "$INSTALL_DIR"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# should_install <name>: true unless the tool is already on PATH (and FORCE != 1)
should_install() {
  if [ "$FORCE" != "1" ] && command -v "$1" >/dev/null 2>&1; then
    ok "$1 already installed ($(command -v "$1")) — skipping (FORCE=1 to reinstall)"
    return 1
  fi
  return 0
}

# install_binary <name> <downloaded file> <version args...>: verify it runs, then move into place
install_binary() {
  local name="$1" file="$2"
  shift 2
  chmod +x "$file"
  "$file" "$@" >/dev/null 2>&1 || { err "$name binary failed to run after download"; exit 1; }
  mv -f "$file" "$INSTALL_DIR/$name"
  ok "$name installed to $INSTALL_DIR/$name"
}

echo -e "\n${BOLD}==> Installing prerequisites into ${INSTALL_DIR} (linux/${ARCH})${NC}"

if should_install kind; then
  info "Downloading kind ${KIND_VERSION}..."
  curl -fsSL -o "$TMP_DIR/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
  install_binary kind "$TMP_DIR/kind" version
fi

if should_install kubectl; then
  KUBECTL_VERSION=$(curl -fsSL "$KUBECTL_VERSION_URL")
  info "Downloading kubectl ${KUBECTL_VERSION}..."
  curl -fsSL -o "$TMP_DIR/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
  install_binary kubectl "$TMP_DIR/kubectl" version --client
fi

if should_install helm; then
  info "Downloading helm ${HELM_VERSION}..."
  curl -fsSL -o "$TMP_DIR/helm.tar.gz" "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  mkdir -p "$TMP_DIR/helm"
  tar -xzf "$TMP_DIR/helm.tar.gz" -C "$TMP_DIR/helm"
  install_binary helm "$TMP_DIR/helm/linux-${ARCH}/helm" version
fi

if should_install jq; then
  info "Downloading jq ${JQ_VERSION}..."
  curl -fsSL -o "$TMP_DIR/jq" "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-${ARCH}"
  install_binary jq "$TMP_DIR/jq" --version
fi

echo -e "\n${BOLD}==> Environment status${NC}"

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ok "$INSTALL_DIR is on PATH" ;;
  *) warn "$INSTALL_DIR is not on PATH — add to ~/.bashrc or ~/.zshrc: export PATH=\"$INSTALL_DIR:\$PATH\"" ;;
esac

RUNTIME_OK=false
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  ok "docker is usable"
  RUNTIME_OK=true
else
  warn "docker is not usable from this shell. Either:"
  info "add yourself to the docker group: sudo usermod -aG docker \$USER, then re-open your shell, or"
  info "enable Docker Desktop > Settings > Resources > WSL integration for this distro"
fi

if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
  ok "podman is usable (setup.sh prefers podman; set CONTAINER_RUNTIME=docker to override)"
  RUNTIME_OK=true
else
  info "podman not usable (optional — docker is enough)"
fi

[ "$RUNTIME_OK" = true ] || warn "no working container runtime yet — make setup will fail until docker or podman works"

if command -v terraform >/dev/null 2>&1; then
  ok "terraform present ($(command -v terraform))"
else
  warn "terraform not found — install tfenv (https://github.com/tfutils/tfenv), then run 'tfenv install && tfenv use' in the project root"
fi

# tfenv unpacks releases with unzip, which minimal WSL images often lack
command -v unzip >/dev/null 2>&1 && ok "unzip present (needed by tfenv install)" \
  || warn "unzip not found — 'tfenv install' will fail with 'Tarball unzip failed' (sudo apt-get install -y unzip)"

command -v python3 >/dev/null 2>&1 && ok "python3 present" || warn "python3 not found — setup.sh needs it (sudo apt-get install -y python3)"

case "$(pwd)" in
  /mnt/*) warn "this checkout is on the Windows filesystem ($(pwd)) — clone into the WSL filesystem (e.g. ~/projects) instead" ;;
  *) info "keep the repo in the WSL filesystem (e.g. ~/projects), not /mnt/c — file I/O and Kind mounts are slower/unreliable there" ;;
esac
echo ""
