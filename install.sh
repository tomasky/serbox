#!/usr/bin/env bash
# serbox installer — https://github.com/tomasky/serbox
#
#   curl -LsSf https://raw.githubusercontent.com/tomasky/serbox/main/install.sh | bash
#   curl -LsSf https://raw.githubusercontent.com/tomasky/serbox/main/install.sh | bash -s -- --version 0.1.1
#
# Environment overrides:
#   SERBOX_VERSION        release version to install (default: latest)
#   SERBOX_INSTALL_DIR    where to put the `serbox` binary (default: ~/.local/bin)
#   SERBOX_REPO           owner/repo to download from (default: tomasky/serbox)
#   SERBOX_DOWNLOAD_BASE  full base URL; overrides SERBOX_REPO/SERBOX_VERSION
set -euo pipefail

REPO="${SERBOX_REPO:-tomasky/serbox}"
BIN="serbox"

say() { printf '%s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
serbox installer

Usage:
  install.sh [options]

Options:
  -v, --version <version>       install a specific version (e.g. 0.1.1)
  -b, --install-dir <dir>       install into <dir> (default: ~/.local/bin)
      --no-verify               skip SHA-256 checksum verification
  -h, --help                    show this help

Environment:
  SERBOX_VERSION, SERBOX_INSTALL_DIR, SERBOX_REPO, SERBOX_DOWNLOAD_BASE
EOF
}

version=""
install_dir=""
verify=1

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -v | --version)
      [ $# -ge 2 ] || err "--version requires a value"
      version="$2"
      shift 2
      ;;
    --version=*)
      version="${1#*=}"
      shift
      ;;
    -b | --install-dir)
      [ $# -ge 2 ] || err "--install-dir requires a value"
      install_dir="$2"
      shift 2
      ;;
    --install-dir=*)
      install_dir="${1#*=}"
      shift
      ;;
    --no-verify)
      verify=0
      shift
      ;;
    *)
      err "unknown argument: $1 (try --help)"
      ;;
  esac
done

[ -n "$version" ] || version="${SERBOX_VERSION:-}"
[ -n "$install_dir" ] || install_dir="${SERBOX_INSTALL_DIR:-}"
[ -n "$install_dir" ] || install_dir="$HOME/.local/bin"
version="${version#v}"

# --- detect platform -------------------------------------------------------
os="$(uname -s)"
arch="$(uname -m)"
case "$os-$arch" in
  Linux-x86_64 | Linux-amd64) target="linux-x86_64" ;;
  Linux-aarch64 | Linux-arm64) target="linux-aarch64" ;;
  *)
    err "unsupported platform: $os-$arch (serbox publishes linux-x86_64 and linux-aarch64; it runs on the server that owns the boxes)"
    ;;
esac

# --- downloader ------------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
  dl() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  dl() { wget -qO "$2" "$1"; }
else
  err "either curl or wget is required"
fi

# --- resolve base URL ------------------------------------------------------
if [ -n "${SERBOX_DOWNLOAD_BASE:-}" ]; then
  base="${SERBOX_DOWNLOAD_BASE%/}"
elif [ -n "$version" ]; then
  base="https://github.com/$REPO/releases/download/v$version"
else
  base="https://github.com/$REPO/releases/latest/download"
fi

asset="serbox-$target"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say "serbox: downloading $base/$asset"
dl "$base/$asset" "$tmp/$asset" || err "failed to download $base/$asset"

# --- verify ----------------------------------------------------------------
if [ "$verify" = 1 ]; then
  if dl "$base/$asset.sha256" "$tmp/$asset.sha256" 2>/dev/null; then
    if command -v sha256sum >/dev/null 2>&1; then
      (cd "$tmp" && sha256sum -c "$asset.sha256" >/dev/null) ||
        err "checksum verification failed for $asset"
    elif command -v shasum >/dev/null 2>&1; then
      (cd "$tmp" && shasum -a 256 -c "$asset.sha256" >/dev/null) ||
        err "checksum verification failed for $asset"
    else
      say "serbox: warning: no sha256sum/shasum available, skipping verification"
    fi
  else
    say "serbox: warning: no checksum published for $asset, skipping verification"
  fi
fi

# --- install ---------------------------------------------------------------
mkdir -p "$install_dir"
if command -v install >/dev/null 2>&1; then
  install -m 755 "$tmp/$asset" "$install_dir/$BIN"
else
  cp "$tmp/$asset" "$install_dir/$BIN"
  chmod 755 "$install_dir/$BIN"
fi

say "serbox: installed $install_dir/$BIN"

case ":$PATH:" in
  *":$install_dir:"*) ;;
  *)
    say ""
    say "$install_dir is not on your PATH. Add it by appending this to your shell profile:"
    say ""
    say "  export PATH=\"$install_dir:\$PATH\""
    ;;
esac

"$install_dir/$BIN" version 2>/dev/null || true
