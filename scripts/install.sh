#!/usr/bin/env sh
set -eu

repo="${ZINDEKS_REPO:-sutantodadang/zindeks}"
version="${ZINDEKS_VERSION:-latest}"
install_dir="${ZINDEKS_INSTALL_DIR:-$HOME/.local/bin}"

usage() {
  cat <<'USAGE'
Install zindeks from GitHub releases.

Usage:
  install.sh --repo <owner/repo> [--version <tag|latest>] [--dir <install-dir>]

Environment:
  ZINDEKS_REPO          GitHub repository, default: sutantodadang/zindeks
  ZINDEKS_VERSION      Release tag or latest
  ZINDEKS_INSTALL_DIR  Install directory, default: ~/.local/bin
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      repo="${2:?missing repo}"
      shift 2
      ;;
    --version)
      version="${2:?missing version}"
      shift 2
      ;;
    --dir)
      install_dir="${2:?missing install directory}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$repo" ]; then
  echo "missing repository; pass --repo <owner/repo> or set ZINDEKS_REPO" >&2
  exit 2
fi

os="$(uname -s)"
arch="$(uname -m)"

case "$os" in
  Linux) platform="linux" ;;
  Darwin) platform="macos" ;;
  *)
    echo "unsupported OS: $os" >&2
    exit 1
    ;;
esac

case "$arch" in
  x86_64|amd64) cpu="x86_64" ;;
  arm64|aarch64) cpu="aarch64" ;;
  *)
    echo "unsupported architecture: $arch" >&2
    exit 1
    ;;
esac

asset="zindeks-${platform}-${cpu}.tar.gz"
if [ "$version" = "latest" ]; then
  url="https://github.com/${repo}/releases/latest/download/${asset}"
else
  url="https://github.com/${repo}/releases/download/${version}/${asset}"
fi

tmp="${TMPDIR:-/tmp}/zindeks-install.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

archive="$tmp/$asset"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$url" -o "$archive"
elif command -v wget >/dev/null 2>&1; then
  wget -q "$url" -O "$archive"
else
  echo "curl or wget is required" >&2
  exit 1
fi

tar -xzf "$archive" -C "$tmp"
mkdir -p "$install_dir"
cp "$tmp/zindeks-${platform}-${cpu}/zindeks" "$install_dir/zindeks"
chmod 0755 "$install_dir/zindeks"

echo "Installed zindeks to $install_dir/zindeks"
case ":$PATH:" in
  *":$install_dir:"*) ;;
  *) echo "Add $install_dir to PATH if zindeks is not found." ;;
esac
