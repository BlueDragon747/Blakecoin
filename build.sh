#!/bin/bash
# =============================================================================
# Blakecoin 0.15.2 Build Script — All Platforms
#
# Single self-contained script to build Blakecoin daemon and/or Qt wallet
# for Linux, macOS, Windows, and AppImage.
#
# Based on Bitcoin Core 0.15.2 — uses autotools (./configure + make).
# Cross-compilation uses pre-built libraries in each Docker image (same
# images as the 0.8.x coins) — does NOT use the depends/ system.
#
# Usage: ./build.sh [PLATFORM] [TARGET] [OPTIONS]
#   See ./build.sh --help for full usage.
#
# Docker Hub images (prebuilt):
#   sidgrip/native-base:20.04     — Native Linux (Ubuntu 20.04, GCC 9, Boost 1.71)
#   sidgrip/native-base:22.04     — Native Linux (Ubuntu 22.04, GCC 11, Boost 1.74)
#   sidgrip/native-base:24.04     — Native Linux (Ubuntu 24.04, GCC 13, Boost 1.83)
#   sidgrip/appimage-base:22.04   — AppImage builds (Ubuntu 22.04 + appimagetool)
#   sidgrip/mxe-base:latest       — Windows cross-compile (MXE + MinGW)
#   sidgrip/osxcross-base:latest  — macOS cross-compile (osxcross + clang-18)
#
# Repository: https://github.com/BlueDragon747/Blakecoin (branch: 0.15.2)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_BASE="$SCRIPT_DIR/outputs"
COIN_NAME="blakecoin"
COIN_NAME_UPPER="Blakecoin"
DAEMON_NAME="blakecoind"
QT_NAME="blakecoin-qt"
CLI_NAME="blakecoin-cli"
TX_NAME="blakecoin-tx"
VERSION="0.15.2"
REPO_URL="https://github.com/BlueDragon747/Blakecoin.git"
REPO_BRANCH="0.15.2"

# Network ports and config
RPC_PORT=8772
P2P_PORT=8773
CHAINZ_CODE="blc"
CONFIG_FILE="${COIN_NAME}.conf"
LISTEN='listen=1'
DAEMON='daemon=1'
SERVER='server=0'
TXINDEX='txindex=0'

# Docker images
DOCKER_NATIVE="sidgrip/native-base:22.04"
DOCKER_APPIMAGE="sidgrip/appimage-base:22.04"
DOCKER_WINDOWS="sidgrip/mxe-base:latest"
DOCKER_MACOS="sidgrip/osxcross-base:latest"

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

# Portable sed -i wrapper (macOS BSD sed requires '' arg, GNU sed does not)
sedi() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
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

  # Cross-compile (Docker required — choose --pull-docker or --build-docker)
  ./build.sh --windows --qt --pull-docker      # Pull mxe-base from Docker Hub
  ./build.sh --macos --qt --pull-docker        # Pull osxcross-base from Docker Hub
  ./build.sh --appimage --pull-docker          # Pull appimage-base from Docker Hub

Docker Hub images (used with --pull-docker):
  sidgrip/native-base:20.04             Native Linux (Ubuntu 20.04, GCC 9)
  sidgrip/native-base:22.04             Native Linux (Ubuntu 22.04, GCC 11) [default]
  sidgrip/native-base:24.04             Native Linux (Ubuntu 24.04, GCC 13)
  sidgrip/appimage-base:22.04           AppImage (Ubuntu 22.04 + appimagetool)
  sidgrip/mxe-base:latest               Windows cross-compile (MXE + MinGW)
  sidgrip/osxcross-base:latest          macOS cross-compile (osxcross + clang-18)
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

write_build_info() {
    local output_dir="$1"
    local platform="$2"
    local target="$3"
    local os_version="$4"

    mkdir -p "$output_dir"
    cat > "$output_dir/build-info.txt" <<EOF
Coin:       $COIN_NAME_UPPER 0.15.2
Target:     $target
Platform:   $platform
OS:         $os_version
Date:       $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Branch:     $REPO_BRANCH
Script:     build.sh
EOF
}

generate_config() {
    local conf_path="$OUTPUT_BASE/$CONFIG_FILE"
    if [[ -f "$conf_path" ]]; then
        info "Config already exists: $conf_path"
        return
    fi

    info "Generating $CONFIG_FILE..."
    local rpcuser rpcpassword peers=""
    rpcuser="rpcuser=$(head -c 100 /dev/urandom | tr -cd '[:alnum:]' | head -c 10)"
    rpcpassword="rpcpassword=$(head -c 200 /dev/urandom | tr -cd '[:alnum:]' | head -c 22)"

    # Fetch active peers from chainz cryptoid
    if command -v curl &>/dev/null; then
        local nodes
        nodes=$(curl -s "https://chainz.cryptoid.info/${CHAINZ_CODE}/api.dws?q=nodes" 2>/dev/null || true)
        if [[ -n "$nodes" ]]; then
            peers=$(grep -oP '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' <<< "$nodes" | grep -v '^0\.' | sed 's/^/addnode=/' || true)
        fi
    fi

    mkdir -p "$OUTPUT_BASE"
    cat > "$conf_path" <<EOF
maxconnections=20
$rpcuser
$rpcpassword
rpcallowip=0.0.0.0/0
rpcport=$RPC_PORT
port=$P2P_PORT
gen=0
$LISTEN
$DAEMON
$SERVER
$TXINDEX
$peers
EOF
    success "Config written: $conf_path"

    # Copy config to data directory if not already present
    local data_dir="$HOME/.${COIN_NAME}"
    mkdir -p "$data_dir"
    if [[ ! -f "$data_dir/$CONFIG_FILE" ]]; then
        cp "$conf_path" "$data_dir/$CONFIG_FILE"
        info "Config installed to $data_dir/$CONFIG_FILE"
    else
        info "Config already exists in $data_dir/ — not overwriting"
    fi
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

    # Pull mode — check local cache first
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
# Uses pre-built libs in mxe-base image — skips depends/ entirely
# =============================================================================

build_windows() {
    local target="$1"
    local jobs="$2"
    local docker_mode="$3"
    local container_name="win-${COIN_NAME}-0152-build"
    local output_dir="$OUTPUT_BASE/windows"

    echo ""
    echo "============================================"
    echo "  Windows Cross-Compile: $COIN_NAME_UPPER $VERSION"
    echo "============================================"
    echo "  Image:    $DOCKER_WINDOWS"
    echo "  Strategy: MXE + autotools (pre-built libs)"
    echo ""

    ensure_docker_image "$DOCKER_WINDOWS" "$docker_mode"
    mkdir -p "$output_dir/daemon" "$output_dir/qt"
    docker rm -f "$container_name" 2>/dev/null || true

    # Copy source to temp dir for volume-mount
    info "Copying source tree to temp build dir..."
    local tmpdir
    tmpdir=$(mktemp -d)
    cp -a "$SCRIPT_DIR"/. "$tmpdir/"
    rm -rf "$tmpdir/outputs" "$tmpdir/.git"
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

# Fix static link deps: use --start-group to resolve circular Qt5/platform plugin deps
if [ -f src/Makefile ]; then
    echo ">>> Fixing static link dependencies (--start-group for circular deps)..."
    sed -i "s|^LIBS = \(.*\)|LIBS = -Wl,--start-group \1 -L${MXE_SYSROOT}/qt5/plugins/platforms -lqwindows -L${MXE_SYSROOT}/qt5/lib -lQt5Widgets -lQt5Gui -lQt5Network -lQt5Core -lQt5PlatformSupport -lQt5AccessibilitySupport -lQt5WindowsUIAutomationSupport -lQt5EventDispatcherSupport -lQt5FontDatabaseSupport -lQt5ThemeSupport -lharfbuzz -lfreetype -lharfbuzz_too -lfreetype_too -lbz2 -lpng16 -lbrotlidec -lbrotlicommon -lglib-2.0 -lintl -liconv -lpcre2-8 -lpcre2-16 -lzstd -lssl -lcrypto -ld3d11 -ldxgi -ldxguid -luxtheme -ldwmapi -ldnsapi -liphlpapi -lcrypt32 -lmpr -luserenv -lnetapi32 -lversion -lcomdlg32 -loleaut32 -limm32 -lshlwapi -latomic -lz -lws2_32 -lgdi32 -luser32 -lkernel32 -ladvapi32 -lole32 -lshell32 -luuid -lwinmm -lrpcrt4 -lssp -lwinspool -lcomctl32 -lwtsapi32 -lm -Wl,--end-group|" src/Makefile
fi

echo ">>> Building..."
make -j'"$jobs"'

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
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoind.exe" "$output_dir/daemon/blakecoind-${VERSION}.exe" 2>/dev/null || true
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoin-cli.exe" "$output_dir/daemon/blakecoin-cli-${VERSION}.exe" 2>/dev/null || true
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoin-tx.exe" "$output_dir/daemon/blakecoin-tx-${VERSION}.exe" 2>/dev/null || true
        write_build_info "$output_dir/daemon" "windows" "daemon" "Docker: $DOCKER_WINDOWS (MXE)"
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        info "Extracting Qt wallet..."
        docker cp "$container_name:/build/$COIN_NAME/src/qt/blakecoin-qt.exe" "$output_dir/qt/blakecoin-qt-${VERSION}.exe" 2>/dev/null || true
        write_build_info "$output_dir/qt" "windows" "qt" "Docker: $DOCKER_WINDOWS (MXE)"
    fi

    docker rm -f "$container_name" 2>/dev/null || true
    docker run --rm -v "$tmpdir:/cleanup" alpine rm -rf /cleanup 2>/dev/null || rm -rf "$tmpdir" 2>/dev/null || true

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL — Windows"
    echo "  Output: $output_dir/"
    echo "============================================"
    ls -lh "$output_dir"/daemon/*.exe "$output_dir"/qt/*.exe 2>/dev/null || true
}

# =============================================================================
# macOS CROSS-COMPILE (Docker + osxcross + autotools)
# Uses pre-built libs in osxcross-base image — skips depends/ entirely
# =============================================================================

build_macos_cross() {
    local target="$1"
    local jobs="$2"
    local docker_mode="$3"
    local container_name="mac-${COIN_NAME}-0152-build"
    local output_dir="$OUTPUT_BASE/macos"

    echo ""
    echo "============================================"
    echo "  macOS Cross-Compile: $COIN_NAME_UPPER $VERSION"
    echo "============================================"
    echo "  Image:    $DOCKER_MACOS"
    echo "  Strategy: osxcross + autotools (pre-built libs)"
    echo ""

    ensure_docker_image "$DOCKER_MACOS" "$docker_mode"
    mkdir -p "$output_dir/daemon" "$output_dir/qt"
    docker rm -f "$container_name" 2>/dev/null || true

    # Copy source to temp dir
    info "Copying source tree to temp build dir..."
    local tmpdir
    tmpdir=$(mktemp -d)
    cp -a "$SCRIPT_DIR"/. "$tmpdir/"
    rm -rf "$tmpdir/outputs" "$tmpdir/.git"
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
${HOST}-strip src/qt/blakecoin-qt 2>/dev/null || true
${HOST}-strip src/blakecoin-cli 2>/dev/null || true
${HOST}-strip src/blakecoin-tx 2>/dev/null || true

echo ">>> Creating macOS .app bundle..."
APP_NAME="Blakecoin-Qt.app"
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

echo ">>> Build complete!"
ls -lh src/blakecoind src/qt/blakecoin-qt src/blakecoin-cli src/blakecoin-tx 2>/dev/null || true
ls -lh "$APP_NAME/Contents/MacOS/" 2>/dev/null || true
'

    info "Starting build container: $container_name"
    docker start -a "$container_name"

    # Extract binaries
    if [[ "$target" == "daemon" || "$target" == "both" ]]; then
        info "Extracting daemon binaries..."
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoind" "$output_dir/daemon/blakecoind-${VERSION}" 2>/dev/null || true
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoin-cli" "$output_dir/daemon/blakecoin-cli-${VERSION}" 2>/dev/null || true
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoin-tx" "$output_dir/daemon/blakecoin-tx-${VERSION}" 2>/dev/null || true
        write_build_info "$output_dir/daemon" "macos" "daemon" "Docker: $DOCKER_MACOS (osxcross)"
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        info "Extracting Qt wallet (.app bundle)..."
        local app_name="Blakecoin-Qt.app"
        rm -rf "$output_dir/qt/$app_name" 2>/dev/null || true
        if docker cp "$container_name:/build/$COIN_NAME/$app_name" "$output_dir/qt/$app_name" 2>/dev/null; then
            # Ensure binary inside .app is executable (docker cp can lose +x)
            find "$output_dir/qt/$app_name" -path "*/Contents/MacOS/*" -type f -exec chmod +x {} + 2>/dev/null || true
            success "macOS app bundle extracted to $output_dir/qt/"
            ls -lh "$output_dir/qt/$app_name/Contents/MacOS/" 2>/dev/null || true
        else
            error "Could not find .app bundle in container"
            docker exec "$container_name" find /build/$COIN_NAME -name "*.app" -type d 2>/dev/null || true
        fi
        # Also copy raw binary for convenience
        docker cp "$container_name:/build/$COIN_NAME/src/qt/blakecoin-qt" "$output_dir/qt/blakecoin-qt-${VERSION}" 2>/dev/null || true
        write_build_info "$output_dir/qt" "macos" "qt" "Docker: $DOCKER_MACOS (osxcross)"
    fi

    docker rm -f "$container_name" 2>/dev/null || true
    docker run --rm -v "$tmpdir:/cleanup" alpine rm -rf /cleanup 2>/dev/null || rm -rf "$tmpdir" 2>/dev/null || true

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL — macOS"
    echo "  Output: $output_dir/"
    echo "============================================"
    ls -lh "$output_dir"/daemon/* "$output_dir"/qt/* 2>/dev/null || true
}

# =============================================================================
# APPIMAGE BUILD (Docker + autotools + AppDir packaging)
# =============================================================================

build_appimage() {
    local jobs="$1"
    local docker_mode="$2"
    local container_name="appimage-${COIN_NAME}-0152-build"
    local output_dir="$OUTPUT_BASE/linux-appimage/qt"

    echo ""
    echo "============================================"
    echo "  AppImage Build: $COIN_NAME_UPPER 0.15.2"
    echo "============================================"
    echo "  Image:  $DOCKER_APPIMAGE"
    echo ""

    ensure_docker_image "$DOCKER_APPIMAGE" "$docker_mode"
    mkdir -p "$output_dir"
    docker rm -f "$container_name" 2>/dev/null || true

    # Copy source to temp dir
    info "Copying source tree to temp build dir..."
    local tmpdir
    tmpdir=$(mktemp -d)
    cp -a "$SCRIPT_DIR"/. "$tmpdir/"
    rm -rf "$tmpdir/outputs" "$tmpdir/.git"
    fix_permissions "$tmpdir"

    docker create \
        --name "$container_name" \
        -v "$tmpdir:/build/$COIN_NAME:rw" \
        "$DOCKER_APPIMAGE" \
        /bin/bash -c '
set -e
cd /build/'"$COIN_NAME"'

# Patch sources for Qt 5.15+ and Boost 1.73+ compatibility
echo ">>> Patching sources for Ubuntu 22.04 compatibility..."
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
Comment='"$COIN_NAME_UPPER"' 0.15.2 Cryptocurrency Wallet
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
    "/build/output/'"$COIN_NAME_UPPER"'-0.15.2-x86_64.AppImage"
chmod +x "/build/output/'"$COIN_NAME_UPPER"'-0.15.2-x86_64.AppImage"

echo ">>> AppImage build complete!"
ls -lh /build/output/
'

    info "Starting build container: $container_name"
    docker start -a "$container_name"

    info "Extracting AppImage..."
    if docker cp "$container_name:/build/output/${COIN_NAME_UPPER}-0.15.2-x86_64.AppImage" "$output_dir/${COIN_NAME_UPPER}-0.15.2-x86_64.AppImage" 2>/dev/null; then
        success "AppImage extracted to $output_dir/"
        ls -lh "$output_dir/${COIN_NAME_UPPER}-0.15.2-x86_64.AppImage"
    else
        error "Could not find AppImage in container"
        docker rm -f "$container_name" 2>/dev/null || true
        exit 1
    fi

    write_build_info "$output_dir" "appimage" "qt" "Docker: $DOCKER_APPIMAGE"
    docker rm -f "$container_name" 2>/dev/null || true
    docker run --rm -v "$tmpdir:/cleanup" alpine rm -rf /cleanup 2>/dev/null || rm -rf "$tmpdir" 2>/dev/null || true

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL — AppImage"
    echo "  Output: $output_dir/${COIN_NAME_UPPER}-0.15.2-x86_64.AppImage"
    echo "============================================"
}

# =============================================================================
# NATIVE BUILD (Docker — runs autotools inside container)
# =============================================================================

build_native_docker() {
    local target="$1"
    local jobs="$2"
    local docker_mode="$3"
    local output_dir="$OUTPUT_BASE/native"

    echo ""
    echo "============================================"
    echo "  Native Docker Build: $COIN_NAME_UPPER 0.15.2"
    echo "============================================"
    echo "  Image:  $DOCKER_NATIVE"
    echo "  Target: $target"
    echo ""

    ensure_docker_image "$DOCKER_NATIVE" "$docker_mode"
    mkdir -p "$output_dir/daemon" "$output_dir/qt"

    # Copy source to temp dir
    info "Copying source tree to temp build dir..."
    local tmpdir
    tmpdir=$(mktemp -d)
    cp -a "$SCRIPT_DIR"/. "$tmpdir/"
    rm -rf "$tmpdir/outputs" "$tmpdir/.git"
    fix_permissions "$tmpdir"

    local configure_extra=""
    case "$target" in
        daemon) configure_extra="--without-gui" ;;
        qt)     configure_extra="" ;;
        both)   configure_extra="" ;;
    esac

    local container_name="native-${COIN_NAME}-0152-build"
    docker rm -f "$container_name" 2>/dev/null || true

    docker create \
        --name "$container_name" \
        -v "$tmpdir:/build/$COIN_NAME:rw" \
        "$DOCKER_NATIVE" \
        /bin/bash -c '
set -e
cd /build/'"$COIN_NAME"'

# Patch sources for Qt 5.15+ and Boost 1.73+ compatibility
echo ">>> Patching sources for Ubuntu 22.04 compatibility..."
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
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoind" "$output_dir/daemon/blakecoind-${VERSION}" 2>/dev/null || true
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoin-cli" "$output_dir/daemon/blakecoin-cli-${VERSION}" 2>/dev/null || true
        docker cp "$container_name:/build/$COIN_NAME/src/blakecoin-tx" "$output_dir/daemon/blakecoin-tx-${VERSION}" 2>/dev/null || true
        write_build_info "$output_dir/daemon" "native-docker" "daemon" "Docker: $DOCKER_NATIVE"
        success "Daemon binaries in $output_dir/daemon/"
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        info "Extracting Qt wallet..."
        docker cp "$container_name:/build/$COIN_NAME/src/qt/blakecoin-qt" "$output_dir/qt/blakecoin-qt-${VERSION}" 2>/dev/null || true
        write_build_info "$output_dir/qt" "native-docker" "qt" "Docker: $DOCKER_NATIVE"
        success "Qt wallet in $output_dir/qt/"
    fi

    docker rm -f "$container_name" 2>/dev/null || true
    docker run --rm -v "$tmpdir:/cleanup" alpine rm -rf /cleanup 2>/dev/null || rm -rf "$tmpdir" 2>/dev/null || true

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL — Native (Docker)"
    echo "  Output: $output_dir/"
    echo "============================================"
}

# =============================================================================
# NATIVE BUILD (Direct — no Docker)
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
    local output_dir="$OUTPUT_BASE/native"

    echo ""
    echo "============================================"
    echo "  Native Linux Build: $COIN_NAME_UPPER 0.15.2"
    echo "============================================"
    echo ""

    # Detect Ubuntu version
    local ubuntu_ver=""
    if [[ -f /etc/os-release ]]; then
        ubuntu_ver=$(. /etc/os-release && echo "$VERSION_ID")
    fi
    info "Detected OS: Ubuntu ${ubuntu_ver:-unknown}"

    # Define required packages
    local build_deps="build-essential libtool-bin autotools-dev automake pkg-config curl"

    # BDB: prefer 4.8 for wallet portability, fall back to system version
    local bdb_deps=""
    local bdb48_candidate
    bdb48_candidate=$(apt-cache policy libdb4.8++-dev 2>/dev/null | grep 'Candidate:' | awk '{print $2}')
    if [[ -n "$bdb48_candidate" && "$bdb48_candidate" != "(none)" ]]; then
        bdb_deps="libdb4.8-dev libdb4.8++-dev"
        info "BDB 4.8 available — wallets will be portable"
    else
        bdb_deps="libdb++-dev"
        info "BDB 4.8 not available — using system BDB (--with-incompatible-bdb will be applied)"
    fi

    local lib_deps="libssl-dev libevent-dev $bdb_deps libminiupnpc-dev libprotobuf-dev protobuf-compiler libboost-all-dev"
    local qt_deps=""
    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        qt_deps="qtbase5-dev qttools5-dev qttools5-dev-tools libqrencode-dev"
    fi

    local all_deps="$build_deps $lib_deps $qt_deps"

    # Check and auto-install missing packages
    info "Checking and installing dependencies..."
    local missing_pkgs=()
    for pkg in $all_deps; do
        dpkg -s "$pkg" &>/dev/null 2>&1 || missing_pkgs+=("$pkg")
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        info "Installing missing packages: ${missing_pkgs[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${missing_pkgs[@]}"
    else
        info "All dependencies already installed"
    fi

    mkdir -p "$output_dir/daemon" "$output_dir/qt"

    local configure_extra=""
    case "$target" in
        daemon) configure_extra="--without-gui" ;;
        qt)     configure_extra="" ;;
        both)   configure_extra="" ;;
    esac

    # BDB 4.8 is preferred for portable wallets; use --with-incompatible-bdb for 5.3+
    if ! test -f /usr/include/db4.8/db_cxx.h && ! test -f /usr/lib/libdb_cxx-4.8.so; then
        info "BDB 4.8 not found, using system BDB with --with-incompatible-bdb"
        configure_extra="$configure_extra --with-incompatible-bdb"
    fi

    cd "$SCRIPT_DIR"

    # Patch sources for Qt 5.15+ and Boost 1.73+ compatibility
    if [[ -f src/qt/trafficgraphwidget.cpp ]]; then
        grep -q "#include <QPainterPath>" src/qt/trafficgraphwidget.cpp || \
            sedi '1i #include <QPainterPath>' src/qt/trafficgraphwidget.cpp
    fi

    info "Running autogen.sh..."
    ./autogen.sh

    info "Configuring..."
    ./configure --disable-tests --disable-bench $configure_extra \
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

    # Copy outputs
    if [[ "$target" == "daemon" || "$target" == "both" ]]; then
        strip src/blakecoind src/blakecoin-cli src/blakecoin-tx 2>/dev/null || true
        cp src/blakecoind "$output_dir/daemon/blakecoind-${VERSION}"
        cp src/blakecoin-cli "$output_dir/daemon/blakecoin-cli-${VERSION}"
        cp src/blakecoin-tx "$output_dir/daemon/blakecoin-tx-${VERSION}"
        write_build_info "$output_dir/daemon" "native-linux" "daemon" "$(detect_os_version linux)"
        success "Daemon binaries in $output_dir/daemon/"
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        strip src/qt/blakecoin-qt 2>/dev/null || true
        cp src/qt/blakecoin-qt "$output_dir/qt/blakecoin-qt-${VERSION}"
        write_build_info "$output_dir/qt" "native-linux" "qt" "$(detect_os_version linux)"
        success "Qt wallet in $output_dir/qt/"

        # Install desktop launcher
        local desktop_dir="$HOME/.local/share/applications"
        local icon_dir="$HOME/.local/share/icons/hicolor/256x256/apps"
        mkdir -p "$desktop_dir" "$icon_dir"
        if [[ -f "src/qt/res/icons/bitcoin.png" ]]; then
            cp "src/qt/res/icons/bitcoin.png" "$icon_dir/${COIN_NAME}.png"
        fi
        cat > "$desktop_dir/${QT_NAME}.desktop" <<DEOF
[Desktop Entry]
Type=Application
Name=$COIN_NAME_UPPER
Icon=$icon_dir/${COIN_NAME}.png
Exec=$output_dir/qt/${QT_NAME}-${VERSION}
Terminal=false
Categories=Finance;Network;
StartupWMClass=${QT_NAME}
DEOF
        chmod +x "$desktop_dir/${QT_NAME}.desktop"
        info "Desktop launcher installed — $COIN_NAME_UPPER will appear in Activities search"
    fi

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL — Native Linux"
    echo "  Output: $output_dir/"
    echo "============================================"
}

build_native_macos() {
    local target="$1"
    local jobs="$2"
    local output_dir="$OUTPUT_BASE/native"

    echo ""
    echo "============================================"
    echo "  Native macOS Build: $COIN_NAME_UPPER 0.15.2"
    echo "============================================"
    echo ""

    # Check for Homebrew
    if ! command -v brew &>/dev/null; then
        error "Homebrew not found. Install from https://brew.sh"
        exit 1
    fi

    # Check/install dependencies
    local deps=(openssl boost miniupnpc berkeley-db@4 qt@5 libevent protobuf pkg-config automake autoconf libtool curl)
    for dep in "${deps[@]}"; do
        if ! brew list "$dep" &>/dev/null; then
            info "Installing $dep..."
            brew install "$dep"
        fi
    done

    mkdir -p "$output_dir/daemon" "$output_dir/qt"

    local configure_extra=""
    case "$target" in
        daemon) configure_extra="--without-gui" ;;
        qt)     configure_extra="" ;;
        both)   configure_extra="" ;;
    esac

    cd "$SCRIPT_DIR"

    info "Running autogen.sh..."
    ./autogen.sh

    # Patch sources for Qt 5.15+ and Boost 1.73+ compatibility
    if [[ -f src/qt/trafficgraphwidget.cpp ]]; then
        grep -q "#include <QPainterPath>" src/qt/trafficgraphwidget.cpp || \
            sedi '1i #include <QPainterPath>' src/qt/trafficgraphwidget.cpp
    fi

    info "Configuring..."
    ./configure --disable-tests --disable-bench $configure_extra \
        CXXFLAGS="-O2 -DBOOST_BIND_GLOBAL_PLACEHOLDERS" \
        PKG_CONFIG_PATH="$(brew --prefix openssl)/lib/pkgconfig:$(brew --prefix qt@5)/lib/pkgconfig:$(brew --prefix libevent)/lib/pkgconfig" \
        CPPFLAGS="-I$(brew --prefix berkeley-db@4)/include -I$(brew --prefix boost)/include -I$(brew --prefix openssl)/include" \
        LDFLAGS="-L$(brew --prefix berkeley-db@4)/lib -L$(brew --prefix boost)/lib -L$(brew --prefix openssl)/lib"

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
        strip src/blakecoind src/blakecoin-cli src/blakecoin-tx 2>/dev/null || true
        cp src/blakecoind "$output_dir/daemon/blakecoind-${VERSION}"
        cp src/blakecoin-cli "$output_dir/daemon/blakecoin-cli-${VERSION}"
        cp src/blakecoin-tx "$output_dir/daemon/blakecoin-tx-${VERSION}"
        write_build_info "$output_dir/daemon" "native-macos" "daemon" "$(detect_os_version macos)"
        success "Daemon binaries in $output_dir/daemon/"
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        strip src/qt/blakecoin-qt 2>/dev/null || true
        cp src/qt/blakecoin-qt "$output_dir/qt/blakecoin-qt-${VERSION}"
        write_build_info "$output_dir/qt" "native-macos" "qt" "$(detect_os_version macos)"
        success "Qt wallet in $output_dir/qt/"
    fi

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL — Native macOS"
    echo "  Output: $output_dir/"
    echo "============================================"
}

build_native_windows() {
    local target="$1"
    local jobs="$2"
    local output_dir="$OUTPUT_BASE/native"

    echo ""
    echo "============================================"
    echo "  Native Windows Build: $COIN_NAME_UPPER 0.15.2"
    echo "============================================"
    echo ""

    # Verify MSYS2/MinGW64 environment
    if [[ -z "${MSYSTEM:-}" ]]; then
        error "This must be run from an MSYS2 MINGW64 shell"
        exit 1
    fi

    if ! command -v curl &>/dev/null; then
        error "curl not found. Install with: pacman -S mingw-w64-x86_64-curl"
        exit 1
    fi

    mkdir -p "$output_dir/daemon" "$output_dir/qt"

    local configure_extra=""
    case "$target" in
        daemon) configure_extra="--without-gui" ;;
        qt)     configure_extra="" ;;
        both)   configure_extra="" ;;
    esac

    cd "$SCRIPT_DIR"

    info "Running autogen.sh..."
    ./autogen.sh

    info "Configuring..."
    ./configure --disable-tests --disable-bench $configure_extra

    info "Building with $jobs jobs..."
    make -j"$jobs"

    if [[ "$target" == "daemon" || "$target" == "both" ]]; then
        strip src/blakecoind.exe src/blakecoin-cli.exe src/blakecoin-tx.exe 2>/dev/null || true
        cp src/blakecoind.exe "$output_dir/daemon/blakecoind-${VERSION}.exe"
        cp src/blakecoin-cli.exe "$output_dir/daemon/blakecoin-cli-${VERSION}.exe"
        cp src/blakecoin-tx.exe "$output_dir/daemon/blakecoin-tx-${VERSION}.exe"

        # Bundle DLLs
        info "Bundling DLL dependencies..."
        for exe in "$output_dir"/daemon/*.exe; do
            ldd "$exe" 2>/dev/null | grep "=> /" | awk '{print $3}' | while read -r dll; do
                case "$dll" in
                    /c/Windows/*|/c/windows/*) ;;
                    *) cp -n "$dll" "$output_dir/daemon/" 2>/dev/null || true ;;
                esac
            done
        done

        write_build_info "$output_dir/daemon" "native-windows" "daemon" "$(detect_os_version windows)"
        success "Daemon binaries in $output_dir/daemon/"
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        strip src/qt/blakecoin-qt.exe 2>/dev/null || true
        cp src/qt/blakecoin-qt.exe "$output_dir/qt/blakecoin-qt-${VERSION}.exe"

        # Bundle DLLs
        info "Bundling DLL dependencies..."
        ldd "$output_dir/qt/blakecoin-qt-${VERSION}.exe" 2>/dev/null | grep "=> /" | awk '{print $3}' | while read -r dll; do
            case "$dll" in
                /c/Windows/*|/c/windows/*) ;;
                *) cp -n "$dll" "$output_dir/qt/" 2>/dev/null || true ;;
            esac
        done

        # Qt platform plugin
        local qt_plugin_dir
        qt_plugin_dir=$(qmake -query QT_INSTALL_PLUGINS 2>/dev/null || echo "")
        if [[ -n "$qt_plugin_dir" && -d "$qt_plugin_dir/platforms" ]]; then
            mkdir -p "$output_dir/qt/platforms"
            cp "$qt_plugin_dir/platforms/qwindows.dll" "$output_dir/qt/platforms/" 2>/dev/null || true
        fi

        write_build_info "$output_dir/qt" "native-windows" "qt" "$(detect_os_version windows)"
        success "Qt wallet in $output_dir/qt/"
    fi

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL — Native Windows"
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
    echo "  $COIN_NAME_UPPER 0.15.2 Build System"
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

    # Generate config file if not already present
    generate_config
}

main "$@"
