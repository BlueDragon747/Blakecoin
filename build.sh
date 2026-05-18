#!/bin/bash
# =============================================================================
# Blakecoin 0.15.21 Build Script  -  All Platforms
#
# Single self-contained script to build Blakecoin daemon and/or Qt wallet
# for Linux, macOS, Windows, and AppImage.
#
# Based on Bitcoin Core 0.15.2  -  uses autotools (./configure + make).
# Windows cross-compilation still uses pre-built libraries in the Docker image.
# macOS cross-compilation now defaults to a depends + CONFIG_SITE flow inside
# the Docker image, with the older pre-built-libs path kept as a fallback.
#
# Usage: ./build.sh [PLATFORM] [TARGET] [OPTIONS]
#   See ./build.sh --help for full usage.
#
# Docker Hub images (prebuilt):
#   sidgrip/native-base:20.04      -  Native Linux (Ubuntu 20.04, GCC 9, Boost 1.71)
#   sidgrip/native-base:22.04      -  Native Linux (Ubuntu 22.04, GCC 11, Boost 1.74)
#   sidgrip/native-base:24.04      -  Native Linux (Ubuntu 24.04, GCC 13, Boost 1.83)
#   sidgrip/native-base:25.10      -  Native Linux (Ubuntu 25.10, GCC 15, Boost 1.88)
#   sidgrip/appimage-base:22.04    -  AppImage builds (Ubuntu 22.04 + appimagetool)
#   sidgrip/mxe-base:latest        -  Windows cross-compile (MXE + MinGW)
#   sidgrip/osxcross-base:sdk-26.2  -  macOS cross-compile (depends + osxcross SDK 26.2)
#
# Repository: https://github.com/BlueDragon747/Blakecoin (branch: master)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_BASE="${OUTPUT_BASE:-$SCRIPT_DIR/outputs}"
COIN_NAME="blakecoin"
COIN_NAME_UPPER="Blakecoin"
DAEMON_NAME="blakecoind"
QT_NAME="blakecoin-qt"
CLI_NAME="blakecoin-cli"
TX_NAME="blakecoin-tx"
VERSION="0.15.21"
REPO_URL="https://github.com/BlueDragon747/Blakecoin.git"
REPO_BRANCH="master"
QT_LINUX_LAUNCHER_SOURCE="$SCRIPT_DIR/contrib/linux-release/blakecoin-qt-launcher.c"
APPIMAGE_PUBLIC_NAME="${COIN_NAME_UPPER}-${VERSION}-x86_64.AppImage"
WINDOWS_ICON_SOURCE_PNG="$SCRIPT_DIR/src/qt/res/icons/bitcoin.png"
WINDOWS_ICON_SOURCE_TESTNET_PNG="$SCRIPT_DIR/src/qt/res/icons/bitcoin_testnet.png"
WINDOWS_EXE_ICON_ICO="$SCRIPT_DIR/src/qt/res/icons/Blakecoin_32.ico"
WINDOWS_EXE_ICON_TESTNET_ICO="$SCRIPT_DIR/src/qt/res/icons/Blakecoin_32_testnet.ico"
WINDOWS_INSTALLER_ICON_ICO="$SCRIPT_DIR/share/pixmaps/Blakecoin.ico"
BDB_PACKAGE_MK="$SCRIPT_DIR/depends/packages/bdb.mk"
BDB_CACHE_ROOT="$SCRIPT_DIR/.cache/bdb"
NATIVE_LINUX_ALL_DEPS=()
NATIVE_LINUX_ALL_DEPS_STR=""
CURRENT_OUTPUT_DIR=""
GENERATE_CONFIG_AFTER_BUILD=0

# Network ports and config
RPC_PORT=8772
P2P_PORT=8773
EXPLORER_API_BASE="https://explorer.blakestream.io/api"
EXPLORER_COIN_ID="blc"
CONFIG_FILE="${COIN_NAME}.conf"
LISTEN='listen=1'
DAEMON='daemon=1'
SERVER='server=1'
TXINDEX='txindex=0'

# Docker images
DOCKER_NATIVE="${DOCKER_NATIVE:-sidgrip/native-base:24.04}"
DOCKER_APPIMAGE="${DOCKER_APPIMAGE:-sidgrip/appimage-base:22.04}"
DOCKER_WINDOWS="${DOCKER_WINDOWS:-sidgrip/mxe-base:latest}"
DOCKER_MACOS="${DOCKER_MACOS:-sidgrip/osxcross-base:sdk-26.2}"

# Cross-compile host triplets
WIN_HOST="x86_64-w64-mingw32.static"
MAC_HOST=""  # Auto-detected from Docker image at build time

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# Fix execute permissions after copying source tree (rsync/cp can lose +x bits)
fix_permissions() {
    local dir="$1"
    find "$dir" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
    find "$dir" -name 'config.guess' -o -name 'config.sub' -o -name 'install-sh' \
        -o -name 'missing' -o -name 'compile' -o -name 'depcomp' \
        -o -name 'build_detect_platform' -o -name 'autogen.sh' \
        | xargs chmod +x 2>/dev/null || true
}

copy_source_tree_to_tempdir() {
    local dest="$1"

    rsync -a \
        --exclude '.git' \
        --exclude 'outputs' \
        --exclude 'staging' \
        --exclude '.cache' \
        --exclude '.electrum-builds' \
        --exclude '.ubuntu-builds' \
        "$SCRIPT_DIR"/ "$dest/"
}

clean_stale_build_artifacts() {
    local dir="$1"

    # Container cross-builds copy the working tree as-is, so stale autotools and
    # libtool outputs from prior native builds can make make believe targets are
    # already satisfied even when their companion objects are missing.
    find "$dir" -type d \( -name '.deps' -o -name '.libs' -o -name 'autom4te.cache' \) \
        -prune -exec rm -rf {} + 2>/dev/null || true

    find "$dir" -type f \( \
        -name 'config.status' -o \
        -name 'config.log' -o \
        -name 'config.cache' -o \
        -name 'libtool' -o \
        -name '*.o' -o \
        -name '*.lo' -o \
        -name '*.la' -o \
        -name '*.obj' -o \
        -name '*.a' -o \
        -name '*.exe' -o \
        -name '*.res' -o \
        -name '*.pdb' -o \
        -name '*.Tpo' -o \
        -name '*.Plo' -o \
        -name '*.Po' -o \
        -name '*.trs' -o \
        -name '*.dirstamp' \
    \) -delete 2>/dev/null || true

    # Cross-builds should regenerate Qt/protobuf build products with the
    # container's own moc/uic/rcc/protoc so host-generated files don't leak in.
    find "$dir/src/qt" -maxdepth 1 -type f \( \
        -name '*.moc' -o \
        -name 'moc_*.cpp' -o \
        -name 'paymentrequest.pb.cc' -o \
        -name 'paymentrequest.pb.h' \
    \) -delete 2>/dev/null || true

    find "$dir/src/qt/forms" -maxdepth 1 -type f -name 'ui_*.h' \
        -delete 2>/dev/null || true
}

# Portable sed -i wrapper (macOS BSD sed requires '' arg, GNU sed does not)
sedi() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

sync_windows_icon_assets() {
    if ! command -v python3 &>/dev/null; then
        warn "python3 not found; using checked-in Windows icon assets."
        return 0
    fi

    if ! python3 -c 'from PIL import Image' >/dev/null 2>&1; then
        warn "python3-pil not found; using checked-in Windows icon assets."
        return 0
    fi

    info "Regenerating Windows icon assets from repo bitcoin.png sources..."
    python3 - <<PY
from PIL import Image

sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
targets = [
    ("$WINDOWS_ICON_SOURCE_PNG", "$WINDOWS_EXE_ICON_ICO"),
    ("$WINDOWS_ICON_SOURCE_PNG", "$WINDOWS_INSTALLER_ICON_ICO"),
    ("$WINDOWS_ICON_SOURCE_TESTNET_PNG", "$WINDOWS_EXE_ICON_TESTNET_ICO"),
]

for src, dst in targets:
    img = Image.open(src).convert("RGBA")
    img.save(dst, format="ICO", sizes=sizes)
    print(f"    generated {dst} from {src}")
PY
}

ensure_windows_icon_assets() {
    local missing=()
    local path

    sync_windows_icon_assets

    for path in \
        "$WINDOWS_ICON_SOURCE_PNG" \
        "$WINDOWS_ICON_SOURCE_TESTNET_PNG" \
        "$WINDOWS_EXE_ICON_ICO" \
        "$WINDOWS_EXE_ICON_TESTNET_ICO" \
        "$WINDOWS_INSTALLER_ICON_ICO"
    do
        [[ -f "$path" ]] || missing+=("$path")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required Windows icon asset(s):"
        printf '  %s\n' "${missing[@]}"
        exit 1
    fi

    info "Windows branding source (main): $WINDOWS_ICON_SOURCE_PNG"
    info "Windows branding source (testnet): $WINDOWS_ICON_SOURCE_TESTNET_PNG"
    info "Windows embedded exe icon (main): $WINDOWS_EXE_ICON_ICO"
    info "Windows embedded exe icon (testnet): $WINDOWS_EXE_ICON_TESTNET_ICO"
    info "Windows installer icon: $WINDOWS_INSTALLER_ICON_ICO"
}

ensure_macos_brew_env() {
    local brew_bin=""

    if command -v brew &>/dev/null; then
        brew_bin=$(command -v brew)
    else
        for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew "$HOME/homebrew/bin/brew"; do
            [[ -x "$brew_bin" ]] && break
        done
    fi

    if [[ -n "$brew_bin" && -x "$brew_bin" ]]; then
        eval "$("$brew_bin" shellenv)" >/dev/null 2>&1 || true
        export PATH="$(dirname "$brew_bin"):$PATH"
        return 0
    fi

    return 1
}

prime_macos_sudo() {
    if sudo -n true 2>/dev/null; then
        return 0
    fi

    if [[ -n "${MACOS_SUDO_PASS:-}" ]]; then
        printf '%s\n' "$MACOS_SUDO_PASS" | sudo -S -p '' -v
    else
        sudo -v
    fi
}

ensure_macos_homebrew() {
    if ensure_macos_brew_env; then
        return 0
    fi

    info "Homebrew not found  -  installing it automatically..."
    prime_macos_sudo
    NONINTERACTIVE=1 CI=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    if ! ensure_macos_brew_env; then
        error "Homebrew installation completed but brew is still not available."
        exit 1
    fi
}

usage() {
    cat <<'EOF'
Usage: build.sh [PLATFORM] [TARGET] [OPTIONS]

Platforms:
  --native          Build natively on this machine (Linux, macOS, or Windows)
  --appimage        Build portable Linux AppImage (requires Docker)
  --windows         Cross-compile for Windows from Linux (requires Docker)
  --macos           Cross-compile for macOS from Linux (requires Docker)

Targets:
  --daemon          Build daemon only (blakecoind + blakecoin-cli + blakecoin-tx)
  --qt              Build Qt wallet only (blakecoin-qt)
  --both            Build daemon and Qt wallet (default)

Docker options (for --appimage, --windows, --macos, or --native on Linux):
  --pull-docker     Pull prebuilt Docker images from Docker Hub
  --build-docker    Build Docker images locally from repo Dockerfiles
  --no-docker       For --native on Linux: skip Docker, build directly on host

Other options:
  --jobs N          Parallel make jobs (default: CPU cores - 1)
  -h, --help        Show this help

Examples:
  # Native builds (no Docker needed)
  ./build.sh --native --both                   # Build directly on host
  ./build.sh --native --daemon                 # Daemon only

  # Native Linux with Docker
  ./build.sh --native --both --pull-docker     # Use appimage-base from Docker Hub
  ./build.sh --native --both --build-docker    # Same as --pull-docker (shared images)

  # Cross-compile (Docker required  -  choose --pull-docker or --build-docker)
  ./build.sh --windows --qt --pull-docker      # Pull mxe-base from Docker Hub
  ./build.sh --macos --qt --pull-docker        # Pull osxcross-base from Docker Hub
  ./build.sh --appimage --pull-docker          # Pull appimage-base from Docker Hub

Docker Hub images (used with --pull-docker):
  sidgrip/native-base:20.04             Native Linux (Ubuntu 20.04, GCC 9)
  sidgrip/native-base:22.04             Native Linux (Ubuntu 22.04, GCC 11)
  sidgrip/native-base:24.04             Native Linux (Ubuntu 24.04, GCC 13) [default]
  sidgrip/native-base:25.10             Native Linux (Ubuntu 25.10, GCC 15)
  sidgrip/appimage-base:22.04           AppImage (Ubuntu 22.04 + appimagetool)
  sidgrip/mxe-base:latest               Windows cross-compile (MXE + MinGW)
  sidgrip/osxcross-base:sdk-26.2        macOS cross-compile (depends + osxcross SDK 26.2) [default]
EOF
    exit 0
}

detect_os() {
    if [[ "${MSYSTEM:-}" =~ MINGW|MSYS ]]; then
        echo "windows"
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        echo "macos"
    else
        echo "linux"
    fi
}

detect_os_version() {
    local os="$1"
    case "$os" in
        linux)
            if command -v lsb_release &>/dev/null; then
                lsb_release -ds 2>/dev/null
            elif [[ -f /etc/os-release ]]; then
                . /etc/os-release && echo "${PRETTY_NAME:-$NAME $VERSION_ID}"
            else
                echo "Linux $(uname -r)"
            fi
            ;;
        macos)
            echo "macOS $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
            ;;
        windows)
            if [[ -n "${MSYSTEM:-}" ]]; then
                echo "$MSYSTEM / Windows $(uname -r 2>/dev/null || echo 'unknown')"
            else
                echo "Windows"
            fi
            ;;
    esac
}

normalize_ubuntu_output_label() {
    local ubuntu_ver="${1:-unknown}"

    case "$ubuntu_ver" in
        20.04*) echo "Ubuntu-20" ;;
        22.04*) echo "Ubuntu-22" ;;
        24.04*) echo "Ubuntu-24" ;;
        25.10*) echo "Ubuntu-25" ;;
        *)
            local major="${ubuntu_ver%%.*}"
            if [[ -n "$major" && "$major" != "$ubuntu_ver" ]]; then
                echo "Ubuntu-$major"
            elif [[ "$ubuntu_ver" =~ ^[0-9]+$ ]]; then
                echo "Ubuntu-$ubuntu_ver"
            else
                echo "Ubuntu"
            fi
            ;;
    esac
}

linux_output_dir() {
    local ubuntu_ver="${1:-unknown}"
    printf '%s/%s\n' "$OUTPUT_BASE" "$(normalize_ubuntu_output_label "$ubuntu_ver")"
}

windows_output_dir() {
    printf '%s/Windows\n' "$OUTPUT_BASE"
}

macos_output_dir() {
    printf '%s/Macosx\n' "$OUTPUT_BASE"
}

appimage_output_dir() {
    printf '%s/AppImage\n' "$OUTPUT_BASE"
}

cleanup_target_output_dir() {
    local output_dir="$1"

    rm -rf "$output_dir"
    mkdir -p "$output_dir"
}

cleanup_legacy_output_root() {
    mkdir -p "$OUTPUT_BASE"

    rm -f \
        "$OUTPUT_BASE/$DAEMON_NAME" \
        "$OUTPUT_BASE/$CLI_NAME" \
        "$OUTPUT_BASE/$TX_NAME" \
        "$OUTPUT_BASE/$QT_NAME" \
        "$OUTPUT_BASE/${QT_NAME}-bin" \
        "$OUTPUT_BASE/${DAEMON_NAME}.exe" \
        "$OUTPUT_BASE/${CLI_NAME}.exe" \
        "$OUTPUT_BASE/${TX_NAME}.exe" \
        "$OUTPUT_BASE/${QT_NAME}.exe" \
        "$OUTPUT_BASE/${DAEMON_NAME}-${VERSION}" \
        "$OUTPUT_BASE/${CLI_NAME}-${VERSION}" \
        "$OUTPUT_BASE/${TX_NAME}-${VERSION}" \
        "$OUTPUT_BASE/${QT_NAME}-${VERSION}" \
        "$OUTPUT_BASE/${DAEMON_NAME}-${VERSION}.exe" \
        "$OUTPUT_BASE/${CLI_NAME}-${VERSION}.exe" \
        "$OUTPUT_BASE/${TX_NAME}-${VERSION}.exe" \
        "$OUTPUT_BASE/${QT_NAME}-${VERSION}.exe" \
        "$OUTPUT_BASE/install-deps.sh" \
        "$OUTPUT_BASE/${COIN_NAME}.desktop" \
        "$OUTPUT_BASE/${COIN_NAME}-256.png" \
        "$OUTPUT_BASE/blakecoin.conf" \
        "$OUTPUT_BASE/qt.conf" \
        "$OUTPUT_BASE/README.md" \
        "$OUTPUT_BASE/build-info.txt"

    rm -rf \
        "$OUTPUT_BASE/.runtime" \
        "$OUTPUT_BASE/lib" \
        "$OUTPUT_BASE/plugins" \
        "$OUTPUT_BASE/platforms" \
        "$OUTPUT_BASE/Blakecoin-Qt.app" \
        "$OUTPUT_BASE/native" \
        "$OUTPUT_BASE/windows" \
        "$OUTPUT_BASE/macos" \
        "$OUTPUT_BASE/windows-native" \
        "$OUTPUT_BASE/macos-native" \
        "$OUTPUT_BASE/daemon" \
        "$OUTPUT_BASE/qt" \
        "$OUTPUT_BASE/appimage" \
        "$OUTPUT_BASE/release"

    shopt -s nullglob
    local stale_dlls=("$OUTPUT_BASE"/*.dll)
    local stale_ubuntu_dirs=("$OUTPUT_BASE"/blakecoin-v${VERSION}-ubuntu-*-x86_64 "$OUTPUT_BASE"/blakecoin-v${VERSION}-ubuntu-*-x86_64-daemon "$OUTPUT_BASE"/blakecoin-v${VERSION}-ubuntu-*-x86_64-qt)
    local stale_ubuntu_archives=("$OUTPUT_BASE"/blakecoin-v${VERSION}-ubuntu-*-x86_64.tar.gz)
    shopt -u nullglob

    if [[ ${#stale_dlls[@]} -gt 0 ]]; then
        rm -f "${stale_dlls[@]}"
    fi
    if [[ ${#stale_ubuntu_dirs[@]} -gt 0 ]]; then
        rm -rf "${stale_ubuntu_dirs[@]}"
    fi
    if [[ ${#stale_ubuntu_archives[@]} -gt 0 ]]; then
        rm -f "${stale_ubuntu_archives[@]}"
    fi
}

bdb_recipe_version() {
    awk -F= '/^\$\(package\)_version=/{print $2}' "$BDB_PACKAGE_MK"
}

bdb_recipe_sha256() {
    awk -F= '/^\$\(package\)_sha256_hash=/{print $2}' "$BDB_PACKAGE_MK"
}

sha256_file() {
    local file="$1"

    if command -v sha256sum &>/dev/null; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        error "No SHA256 tool found (need sha256sum or shasum)"
        exit 1
    fi
}

native_bdb48_prefix() {
    local host_id="$1"
    printf '%s/4.8/%s\n' "$BDB_CACHE_ROOT" "$host_id"
}

ensure_repo_bdb48() {
    local platform="$1"
    local host_id="$2"
    local jobs="$3"
    local prefix=""
    local prefix_tmp=""
    local sources_dir=""
    local build_root=""
    local version=""
    local sha256=""
    local archive_name=""
    local archive_path=""
    local dist_name=""
    local build_dir=""
    local machine=""
    local actual_sha=""
    local configure_cmd=()

    prefix="$(native_bdb48_prefix "$host_id")"
    prefix_tmp="${prefix}.tmp"
    sources_dir="$BDB_CACHE_ROOT/sources"
    build_root="$BDB_CACHE_ROOT/work/$host_id"
    version="$(bdb_recipe_version)"
    sha256="$(bdb_recipe_sha256)"
    archive_name="db-${version}.NC.tar.gz"
    archive_path="$sources_dir/$archive_name"
    dist_name="db-${version}.NC"
    build_dir="$build_root/$dist_name/build_unix"

    if [[ -f "$prefix/include/db_cxx.h" && -f "$prefix/lib/libdb_cxx-4.8.a" && -f "$prefix/lib/libdb-4.8.a" ]]; then
        echo "$prefix"
        return 0
    fi

    mkdir -p "$sources_dir" "$(dirname "$prefix")"

    if [[ ! -f "$archive_path" ]]; then
        info "Downloading Berkeley DB 4.8.30.NC source..." >&2
        curl -L "https://download.oracle.com/berkeley-db/$archive_name" -o "${archive_path}.tmp"
        mv "${archive_path}.tmp" "$archive_path"
    fi

    actual_sha="$(sha256_file "$archive_path")"
    if [[ "$actual_sha" != "$sha256" ]]; then
        error "Berkeley DB source hash mismatch for $archive_name" >&2
        error "Expected: $sha256" >&2
        error "Actual:   $actual_sha" >&2
        exit 1
    fi

    info "Bootstrapping Berkeley DB 4.8.30.NC for $host_id..." >&2
    rm -rf "$build_root" "$prefix_tmp"
    mkdir -p "$build_root"
    tar -xzf "$archive_path" -C "$build_root"

    pushd "$build_dir" >/dev/null

    sed -i.bak 's/__atomic_compare_exchange/__atomic_compare_exchange_db/g' ../dbinc/atomic.h
    while IFS= read -r -d '' source_file; do
        sed -i.bak 's/\batomic_init\b/bdb_atomic_init/g' "$source_file"
    done < <(find .. \( -name '*.h' -o -name '*.c' -o -name '*.cpp' \) -print0)
    find .. -name '*.bak' -delete 2>/dev/null || true
    cp -f "$SCRIPT_DIR/depends/config.guess" "$SCRIPT_DIR/depends/config.sub" ../dist/

    configure_cmd=(
        ../dist/configure
        --prefix="$prefix_tmp"
        --enable-cxx
        --disable-shared
        --disable-replication
        --disable-atomicsupport
    )

    case "$platform" in
        linux)
            configure_cmd+=(--with-pic --with-mutex=POSIX/pthreads)
            ;;
        mingw)
            machine="$(gcc -dumpmachine 2>/dev/null || true)"
            [[ -n "$machine" ]] && configure_cmd+=(--host="$machine")
            configure_cmd+=(--enable-mingw)
            ;;
        *)
            error "Unsupported Berkeley DB bootstrap platform: $platform" >&2
            exit 1
            ;;
    esac

    env CFLAGS="-O2" CXXFLAGS="-O2 -std=c++11" "${configure_cmd[@]}" >&2
    make -j"$jobs" libdb_cxx-4.8.a libdb-4.8.a >&2

    mkdir -p "$prefix_tmp/lib" "$prefix_tmp/include"

    if [[ ! -f db.h || ! -f db_cxx.h ]]; then
        error "Failed to locate Berkeley DB headers in $build_dir" >&2
        exit 1
    fi

    cp -f db.h "$prefix_tmp/include/db.h"
    cp -f db_cxx.h "$prefix_tmp/include/db_cxx.h"
    cp -f libdb-4.8.a "$prefix_tmp/lib/libdb-4.8.a"
    cp -f libdb_cxx-4.8.a "$prefix_tmp/lib/libdb_cxx-4.8.a"

    if [[ -f libdb.a ]]; then
        cp -f libdb.a "$prefix_tmp/lib/libdb.a"
    else
        cp -f libdb-4.8.a "$prefix_tmp/lib/libdb.a"
    fi

    if [[ -f libdb_cxx.a ]]; then
        cp -f libdb_cxx.a "$prefix_tmp/lib/libdb_cxx.a"
    else
        cp -f libdb_cxx-4.8.a "$prefix_tmp/lib/libdb_cxx.a"
    fi

    popd >/dev/null

    rm -rf "$prefix"
    mv "$prefix_tmp" "$prefix"
    rm -rf "$build_root"

    echo "$prefix"
}

verify_bdb48_prefix() {
    local prefix="$1"
    local label="$2"

    if [[ ! -f "$prefix/include/db_cxx.h" ]]; then
        error "$label is missing Berkeley DB 4.8 headers at $prefix/include/db_cxx.h"
        return 1
    fi

    if ! compgen -G "$prefix/lib/libdb_cxx-4.8*" >/dev/null; then
        error "$label is missing Berkeley DB 4.8 C++ libraries under $prefix/lib"
        return 1
    fi

    if ! compgen -G "$prefix/lib/libdb-4.8*" >/dev/null; then
        error "$label is missing Berkeley DB 4.8 libraries under $prefix/lib"
        return 1
    fi
}

native_linux_link_command() {
    local target="$1"
    local cmd=""

    pushd "$SCRIPT_DIR/src" >/dev/null
    cmd="$(make -n V=1 "$target" 2>/dev/null | awk '/\/libtool[[:space:]].*--mode=link/ { line=$0 } END { if (line != "") print line; else exit 1 }')"
    popd >/dev/null

    [[ -n "$cmd" ]] || return 1
    printf '%s\n' "$cmd"
}

relink_native_linux_target() {
    local target="$1"
    local artifact="$2"
    local cmd=""

    cmd="$(native_linux_link_command "$target")" || {
        error "Failed to capture native Linux link command for $target"
        return 1
    }

    pushd "$SCRIPT_DIR/src" >/dev/null
    bash -lc "$cmd" >/dev/null
    popd >/dev/null

    if objdump -p "$artifact" 2>/dev/null | grep -Eq 'libdb(_cxx)?-5\.3\.so'; then
        error "Native Linux post-link verification failed for $artifact"
        return 1
    fi
}

ensure_windows_native_shell() {
    local target="$1"
    local jobs="$2"
    local msys_root="/c/msys64"
    local msys_bash="$msys_root/usr/bin/bash.exe"
    local msys_env="$msys_root/usr/bin/env.exe"
    local target_flag="--both"
    local reexec_cmd=""

    case "$target" in
        daemon) target_flag="--daemon" ;;
        qt)     target_flag="--qt" ;;
        both)   target_flag="--both" ;;
    esac

    if [[ "${MSYSTEM:-}" == "MINGW64" ]] && command -v pacman &>/dev/null; then
        return 0
    fi

    if ! command -v powershell.exe &>/dev/null; then
        error "PowerShell is required to bootstrap native Windows builds."
        exit 1
    fi

    if [[ ! -x "$msys_bash" || ! -x "$msys_env" ]]; then
        info "MSYS2 not found  -  installing it automatically..."
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '
            $ErrorActionPreference = "Stop"
            $msysUrl = "https://github.com/msys2/msys2-installer/releases/download/nightly-x86_64/msys2-base-x86_64-latest.sfx.exe"
            $msysExe = "$env:TEMP\msys2-base-x86_64-latest.sfx.exe"
            Invoke-WebRequest -UseBasicParsing -Uri $msysUrl -OutFile $msysExe
            & $msysExe "-y" "-oC:\"
        '
    fi

    if [[ ! -x "$msys_bash" || ! -x "$msys_env" ]]; then
        error "MSYS2 installation did not produce $msys_bash"
        exit 1
    fi

    info "Initializing MSYS2..."
    "$msys_env" MSYSTEM=MINGW64 CHERE_INVOKING=yes MSYS2_PATH_TYPE=inherit \
        "$msys_bash" -lc '
            set +e
            pacman-key --init >/dev/null 2>&1
            pacman-key --populate msys2 >/dev/null 2>&1
            pacman --noconfirm -Sy >/dev/null 2>&1
            pacman --noconfirm -Syuu >/dev/null 2>&1
            pacman --noconfirm -Syuu >/dev/null 2>&1
            exit 0
        '

    printf -v reexec_cmd 'cd %q && ./build.sh --native %s --jobs %q' "$SCRIPT_DIR" "$target_flag" "$jobs"
    info "Re-entering build.sh inside MSYS2 MINGW64..."
    exec "$msys_env" MSYSTEM=MINGW64 CHERE_INVOKING=yes MSYS2_PATH_TYPE=inherit \
        "$msys_bash" -lc "$reexec_cmd"
}

write_build_info() {
    local output_dir="$1"
    local platform="$2"
    local target="$3"
    local os_version="$4"

    mkdir -p "$output_dir"
    cat > "$output_dir/build-info.txt" <<EOF
Coin:       $COIN_NAME_UPPER 0.15.21
Target:     $target
Platform:   $platform
OS:         $os_version
Date:       $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Branch:     $REPO_BRANCH
Script:     build.sh
EOF
}

copy_runtime_libs() {
    local binary="$1"
    local dest_dir="$2"

    mkdir -p "$dest_dir"
    while IFS= read -r lib; do
        [[ -n "$lib" && -r "$lib" ]] || continue
        case "$(basename "$lib")" in
            ld-linux-*|libc.so.*|libdl.so.*|libm.so.*|libpthread.so.*|librt.so.*|libresolv.so.*|libutil.so.*|libnsl.so.*|libanl.so.*)
                continue
                ;;
        esac
        cp -Lf "$lib" "$dest_dir/"
    done < <(
        ldd "$binary" 2>/dev/null | awk '
            /=> \// {print $3}
            /^\// {print $1}
        ' | sort -u
    )
}

is_macos_system_dylib() {
    case "$1" in
        /System/Library/*|/usr/lib/*)
            return 0
            ;;
    esac
    return 1
}

resolve_macos_bundle_dep_target() {
    local dep="$1"
    local subject="$2"
    local main_exe_dir="$3"
    local frameworks_dir="$4"

    case "$dep" in
        @executable_path/*)
            printf '%s\n' "$main_exe_dir/${dep#@executable_path/}"
            ;;
        @loader_path/*)
            printf '%s\n' "$(dirname "$subject")/${dep#@loader_path/}"
            ;;
        @rpath/*)
            local rel="${dep#@rpath/}"
            if [[ -e "$frameworks_dir/$rel" ]]; then
                printf '%s\n' "$frameworks_dir/$rel"
            else
                printf '%s\n' "$frameworks_dir/$(basename "$dep")"
            fi
            ;;
        *)
            printf '%s\n' "$dep"
            ;;
    esac
}

find_macos_source_dylib() {
    local dylib_name="$1"
    shift

    local search_dir=""
    for search_dir in "$@"; do
        [[ -n "$search_dir" && -d "$search_dir" ]] || continue
        if [[ -f "$search_dir/$dylib_name" ]]; then
            printf '%s\n' "$search_dir/$dylib_name"
            return 0
        fi
    done

    return 1
}

bundle_macos_transitive_dylibs() {
    local app_dir="$1"
    shift

    local frameworks_dir="$app_dir/Contents/Frameworks"
    local main_exe_dir="$app_dir/Contents/MacOS"
    local main_exe="$main_exe_dir/Blakecoin-Qt"
    local search_dirs=("$@")
    local pass=0
    local changed=1

    [[ -f "$main_exe" && -d "$frameworks_dir" ]] || return 0

    while [[ $changed -eq 1 && $pass -lt 10 ]]; do
        changed=0
        pass=$((pass + 1))

        local subject=""
        local dep=""
        local dep_target=""
        local dep_name=""
        local source_lib=""
        local bundled_lib=""
        local new_ref=""
        while IFS= read -r subject; do
            [[ -f "$subject" ]] || continue
            while IFS= read -r dep; do
                [[ -n "$dep" ]] || continue
                if is_macos_system_dylib "$dep"; then
                    continue
                fi

                dep_target=$(resolve_macos_bundle_dep_target "$dep" "$subject" "$main_exe_dir" "$frameworks_dir")
                if [[ -n "$dep_target" && -e "$dep_target" ]]; then
                    continue
                fi

                dep_name=$(basename "$dep")
                source_lib=$(find_macos_source_dylib "$dep_name" "${search_dirs[@]}" || true)
                [[ -n "$source_lib" ]] || continue

                bundled_lib="$frameworks_dir/$dep_name"
                if [[ ! -f "$bundled_lib" ]]; then
                    cp -f "$source_lib" "$bundled_lib"
                    chmod u+w "$bundled_lib" 2>/dev/null || true
                    install_name_tool -id "@executable_path/../Frameworks/$dep_name" "$bundled_lib" 2>/dev/null || true
                    changed=1
                fi

                if [[ "$subject" == "$main_exe" ]]; then
                    new_ref="@executable_path/../Frameworks/$dep_name"
                else
                    new_ref="@loader_path/$dep_name"
                fi
                install_name_tool -change "$dep" "$new_ref" "$subject" 2>/dev/null || true
            done < <(otool -L "$subject" 2>/dev/null | tail -n +2 | awk '{print $1}')
        done < <(
            printf '%s\n' "$main_exe"
            find "$frameworks_dir" -maxdepth 1 -type f -name '*.dylib' | sort
        )
    done
}

compile_linux_qt_launcher() {
    local output_path="$1"
    local target_rel="${2:-.runtime/${QT_NAME}-bin}"
    local use_runtime_env="${3:-1}"
    local force_docker="${4:-0}"
    local launcher_cc="${CC:-}"
    local output_dir=""
    local output_name=""
    local gcc_args=(
        -O2
        -s
        -Wall
        -Wextra
        -no-pie
        "-DBLAKECOIN_QT_LAUNCH_TARGET=\"${target_rel}\""
        "-DBLAKECOIN_QT_USE_RUNTIME_ENV=${use_runtime_env}"
    )

    [[ -f "$QT_LINUX_LAUNCHER_SOURCE" ]] || {
        error "Linux Qt launcher source not found: $QT_LINUX_LAUNCHER_SOURCE"
        exit 1
    }

    if [[ "$force_docker" != "1" && -z "$launcher_cc" ]]; then
        for candidate in gcc cc clang; do
            if command -v "$candidate" >/dev/null 2>&1; then
                launcher_cc="$candidate"
                break
            fi
        done
    fi

    if [[ "$force_docker" == "1" || -z "$launcher_cc" ]]; then
        if command -v docker >/dev/null 2>&1 && [[ -n "${DOCKER_NATIVE:-}" ]]; then
            output_dir="$(cd "$(dirname "$output_path")" && pwd)"
            output_name="$(basename "$output_path")"
            docker run --rm \
                -u "$(id -u):$(id -g)" \
                -e BLAKECOIN_QT_LAUNCH_TARGET="$target_rel" \
                -e BLAKECOIN_QT_USE_RUNTIME_ENV="$use_runtime_env" \
                -e BLAKECOIN_QT_LAUNCH_OUTPUT="$output_name" \
                -v "$SCRIPT_DIR:/repo:ro" \
                -v "$output_dir:/out" \
                "$DOCKER_NATIVE" \
                /bin/bash -lc '
set -e
compiler=""
for candidate in "${CC:-}" gcc cc clang; do
    if [[ -n "$candidate" ]] && command -v "$candidate" >/dev/null 2>&1; then
        compiler="$candidate"
        break
    fi
done

[[ -n "$compiler" ]] || {
    echo "No usable C compiler found in Linux launcher fallback container" >&2
    exit 1
}

"$compiler" -O2 -s -Wall -Wextra -no-pie \
    "-DBLAKECOIN_QT_LAUNCH_TARGET=\"${BLAKECOIN_QT_LAUNCH_TARGET}\"" \
    "-DBLAKECOIN_QT_USE_RUNTIME_ENV=${BLAKECOIN_QT_USE_RUNTIME_ENV}" \
    /repo/contrib/linux-release/blakecoin-qt-launcher.c \
    -o "/out/${BLAKECOIN_QT_LAUNCH_OUTPUT}"
'
        else
            error "No usable C compiler found for the Linux Qt launcher helper"
            exit 1
        fi
        chmod +x "$output_path"
        return
    fi

    # Ubuntu 20's default PIE launcher gets classified as application/x-sharedlib
    # in GNOME, so force a normal executable for release-click behavior.
    "$launcher_cc" "${gcc_args[@]}" "$QT_LINUX_LAUNCHER_SOURCE" -o "$output_path"
    chmod +x "$output_path"
}

write_linux_release_desktop() {
    local desktop_path="$1"

    cat > "$desktop_path" <<EOF
[Desktop Entry]
Type=Application
Name=Blakecoin Qt
Comment=Blakecoin Cryptocurrency Wallet
Exec=blakecoin-qt
Icon=blakecoin-qt
Terminal=false
Categories=Finance;Network;
EOF
}

resolve_native_linux_packages() {
    local target="$1"
    local qt_deps=()

    NATIVE_LINUX_ALL_DEPS=(
        build-essential
        libtool-bin
        autotools-dev
        automake
        pkg-config
        curl
        libssl-dev
        libevent-dev
        libminiupnpc-dev
        libzmq5
        libprotobuf-dev
        protobuf-compiler
        libboost-all-dev
    )

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        qt_deps=(qtbase5-dev qttools5-dev qttools5-dev-tools libqrencode-dev)
        NATIVE_LINUX_ALL_DEPS+=("${qt_deps[@]}")
    fi

    NATIVE_LINUX_ALL_DEPS_STR="${NATIVE_LINUX_ALL_DEPS[*]}"
}

write_linux_install_deps_script() {
    local script_path="$1"
    local install_packages="$2"

    cat > "$script_path" <<EOF
#!/bin/bash
set -euo pipefail

sudo apt-get update -qq
sudo apt-get install -y -qq ${install_packages}
EOF
    chmod +x "$script_path"
}

write_linux_release_readme() {
    local readme_path="$1"
    local ubuntu_ver="$2"
    local target="${3:-both}"
    local install_packages="${4:-}"
    local qt_launcher_note=""
    local qt_copy_block="cp blakecoin-qt ~/.local/bin/"
    local qt_desktop_note=""

    if [[ "$ubuntu_ver" == 20.04* ]]; then
        qt_launcher_note=$'\nUbuntu 20.04 keeps `blakecoin-qt` as a tiny launcher beside `blakecoin-qt-bin` so GNOME treats it like an app instead of a shared library. Keep those two files together.\n'
        qt_copy_block=$'cp blakecoin-qt blakecoin-qt-bin ~/.local/bin/'
        qt_desktop_note=$'\nOn Ubuntu 20.04, copy `blakecoin-qt-bin` beside it too.\n'
    fi

    case "$target" in
        daemon)
            cat > "$readme_path" <<EOF
# Blakecoin v${VERSION} - Linux x86_64 (Ubuntu ${ubuntu_ver})

## Quick Start

These are bare Ubuntu-native daemon binaries. Install the native Ubuntu packages first if this host does not already have them.

### Install native Ubuntu runtime dependencies:
\`\`\`bash
chmod +x install-deps.sh
./install-deps.sh
\`\`\`

Berkeley DB 4.8 is already handled by the build and is not installed from apt.

Equivalent apt command:
\`\`\`bash
sudo apt-get update -qq
sudo apt-get install -y -qq ${install_packages}
\`\`\`

### Start the daemon:
\`\`\`bash
./blakecoind -daemon
./blakecoin-cli getinfo
\`\`\`

### Transaction utility:
\`\`\`bash
./blakecoin-tx -help
\`\`\`

## Installation (optional)

\`\`\`bash
cp blakecoind blakecoin-cli blakecoin-tx ~/.local/bin/
\`\`\`

After the native packages are installed, the daemon tools can live outside this folder.

## Configuration

On first run, a config file will be generated at \`~/.blakecoin/blakecoin.conf\` with random RPC credentials and peer nodes.

- P2P port: 8773
- RPC port: 8772

## Build Info

Built on Ubuntu ${ubuntu_ver}.
EOF
            ;;
        qt)
            cat > "$readme_path" <<EOF
# Blakecoin v${VERSION} - Linux x86_64 (Ubuntu ${ubuntu_ver})

## Quick Start

This is a bare Ubuntu-native Qt wallet binary. Install the native Ubuntu packages first if this host does not already have them.
${qt_launcher_note}

### Install native Ubuntu runtime dependencies:
\`\`\`bash
chmod +x install-deps.sh
./install-deps.sh
\`\`\`

Berkeley DB 4.8 is already handled by the build and is not installed from apt.

Equivalent apt command:
\`\`\`bash
sudo apt-get update -qq
sudo apt-get install -y -qq ${install_packages}
\`\`\`

### Run the Qt wallet:
\`\`\`bash
./blakecoin-qt
\`\`\`

## Installation (optional)

\`\`\`bash
mkdir -p ~/.local/bin
${qt_copy_block}
\`\`\`

### Install desktop entry and icon:
${qt_desktop_note}

\`\`\`bash
mkdir -p ~/.local/bin
mkdir -p ~/.local/share/applications
mkdir -p ~/.local/share/icons/hicolor/256x256/apps
${qt_copy_block}
cp blakecoin.desktop ~/.local/share/applications/
cp blakecoin-256.png ~/.local/share/icons/hicolor/256x256/apps/blakecoin-qt.png
\`\`\`

## Configuration

On first run, a config file will be generated at \`~/.blakecoin/blakecoin.conf\` with random RPC credentials and peer nodes.

- P2P port: 8773
- RPC port: 8772

## Build Info

Built on Ubuntu ${ubuntu_ver}.
EOF
            ;;
        both)
            cat > "$readme_path" <<EOF
# Blakecoin v${VERSION} - Linux x86_64 (Ubuntu ${ubuntu_ver})

## Quick Start

These are bare Ubuntu-native binaries. Install the native Ubuntu packages first if this host does not already have them.
${qt_launcher_note}

### Install native Ubuntu runtime dependencies:
\`\`\`bash
chmod +x install-deps.sh
./install-deps.sh
\`\`\`

Berkeley DB 4.8 is already handled by the build and is not installed from apt.

Equivalent apt command:
\`\`\`bash
sudo apt-get update -qq
sudo apt-get install -y -qq ${install_packages}
\`\`\`

### Run the Qt wallet:
\`\`\`bash
./blakecoin-qt
\`\`\`

### Run the daemon:
\`\`\`bash
./blakecoind -daemon
./blakecoin-cli getinfo
\`\`\`

## Installation (optional)

### Copy daemon binaries:
\`\`\`bash
mkdir -p ~/.local/bin
cp blakecoind blakecoin-cli blakecoin-tx ~/.local/bin/
\`\`\`

### Install the Qt wallet:
\`\`\`bash
mkdir -p ~/.local/bin
${qt_copy_block}
\`\`\`

### Install desktop entry and icon:

This step only adds a Show Apps / application-menu launcher. Copy \`blakecoin-qt\` into \`~/.local/bin/\` first so the desktop entry resolves correctly.
${qt_desktop_note}

\`\`\`bash
mkdir -p ~/.local/bin
mkdir -p ~/.local/share/applications
mkdir -p ~/.local/share/icons/hicolor/256x256/apps
${qt_copy_block}
cp blakecoin.desktop ~/.local/share/applications/
cp blakecoin-256.png ~/.local/share/icons/hicolor/256x256/apps/blakecoin-qt.png

# Create index.theme if missing
if [ ! -f ~/.local/share/icons/hicolor/index.theme ]; then
    mkdir -p ~/.local/share/icons/hicolor
    echo -e "[Icon Theme]\\nName=Hicolor\\nComment=Fallback Icon Theme\\nDirectories=256x256/apps\\n\\n[256x256/apps]\\nSize=256\\nContext=Applications\\nType=Fixed" > ~/.local/share/icons/hicolor/index.theme
fi

gtk-update-icon-cache ~/.local/share/icons/hicolor/ 2>/dev/null || true
\`\`\`

## Configuration

On first run, a config file will be generated at \`~/.blakecoin/blakecoin.conf\` with random RPC credentials and peer nodes.

- P2P port: 8773
- RPC port: 8772

## Build Info

Built on Ubuntu ${ubuntu_ver}.
EOF
            ;;
        *)
            error "Unknown Linux readme target: $target"
            exit 1
            ;;
    esac
}

cleanup_linux_native_output_root() {
    local stale_paths=()

    mkdir -p "$OUTPUT_BASE"

    rm -f \
        "$OUTPUT_BASE/$DAEMON_NAME" \
        "$OUTPUT_BASE/$CLI_NAME" \
        "$OUTPUT_BASE/$TX_NAME" \
        "$OUTPUT_BASE/$QT_NAME" \
        "$OUTPUT_BASE/${QT_NAME}-bin" \
        "$OUTPUT_BASE/install-deps.sh" \
        "$OUTPUT_BASE/${COIN_NAME}.desktop" \
        "$OUTPUT_BASE/${COIN_NAME}-256.png" \
        "$OUTPUT_BASE/README.md"
    rm -rf "$OUTPUT_BASE/.runtime" "$OUTPUT_BASE/lib" "$OUTPUT_BASE/plugins"
    rm -rf "$OUTPUT_BASE/native"

    shopt -s nullglob
    stale_paths=(
        "$OUTPUT_BASE"/blakecoin-v${VERSION}-ubuntu-*-x86_64
        "$OUTPUT_BASE"/blakecoin-v${VERSION}-ubuntu-*-x86_64-daemon
        "$OUTPUT_BASE"/blakecoin-v${VERSION}-ubuntu-*-x86_64-qt
        "$OUTPUT_BASE"/blakecoin-v${VERSION}-ubuntu-*-x86_64.tar.gz
    )
    shopt -u nullglob

    if [[ ${#stale_paths[@]} -gt 0 ]]; then
        rm -rf "${stale_paths[@]}"
    fi
}

cleanup_windows_native_output_root() {
    mkdir -p "$OUTPUT_BASE"

    rm -f \
        "$OUTPUT_BASE/${DAEMON_NAME}.exe" \
        "$OUTPUT_BASE/${CLI_NAME}.exe" \
        "$OUTPUT_BASE/${TX_NAME}.exe" \
        "$OUTPUT_BASE/${QT_NAME}.exe" \
        "$OUTPUT_BASE/qt.conf" \
        "$OUTPUT_BASE/build-info.txt"
    rm -rf \
        "$OUTPUT_BASE/platforms" \
        "$OUTPUT_BASE/windows-native"

    shopt -s nullglob
    local stale_files=(
        "$OUTPUT_BASE"/*.dll
        "$OUTPUT_BASE"/${DAEMON_NAME}-${VERSION}.exe
        "$OUTPUT_BASE"/${CLI_NAME}-${VERSION}.exe
        "$OUTPUT_BASE"/${TX_NAME}-${VERSION}.exe
        "$OUTPUT_BASE"/${QT_NAME}-${VERSION}.exe
    )
    shopt -u nullglob

    if [[ ${#stale_files[@]} -gt 0 ]]; then
        rm -f "${stale_files[@]}"
    fi
}

cleanup_simple_output_root() {
    mkdir -p "$OUTPUT_BASE"

    rm -f \
        "$OUTPUT_BASE/$DAEMON_NAME" \
        "$OUTPUT_BASE/$CLI_NAME" \
        "$OUTPUT_BASE/$TX_NAME" \
        "$OUTPUT_BASE/$QT_NAME" \
        "$OUTPUT_BASE/${QT_NAME}-bin" \
        "$OUTPUT_BASE/${DAEMON_NAME}.exe" \
        "$OUTPUT_BASE/${CLI_NAME}.exe" \
        "$OUTPUT_BASE/${TX_NAME}.exe" \
        "$OUTPUT_BASE/${QT_NAME}.exe" \
        "$OUTPUT_BASE/${DAEMON_NAME}-${VERSION}" \
        "$OUTPUT_BASE/${CLI_NAME}-${VERSION}" \
        "$OUTPUT_BASE/${TX_NAME}-${VERSION}" \
        "$OUTPUT_BASE/${QT_NAME}-${VERSION}" \
        "$OUTPUT_BASE/${DAEMON_NAME}-${VERSION}.exe" \
        "$OUTPUT_BASE/${CLI_NAME}-${VERSION}.exe" \
        "$OUTPUT_BASE/${TX_NAME}-${VERSION}.exe" \
        "$OUTPUT_BASE/${QT_NAME}-${VERSION}.exe" \
        "$OUTPUT_BASE/install-deps.sh" \
        "$OUTPUT_BASE/${COIN_NAME}.desktop" \
        "$OUTPUT_BASE/${COIN_NAME}-256.png" \
        "$OUTPUT_BASE/blakecoin.conf" \
        "$OUTPUT_BASE/qt.conf" \
        "$OUTPUT_BASE/README.md" \
        "$OUTPUT_BASE/build-info.txt"

    rm -rf \
        "$OUTPUT_BASE/.runtime" \
        "$OUTPUT_BASE/lib" \
        "$OUTPUT_BASE/plugins" \
        "$OUTPUT_BASE/platforms" \
        "$OUTPUT_BASE/Blakecoin-Qt.app" \
        "$OUTPUT_BASE/native" \
        "$OUTPUT_BASE/windows" \
        "$OUTPUT_BASE/macos" \
        "$OUTPUT_BASE/windows-native" \
        "$OUTPUT_BASE/macos-native" \
        "$OUTPUT_BASE/daemon" \
        "$OUTPUT_BASE/qt"

    shopt -s nullglob
    local stale_dlls=("$OUTPUT_BASE"/*.dll)
    shopt -u nullglob
    if [[ ${#stale_dlls[@]} -gt 0 ]]; then
        rm -f "${stale_dlls[@]}"
    fi
}

normalize_windows_source_timestamps() {
    [[ -d "$SCRIPT_DIR" ]] || return 0

    info "Normalizing native Windows source timestamps..."
    find "$SCRIPT_DIR" -type f \
        -not -path "$SCRIPT_DIR/.git/*" \
        -not -path "$SCRIPT_DIR/outputs/*" \
        -exec touch -c {} + 2>/dev/null || true
}

stage_linux_qt_runtime_bundle() {
    local qt_source_binary="$1"
    local package_dir="$2"
    local stage_dir=""

    [[ -x "$qt_source_binary" ]] || {
        error "Qt source binary not found: $qt_source_binary"
        exit 1
    }

    stage_dir=$(mktemp -d)
    cp "$qt_source_binary" "$stage_dir/${QT_NAME}-${VERSION}"
    bundle_linux_qt_runtime "$stage_dir"

    mkdir -p "$package_dir/.runtime"
    cp -a "$stage_dir/.runtime/." "$package_dir/.runtime/"
    if [[ -f "$package_dir/.runtime/${QT_NAME}-bin-${VERSION}" ]]; then
        mv "$package_dir/.runtime/${QT_NAME}-bin-${VERSION}" "$package_dir/.runtime/${QT_NAME}-bin"
    fi

    rm -f "$package_dir/$QT_NAME"
    compile_linux_qt_launcher "$package_dir/$QT_NAME"
    rm -rf "$stage_dir"
}

install_linux_desktop_launcher() {
    local qt_bundle_dir="$1"
    local desktop_dir="$HOME/.local/share/applications"
    local icon_dir="$HOME/.local/share/icons/hicolor/256x256/apps"
    local icon_source="$SCRIPT_DIR/src/qt/res/icons/bitcoin.png"

    mkdir -p "$desktop_dir" "$icon_dir"
    if [[ -f "$icon_source" ]]; then
        cp "$icon_source" "$icon_dir/${COIN_NAME}.png"
    fi
    cat > "$desktop_dir/${QT_NAME}.desktop" <<DEOF
[Desktop Entry]
Type=Application
Name=Blakecoin Qt
Icon=$icon_dir/${COIN_NAME}.png
Exec=$qt_bundle_dir/$QT_NAME
Terminal=false
Categories=Finance;Network;
StartupWMClass=${QT_NAME}
DEOF
    chmod +x "$desktop_dir/${QT_NAME}.desktop"
    info "Desktop launcher installed  -  Blakecoin Qt will appear in Activities search"
}

detect_native_docker_ubuntu_version() {
    local version=""

    case "$DOCKER_NATIVE" in
        *native-base:20.04*) version="20.04" ;;
        *native-base:22.04*) version="22.04" ;;
        *native-base:24.04*) version="24.04" ;;
        *native-base:25.10*) version="25.10" ;;
    esac

    if [[ -n "$version" ]]; then
        printf '%s\n' "$version"
        return 0
    fi

    docker run --rm "$DOCKER_NATIVE" /bin/bash -lc '. /etc/os-release >/dev/null 2>&1 && printf "%s\n" "$VERSION_ID"' 2>/dev/null || true
}

write_appimage_bundle_readme() {
    local readme_path="$1"

    cat > "$readme_path" <<EOF
# Blakecoin v${VERSION} - Linux AppImage

## Contents

- ${APPIMAGE_PUBLIC_NAME}
- README.md
- build-info.txt

## Quick Start

Make the AppImage executable and run it:

\`\`\`bash
chmod +x ${APPIMAGE_PUBLIC_NAME}
./${APPIMAGE_PUBLIC_NAME}
\`\`\`

## Ubuntu Direct Launch Requirements

- Ubuntu 22.04.5: \`sudo apt install libfuse2\`
- Ubuntu 24.04.4: \`sudo apt install libfuse2t64\`
- Ubuntu 25.10: \`sudo apt install libfuse2t64\`

If the host is missing that package, direct AppImage startup fails with:

\`\`\`text
dlopen(): error loading libfuse.so.2
\`\`\`

## Fallback Launch

\`\`\`bash
./${APPIMAGE_PUBLIC_NAME} --appimage-extract-and-run
\`\`\`

## Notes

- This AppImage is intended for Ubuntu 22.04 and newer.
- Ubuntu 20.04 users should use the native Ubuntu 20.04 build in \`outputs/\`.
EOF
}

finalize_linux_native_output() {
    local ubuntu_ver="$1"
    local target="$2"
    local daemon_source="$3"
    local cli_source="$4"
    local tx_source="$5"
    local qt_source_binary="$6"
    local install_packages="${7:-}"
    local output_dir=""
    local icon_source="$SCRIPT_DIR/src/qt/res/icons/bitcoin.png"

    ubuntu_ver="${ubuntu_ver:-unknown}"
    output_dir="$(linux_output_dir "$ubuntu_ver")"

    case "$target" in
        daemon|both)
            for source_file in "$daemon_source" "$cli_source" "$tx_source"; do
                [[ -x "$source_file" ]] || {
                    error "Missing Linux daemon artifact: $source_file"
                    exit 1
                }
            done
            ;;
    esac

    case "$target" in
        qt|both)
            [[ -x "$qt_source_binary" ]] || {
                error "Missing Linux Qt artifact: $qt_source_binary"
                exit 1
            }
            ;;
    esac

    cleanup_legacy_output_root
    cleanup_target_output_dir "$output_dir"

    if [[ "$target" == "daemon" || "$target" == "both" ]]; then
        cp "$daemon_source" "$output_dir/$DAEMON_NAME"
        cp "$cli_source" "$output_dir/$CLI_NAME"
        cp "$tx_source" "$output_dir/$TX_NAME"
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        if [[ "$ubuntu_ver" == 20.04* ]]; then
            cp "$qt_source_binary" "$output_dir/${QT_NAME}-bin"
            compile_linux_qt_launcher "$output_dir/$QT_NAME" "${QT_NAME}-bin" 0 1
        else
            cp "$qt_source_binary" "$output_dir/$QT_NAME"
        fi

        if [[ -f "$icon_source" ]]; then
            cp "$icon_source" "$output_dir/${COIN_NAME}-256.png"
        else
            warn "Release icon source not found: $icon_source"
        fi

        write_linux_release_desktop "$output_dir/${COIN_NAME}.desktop"
    fi

    write_linux_install_deps_script "$output_dir/install-deps.sh" "$install_packages"
    write_linux_release_readme "$output_dir/README.md" "$ubuntu_ver" "$target" "$install_packages"
    CURRENT_OUTPUT_DIR="$output_dir"
    GENERATE_CONFIG_AFTER_BUILD=1

    success "Linux output files updated in: $output_dir"
}

bundle_linux_qt_runtime() {
    local qt_output_dir="$1"
    local launcher_path="$qt_output_dir/${QT_NAME}-${VERSION}"
    local runtime_dir="$qt_output_dir/.runtime"
    local binary_path="$runtime_dir/${QT_NAME}-bin-${VERSION}"
    local lib_dir="$runtime_dir/lib"
    local plugin_dir="$runtime_dir/plugins/platforms"
    local qt_plugin_root=""

    [[ -f "$launcher_path" ]] || return 0

    rm -rf "$runtime_dir"
    mkdir -p "$lib_dir" "$plugin_dir"
    mv "$launcher_path" "$binary_path"

    copy_runtime_libs "$binary_path" "$lib_dir"

    if command -v qtpaths >/dev/null 2>&1; then
        qt_plugin_root=$(qtpaths --plugin-dir 2>/dev/null || true)
    fi
    if [[ -z "$qt_plugin_root" ]] && command -v qmake >/dev/null 2>&1; then
        qt_plugin_root=$(qmake -query QT_INSTALL_PLUGINS 2>/dev/null || true)
    fi
    if [[ -z "$qt_plugin_root" ]] && [[ -d /usr/lib/x86_64-linux-gnu/qt5/plugins ]]; then
        qt_plugin_root="/usr/lib/x86_64-linux-gnu/qt5/plugins"
    fi

    if [[ -n "$qt_plugin_root" && -f "$qt_plugin_root/platforms/libqxcb.so" ]]; then
        cp -Lf "$qt_plugin_root/platforms/libqxcb.so" "$plugin_dir/"
        copy_runtime_libs "$plugin_dir/libqxcb.so" "$lib_dir"
    else
        warn "Qt platform plugin libqxcb.so not found; bundled launcher may still rely on system Qt plugins"
    fi

    cat > "$launcher_path" <<EOF
#!/bin/sh
set -e
APPDIR=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)
export LD_LIBRARY_PATH="\$APPDIR/.runtime/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export QT_PLUGIN_PATH="\$APPDIR/.runtime/plugins\${QT_PLUGIN_PATH:+:\$QT_PLUGIN_PATH}"
export QT_QPA_PLATFORM_PLUGIN_PATH="\$APPDIR/.runtime/plugins/platforms"
exec "\$APPDIR/.runtime/${QT_NAME}-bin-${VERSION}" "\$@"
EOF
    chmod +x "$launcher_path"
    info "Bundled Qt runtime libraries into $qt_output_dir/"
}

generate_config() {
    local output_dir="${1:-$OUTPUT_BASE}"
    local conf_path="$output_dir/$CONFIG_FILE"
    local data_dir="$HOME/.${COIN_NAME}"
    local data_conf_path="$data_dir/$CONFIG_FILE"
    local rpcuser rpcpassword peers=""
    local peers_json=""
    local tmp_conf=""
    local host_os=""
    local daemon_line="$DAEMON"

    fetch_explorer_addnodes() {
        if ! command -v curl &>/dev/null; then
            return 0
        fi

        peers_json=$(curl -fsSL --connect-timeout 5 --max-time 15 \
            "${EXPLORER_API_BASE%/}/${EXPLORER_COIN_ID}/globe/peers" 2>/dev/null || true)

        if [[ -n "$peers_json" ]]; then
            printf '%s\n' "$peers_json" \
                | grep -oE '"addr"[[:space:]]*:[[:space:]]*"([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]+)?"' \
                | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
                | awk -F. '
                    $1 >= 0 && $1 <= 255 &&
                    $2 >= 0 && $2 <= 255 &&
                    $3 >= 0 && $3 <= 255 &&
                    $4 >= 0 && $4 <= 255 &&
                    $1 != 0 &&
                    $1 != 10 &&
                    $1 != 127 &&
                    !($1 == 169 && $2 == 254) &&
                    !($1 == 172 && $2 >= 16 && $2 <= 31) &&
                    !($1 == 192 && $2 == 168) &&
                    !($1 == 100 && $2 >= 64 && $2 <= 127) &&
                    $1 < 224
                ' \
                | sort -u \
                | sed 's/^/addnode=/'
        fi
    }

    mkdir -p "$output_dir" "$data_dir"
    host_os="$(detect_os)"
    if [[ "$host_os" == "windows" ]]; then
        daemon_line=""
    fi
    peers="$(fetch_explorer_addnodes || true)"

    if [[ -f "$data_conf_path" ]]; then
        info "Refreshing active peer addnode entries in $data_conf_path"
        tmp_conf=$(mktemp)
        if [[ "$host_os" == "windows" ]]; then
            sed '/^addnode=/d;/^daemon=/d' "$data_conf_path" > "$tmp_conf"
        else
            sed '/^addnode=/d' "$data_conf_path" > "$tmp_conf"
        fi
        if [[ -n "$peers" ]]; then
            printf '%s\n' "$peers" >> "$tmp_conf"
        else
            warn "Explorer returned no usable peers; leaving config without addnode entries"
        fi
        mv "$tmp_conf" "$data_conf_path"
        tmp_conf=""
    else
        info "Generating $CONFIG_FILE..."
        rpcuser="rpcuser=$(LC_ALL=C head -c 100 /dev/urandom | LC_ALL=C tr -cd '[:alnum:]' | head -c 10)"
        rpcpassword="rpcpassword=$(LC_ALL=C head -c 200 /dev/urandom | LC_ALL=C tr -cd '[:alnum:]' | head -c 22)"
        cat > "$data_conf_path" <<EOF
maxconnections=20
$rpcuser
$rpcpassword
rpcallowip=0.0.0.0/0
rpcport=$RPC_PORT
port=$P2P_PORT
gen=0
$LISTEN
$daemon_line
$SERVER
$TXINDEX
$peers
EOF
        if [[ -z "$peers" ]]; then
            warn "Explorer returned no usable peers; created config without addnode entries"
        fi
    fi

    cp "$data_conf_path" "$conf_path"
    success "Config written: $conf_path"
    info "Config installed to $data_conf_path"
}

ensure_docker_image() {
    local image="$1"
    local docker_mode="$2"

    if [[ "$docker_mode" == "build" ]]; then
        # Use cached image if it exists, otherwise build from local Dockerfiles
        if docker image inspect "$image" >/dev/null 2>&1; then
            info "Image $image found locally (built)."
            return 0
        fi
        local docker_dir="$SCRIPT_DIR/docker"
        local dockerfile=""
        case "$image" in
            *native-base:20.04*)  dockerfile="Dockerfile.native-base-20.04" ;;
            *native-base:22.04*)  dockerfile="Dockerfile.native-base-22.04" ;;
            *native-base:24.04*)  dockerfile="Dockerfile.native-base-24.04" ;;
            *native-base:25.10*)  dockerfile="Dockerfile.native-base-25.10" ;;
            *native-base*)        dockerfile="Dockerfile.native-base-22.04" ;;
            *appimage-base*)      dockerfile="Dockerfile.appimage-base" ;;
            *mxe-base*)           dockerfile="Dockerfile.mxe-base" ;;
            *osxcross-base*)      dockerfile="Dockerfile.osxcross-base" ;;
            *)
                error "Unknown image: $image"
                exit 1
                ;;
        esac
        if [[ -f "$docker_dir/$dockerfile" ]]; then
            info "Building $image from $dockerfile..."
            if docker build -t "$image" -f "$docker_dir/$dockerfile" "$docker_dir/"; then
                success "Built $image"
            else
                error "Failed to build $image from $dockerfile"
                exit 1
            fi
        else
            error "Dockerfile not found: $docker_dir/$dockerfile"
            error "Ensure docker/ directory contains the Dockerfiles."
            exit 1
        fi
        return 0
    fi

    # Pull mode  -  check local cache first
    if docker image inspect "$image" >/dev/null 2>&1; then
        info "Image $image found locally."
        return 0
    fi

    if [[ "$docker_mode" == "pull" ]]; then
        info "Pulling $image from Docker Hub..."
        if docker pull "$image"; then
            success "Pulled $image"
        else
            error "Failed to pull $image"
            error "Check https://hub.docker.com/r/${image%%:*}"
            error "Or use --build-docker to build from local Dockerfiles."
            exit 1
        fi
    else
        error "Docker is required for this build. Use --pull-docker or --build-docker"
        error "  --pull-docker   Pull prebuilt image from Docker Hub"
        error "  --build-docker  Build image locally from Dockerfiles in docker/"
        exit 1
    fi
}

# =============================================================================
# WINDOWS CROSS-COMPILE (Docker + MXE + autotools)
# Uses pre-built libs in mxe-base image  -  skips depends/ entirely
# =============================================================================

build_windows() {
    local target="$1"
    local jobs="$2"
    local docker_mode="$3"
    local container_name="win-${COIN_NAME}-0152-build"
    local output_dir=""

    echo ""
    echo "============================================"
    echo "  Windows Cross-Compile: $COIN_NAME_UPPER $VERSION"
    echo "============================================"
    echo "  Image:    $DOCKER_WINDOWS"
    echo "  Strategy: MXE + autotools (pre-built libs)"
    echo ""

    output_dir="$(windows_output_dir)"
    ensure_windows_icon_assets
    ensure_docker_image "$DOCKER_WINDOWS" "$docker_mode"
    cleanup_legacy_output_root
    cleanup_target_output_dir "$output_dir"
    docker rm -f "$container_name" 2>/dev/null || true

    # Copy source to temp dir for volume-mount
    info "Copying source tree to temp build dir..."
    local tmpdir
    tmpdir=$(mktemp -d)
    copy_source_tree_to_tempdir "$tmpdir"
    clean_stale_build_artifacts "$tmpdir"
    fix_permissions "$tmpdir"

    # Build configure flags based on target
    local configure_extra=""
    case "$target" in
        daemon) configure_extra="--without-gui" ;;
        qt)     configure_extra="--with-gui=qt5" ;;
        both)   configure_extra="--with-gui=qt5" ;;
    esac

    docker create \
        --name "$container_name" \
        -v "$tmpdir:/build/$COIN_NAME:rw" \
        "$DOCKER_WINDOWS" \
        /bin/bash -c '
set -e
cd /build/'"$COIN_NAME"'

# MXE cross-compiler setup
export PATH=/opt/mxe/usr/bin:$PATH
HOST='"$WIN_HOST"'
MXE_SYSROOT=/opt/mxe/usr/${HOST}
export PATH="${MXE_SYSROOT}/qt5/bin:$PATH"

# Set pkg-config to find MXE target libraries (Qt5, libevent, protobuf)
export PKG_CONFIG_LIBDIR="${MXE_SYSROOT}/qt5/lib/pkgconfig:${MXE_SYSROOT}/lib/pkgconfig"

echo ">>> MXE environment:"
echo "    HOST=$HOST"
echo "    MXE_SYSROOT=$MXE_SYSROOT"
echo "    PKG_CONFIG_LIBDIR=$PKG_CONFIG_LIBDIR"
echo "    Compat libs: /opt/compat/"
which ${HOST}-gcc || { echo "ERROR: Cross-compiler not found"; exit 1; }

# Restore MXE OpenSSL 3.x (Qt5 was compiled against it; compat has 1.1.1 which is incompatible)
echo ">>> Restoring MXE OpenSSL 3.x for Qt5 compatibility..."
rm -f /opt/compat/lib/libssl.a /opt/compat/lib/libcrypto.a
if [ -d ${MXE_SYSROOT}/include/openssl.mxe.bak ]; then
    rm -rf ${MXE_SYSROOT}/include/openssl
    cp -r ${MXE_SYSROOT}/include/openssl.mxe.bak ${MXE_SYSROOT}/include/openssl
fi
cp ${MXE_SYSROOT}/lib/mxe_bak/libssl.a ${MXE_SYSROOT}/lib/libssl.a
cp ${MXE_SYSROOT}/lib/mxe_bak/libcrypto.a ${MXE_SYSROOT}/lib/libcrypto.a

# Verify Qt5 is findable
pkg-config --cflags Qt5Core 2>/dev/null && echo ">>> Qt5Core found via pkg-config" || echo "WARNING: Qt5Core not found"

# Patch sources for Qt 5.15+ and Boost 1.73+ compatibility
echo ">>> Patching sources..."
if [ -f src/qt/trafficgraphwidget.cpp ]; then
    grep -q "#include <QPainterPath>" src/qt/trafficgraphwidget.cpp || \
        sed -i "1i #include <QPainterPath>" src/qt/trafficgraphwidget.cpp
fi
for f in $(grep -rl "boost::bind" src/ 2>/dev/null | grep "\.cpp$"); do
    grep -q "boost/bind.hpp" "$f" || \
        sed -i "1i #include <boost/bind.hpp>" "$f"
done

# Build Qt5 include flags (all module subdirs)
QT5INC="${MXE_SYSROOT}/qt5/include"
QT5_CPPFLAGS="-I${QT5INC}"
for qtmod in QtCore QtGui QtWidgets QtNetwork QtDBus; do
    [ -d "${QT5INC}/${qtmod}" ] && QT5_CPPFLAGS="${QT5_CPPFLAGS} -I${QT5INC}/${qtmod}"
done
echo ">>> Qt5 include flags: $QT5_CPPFLAGS"

# Create Qt5PlatformSupport merged lib (split into multiple libs in Qt 5.14+)
QT5LIBDIR="${MXE_SYSROOT}/qt5/lib"
if [ ! -f "${QT5LIBDIR}/libQt5PlatformSupport.a" ]; then
    echo ">>> Creating merged Qt5PlatformSupport.a from split modules..."
    _qt5ps_save_dir=$(pwd)
    mkdir -p /tmp/qt5ps && cd /tmp/qt5ps
    for lib in EventDispatcherSupport FontDatabaseSupport ThemeSupport AccessibilitySupport WindowsUIAutomationSupport; do
        [ -f "${QT5LIBDIR}/libQt5${lib}.a" ] && ar x "${QT5LIBDIR}/libQt5${lib}.a"
    done
    ar crs "${QT5LIBDIR}/libQt5PlatformSupport.a" *.o 2>/dev/null || ar crs "${QT5LIBDIR}/libQt5PlatformSupport.a"
    cd "$_qt5ps_save_dir" && rm -rf /tmp/qt5ps
    cat > "${QT5LIBDIR}/pkgconfig/Qt5PlatformSupport.pc" <<PCEOF
Name: Qt5PlatformSupport
Description: Merged compat lib for Qt 5.14+ (split into separate modules)
Version: 5.15
Cflags:
Libs: -L${QT5LIBDIR} -lQt5PlatformSupport -lQt5EventDispatcherSupport -lQt5FontDatabaseSupport -lQt5ThemeSupport -lQt5AccessibilitySupport
PCEOF
fi

echo ">>> Running autogen.sh..."
./autogen.sh

# Patch configure to skip static Qt plugin link tests (deps too complex for configure)
# The actual make build handles Qt5 plugin deps correctly via .prl files
echo ">>> Patching configure to skip Qt static plugin link tests..."
sed -i "/as_fn_error.*Could not resolve/s/as_fn_error/true #/" configure

echo ">>> Configuring for Windows ($HOST)..."
./configure --host=$HOST --prefix=/usr/local \
    --disable-tests --disable-bench \
    --with-qt-plugindir=${MXE_SYSROOT}/qt5/plugins \
    --with-boost=/opt/compat \
    --with-boost-libdir=/opt/compat/lib \
    '"$configure_extra"' \
    CXXFLAGS="-O2 -DWIN32 -DMINIUPNP_STATICLIB -DBOOST_BIND_GLOBAL_PLACEHOLDERS" \
    CFLAGS="-O2 -DWIN32" \
    CPPFLAGS="-I/opt/compat/include ${QT5_CPPFLAGS}" \
    LDFLAGS="-L/opt/compat/lib -L${MXE_SYSROOT}/lib -L${MXE_SYSROOT}/qt5/lib -static" \
    BDB_CFLAGS="-I/opt/compat/include" \
    BDB_LIBS="-L/opt/compat/lib -ldb_cxx-4.8 -ldb-4.8" \
    PROTOC=/opt/mxe/usr/x86_64-pc-linux-gnu/bin/protoc

# The MXE Boost 1.81 headers emit duplicate category singletons when this legacy
# tree is forced through C++11. Moving the Windows cross-build to C++17 avoids
# those multiple-definition link failures without changing other host paths.
find . -name Makefile -type f -exec sed -i "s/-std=c++11/-std=c++17/g" {} +

# Fix missing Qt translation files (Blakecoin fork does not include them)
if [ -f src/Makefile ]; then
    sed -i "s/^QT_QM.*=.*/QT_QM =/" src/Makefile
    sed -i "/bitcoin_.*\.qm/d" src/Makefile
    sed -i "/locale\/.*\.qm/d" src/Makefile
fi
mkdir -p src/qt
if [ -x /opt/mxe/usr/x86_64-pc-linux-gnu/bin/protoc ] && [ -f src/qt/paymentrequest.proto ]; then
    echo ">>> Regenerating paymentrequest protobuf sources..."
    (
        cd src/qt
        /opt/mxe/usr/x86_64-pc-linux-gnu/bin/protoc --cpp_out=. paymentrequest.proto
    )
fi
cat > src/qt/bitcoin_locale.qrc <<QRC_EOF
<!DOCTYPE RCC><RCC version="1.0">
<qresource prefix="/translations">
</qresource>
</RCC>
QRC_EOF

# Fix static link deps: use --start-group to resolve circular Qt5/platform plugin deps
if [ -f src/Makefile ]; then
    echo ">>> Fixing static link dependencies (--start-group for circular deps)..."
    sed -i "s|^LIBS = \(.*\)|LIBS = -Wl,--start-group \1 -L${MXE_SYSROOT}/qt5/plugins/platforms -lqwindows -L${MXE_SYSROOT}/qt5/lib -lQt5Widgets -lQt5Gui -lQt5Network -lQt5Core -lQt5PlatformSupport -lQt5AccessibilitySupport -lQt5WindowsUIAutomationSupport -lQt5EventDispatcherSupport -lQt5FontDatabaseSupport -lQt5ThemeSupport -lharfbuzz -lfreetype -lharfbuzz_too -lfreetype_too -lbz2 -lpng16 -lbrotlidec -lbrotlicommon -lglib-2.0 -lintl -liconv -lpcre2-8 -lpcre2-16 -lzstd -lssl -lcrypto -ld3d11 -ldxgi -ldxguid -luxtheme -ldwmapi -ldnsapi -liphlpapi -lcrypt32 -lmpr -luserenv -lnetapi32 -lversion -lcomdlg32 -loleaut32 -limm32 -lshlwapi -latomic -lz -lws2_32 -lgdi32 -luser32 -lkernel32 -ladvapi32 -lole32 -lshell32 -luuid -lwinmm -lrpcrt4 -lssp -lwinspool -lcomctl32 -lwtsapi32 -lm -Wl,--end-group|" src/Makefile
fi

if [ -f src/univalue/Makefile ]; then
    echo ">>> Prebuilding libunivalue to avoid parallel archive races..."
    make -C src/univalue -j1 libunivalue.la
fi

if [ -f src/Makefile ]; then
    echo ">>> Prebuilding libbitcoinconsensus serially to avoid MXE/libtool ordering issues..."
    make -C src -j1 \
        libbitcoinconsensus_la-arith_uint256.lo \
        libbitcoinconsensus_la-hash.lo \
        libbitcoinconsensus_la-pubkey.lo \
        libbitcoinconsensus_la-uint256.lo \
        libbitcoinconsensus_la-utilstrencodings.lo \
        script/libbitcoinconsensus_la-script_error.lo \
        libbitcoinconsensus.la
fi

echo ">>> Building..."
if ! make -j'"$jobs"'; then
    echo ">>> Parallel build failed; retrying serial make to work around libtool archive races..."
    make -j1
fi

echo ">>> Stripping binaries..."
${HOST}-strip src/blakecoind.exe 2>/dev/null || true
${HOST}-strip src/qt/blakecoin-qt.exe 2>/dev/null || true
${HOST}-strip src/blakecoin-cli.exe 2>/dev/null || true
${HOST}-strip src/blakecoin-tx.exe 2>/dev/null || true

echo ">>> Build complete!"
ls -lh src/blakecoind.exe src/qt/blakecoin-qt.exe src/blakecoin-cli.exe src/blakecoin-tx.exe 2>/dev/null || true
'

    info "Starting build container: $container_name"
    docker start -a "$container_name"

    # Extract binaries
    if [[ "$target" == "daemon" || "$target" == "both" ]]; then
        info "Extracting daemon binaries..."
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoind.exe" "$output_dir/blakecoind-${VERSION}.exe" 2>/dev/null || true
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoin-cli.exe" "$output_dir/blakecoin-cli-${VERSION}.exe" 2>/dev/null || true
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoin-tx.exe" "$output_dir/blakecoin-tx-${VERSION}.exe" 2>/dev/null || true
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        info "Extracting Qt wallet..."
        docker cp "$container_name:/build/$COIN_NAME/src/qt/blakecoin-qt.exe" "$output_dir/blakecoin-qt-${VERSION}.exe" 2>/dev/null || true
    fi

    write_build_info "$output_dir" "windows" "$target" "Docker: $DOCKER_WINDOWS (MXE)"
    CURRENT_OUTPUT_DIR="$output_dir"
    GENERATE_CONFIG_AFTER_BUILD=0

    docker rm -f "$container_name" 2>/dev/null || true
    docker run --rm -v "$tmpdir:/cleanup" alpine rm -rf /cleanup 2>/dev/null || rm -rf "$tmpdir" 2>/dev/null || true

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL  -  Windows"
    echo "  Output: $output_dir/"
    echo "============================================"
    ls -lh "$output_dir"/*.exe "$output_dir"/build-info.txt 2>/dev/null || true
}

# =============================================================================
# LEGACY macOS CROSS-COMPILE (Docker + osxcross + autotools)
# Uses pre-built libs in osxcross-base image and skips depends/.
# Kept as a fallback while the fork migrates toward a real depends pipeline.
# =============================================================================

build_macos_cross_legacy() {
    local target="$1"
    local jobs="$2"
    local docker_mode="$3"
    local container_name="mac-${COIN_NAME}-0152-build"
    local output_dir=""

    echo ""
    echo "============================================"
    echo "  macOS Cross-Compile: $COIN_NAME_UPPER $VERSION"
    echo "============================================"
    echo "  Image:    $DOCKER_MACOS"
    echo "  Strategy: osxcross + autotools (pre-built libs)"
    echo ""

    output_dir="$(macos_output_dir)"
    ensure_docker_image "$DOCKER_MACOS" "$docker_mode"
    cleanup_legacy_output_root
    cleanup_target_output_dir "$output_dir"
    docker rm -f "$container_name" 2>/dev/null || true

    # Copy source to temp dir
    info "Copying source tree to temp build dir..."
    local tmpdir
    tmpdir=$(mktemp -d)
    cp -a "$SCRIPT_DIR"/. "$tmpdir/"
    rm -rf "$tmpdir/outputs" "$tmpdir/.git"
    clean_stale_build_artifacts "$tmpdir"
    fix_permissions "$tmpdir"

    local configure_extra=""
    case "$target" in
        daemon) configure_extra="--without-gui" ;;
        qt)     configure_extra="--with-gui=qt5" ;;
        both)   configure_extra="--with-gui=qt5" ;;
    esac

    docker create \
        --name "$container_name" \
        -v "$tmpdir:/build/$COIN_NAME:rw" \
        "$DOCKER_MACOS" \
        /bin/bash -c '
set -e
cd /build/'"$COIN_NAME"'

# osxcross toolchain setup
export PATH=/opt/osxcross/target/bin:$PATH
export PREFIX=/opt/osxcross/target/macports/pkgs/opt/local
# Auto-detect darwin version from available toolchain
HOST=$(ls /opt/osxcross/target/bin/ | grep -oP "x86_64-apple-darwin[0-9.]+" | head -1)
if [ -z "$HOST" ]; then echo "ERROR: Could not detect osxcross HOST triplet"; exit 1; fi

echo ">>> osxcross environment:"
echo "    HOST=$HOST"
echo "    PREFIX=$PREFIX"
echo "    CC=${HOST}-clang"
echo "    CXX=${HOST}-clang++"
which ${HOST}-clang++ || { echo "ERROR: Cross-compiler not found"; exit 1; }

# --- Cross-compile libevent (missing from osxcross-base, needed by 0.15.2) ---
echo ">>> Cross-compiling libevent..."
cd /tmp
curl -LO https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz
tar xf libevent-2.1.12-stable.tar.gz
cd libevent-2.1.12-stable
./configure --host=$HOST --prefix=$PREFIX \
    --disable-shared --enable-static \
    --disable-openssl --disable-samples --disable-libevent-regress \
    CC=${HOST}-clang CXX=${HOST}-clang++ \
    CFLAGS="-mmacosx-version-min=11.0" \
    CXXFLAGS="-mmacosx-version-min=11.0"
make -j'"$jobs"'
make install
echo ">>> libevent installed to $PREFIX"

# --- Cross-compile protobuf (needed for Qt/BIP70) ---
echo ">>> Cross-compiling protobuf..."
apt-get update -qq && apt-get install -y -qq protobuf-compiler > /dev/null 2>&1
cd /tmp
curl -LO https://github.com/protocolbuffers/protobuf/releases/download/v3.12.4/protobuf-cpp-3.12.4.tar.gz
tar xf protobuf-cpp-3.12.4.tar.gz
cd protobuf-3.12.4
./configure --host=$HOST --prefix=$PREFIX \
    --disable-shared --enable-static \
    --with-protoc=/usr/bin/protoc \
    CC=${HOST}-clang CXX=${HOST}-clang++ \
    CFLAGS="-mmacosx-version-min=11.0" \
    CXXFLAGS="-stdlib=libc++ -mmacosx-version-min=11.0" \
    LDFLAGS="-stdlib=libc++"
make -j'"$jobs"'
make install
echo ">>> protobuf installed to $PREFIX"

# --- Build Blakecoin ---
cd /build/'"$COIN_NAME"'

# Patch sources for Qt 5.15+ and Boost 1.73+ compatibility
echo ">>> Patching sources..."
if [ -f src/qt/trafficgraphwidget.cpp ]; then
    grep -q "#include <QPainterPath>" src/qt/trafficgraphwidget.cpp || \
        sed -i "1i #include <QPainterPath>" src/qt/trafficgraphwidget.cpp
fi
for f in $(grep -rl "boost::bind" src/ 2>/dev/null | grep "\.cpp$"); do
    grep -q "boost/bind.hpp" "$f" || \
        sed -i "1i #include <boost/bind.hpp>" "$f"
done

# Use system pkg-config instead of osxcross wrapper (which ignores PKG_CONFIG_PATH)
export PKG_CONFIG=/usr/bin/pkg-config
export PKG_CONFIG_LIBDIR="$PREFIX/qt5/lib/pkgconfig:$PREFIX/lib/pkgconfig"
echo ">>> Using system pkg-config with PKG_CONFIG_LIBDIR=$PKG_CONFIG_LIBDIR"
pkg-config --cflags Qt5Core 2>/dev/null && echo ">>> Qt5Core found" || echo "WARNING: Qt5Core not found"

# Build Qt5 include flags (all module subdirs)
QT5INC="$PREFIX/qt5/include"
QT5_CPPFLAGS="-I${QT5INC}"
for qtmod in QtCore QtGui QtWidgets QtNetwork QtDBus; do
    [ -d "${QT5INC}/${qtmod}" ] && QT5_CPPFLAGS="${QT5_CPPFLAGS} -I${QT5INC}/${qtmod}"
done
echo ">>> Qt5 include flags: $QT5_CPPFLAGS"

# Create Qt5PlatformSupport merged lib (split into multiple libs in Qt 5.14+)
QT5LIBDIR="$PREFIX/qt5/lib"
if [ ! -f "${QT5LIBDIR}/libQt5PlatformSupport.a" ]; then
    echo ">>> Creating merged Qt5PlatformSupport.a from split modules..."
    _qt5ps_save_dir=$(pwd)
    mkdir -p /tmp/qt5ps && cd /tmp/qt5ps
    for lib in EventDispatcherSupport FontDatabaseSupport ThemeSupport AccessibilitySupport ClipboardSupport GraphicsSupport ServiceSupport; do
        [ -f "${QT5LIBDIR}/libQt5${lib}.a" ] && ar x "${QT5LIBDIR}/libQt5${lib}.a" 2>/dev/null || true
    done
    ar crs "${QT5LIBDIR}/libQt5PlatformSupport.a" *.o 2>/dev/null || true
    cd "$_qt5ps_save_dir" && rm -rf /tmp/qt5ps
    cat > "${QT5LIBDIR}/pkgconfig/Qt5PlatformSupport.pc" <<PCEOF
Name: Qt5PlatformSupport
Description: Merged compat lib for Qt 5.14+ (split into separate modules)
Version: 5.15
Cflags:
Libs: -L${QT5LIBDIR} -lQt5PlatformSupport -lQt5EventDispatcherSupport -lQt5FontDatabaseSupport -lQt5ThemeSupport -lQt5AccessibilitySupport -lQt5ClipboardSupport -lQt5GraphicsSupport
PCEOF
fi

echo ">>> Creating Boost -mt symlinks (configure looks for suffixed versions)..."
for lib in $PREFIX/lib/libboost_*.a; do
    case "$lib" in
        *-mt.a) continue ;;
    esac
    mt="${lib%.a}-mt.a"
    [ ! -f "$mt" ] && ln -sf "$(basename "$lib")" "$mt"
done

echo ">>> Running autogen.sh..."
./autogen.sh

# Patch configure to skip static Qt plugin link tests (deps too complex for configure)
echo ">>> Patching configure to skip Qt static plugin link tests..."
sed -i "/as_fn_error.*Could not resolve/s/as_fn_error/true #/" configure

echo ">>> Configuring for macOS ($HOST)..."
./configure --host=$HOST --prefix=/usr/local \
    --disable-tests --disable-bench --disable-zmq \
    --with-qt-plugindir=$PREFIX/qt5/plugins \
    --with-boost=$PREFIX \
    --with-boost-libdir=$PREFIX/lib \
    '"$configure_extra"' \
    CC=${HOST}-clang \
    CXX=${HOST}-clang++ \
    CXXFLAGS="-stdlib=libc++ -O2 -mmacosx-version-min=11.0 -DBOOST_BIND_GLOBAL_PLACEHOLDERS -DOBJC_OLD_DISPATCH_PROTOTYPES=1" \
    CFLAGS="-O2 -mmacosx-version-min=11.0 -DOBJC_OLD_DISPATCH_PROTOTYPES=1" \
    OBJCXXFLAGS="-stdlib=libc++ -O2 -mmacosx-version-min=11.0 -DOBJC_OLD_DISPATCH_PROTOTYPES=1" \
    OBJCFLAGS="-O2 -mmacosx-version-min=11.0 -DOBJC_OLD_DISPATCH_PROTOTYPES=1" \
    LDFLAGS="-L$PREFIX/lib -L$PREFIX/qt5/lib -stdlib=libc++ -mmacosx-version-min=11.0" \
    CPPFLAGS="-I$PREFIX/include ${QT5_CPPFLAGS}" \
    BDB_CFLAGS="-I$PREFIX/include" \
    BDB_LIBS="-L$PREFIX/lib -ldb_cxx-4.8 -ldb-4.8" \
    PKG_CONFIG=/usr/bin/pkg-config \
    PROTOC=/usr/bin/protoc

# Fix missing Qt translation files (Blakecoin fork does not include them)
if [ -f src/Makefile ]; then
    sed -i "s/^QT_QM.*=.*/QT_QM =/" src/Makefile
    sed -i "/bitcoin_.*\.qm/d" src/Makefile
    sed -i "/locale\/.*\.qm/d" src/Makefile
fi
mkdir -p src/qt
cat > src/qt/bitcoin_locale.qrc <<QRC_EOF
<!DOCTYPE RCC><RCC version="1.0">
<qresource prefix="/translations">
</qresource>
</RCC>
QRC_EOF

# Fix static link deps: Qt5 Cocoa plugin + platform support + bundled Qt libs + macOS frameworks
if [ -f src/Makefile ]; then
    echo ">>> Fixing static link dependencies (frameworks + Qt plugins)..."
    sed -i "s|^LIBS = \(.*\)|LIBS = \1 -L$PREFIX/qt5/plugins/platforms -lqcocoa -L$PREFIX/qt5/lib -lQt5PrintSupport -lQt5Widgets -lQt5Gui -lQt5Network -lQt5Core -lQt5MacExtras -lQt5PlatformSupport -lQt5AccessibilitySupport -lQt5ClipboardSupport -lQt5EventDispatcherSupport -lQt5FontDatabaseSupport -lQt5GraphicsSupport -lQt5ServiceSupport -lQt5ThemeSupport $PREFIX/qt5/lib/libqtfreetype.a $PREFIX/qt5/lib/libqtharfbuzz.a $PREFIX/qt5/lib/libqtlibpng.a $PREFIX/qt5/lib/libqtpcre2.a -lz -lbz2 -lcups -framework SystemConfiguration -framework GSS -framework Carbon -framework IOKit -framework IOSurface -framework CoreVideo -framework Metal -framework QuartzCore -framework Cocoa -framework CoreGraphics -framework CoreText -framework CoreFoundation -framework Security -framework DiskArbitration -framework AppKit -framework ApplicationServices -framework Foundation -framework CoreServices|" src/Makefile
fi

echo ">>> Building..."
make -j'"$jobs"'

echo ">>> Stripping binaries..."
${HOST}-strip src/blakecoind 2>/dev/null || true
${HOST}-strip src/blakecoin-cli 2>/dev/null || true
${HOST}-strip src/blakecoin-tx 2>/dev/null || true
if [[ "'"$target"'" == "qt" || "'"$target"'" == "both" ]]; then
    ${HOST}-strip src/qt/blakecoin-qt 2>/dev/null || true
fi

APP_NAME="Blakecoin-Qt.app"
if [[ "'"$target"'" == "qt" || "'"$target"'" == "both" ]]; then
echo ">>> Creating macOS .app bundle..."
rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"
cp src/qt/blakecoin-qt "$APP_NAME/Contents/MacOS/Blakecoin-Qt"

# Generate .icns icon from bitcoin.png
ICONS_DIR="src/qt/res/icons"
if [ -f "$ICONS_DIR/bitcoin.png" ]; then
    echo ">>> Generating macOS icon from bitcoin.png..."
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq python3-pil >/dev/null 2>&1 || true
    python3 -c "
from PIL import Image
img = Image.open('"'"'$ICONS_DIR/bitcoin.png'"'"')
img.save('"'"'$APP_NAME/Contents/Resources/blakecoin.icns'"'"')
print('"'"'    Icon generated'"'"')
" 2>/dev/null || echo "    Warning: Pillow icon conversion failed"
fi

# Create Info.plist
cat > "$APP_NAME/Contents/Info.plist" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Blakecoin-Qt</string>
    <key>CFBundleIdentifier</key>
    <string>org.blakecoin.Blakecoin-Qt</string>
    <key>CFBundleName</key>
    <string>Blakecoin-Qt</string>
    <key>CFBundleDisplayName</key>
    <string>Blakecoin Core</string>
    <key>CFBundleVersion</key>
    <string>'"$VERSION"'</string>
    <key>CFBundleShortVersionString</key>
    <string>'"$VERSION"'</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleIconFile</key>
    <string>blakecoin</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>10.14</string>
</dict>
</plist>
PLIST_EOF
fi

echo ">>> Build complete!"
ls -lh src/blakecoind src/qt/blakecoin-qt src/blakecoin-cli src/blakecoin-tx 2>/dev/null || true
if [[ "'"$target"'" == "qt" || "'"$target"'" == "both" ]]; then
    ls -lh "$APP_NAME/Contents/MacOS/" 2>/dev/null || true
fi
'

    info "Starting build container: $container_name"
    docker start -a "$container_name"

    # Extract binaries
    if [[ "$target" == "daemon" || "$target" == "both" ]]; then
        info "Extracting daemon binaries..."
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoind" "$output_dir/blakecoind-${VERSION}" 2>/dev/null || true
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoin-cli" "$output_dir/blakecoin-cli-${VERSION}" 2>/dev/null || true
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoin-tx" "$output_dir/blakecoin-tx-${VERSION}" 2>/dev/null || true
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        info "Extracting Qt wallet (.app bundle)..."
        local app_name="Blakecoin-Qt.app"
        rm -rf "$output_dir/$app_name" 2>/dev/null || true
        if docker cp "$container_name:/build/$COIN_NAME/$app_name" "$output_dir/$app_name" 2>/dev/null; then
            # Ensure binary inside .app is executable (docker cp can lose +x)
            find "$output_dir/$app_name" -path "*/Contents/MacOS/*" -type f -exec chmod +x {} + 2>/dev/null || true
            success "macOS app bundle extracted to $output_dir/"
            ls -lh "$output_dir/$app_name/Contents/MacOS/" 2>/dev/null || true
        else
            error "Could not find .app bundle in container"
            docker exec "$container_name" find /build/$COIN_NAME -name "*.app" -type d 2>/dev/null || true
        fi
        # Also copy raw binary for convenience
        docker cp "$container_name:/build/$COIN_NAME/src/qt/blakecoin-qt" "$output_dir/blakecoin-qt-${VERSION}" 2>/dev/null || true
    fi

    write_build_info "$output_dir" "macos" "$target" "Docker: $DOCKER_MACOS (osxcross)"
    CURRENT_OUTPUT_DIR="$output_dir"
    GENERATE_CONFIG_AFTER_BUILD=0

    docker rm -f "$container_name" 2>/dev/null || true
    docker run --rm -v "$tmpdir:/cleanup" alpine rm -rf /cleanup 2>/dev/null || rm -rf "$tmpdir" 2>/dev/null || true

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL  -  macOS"
    echo "  Output: $output_dir/"
    echo "============================================"
    ls -lh "$output_dir"/* 2>/dev/null || true
}

# =============================================================================
# macOS CROSS-COMPILE (Docker + depends + autotools)
# Default path: Bitcoin-style depends + CONFIG_SITE inside the osxcross image
# =============================================================================

build_macos_cross() {
    local target="$1"
    local jobs="$2"
    local docker_mode="$3"
    local container_name="mac-${COIN_NAME}-0152-build"
    local output_dir=""
    local tmpdir=""
    local build_strategy="${MACOS_CROSS_STRATEGY:-depends}"
    local build_note=""

    if [[ "$build_strategy" == "legacy" ]]; then
        warn "Using legacy macOS cross-build path because MACOS_CROSS_STRATEGY=legacy"
        build_macos_cross_legacy "$target" "$jobs" "$docker_mode"
        return
    fi

    echo ""
    echo "============================================"
    echo "  macOS Cross-Compile: $COIN_NAME_UPPER $VERSION"
    echo "============================================"
    echo "  Image:    $DOCKER_MACOS"
    echo "  Strategy: depends + CONFIG_SITE + autotools"
    echo ""

    output_dir="$(macos_output_dir)"
    ensure_docker_image "$DOCKER_MACOS" "$docker_mode"
    cleanup_legacy_output_root
    cleanup_target_output_dir "$output_dir"
    docker rm -f "$container_name" 2>/dev/null || true

    info "Copying source tree to temp build dir..."
    tmpdir=$(mktemp -d)
    copy_source_tree_to_tempdir "$tmpdir"
    rm -rf "$tmpdir/release"
    clean_stale_build_artifacts "$tmpdir"
    fix_permissions "$tmpdir"

    docker create \
        --name "$container_name" \
        -e BLAKE_TARGET="$target" \
        -e BLAKE_JOBS="$jobs" \
        -v "$tmpdir:/build/$COIN_NAME:rw" \
        "$DOCKER_MACOS" \
        /bin/bash -lc '
set -euo pipefail
cd /build/'"$COIN_NAME"'

HOST="${OSXCROSS_HOST:-}"
if [[ -z "$HOST" ]]; then
    HOST=$(ls /opt/osxcross/target/bin/ 2>/dev/null | grep -oE "x86_64-apple-darwin[0-9.]+" | head -1 || true)
fi
if [[ -z "$HOST" ]]; then
    echo "ERROR: Could not detect macOS host triplet"
    exit 1
fi

SDK_ROOT="/opt/osxcross/target/SDK"
SDK_NAME="${OSXCROSS_SDK:-}"
if [[ -z "$SDK_NAME" ]]; then
    SDK_NAME=$(find "$SDK_ROOT" -maxdepth 1 -type d -name "MacOSX*.sdk" -printf "%f\n" | sort | tail -1 || true)
fi
if [[ -z "$SDK_NAME" || ! -d "$SDK_ROOT/$SDK_NAME" ]]; then
    echo "ERROR: Could not locate macOS SDK under $SDK_ROOT"
    exit 1
fi
SDK_VERSION="${SDK_NAME#MacOSX}"
SDK_VERSION="${SDK_VERSION%.sdk}"

LD64_VERSION="$(${HOST}-ld -v 2>&1 | sed -n "s/.*PROJECT:ld64-\([0-9.]*\).*/\1/p" | head -1)"
if [[ -z "$LD64_VERSION" ]]; then
    echo "ERROR: Could not detect ld64 version"
    exit 1
fi

DEPENDS_ARGS=()
if [[ "$BLAKE_TARGET" == "daemon" ]]; then
    DEPENDS_ARGS+=(NO_QT=1)
    CONFIGURE_EXTRA="--without-gui"
else
    CONFIGURE_EXTRA="--with-gui=qt5"
fi

echo ">>> depends environment:"
echo "    HOST=$HOST"
echo "    SDK_ROOT=$SDK_ROOT"
echo "    SDK_NAME=$SDK_NAME"
echo "    SDK_VERSION=$SDK_VERSION"
echo "    LD64_VERSION=$LD64_VERSION"
echo "    TARGET=$BLAKE_TARGET"

echo ">>> Building depends..."
make -C depends \
    HOST="$HOST" \
    SDK_PATH="$SDK_ROOT" \
    OSX_SDK_VERSION="$SDK_VERSION" \
    OSX_MIN_VERSION=11.0 \
    LD64_VERSION="$LD64_VERSION" \
    darwin_native_toolchain= \
    darwin_native_packages= \
    build_CC=clang \
    build_CXX=clang++ \
    NO_ZMQ=1 \
    "${DEPENDS_ARGS[@]}" \
    -j"$BLAKE_JOBS"

echo ">>> Verifying Berkeley DB 4.8 from depends..."
if [[ ! -f "depends/$HOST/include/db_cxx.h" ]]; then
    echo "ERROR: depends prefix is missing db_cxx.h for $HOST"
    exit 1
fi
if [[ ! -f "depends/$HOST/lib/libdb_cxx-4.8.a" || ! -f "depends/$HOST/lib/libdb-4.8.a" ]]; then
    echo "ERROR: depends prefix is not using Berkeley DB 4.8 static libs for $HOST"
    exit 1
fi

BOOST_PREFIX="$PWD/depends/$HOST"
CONFIGURE_EXTRA="$CONFIGURE_EXTRA --with-boost=$BOOST_PREFIX --with-boost-libdir=$BOOST_PREFIX/lib"

echo ">>> Creating Boost -mt symlinks (configure looks for suffixed versions)..."
for lib in "$BOOST_PREFIX"/lib/libboost_*.a; do
    [ -e "$lib" ] || continue
    case "$lib" in
        *-mt.a) continue ;;
    esac
    mt="${lib%.a}-mt.a"
    [ -f "$mt" ] || ln -sf "$(basename "$lib")" "$mt"
done

echo ">>> Running autogen.sh..."
./autogen.sh

echo ">>> Configuring with CONFIG_SITE..."
CONFIG_SITE="$PWD/depends/$HOST/share/config.site" \
CXXFLAGS="${CXXFLAGS:-} -Wno-enum-constexpr-conversion" \
OBJCXXFLAGS="${OBJCXXFLAGS:-} -Wno-enum-constexpr-conversion" \
./configure \
    --prefix=/ \
    --disable-tests \
    --disable-bench \
    --disable-zmq \
    $CONFIGURE_EXTRA

echo ">>> Building Blakecoin..."
make -j"$BLAKE_JOBS"

if [[ "$BLAKE_TARGET" == "qt" || "$BLAKE_TARGET" == "both" ]]; then
    if [[ -f share/qt/Info.plist ]]; then
        sed -i \
            -e "s/Bitcoin-Qt/Blakecoin-Qt/g" \
            -e "s/org.bitcoinfoundation.Bitcoin-Qt/org.blakecoin.Blakecoin-Qt/g" \
            -e "s/org.bitcoin.BitcoinPayment/org.blakecoin.BlakecoinPayment/g" \
            -e "s/org.bitcoin.paymentrequest/org.blakecoin.paymentrequest/g" \
            -e "s/Bitcoin payment request/Blakecoin payment request/g" \
            -e "s/application\\/x-bitcoin-payment-request/application\\/x-blakecoin-payment-request/g" \
            -e "s|<string>bitcoin</string>|<string>blakecoin</string>|g" \
            share/qt/Info.plist
    fi

    echo ">>> Creating app bundle..."
    make appbundle

    if [[ -d Bitcoin-Qt.app ]]; then
        rm -rf Blakecoin-Qt.app
        mv Bitcoin-Qt.app Blakecoin-Qt.app
        if [[ -f Blakecoin-Qt.app/Contents/MacOS/Bitcoin-Qt ]]; then
            mv Blakecoin-Qt.app/Contents/MacOS/Bitcoin-Qt Blakecoin-Qt.app/Contents/MacOS/Blakecoin-Qt
        fi
    fi
fi

echo ">>> Build complete!"
ls -lh src/blakecoind src/blakecoin-cli src/blakecoin-tx 2>/dev/null || true
if [[ "$BLAKE_TARGET" == "qt" || "$BLAKE_TARGET" == "both" ]]; then
    ls -lh src/qt/blakecoin-qt 2>/dev/null || true
    ls -lh Blakecoin-Qt.app/Contents/MacOS/ 2>/dev/null || true
fi
' >/dev/null

    info "Starting build container: $container_name"
    docker start -a "$container_name"

    if [[ "$target" == "daemon" || "$target" == "both" ]]; then
        info "Extracting daemon binaries..."
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoind" "$output_dir/blakecoind-${VERSION}" 2>/dev/null || true
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoin-cli" "$output_dir/blakecoin-cli-${VERSION}" 2>/dev/null || true
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoin-tx" "$output_dir/blakecoin-tx-${VERSION}" 2>/dev/null || true
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        info "Extracting Qt wallet (.app bundle)..."
        rm -rf "$output_dir/Blakecoin-Qt.app" 2>/dev/null || true
        if docker cp "$container_name:/build/$COIN_NAME/Blakecoin-Qt.app" "$output_dir/Blakecoin-Qt.app" 2>/dev/null; then
            find "$output_dir/Blakecoin-Qt.app" -path "*/Contents/MacOS/*" -type f -exec chmod +x {} + 2>/dev/null || true
            success "macOS app bundle extracted to $output_dir/"
        else
            error "Could not find Blakecoin-Qt.app in container"
            docker exec "$container_name" find /build/$COIN_NAME -maxdepth 2 -name "*.app" -type d 2>/dev/null || true
        fi
        docker cp "$container_name:/build/$COIN_NAME/src/qt/blakecoin-qt" "$output_dir/blakecoin-qt-${VERSION}" 2>/dev/null || true
    fi

    build_note="Docker: $DOCKER_MACOS (depends + CONFIG_SITE)"
    write_build_info "$output_dir" "macos" "$target" "$build_note"
    CURRENT_OUTPUT_DIR="$output_dir"
    GENERATE_CONFIG_AFTER_BUILD=0

    docker rm -f "$container_name" 2>/dev/null || true
    docker run --rm -v "$tmpdir:/cleanup" alpine rm -rf /cleanup 2>/dev/null || rm -rf "$tmpdir" 2>/dev/null || true

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL  -  macOS"
    echo "  Output: $output_dir/"
    echo "============================================"
    ls -lh "$output_dir"/* 2>/dev/null || true
}

# =============================================================================
# APPIMAGE BUILD (Docker + autotools + AppDir packaging)
# =============================================================================

build_appimage() {
    local jobs="$1"
    local docker_mode="$2"
    local container_name="appimage-${COIN_NAME}-0152-build"
    local output_dir
    output_dir="$(appimage_output_dir)"
    local appimage_path="$output_dir/${APPIMAGE_PUBLIC_NAME}"

    echo ""
    echo "============================================"
    echo "  AppImage Build: $COIN_NAME_UPPER 0.15.21"
    echo "============================================"
    echo "  Image:  $DOCKER_APPIMAGE"
    echo ""

    ensure_docker_image "$DOCKER_APPIMAGE" "$docker_mode"
    cleanup_legacy_output_root
    rm -rf "$output_dir" "$OUTPUT_BASE/linux-appimage"
    rm -f "$output_dir/${APPIMAGE_PUBLIC_NAME}.tar.gz"
    mkdir -p "$output_dir"
    docker rm -f "$container_name" 2>/dev/null || true

    # Copy source to temp dir
    info "Copying source tree to temp build dir..."
    local tmpdir
    tmpdir=$(mktemp -d)
    copy_source_tree_to_tempdir "$tmpdir"
    clean_stale_build_artifacts "$tmpdir"
    fix_permissions "$tmpdir"

    docker create \
        --name "$container_name" \
        -v "$tmpdir:/build/$COIN_NAME:rw" \
        "$DOCKER_APPIMAGE" \
        /bin/bash -c '
set -e
cd /build/'"$COIN_NAME"'

# Patch sources for Qt 5.15+ and Boost 1.73+ compatibility
echo ">>> Patching sources for modern Ubuntu compatibility..."
if [ -f src/qt/trafficgraphwidget.cpp ]; then
    grep -q "#include <QPainterPath>" src/qt/trafficgraphwidget.cpp || \
        sed -i "1i #include <QPainterPath>" src/qt/trafficgraphwidget.cpp
fi
for f in $(grep -rl "boost::bind" src/ 2>/dev/null | grep "\.cpp$"); do
    grep -q "boost/bind.hpp" "$f" || \
        sed -i "1i #include <boost/bind.hpp>" "$f"
done

echo ">>> Building Qt wallet with autotools..."
./autogen.sh
./configure --disable-tests --disable-bench --enable-upnp-default \
    CXXFLAGS="-O2 -DBOOST_BIND_GLOBAL_PLACEHOLDERS" LDFLAGS="-static-libstdc++"

# Fix missing Qt translation files (Blakecoin fork does not include them)
if [ -f src/Makefile ]; then
    sed -i "s/^QT_QM.*=.*/QT_QM =/" src/Makefile
    sed -i "/bitcoin_.*\.qm/d" src/Makefile
    sed -i "/locale\/.*\.qm/d" src/Makefile
fi
mkdir -p src/qt
cat > src/qt/bitcoin_locale.qrc <<QRC_EOF
<!DOCTYPE RCC><RCC version="1.0">
<qresource prefix="/translations">
</qresource>
</RCC>
QRC_EOF

make -j'"$jobs"'

QT_BIN="src/qt/'"$QT_NAME"'"
if [ ! -f "$QT_BIN" ]; then
    echo "ERROR: Could not find built Qt binary at $QT_BIN"
    find src -name "*qt*" -type f 2>/dev/null
    exit 1
fi
strip "$QT_BIN"

echo ">>> Creating AppDir..."
APPDIR=/build/appdir
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/plugins" \
    "$APPDIR/usr/share/glib-2.0/schemas" "$APPDIR/etc"

cp "$QT_BIN" "$APPDIR/usr/bin/'"$QT_NAME"'"

# Bundle Qt plugins
QT_PLUGIN_DIR=""
for p in /usr/lib/x86_64-linux-gnu/qt5/plugins /usr/lib/qt5/plugins /usr/lib64/qt5/plugins; do
    [ -d "$p" ] && QT_PLUGIN_DIR="$p" && break
done
if [ -n "$QT_PLUGIN_DIR" ]; then
    cp -r "$QT_PLUGIN_DIR/platforms" "$APPDIR/usr/plugins/" 2>/dev/null || true
    for plugin_type in platformthemes platforminputcontexts imageformats; do
        if [ -d "$QT_PLUGIN_DIR/$plugin_type" ]; then
            mkdir -p "$APPDIR/usr/plugins/$plugin_type"
            cp -r "$QT_PLUGIN_DIR/$plugin_type/"* "$APPDIR/usr/plugins/$plugin_type/" 2>/dev/null || true
        fi
    done
fi

# Bundle shared libraries (ldd-based)
echo ">>> Bundling shared libraries..."
for bin in "$APPDIR"/usr/bin/*; do
    [ -f "$bin" ] || continue
    ldd "$bin" 2>/dev/null | grep "=>" | awk "{print \$3}" | grep -v "^\$" | while read -r lib; do
        [ -z "$lib" ] || [ ! -f "$lib" ] && continue
        lib_name=$(basename "$lib")
        case "$lib_name" in
            libc.so*|libdl.so*|libpthread.so*|libm.so*|librt.so*|libgcc_s.so*|libstdc++.so*|ld-linux*)
                ;;
            libfontconfig.so*|libfreetype.so*)
                ;;
            *)
                cp -nL "$lib" "$APPDIR/usr/lib/" 2>/dev/null || true
                ;;
        esac
    done
done

# Bundle Qt plugin dependencies
echo ">>> Bundling Qt plugin dependencies..."
find "$APPDIR/usr/plugins" -name "*.so" 2>/dev/null | while read -r plugin; do
    ldd "$plugin" 2>/dev/null | grep "=>" | awk "{print \$3}" | grep -v "^\$" | while read -r plib; do
        [ -z "$plib" ] || [ ! -f "$plib" ] && continue
        plib_name=$(basename "$plib")
        case "$plib_name" in
            libc.so*|libdl.so*|libpthread.so*|libm.so*|librt.so*|libgcc_s.so*|libstdc++.so*|ld-linux*)
                ;;
            libfontconfig.so*|libfreetype.so*)
                ;;
            *)
                cp -nL "$plib" "$APPDIR/usr/lib/" 2>/dev/null || true
                ;;
        esac
    done
done

# Remove GTK3-related libs (segfault with newer host themes)
rm -f "$APPDIR/usr/lib/libgtk-3.so"* "$APPDIR/usr/lib/libgdk-3.so"*
rm -f "$APPDIR/usr/lib/libatk-bridge-2.0.so"* "$APPDIR/usr/lib/libatspi.so"*
rm -f "$APPDIR/usr/lib/libepoxy.so"*
rm -f "$APPDIR/usr/plugins/platformthemes/libqgtk3.so" 2>/dev/null || true

# Create qt.conf
cat > "$APPDIR/usr/bin/qt.conf" << '\''QTCONF'\''
[Paths]
Plugins = ../plugins
QTCONF

# GSettings schema (cross-Ubuntu compatibility)
SCHEMA_DIR="$APPDIR/usr/share/glib-2.0/schemas"
cat > "$SCHEMA_DIR/org.gnome.settings-daemon.plugins.xsettings.gschema.xml" << '\''SCHEMA_EOF'\''
<?xml version="1.0" encoding="UTF-8"?>
<schemalist>
  <enum id="org.gnome.settings-daemon.GsdFontAntialiasingMode">
    <value nick="none" value="0"/>
    <value nick="grayscale" value="1"/>
    <value nick="rgba" value="2"/>
  </enum>
  <enum id="org.gnome.settings-daemon.GsdFontHinting">
    <value nick="none" value="0"/>
    <value nick="slight" value="1"/>
    <value nick="medium" value="2"/>
    <value nick="full" value="3"/>
  </enum>
  <enum id="org.gnome.settings-daemon.GsdFontRgbaOrder">
    <value nick="rgba" value="0"/>
    <value nick="rgb" value="1"/>
    <value nick="bgr" value="2"/>
    <value nick="vrgb" value="3"/>
    <value nick="vbgr" value="4"/>
  </enum>
  <schema gettext-domain="gnome-settings-daemon" id="org.gnome.settings-daemon.plugins.xsettings" path="/org/gnome/settings-daemon/plugins/xsettings/">
    <key name="disabled-gtk-modules" type="as">
      <default>[]</default>
    </key>
    <key name="enabled-gtk-modules" type="as">
      <default>[]</default>
    </key>
    <key type="a{sv}" name="overrides">
      <default>{}</default>
    </key>
    <key name="antialiasing" enum="org.gnome.settings-daemon.GsdFontAntialiasingMode">
      <default>'\''grayscale'\''</default>
    </key>
    <key name="hinting" enum="org.gnome.settings-daemon.GsdFontHinting">
      <default>'\''slight'\''</default>
    </key>
    <key name="rgba-order" enum="org.gnome.settings-daemon.GsdFontRgbaOrder">
      <default>'\''rgb'\''</default>
    </key>
  </schema>
</schemalist>
SCHEMA_EOF
glib-compile-schemas "$SCHEMA_DIR" 2>/dev/null || echo "WARNING: glib-compile-schemas failed"

# Minimal OpenSSL config
mkdir -p "$APPDIR/etc"
cat > "$APPDIR/etc/openssl.cnf" << '\''SSL_EOF'\''
openssl_conf = openssl_init
[openssl_init]
ssl_conf = ssl_sect
[ssl_sect]
system_default = system_default_sect
[system_default_sect]
MinProtocol = TLSv1.2
SSL_EOF

# Desktop file
cat > "$APPDIR/'"$COIN_NAME"'.desktop" << '\''DESKTOP_EOF'\''
[Desktop Entry]
Type=Application
Name='"$COIN_NAME_UPPER"'
Comment='"$COIN_NAME_UPPER"' 0.15.21 Cryptocurrency Wallet
Exec='"$QT_NAME"'
Icon='"$COIN_NAME"'
Categories=Network;Finance;
Terminal=false
StartupWMClass='"$QT_NAME"'
DESKTOP_EOF
mkdir -p "$APPDIR/usr/share/applications"
cp "$APPDIR/'"$COIN_NAME"'.desktop" "$APPDIR/usr/share/applications/"

# Icon
ICON_DIR="$APPDIR/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$ICON_DIR"
if [ -f src/qt/res/icons/bitcoin.png ]; then
    cp src/qt/res/icons/bitcoin.png "$ICON_DIR/'"$COIN_NAME"'.png"
else
    echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==" | base64 -d > "$ICON_DIR/'"$COIN_NAME"'.png"
fi
ln -sf "usr/share/icons/hicolor/256x256/apps/'"$COIN_NAME"'.png" "$APPDIR/'"$COIN_NAME"'.png"

# AppRun script
cat > "$APPDIR/AppRun" << '\''APPRUN_EOF'\''
#!/bin/bash
APPDIR="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$APPDIR/usr/lib:$LD_LIBRARY_PATH"
export PATH="$APPDIR/usr/bin:$PATH"

export GSETTINGS_SCHEMA_DIR="$APPDIR/usr/share/glib-2.0/schemas"
export GSETTINGS_BACKEND=memory
export GIO_MODULE_DIR="$APPDIR/usr/lib/gio/modules"

if [ -d "$APPDIR/usr/plugins" ]; then
    export QT_PLUGIN_PATH="$APPDIR/usr/plugins"
fi

export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}"
export QT_STYLE_OVERRIDE=Fusion
export XDG_DATA_DIRS="$APPDIR/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export OPENSSL_CONF="$APPDIR/etc/openssl.cnf"

# Desktop integration
_ICON_NAME="'"$COIN_NAME"'"
_QT_NAME="'"$QT_NAME"'"
_WM_CLASS="'"$COIN_NAME_UPPER"'-Qt"
_COIN_NAME="'"$COIN_NAME_UPPER"'"
_APPIMAGE_PATH="${APPIMAGE:-$0}"
_ICON_SRC="$APPDIR/usr/share/icons/hicolor/256x256/apps/${_ICON_NAME}.png"
_ICON_DST="$HOME/.local/share/icons/hicolor/256x256/apps/${_ICON_NAME}.png"
_DESKTOP_DST="$HOME/.local/share/applications/${_QT_NAME}.desktop"

if [ -f "$_ICON_SRC" ]; then
    mkdir -p "$(dirname "$_ICON_DST")" "$(dirname "$_DESKTOP_DST")" 2>/dev/null
    cp "$_ICON_SRC" "$_ICON_DST" 2>/dev/null
    cat > "$_DESKTOP_DST" <<_DEOF
[Desktop Entry]
Type=Application
Name=$_COIN_NAME
Icon=$_ICON_DST
Exec=$_APPIMAGE_PATH
Terminal=false
Categories=Finance;Network;
StartupWMClass=$_WM_CLASS
_DEOF
    chmod +x "$_DESKTOP_DST" 2>/dev/null
fi

exec "$APPDIR/usr/bin/'"$QT_NAME"'" "$@"
APPRUN_EOF
chmod +x "$APPDIR/AppRun"

echo ">>> Creating AppImage..."
mkdir -p /build/output
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 appimagetool --no-appstream "$APPDIR" \
    "/build/output/'"$COIN_NAME_UPPER"'-0.15.21-x86_64.AppImage"
chmod +x "/build/output/'"$COIN_NAME_UPPER"'-0.15.21-x86_64.AppImage"

echo ">>> AppImage build complete!"
ls -lh /build/output/
'

    info "Starting build container: $container_name"
    docker start -a "$container_name"

    info "Extracting AppImage..."
    if docker cp "$container_name:/build/output/${APPIMAGE_PUBLIC_NAME}" "$appimage_path" 2>/dev/null; then
        success "AppImage extracted to $output_dir/"
        ls -lh "$appimage_path"
    else
        error "Could not find AppImage in container"
        docker rm -f "$container_name" 2>/dev/null || true
        exit 1
    fi

    write_build_info "$output_dir" "appimage" "qt" "Docker: $DOCKER_APPIMAGE"
    write_appimage_bundle_readme "$output_dir/README.md"
    CURRENT_OUTPUT_DIR="$output_dir"
    GENERATE_CONFIG_AFTER_BUILD=0
    docker rm -f "$container_name" 2>/dev/null || true
    docker run --rm -v "$tmpdir:/cleanup" alpine rm -rf /cleanup 2>/dev/null || rm -rf "$tmpdir" 2>/dev/null || true

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL  -  AppImage"
    echo "  Output: $appimage_path"
    echo "  Note:   Ubuntu 22.04.5 direct launch needs libfuse2"
    echo "          Ubuntu 24.04.4 / 25.10 direct launch needs libfuse2t64"
    echo "          Otherwise use --appimage-extract-and-run"
    echo "============================================"
}

# =============================================================================
# NATIVE BUILD (Docker  -  runs autotools inside container)
# =============================================================================

build_native_docker() {
    local target="$1"
    local jobs="$2"
    local docker_mode="$3"
    local ubuntu_ver=""
    local final_output_dir=""
    local install_packages=""
    local daemon_stage="$OUTPUT_BASE/.linux-native-stage/daemon"
    local qt_stage="$OUTPUT_BASE/.linux-native-stage/qt"

    echo ""
    echo "============================================"
    echo "  Native Docker Build: $COIN_NAME_UPPER 0.15.21"
    echo "============================================"
    echo "  Image:  $DOCKER_NATIVE"
    echo "  Target: $target"
    echo ""

    ensure_docker_image "$DOCKER_NATIVE" "$docker_mode"
    ubuntu_ver="$(detect_native_docker_ubuntu_version)"
    cleanup_legacy_output_root
    rm -rf "$OUTPUT_BASE/native" "$OUTPUT_BASE/.linux-native-stage"
    mkdir -p "$daemon_stage" "$qt_stage"
    resolve_native_linux_packages "$target"
    install_packages="$NATIVE_LINUX_ALL_DEPS_STR"

    # Copy source to temp dir. Use rsync with explicit excludes so stale local
    # outputs and builder-only scratch trees do not leak into native container
    # builds or fail due to root-owned files left behind by prior cross-builds.
    info "Copying source tree to temp build dir..."
    local tmpdir
    tmpdir=$(mktemp -d)
    copy_source_tree_to_tempdir "$tmpdir"
    clean_stale_build_artifacts "$tmpdir"
    fix_permissions "$tmpdir"

    local configure_extra=""
    case "$target" in
        daemon) configure_extra="--without-gui" ;;
        qt)     configure_extra="--with-gui=qt5" ;;
        both)   configure_extra="--with-gui=qt5" ;;
    esac

    local container_name="${NATIVE_CONTAINER_NAME:-native-${COIN_NAME}-0152-build}"
    docker rm -f "$container_name" 2>/dev/null || true

    docker create \
        --name "$container_name" \
        -v "$tmpdir:/build/$COIN_NAME:rw" \
        "$DOCKER_NATIVE" \
        /bin/bash -c '
set -e
cd /build/'"$COIN_NAME"'

# Patch sources for Qt 5.15+ and Boost 1.73+ compatibility
echo ">>> Patching sources for modern Ubuntu compatibility..."
# QPainterPath split into separate header in Qt 5.15
if [ -f src/qt/trafficgraphwidget.cpp ]; then
    grep -q "#include <QPainterPath>" src/qt/trafficgraphwidget.cpp || \
        sed -i "1i #include <QPainterPath>" src/qt/trafficgraphwidget.cpp
fi
# Boost 1.73+ moved bind placeholders (_1, _2, etc.) to boost::placeholders namespace
# Files that use boost::bind but include it transitively need an explicit include
# to trigger BOOST_BIND_GLOBAL_PLACEHOLDERS
for f in $(grep -rl "boost::bind" src/ 2>/dev/null | grep "\.cpp$"); do
    grep -q "boost/bind.hpp" "$f" || \
        sed -i "1i #include <boost/bind.hpp>" "$f"
done

echo ">>> Running autogen.sh..."
./autogen.sh

echo ">>> Configuring..."
./configure --disable-tests --disable-bench '"$configure_extra"' \
    CXXFLAGS="-O2 -DBOOST_BIND_GLOBAL_PLACEHOLDERS"

# Fix missing Qt translation files (Blakecoin fork does not include them)
if [ -f src/Makefile ]; then
    sed -i "s/^QT_QM.*=.*/QT_QM =/" src/Makefile
    sed -i "/bitcoin_.*\.qm/d" src/Makefile
    sed -i "/locale\/.*\.qm/d" src/Makefile
fi
mkdir -p src/qt
cat > src/qt/bitcoin_locale.qrc <<QRC_EOF
<!DOCTYPE RCC><RCC version="1.0">
<qresource prefix="/translations">
</qresource>
</RCC>
QRC_EOF

echo ">>> Building..."
make -j'"$jobs"'

echo ">>> Stripping binaries..."
strip src/blakecoind 2>/dev/null || true
strip src/qt/blakecoin-qt 2>/dev/null || true
strip src/blakecoin-cli 2>/dev/null || true
strip src/blakecoin-tx 2>/dev/null || true

echo ">>> Build complete!"
ls -lh src/blakecoind src/qt/blakecoin-qt src/blakecoin-cli src/blakecoin-tx 2>/dev/null || true
'

    info "Starting build container: $container_name"
    docker start -a "$container_name"

    # Extract binaries
    if [[ "$target" == "daemon" || "$target" == "both" ]]; then
        info "Extracting daemon binaries..."
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoind" "$daemon_stage/blakecoind-${VERSION}" 2>/dev/null || true
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoin-cli" "$daemon_stage/blakecoin-cli-${VERSION}" 2>/dev/null || true
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoin-tx" "$daemon_stage/blakecoin-tx-${VERSION}" 2>/dev/null || true
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        info "Extracting Qt wallet..."
        docker cp "$container_name:/build/$COIN_NAME/src/qt/blakecoin-qt" "$qt_stage/blakecoin-qt-${VERSION}" 2>/dev/null || true
    fi

    finalize_linux_native_output \
        "$ubuntu_ver" \
        "$target" \
        "$daemon_stage/blakecoind-${VERSION}" \
        "$daemon_stage/blakecoin-cli-${VERSION}" \
        "$daemon_stage/blakecoin-tx-${VERSION}" \
        "$qt_stage/blakecoin-qt-${VERSION}" \
        "$install_packages"

    final_output_dir="$(linux_output_dir "$ubuntu_ver")"

    docker rm -f "$container_name" 2>/dev/null || true
    docker run --rm -v "$tmpdir:/cleanup" alpine rm -rf /cleanup 2>/dev/null || rm -rf "$tmpdir" 2>/dev/null || true
    rm -rf "$OUTPUT_BASE/.linux-native-stage"

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL  -  Native (Docker)"
    echo "  Output: $final_output_dir/"
    echo "============================================"
}

# =============================================================================
# NATIVE BUILD (Direct  -  no Docker)
# =============================================================================

build_native_direct() {
    local target="$1"
    local jobs="$2"

    local os
    os=$(detect_os)

    case "$os" in
        linux)   build_native_linux_direct "$target" "$jobs" ;;
        macos)   build_native_macos "$target" "$jobs" ;;
        windows) build_native_windows "$target" "$jobs" ;;
    esac
}

build_native_linux_direct() {
    local target="$1"
    local jobs="$2"
    local final_output_dir=""
    local install_packages=""

    echo ""
    echo "============================================"
    echo "  Native Linux Build: $COIN_NAME_UPPER 0.15.21"
    echo "============================================"
    echo ""

    # Detect Ubuntu version
    local ubuntu_ver=""
    if [[ -f /etc/os-release ]]; then
        ubuntu_ver=$(. /etc/os-release && echo "$VERSION_ID")
    fi
    info "Detected OS: Ubuntu ${ubuntu_ver:-unknown}"

    resolve_native_linux_packages "$target"
    install_packages="$NATIVE_LINUX_ALL_DEPS_STR"

    # Check and auto-install missing packages
    info "Checking and installing dependencies..."
    local missing_pkgs=()
    for pkg in "${NATIVE_LINUX_ALL_DEPS[@]}"; do
        dpkg -s "$pkg" &>/dev/null 2>&1 || missing_pkgs+=("$pkg")
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        info "Installing missing packages: ${missing_pkgs[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${missing_pkgs[@]}"
    else
        info "All dependencies already installed"
    fi

    cleanup_legacy_output_root
    rm -rf "$OUTPUT_BASE/native"
    local linux_bdb_prefix=""
    linux_bdb_prefix="$(ensure_repo_bdb48 linux "linux-$(uname -m)" "$jobs")" || return 1

    local configure_extra=""
    case "$target" in
        daemon) configure_extra="--without-gui" ;;
        qt)     configure_extra="--with-gui=qt5" ;;
        both)   configure_extra="--with-gui=qt5" ;;
    esac

    cd "$SCRIPT_DIR"

    # Patch sources for Qt 5.15+ and Boost 1.73+ compatibility
    if [[ -f src/qt/trafficgraphwidget.cpp ]]; then
        grep -q "#include <QPainterPath>" src/qt/trafficgraphwidget.cpp || \
            sedi '1i #include <QPainterPath>' src/qt/trafficgraphwidget.cpp
    fi

    # MSYS2 Boost 1.90 provides Boost.System as a header-only component,
    # so the legacy AX_BOOST_SYSTEM macro must not hard-fail on a missing
    # libboost_system archive.
    if [[ -n "${MSYSTEM:-}" ]] && ! compgen -G "/mingw64/lib/libboost_system*" >/dev/null && [[ -f build-aux/m4/ax_boost_system.m4 ]]; then
        info "MSYS2 Boost.System is header-only  -  patching AX_BOOST_SYSTEM"
        perl -0pi -e 's/AC_MSG_ERROR\(Could not find a version of the boost_system library!\)/BOOST_SYSTEM_LIB=""; AC_SUBST(BOOST_SYSTEM_LIB); link_system="yes"/g' build-aux/m4/ax_boost_system.m4
    fi

    info "Running autogen.sh..."
    ./autogen.sh

    # Modern MSYS2 ships Boost.System as a header-only component, so there is
    # no libboost_system*.a to locate even though Boost itself is present.
    if [[ -n "${MSYSTEM:-}" ]] && ! compgen -G "/mingw64/lib/libboost_system*" >/dev/null && [[ -f build-aux/m4/ax_boost_system.m4 ]]; then
        info "MSYS2 Boost.System is header-only  -  patching AX_BOOST_SYSTEM for no-library mode"
        perl -0pi -e 's/AC_MSG_ERROR\(Could not find a version of the boost_system library!\)/BOOST_SYSTEM_LIB=""; AC_SUBST(BOOST_SYSTEM_LIB); link_system="yes"/g' build-aux/m4/ax_boost_system.m4
    fi

    info "Configuring..."
    ./configure --disable-tests --disable-bench $configure_extra \
        BDB_CFLAGS="-I$linux_bdb_prefix/include" \
        BDB_LIBS="-L$linux_bdb_prefix/lib -ldb_cxx-4.8 -ldb-4.8" \
        CXXFLAGS="-O2 -DBOOST_BIND_GLOBAL_PLACEHOLDERS"

    # Fix missing Qt translation files (Blakecoin fork does not include them)
    if [[ -f src/Makefile ]]; then
        sedi 's/^QT_QM.*=.*/QT_QM =/' src/Makefile
        sedi '/bitcoin_.*\.qm/d' src/Makefile
        sedi '/locale\/.*\.qm/d' src/Makefile
    fi
    mkdir -p src/qt
    cat > src/qt/bitcoin_locale.qrc <<'QRC_EOF'
<!DOCTYPE RCC><RCC version="1.0">
<qresource prefix="/translations">
</qresource>
</RCC>
QRC_EOF

    info "Building with $jobs jobs..."
    make -j"$jobs"

    if [[ "$target" == "daemon" || "$target" == "both" ]]; then
        info "Relinking native Linux daemon tools against Berkeley DB 4.8..."
        relink_native_linux_target "blakecoind" "$SCRIPT_DIR/src/blakecoind"
        relink_native_linux_target "blakecoin-cli" "$SCRIPT_DIR/src/blakecoin-cli"
        relink_native_linux_target "blakecoin-tx" "$SCRIPT_DIR/src/blakecoin-tx"
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        info "Relinking native Linux Qt wallet against Berkeley DB 4.8..."
        relink_native_linux_target "qt/blakecoin-qt" "$SCRIPT_DIR/src/qt/blakecoin-qt"
    fi

    if [[ "$target" == "daemon" || "$target" == "both" ]]; then
        strip src/blakecoind src/blakecoin-cli src/blakecoin-tx 2>/dev/null || true
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        strip src/qt/blakecoin-qt 2>/dev/null || true
    fi

    finalize_linux_native_output \
        "$ubuntu_ver" \
        "$target" \
        "$SCRIPT_DIR/src/blakecoind" \
        "$SCRIPT_DIR/src/blakecoin-cli" \
        "$SCRIPT_DIR/src/blakecoin-tx" \
        "$SCRIPT_DIR/src/qt/blakecoin-qt" \
        "$install_packages"

    final_output_dir="$(linux_output_dir "$ubuntu_ver")"

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        install_linux_desktop_launcher "$final_output_dir"
    fi

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL  -  Native Linux"
    echo "  Output: $final_output_dir/"
    echo "============================================"
}

build_native_macos() {
    local target="$1"
    local jobs="$2"
    local output_dir
    output_dir="$(macos_output_dir)"
    local app_name="Blakecoin-Qt.app"
    local native_dep_root="$SCRIPT_DIR/.native-macos-deps"
    local protobuf_version="3.12.4"
    local protobuf_archive="$native_dep_root/src/protobuf-cpp-${protobuf_version}.tar.gz"
    local protobuf_src_dir="$native_dep_root/src/protobuf-${protobuf_version}"
    local protobuf_prefix=""

    echo ""
    echo "============================================"
    echo "  Native macOS Build: $COIN_NAME_UPPER 0.15.21"
    echo "============================================"
    echo ""

    ensure_macos_homebrew

    # Check/install dependencies
    local deps=(openssl@3 boost miniupnpc berkeley-db@4 qt@5 libevent pkg-config automake autoconf libtool curl)
    for dep in "${deps[@]}"; do
        if ! brew list "$dep" &>/dev/null; then
            info "Installing $dep..."
            HOMEBREW_NO_AUTO_UPDATE=1 brew install "$dep"
        fi
    done

    local openssl_prefix boost_prefix bdb_prefix qt5_prefix libevent_prefix miniupnpc_prefix
    openssl_prefix=$(brew --prefix openssl@3)
    boost_prefix=$(brew --prefix boost)
    bdb_prefix=$(brew --prefix berkeley-db@4)
    qt5_prefix=$(brew --prefix qt@5)
    libevent_prefix=$(brew --prefix libevent)
    miniupnpc_prefix=$(brew --prefix miniupnpc)

    verify_bdb48_prefix "$bdb_prefix" "Native macOS Homebrew Berkeley DB" || return 1

    cleanup_legacy_output_root
    cleanup_target_output_dir "$output_dir"
    mkdir -p "$native_dep_root/src"

    local configure_extra=""
    case "$target" in
        daemon) configure_extra="--without-gui" ;;
        qt)     configure_extra="--with-gui=qt5" ;;
        both)   configure_extra="--with-gui=qt5" ;;
    esac

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        protobuf_prefix="$native_dep_root/protobuf-${protobuf_version}"
        if [[ ! -x "$protobuf_prefix/bin/protoc" || ! -f "$protobuf_prefix/lib/pkgconfig/protobuf.pc" ]]; then
            info "Building protobuf ${protobuf_version} for native macOS compatibility..."
            rm -rf "$protobuf_src_dir" "$protobuf_prefix"
            curl -L "https://github.com/protocolbuffers/protobuf/releases/download/v${protobuf_version}/protobuf-cpp-${protobuf_version}.tar.gz" -o "$protobuf_archive"
            tar -xzf "$protobuf_archive" -C "$native_dep_root/src"
            (
                cd "$protobuf_src_dir"
                ./configure --prefix="$protobuf_prefix" --disable-shared --enable-static \
                    CFLAGS="-O2" CXXFLAGS="-O2 -std=c++11"
                make -j"$jobs"
                make install
            )
        fi
        export PATH="$qt5_prefix/bin:$protobuf_prefix/bin:$PATH"
    else
        export PATH="$qt5_prefix/bin:$PATH"
    fi

    local pkg_config_path="$openssl_prefix/lib/pkgconfig:$qt5_prefix/lib/pkgconfig:$libevent_prefix/lib/pkgconfig:$miniupnpc_prefix/lib/pkgconfig"
    local cppflags="-I$bdb_prefix/include -I$boost_prefix/include -I$openssl_prefix/include -I$miniupnpc_prefix/include -I$libevent_prefix/include"
    local ldflags="-L$bdb_prefix/lib -L$boost_prefix/lib -L$openssl_prefix/lib -L$miniupnpc_prefix/lib -L$libevent_prefix/lib"
    local protoc_bin=""
    configure_extra="$configure_extra --with-boost=$boost_prefix --with-boost-libdir=$boost_prefix/lib"
    if [[ -n "$protobuf_prefix" ]]; then
        pkg_config_path="$protobuf_prefix/lib/pkgconfig:$pkg_config_path"
        cppflags="$cppflags -I$protobuf_prefix/include"
        ldflags="$ldflags -L$protobuf_prefix/lib"
        protoc_bin="$protobuf_prefix/bin/protoc"
    fi

    cd "$SCRIPT_DIR"

    # Modern Homebrew Boost can ship Boost.System as a header-only component,
    # so the legacy AX_BOOST_SYSTEM macro must not hard-fail on a missing
    # libboost_system library during native macOS configure.
    if ! compgen -G "$boost_prefix/lib/libboost_system*" >/dev/null && [[ -f build-aux/m4/ax_boost_system.m4 ]]; then
        info "Homebrew Boost.System is header-only  -  patching AX_BOOST_SYSTEM"
        python3 - <<'PY'
from pathlib import Path

replacement_old = """            if test "x$ax_lib" = "x"; then
                AC_MSG_ERROR(Could not find a version of the boost_system library!)
            fi
\t\t\tif test "x$link_system" = "xno"; then
\t\t\t\tAC_MSG_ERROR(Could not link against $ax_lib !)
\t\t\tfi"""

replacement_new = """            if test "x$ax_lib" = "x"; then
                BOOST_SYSTEM_LIB=""
                AC_SUBST(BOOST_SYSTEM_LIB)
                link_system="yes"
            fi
\t\t\tif test "x$link_system" = "xno" && test "x$ax_lib" != "x"; then
\t\t\t\tAC_MSG_ERROR(Could not link against $ax_lib !)
\t\t\tfi"""

p = Path("build-aux/m4/ax_boost_system.m4")
text = p.read_text()
if replacement_old in text:
    p.write_text(text.replace(replacement_old, replacement_new))
PY
    fi

    info "Running autogen.sh..."
    ./autogen.sh

    # Patch sources for Qt 5.15+ and Boost 1.73+ compatibility
    if [[ -f src/qt/trafficgraphwidget.cpp ]]; then
        grep -q "#include <QPainterPath>" src/qt/trafficgraphwidget.cpp || \
            sedi '1i #include <QPainterPath>' src/qt/trafficgraphwidget.cpp
    fi
    while IFS= read -r boost_bind_file; do
        grep -q "boost/bind.hpp" "$boost_bind_file" || \
            perl -0pi -e 's/\A/#include <boost\/bind.hpp>\n/' "$boost_bind_file"
    done < <(grep -rl "boost::bind" src/ 2>/dev/null | grep '\.cpp$' || true)

    info "Configuring..."
    ./configure --disable-tests --disable-bench --disable-zmq $configure_extra \
        CXXFLAGS="-O2 -DBOOST_BIND_GLOBAL_PLACEHOLDERS -Wno-enum-constexpr-conversion" \
        OBJCXXFLAGS="-O2 -Wno-enum-constexpr-conversion" \
        PKG_CONFIG_PATH="$pkg_config_path" \
        CPPFLAGS="$cppflags" \
        LDFLAGS="$ldflags" \
        BDB_CFLAGS="-I$bdb_prefix/include" \
        BDB_LIBS="-L$bdb_prefix/lib -ldb_cxx-4.8 -ldb-4.8" \
        PROTOC="$protoc_bin"

    # Fix missing Qt translation files (Blakecoin fork does not include them)
    if [[ -f src/Makefile ]]; then
        python3 - <<PY
from pathlib import Path

p = Path("src/Makefile")
text = p.read_text()
text = text.replace("-I/usr/local/include", "-I${boost_prefix}/include")
p.write_text(text)
PY
        sedi 's/^QT_QM.*=.*/QT_QM =/' src/Makefile
        sedi '/bitcoin_.*\.qm/d' src/Makefile
        sedi '/locale\/.*\.qm/d' src/Makefile
    fi
    if [[ "$target" == "qt" || "$target" == "both" ]] && command -v protoc &>/dev/null && [[ -f src/qt/paymentrequest.proto ]]; then
        info "Regenerating paymentrequest protobuf sources for native macOS protobuf..."
        (
            cd src/qt
            protoc --cpp_out=. paymentrequest.proto
        )
    fi
    mkdir -p src/qt
    cat > src/qt/bitcoin_locale.qrc <<'QRC_EOF'
<!DOCTYPE RCC><RCC version="1.0">
<qresource prefix="/translations">
</qresource>
</RCC>
QRC_EOF

    info "Building with $jobs jobs..."
    make -j"$jobs"

    if [[ "$target" == "daemon" || "$target" == "both" ]]; then
        strip src/blakecoind src/blakecoin-cli src/blakecoin-tx 2>/dev/null || true
        cp src/blakecoind "$output_dir/blakecoind-${VERSION}"
        cp src/blakecoin-cli "$output_dir/blakecoin-cli-${VERSION}"
        cp src/blakecoin-tx "$output_dir/blakecoin-tx-${VERSION}"
        success "Daemon binaries in $output_dir/"
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        strip src/qt/blakecoin-qt 2>/dev/null || true
        cp src/qt/blakecoin-qt "$output_dir/blakecoin-qt-${VERSION}"

        rm -rf "$output_dir/$app_name"
        mkdir -p "$output_dir/$app_name/Contents/MacOS" "$output_dir/$app_name/Contents/Resources"
        cp src/qt/blakecoin-qt "$output_dir/$app_name/Contents/MacOS/Blakecoin-Qt"

        local icons_dir="$SCRIPT_DIR/src/qt/res/icons"
        if [[ -f "$icons_dir/bitcoin.png" ]] && command -v sips &>/dev/null && command -v iconutil &>/dev/null; then
            info "Generating macOS icon from bitcoin.png..."
            local iconset_root iconset_dir size size2
            iconset_root=$(mktemp -d)
            iconset_dir="$iconset_root/blakecoin.iconset"
            mkdir -p "$iconset_dir"
            for size in 16 32 128 256 512; do
                sips -z "$size" "$size" "$icons_dir/bitcoin.png" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null 2>&1 || true
                size2=$((size * 2))
                sips -z "$size2" "$size2" "$icons_dir/bitcoin.png" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || true
            done
            iconutil -c icns "$iconset_dir" -o "$output_dir/$app_name/Contents/Resources/blakecoin.icns" 2>/dev/null || true
            rm -rf "$iconset_root"
        fi

        cat > "$output_dir/$app_name/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Blakecoin-Qt</string>
    <key>CFBundleIdentifier</key>
    <string>org.blakecoin.Blakecoin-Qt</string>
    <key>CFBundleName</key>
    <string>Blakecoin-Qt</string>
    <key>CFBundleDisplayName</key>
    <string>Blakecoin Core</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleIconFile</key>
    <string>blakecoin</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST_EOF

        if [[ -x "$qt5_prefix/bin/macdeployqt" ]]; then
            info "Bundling Qt frameworks with macdeployqt..."
            "$qt5_prefix/bin/macdeployqt" "$output_dir/$app_name" >/dev/null 2>&1 || warn "macdeployqt failed; leaving native bundle unmodified"
        fi

        info "Resolving transitive dylib dependencies for native macOS bundle..."
        bundle_macos_transitive_dylibs \
            "$output_dir/$app_name" \
            "$boost_prefix/lib" \
            "$openssl_prefix/lib" \
            "$bdb_prefix/lib" \
            "$libevent_prefix/lib" \
            "$miniupnpc_prefix/lib" \
            "$qt5_prefix/lib"

        codesign --force --deep --sign - "$output_dir/$app_name" 2>/dev/null || true
        success "Qt wallet in $output_dir/"
    fi

    write_build_info "$output_dir" "native-macos" "$target" "$(detect_os_version macos)"
    CURRENT_OUTPUT_DIR="$output_dir"
    GENERATE_CONFIG_AFTER_BUILD=1

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL  -  Native macOS"
    echo "  Output: $output_dir/"
    echo "============================================"
}

build_native_windows() {
    local target="$1"
    local jobs="$2"
    local output_dir
    output_dir="$(windows_output_dir)"
    local native_windows_debug_symbols="${NATIVE_WINDOWS_DEBUG_SYMBOLS:-0}"
    local mingw_triplet=""
    local native_dep_root="$SCRIPT_DIR/.native-windows-deps"
    local protobuf_version="3.12.4"
    local protobuf_archive="$native_dep_root/src/protobuf-cpp-${protobuf_version}.tar.gz"
    local protobuf_src_dir="$native_dep_root/src/protobuf-${protobuf_version}"
    local protobuf_prefix="$native_dep_root/protobuf-${protobuf_version}"
    local msys_packages=(
        autoconf
        automake
        libtool
        make
        pkgconf
        curl
        git
        patch
        perl
        tar
        zip
        unzip
    )
    local mingw_packages=(
        mingw-w64-x86_64-gcc
        mingw-w64-x86_64-pkgconf
        mingw-w64-x86_64-boost
        mingw-w64-x86_64-openssl
        mingw-w64-x86_64-libevent
        mingw-w64-x86_64-miniupnpc
    )
    local windows_cflags="-O2"
    local windows_cxxflags="-O2 -DBOOST_BIND_GLOBAL_PLACEHOLDERS"

    echo ""
    echo "============================================"
    echo "  Native Windows Build: $COIN_NAME_UPPER 0.15.21"
    echo "============================================"
    echo ""

    if [[ "$native_windows_debug_symbols" == "1" ]]; then
        # Keep native Windows release builds fast and stripped by default, but
        # allow a symbolized debug build when we need to map a crash offset.
        windows_cflags="-g -O0"
        windows_cxxflags="-g -O0 -DBOOST_BIND_GLOBAL_PLACEHOLDERS"
        info "Native Windows debug symbols enabled (no strip, -g -O0)."
    fi

    ensure_windows_icon_assets
    ensure_windows_native_shell "$target" "$jobs"

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        mingw_packages+=(
            mingw-w64-x86_64-qt5-base
            mingw-w64-x86_64-qt5-tools
            mingw-w64-x86_64-qrencode
        )
    fi

    info "Installing required MSYS2 packages..."
    pacman -S --needed --noconfirm "${msys_packages[@]}" "${mingw_packages[@]}"

    # MSYS2 names the Qt5 tools with a -qt5 suffix.
    if ! command -v qmake &>/dev/null && command -v qmake-qt5 &>/dev/null; then
        ln -sf "$(command -v qmake-qt5)" /mingw64/bin/qmake 2>/dev/null || true
    fi
    if ! command -v lrelease &>/dev/null && command -v lrelease-qt5 &>/dev/null; then
        ln -sf "$(command -v lrelease-qt5)" /mingw64/bin/lrelease 2>/dev/null || true
    fi
    if ! command -v moc &>/dev/null && [[ -x /mingw64/bin/moc.exe ]]; then
        ln -sf /mingw64/bin/moc.exe /mingw64/bin/moc 2>/dev/null || true
    fi
    if ! command -v uic &>/dev/null && [[ -x /mingw64/bin/uic.exe ]]; then
        ln -sf /mingw64/bin/uic.exe /mingw64/bin/uic 2>/dev/null || true
    fi
    if ! command -v rcc &>/dev/null && [[ -x /mingw64/bin/rcc.exe ]]; then
        ln -sf /mingw64/bin/rcc.exe /mingw64/bin/rcc 2>/dev/null || true
    fi

    local missing_tools=()
    local tool
    for tool in curl pkg-config make gcc g++ strip ldd autoconf automake libtoolize; do
        command -v "$tool" &>/dev/null || missing_tools+=("$tool")
    done
    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        command -v qmake &>/dev/null || command -v qmake-qt5 &>/dev/null || missing_tools+=("qmake")
        command -v lrelease &>/dev/null || command -v lrelease-qt5 &>/dev/null || missing_tools+=("lrelease")
    fi
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        error "Missing required MSYS2 tools after install: ${missing_tools[*]}"
        exit 1
    fi

    cleanup_legacy_output_root
    cleanup_target_output_dir "$output_dir"
    mingw_triplet="$(gcc -dumpmachine)"
    local windows_bdb_prefix=""
    windows_bdb_prefix="$(ensure_repo_bdb48 mingw "mingw64-$(printf '%s' "$mingw_triplet" | tr '/' '_')" "$jobs")" || return 1

    local configure_extra=""
    case "$target" in
        daemon) configure_extra="--without-gui" ;;
        qt)     configure_extra="--with-gui=qt5" ;;
        both)   configure_extra="--with-gui=qt5" ;;
    esac
    configure_extra="$configure_extra --host=$mingw_triplet --build=$mingw_triplet"

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        # MSYS2 pkg-config reports Qt host tool paths in Windows form
        # (for example C:/msys64/...), which the autotools Qt macros do not
        # reliably resolve under this native SSH/MSYS2 build flow.
        configure_extra="$configure_extra --with-qt-bindir=/mingw64/bin"
        export PATH="/mingw64/bin:/usr/bin:$PATH"
        export MOC="${MOC:-/mingw64/bin/moc}"
        export UIC="${UIC:-/mingw64/bin/uic}"
        export RCC="${RCC:-/mingw64/bin/rcc}"
        export LRELEASE="${LRELEASE:-/mingw64/bin/lrelease}"
        export LUPDATE="${LUPDATE:-$(command -v lupdate 2>/dev/null || command -v lupdate-qt5 2>/dev/null || printf '%s' /mingw64/bin/lupdate-qt5.exe)}"
    fi

    # Modern MSYS2 uses Boost 1.90 with -mt library names for the compiled
    # components that Blakecoin links against.
    configure_extra="$configure_extra --with-boost=/mingw64 --with-boost-libdir=/mingw64/lib"
    configure_extra="$configure_extra --with-boost-filesystem=boost_filesystem-mt"
    configure_extra="$configure_extra --with-boost-program-options=boost_program_options-mt"
    configure_extra="$configure_extra --with-boost-thread=boost_thread-mt"
    configure_extra="$configure_extra --with-boost-chrono=boost_chrono-mt"

    cd "$SCRIPT_DIR"
    normalize_windows_source_timestamps

    # Patch sources for Qt 5.15+ and Boost 1.73+ compatibility
    if [[ -f src/qt/trafficgraphwidget.cpp ]]; then
        grep -q "#include <QPainterPath>" src/qt/trafficgraphwidget.cpp || \
            sedi '1i #include <QPainterPath>' src/qt/trafficgraphwidget.cpp
    fi

    # Modern MSYS2 ships Boost.System as a header-only component, so there is
    # no libboost_system*.a to locate even though Boost itself is present.
    if ! compgen -G "/mingw64/lib/libboost_system*" >/dev/null; then
        info "MSYS2 Boost.System is header-only  -  patching legacy boost_system detection"
        python3 - <<'PY'
from pathlib import Path

replacement_old = """            if test "x$ax_lib" = "x"; then
                AC_MSG_ERROR(Could not find a version of the boost_system library!)
            fi
\t\t\tif test "x$link_system" = "xno"; then
\t\t\t\tAC_MSG_ERROR(Could not link against $ax_lib !)
\t\t\tfi"""

replacement_new = """            if test "x$ax_lib" = "x"; then
                BOOST_SYSTEM_LIB=""
                AC_SUBST(BOOST_SYSTEM_LIB)
                link_system="yes"
            fi
\t\t\tif test "x$link_system" = "xno" && test "x$ax_lib" != "x"; then
\t\t\t\tAC_MSG_ERROR(Could not link against $ax_lib !)
\t\t\tfi"""

for rel in ("build-aux/m4/ax_boost_system.m4",):
    p = Path(rel)
    if not p.exists():
        continue
    text = p.read_text()
    if replacement_old in text:
        p.write_text(text.replace(replacement_old, replacement_new))
PY
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        mkdir -p "$native_dep_root/src"
        if [[ ! -x "$protobuf_prefix/bin/protoc" || ! -f "$protobuf_prefix/lib/pkgconfig/protobuf.pc" ]]; then
            info "Building protobuf ${protobuf_version} for native Windows compatibility..."
            rm -rf "$protobuf_src_dir" "$protobuf_prefix"
            curl -L "https://github.com/protocolbuffers/protobuf/releases/download/v${protobuf_version}/protobuf-cpp-${protobuf_version}.tar.gz" -o "$protobuf_archive"
            tar -xzf "$protobuf_archive" -C "$native_dep_root/src"
            (
                cd "$protobuf_src_dir"
                ./configure --prefix="$protobuf_prefix" --disable-shared --enable-static \
                    CFLAGS="-O2" CXXFLAGS="-O2"
                make -j"$jobs"
                make install
            )
        fi
        export PATH="$protobuf_prefix/bin:$PATH"
        export PKG_CONFIG_PATH="$protobuf_prefix/lib/pkgconfig:/mingw64/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
        export QMAKE="$(command -v qmake)"
        export CPPFLAGS="-I$protobuf_prefix/include -I/mingw64/include -I/mingw64/include/QtCore -I/mingw64/include/QtGui -I/mingw64/include/QtWidgets -I/mingw64/include/QtNetwork ${CPPFLAGS:-}"
        export LDFLAGS="-L$protobuf_prefix/lib ${LDFLAGS:-}"
    fi

    info "Running autogen.sh..."
    ./autogen.sh

    if ! compgen -G "/mingw64/lib/libboost_system*" >/dev/null && [[ -f configure ]]; then
        python3 - <<'PY'
from pathlib import Path

p = Path("configure")
text = p.read_text()
old = """            if test "x$ax_lib" = "x"; then
                as_fn_error $? "Could not find a version of the boost_system library!" "$LINENO" 5
            fi
\t\t\tif test "x$link_system" = "xno"; then
\t\t\t\tas_fn_error $? "Could not link against $ax_lib !" "$LINENO" 5
\t\t\tfi"""
new = """            if test "x$ax_lib" = "x"; then
                BOOST_SYSTEM_LIB=""
                link_system="yes"
            fi
\t\t\tif test "x$link_system" = "xno" && test "x$ax_lib" != "x"; then
\t\t\t\tas_fn_error $? "Could not link against $ax_lib !" "$LINENO" 5
\t\t\tfi"""
if old in text:
    p.write_text(text.replace(old, new))
PY
    fi

    info "Configuring..."
    ./configure --disable-tests --disable-bench $configure_extra \
        BDB_CFLAGS="-I$windows_bdb_prefix/include" \
        BDB_LIBS="-L$windows_bdb_prefix/lib -ldb_cxx-4.8 -ldb-4.8" \
        CFLAGS="$windows_cflags" \
        CXXFLAGS="$windows_cxxflags"

    # Blakecoin 0.15.21 does not ship the upstream translation payloads.
    if [[ -f src/Makefile ]]; then
        sedi 's/^QT_QM.*=.*/QT_QM =/' src/Makefile
        sedi '/bitcoin_.*\.qm/d' src/Makefile
        sedi '/locale\/.*\.qm/d' src/Makefile
        # MSYS2 ships DLL import libraries for Qt/qrencode, not fully static
        # archives. Native Windows validation builds should link against those
        # import libs and bundle the resulting DLL dependencies afterward.
        sedi 's/^LIBTOOL_APP_LDFLAGS = .*/LIBTOOL_APP_LDFLAGS =/' src/Makefile
    fi
    mkdir -p src/qt
    if [[ "$target" == "qt" || "$target" == "both" ]] && command -v protoc &>/dev/null && [[ -f src/qt/paymentrequest.proto ]]; then
        info "Regenerating paymentrequest protobuf sources for native Windows protobuf..."
        (
            cd src/qt
            protoc --cpp_out=. paymentrequest.proto
        )
    fi
    cat > src/qt/bitcoin_locale.qrc <<'QRC_EOF'
<!DOCTYPE RCC><RCC version="1.0">
<qresource prefix="/translations">
</qresource>
</RCC>
QRC_EOF

    info "Building with $jobs jobs..."
    make -j"$jobs"

    if [[ "$target" == "daemon" || "$target" == "both" ]]; then
        local daemon_bin="src/blakecoind.exe"
        local cli_bin="src/blakecoin-cli.exe"
        local tx_bin="src/blakecoin-tx.exe"
        [[ -f src/.libs/blakecoind.exe ]] && daemon_bin="src/.libs/blakecoind.exe"
        [[ -f src/.libs/blakecoin-cli.exe ]] && cli_bin="src/.libs/blakecoin-cli.exe"
        [[ -f src/.libs/blakecoin-tx.exe ]] && tx_bin="src/.libs/blakecoin-tx.exe"

        if [[ "$native_windows_debug_symbols" != "1" ]]; then
            strip "$daemon_bin" "$cli_bin" "$tx_bin" 2>/dev/null || true
        fi
        cp "$daemon_bin" "$output_dir/${DAEMON_NAME}.exe"
        cp "$cli_bin" "$output_dir/${CLI_NAME}.exe"
        cp "$tx_bin" "$output_dir/${TX_NAME}.exe"

        # Bundle DLLs
        info "Bundling DLL dependencies..."
        for exe in \
            "$output_dir/${DAEMON_NAME}.exe" \
            "$output_dir/${CLI_NAME}.exe" \
            "$output_dir/${TX_NAME}.exe"
        do
            ldd "$exe" 2>/dev/null | grep "=> /" | awk '{print $3}' | while read -r dll; do
                local dll_lc
                dll_lc=$(printf '%s' "$dll" | tr '[:upper:]' '[:lower:]')
                case "$dll_lc" in
                    /c/windows/*) ;;
                    *) cp -n "$dll" "$output_dir/" 2>/dev/null || true ;;
                esac
            done
        done

        success "Daemon binaries in $output_dir/"
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        local qt_bin="src/qt/blakecoin-qt.exe"
        [[ -f src/qt/.libs/blakecoin-qt.exe ]] && qt_bin="src/qt/.libs/blakecoin-qt.exe"

        if [[ "$native_windows_debug_symbols" != "1" ]]; then
            strip "$qt_bin" 2>/dev/null || true
        fi
        cp "$qt_bin" "$output_dir/${QT_NAME}.exe"

        # Bundle DLLs
        info "Bundling DLL dependencies..."
        ldd "$output_dir/${QT_NAME}.exe" 2>/dev/null | grep "=> /" | awk '{print $3}' | while read -r dll; do
            local dll_lc
            dll_lc=$(printf '%s' "$dll" | tr '[:upper:]' '[:lower:]')
            case "$dll_lc" in
                /c/windows/*) ;;
                *) cp -n "$dll" "$output_dir/" 2>/dev/null || true ;;
            esac
        done

        # Qt platform plugin
        # Legacy native Windows builds worked because they copied qwindows.dll
        # from the known MSYS2 Qt plugin directory. Keep the qmake query for
        # portability, but fall back to the fixed MSYS2 path so fresh Windows
        # hosts still get a runnable bundle.
        local qt_plugin_dir=""
        local qmake_bin=""
        for qmake_bin in "${QMAKE:-}" "$(command -v qmake 2>/dev/null || true)" "$(command -v qmake-qt5 2>/dev/null || true)" /mingw64/bin/qmake; do
            [[ -z "$qmake_bin" || ! -x "$qmake_bin" ]] && continue
            qt_plugin_dir=$("$qmake_bin" -query QT_INSTALL_PLUGINS 2>/dev/null | tr -d '\r')
            [[ -n "$qt_plugin_dir" && -f "$qt_plugin_dir/platforms/qwindows.dll" ]] && break
            qt_plugin_dir=""
        done
        if [[ -z "$qt_plugin_dir" || ! -f "$qt_plugin_dir/platforms/qwindows.dll" ]]; then
            if [[ -f /mingw64/share/qt5/plugins/platforms/qwindows.dll ]]; then
                qt_plugin_dir="/mingw64/share/qt5/plugins"
            fi
        fi
        if [[ -n "$qt_plugin_dir" && -f "$qt_plugin_dir/platforms/qwindows.dll" ]]; then
            mkdir -p "$output_dir/platforms"
            cp "$qt_plugin_dir/platforms/qwindows.dll" "$output_dir/platforms/" 2>/dev/null || true
            cat > "$output_dir/qt.conf" <<'EOF'
[Paths]
Plugins=.
EOF
        else
            warn "qwindows.dll not found; native Windows Qt wallet may fail to launch"
        fi

        success "Qt wallet in $output_dir/"
    fi

    write_build_info "$output_dir" "native-windows" "$target" "$(detect_os_version windows)"
    CURRENT_OUTPUT_DIR="$output_dir"
    GENERATE_CONFIG_AFTER_BUILD=1

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL  -  Native Windows"
    echo "  Output: $output_dir/"
    echo "============================================"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local platform=""
    local target="both"
    local docker_mode="none"
    local jobs
    local cores
    cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
    jobs=$(( cores > 1 ? cores - 1 : 1 ))

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --native)       platform="native" ;;
            --appimage)     platform="appimage" ;;
            --windows)      platform="windows" ;;
            --macos)        platform="macos" ;;
            --daemon)       target="daemon" ;;
            --qt)           target="qt" ;;
            --both)         target="both" ;;
            --pull-docker)  docker_mode="pull" ;;
            --build-docker) docker_mode="build" ;;
            --no-docker)    docker_mode="none" ;;
            --jobs)         shift; jobs="$1" ;;
            -h|--help)      usage ;;
            *)              error "Unknown option: $1"; usage ;;
        esac
        shift
    done

    if [[ -z "$platform" ]]; then
        error "No platform specified. Use --native, --appimage, --windows, or --macos"
        echo ""
        usage
    fi

    # Cross-compile platforms require Docker
    if [[ "$platform" =~ ^(windows|macos|appimage)$ && "$docker_mode" == "none" ]]; then
        error "--$platform requires Docker. Use --pull-docker or --build-docker"
        echo ""
        echo "  --pull-docker   Pull prebuilt image from Docker Hub"
        echo "  --build-docker  Build image locally from repo Dockerfiles"
        echo ""
        exit 1
    fi

    echo ""
    echo "============================================"
    echo "  $COIN_NAME_UPPER 0.15.21 Build System"
    echo "============================================"
    echo "  Platform: $platform"
    echo "  Target:   $target"
    echo "  Docker:   $docker_mode"
    echo "  Jobs:     $jobs"
    echo ""

    case "$platform" in
        native)
            if [[ "$docker_mode" != "none" ]]; then
                build_native_docker "$target" "$jobs" "$docker_mode"
            else
                build_native_direct "$target" "$jobs"
            fi
            ;;
        windows)
            build_windows "$target" "$jobs" "$docker_mode"
            ;;
        macos)
            build_macos_cross "$target" "$jobs" "$docker_mode"
            ;;
        appimage)
            build_appimage "$jobs" "$docker_mode"
            ;;
    esac

    if [[ "$GENERATE_CONFIG_AFTER_BUILD" == 1 ]]; then
        generate_config "${CURRENT_OUTPUT_DIR:-$OUTPUT_BASE}"
    fi
}

main "$@"
