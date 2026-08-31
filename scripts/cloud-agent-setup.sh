#!/usr/bin/env bash
# Cloud Agent environment bootstrap for Clipora.
#
# Clipora itself is a native macOS menu-bar app (AppKit/SwiftUI, SDKROOT=macosx)
# and can only be built with Xcode on macOS. On a Linux Cloud Agent VM we set up
# the portable slice of the project instead: the Swift toolchain plus the
# `scripts/perfbench` package, which mirrors the app's DatabaseManager SQL layer
# (GRDB + SQLite) and is fully runnable here.
#
# This script is idempotent: it can be re-run safely and skips work that is
# already done.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRDB_VERSION="7.11.1"
GRDB_REVISION="b83108d10f42680d78f23fe4d4d80fc88dab3212"
GRDB_CHECKOUT="${REPO_ROOT}/build/SourcePackages/checkouts/GRDB.swift"
SWIFTLY_HOME="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}"

log() { printf '\n=== %s ===\n' "$1"; }

log "Installing system prerequisites for the Swift toolchain"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq \
  binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev \
  libpython3-dev libsqlite3-dev libstdc++-13-dev libxml2-dev libz3-dev \
  pkg-config tzdata unzip zlib1g-dev libncurses-dev

log "Installing Swift via swiftly (skipped if already present)"
if [ ! -x "${SWIFTLY_HOME}/bin/swiftly" ]; then
  tmpdir="$(mktemp -d)"
  arch="$(uname -m)"
  curl -fsSL -o "${tmpdir}/swiftly.tar.gz" \
    "https://download.swift.org/swiftly/linux/swiftly-${arch}.tar.gz"
  tar zxf "${tmpdir}/swiftly.tar.gz" -C "${tmpdir}"
  "${tmpdir}/swiftly" init --quiet-shell-followup --assume-yes --skip-install
  rm -rf "${tmpdir}"
fi

# shellcheck disable=SC1091
. "${SWIFTLY_HOME}/env.sh"
hash -r

if ! swiftly list 2>/dev/null | grep -q "Swift"; then
  swiftly install latest --assume-yes
fi
swift --version

log "Fetching pinned GRDB ${GRDB_VERSION} for perfbench"
if [ ! -d "${GRDB_CHECKOUT}/.git" ]; then
  mkdir -p "$(dirname "${GRDB_CHECKOUT}")"
  git clone --quiet --branch "v${GRDB_VERSION}" --depth 1 \
    https://github.com/groue/GRDB.swift.git "${GRDB_CHECKOUT}"
fi
current_rev="$(git -C "${GRDB_CHECKOUT}" rev-parse HEAD)"
if [ "${current_rev}" != "${GRDB_REVISION}" ]; then
  echo "warning: GRDB checkout at ${current_rev}, expected ${GRDB_REVISION}" >&2
fi

log "Building the perfbench package"
(cd "${REPO_ROOT}/scripts/perfbench" && swift build -c release)

log "Environment ready"
echo "Run the DB/search benchmark with:"
echo "  cd scripts/perfbench && swift run -c release perfbench --count 20000"
echo "Run the correctness assertions with:"
echo "  cd scripts/perfbench && swift run -c release perfbench --semantics-check"
