#!/bin/bash
# =============================================================================
# Blakecoin Build Script — All Platforms
#
# Single self-contained script to build Blakecoin daemon and/or Qt wallet
# for Linux, macOS, Windows, and AppImage.
#
# Usage: ./build.sh [PLATFORM] [TARGET] [OPTIONS]
#   See ./build.sh --help for full usage.
#
# Docker Hub images (prebuilt):
#   sidgrip/native-base:18.04      — Linux native build environment
#   sidgrip/mxe-base:latest        — Windows cross-compiler (MXE)
#   sidgrip/osxcross-base:latest   — macOS cross-compiler (osxcross)
#   sidgrip/appimage-base:22.04    — AppImage builder (Wayland compatible)
#
# Repository: https://github.com/SidGrip/Blakecoin
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_BASE="$SCRIPT_DIR/outputs"
COIN_NAME="blakecoin"
COIN_NAME_UPPER="Blakecoin"
DAEMON_NAME="blakecoind"
QT_NAME="blakecoin-qt"
REPO_URL="https://github.com/SidGrip/Blakecoin.git"
REPO_BRANCH="master"

# Network ports and config
RPC_PORT=8772
P2P_PORT=8773
CHAINZ_CODE="blc"
CONFIG_FILE="${COIN_NAME}.conf"
CONFIG_DIR=".${COIN_NAME}"

# Docker images
DOCKER_NATIVE="sidgrip/native-base:18.04"
DOCKER_WINDOWS="sidgrip/mxe-base:latest"
DOCKER_MACOS="sidgrip/osxcross-base:latest"
DOCKER_APPIMAGE="sidgrip/appimage-base:22.04"

# MXE paths (Windows cross-compile)
MXE_SYSROOT="/opt/mxe/usr/x86_64-w64-mingw32.static"

# osxcross paths (macOS cross-compile)
OSXCROSS_TARGET="/opt/osxcross/target"
OSXCROSS_HOST="x86_64-apple-darwin25.2"
MACPORTS_PREFIX="/opt/osxcross/target/macports/pkgs/opt/local"

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
  --daemon          Build daemon only (blakecoind)
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
  ./build.sh --native --both --pull-docker     # Use native-base from Docker Hub
  ./build.sh --native --both --build-docker    # Build native-base locally first

  # Cross-compile (Docker required — choose --pull-docker or --build-docker)
  ./build.sh --windows --qt --pull-docker      # Pull mxe-base from Docker Hub
  ./build.sh --windows --qt --build-docker     # Build mxe-base locally
  ./build.sh --macos --qt --pull-docker        # Pull osxcross-base from Docker Hub
  ./build.sh --appimage --pull-docker          # Pull appimage-base from Docker Hub

Docker Hub images (prebuilt, used with --pull-docker):
  sidgrip/native-base:18.04            Linux build environment (~320 MB)
  sidgrip/mxe-base:latest              Windows MXE cross-compiler (~4.2 GB)
  sidgrip/osxcross-base:latest         macOS osxcross cross-compiler (~7.2 GB)
  sidgrip/appimage-base:22.04          AppImage builder (~515 MB)

Local Dockerfiles (used with --build-docker):
  docker/Dockerfile.native-base        Linux build environment (~5 min)
  docker/Dockerfile.mxe-base           Windows MXE cross-compiler (~2-4 hours)
  docker/Dockerfile.osxcross-base      macOS osxcross cross-compiler (~1-2 hours)
  docker/Dockerfile.appimage-base      AppImage builder (~15 min)
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
            # Linux: lsb_release or /etc/os-release
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
Coin:       $COIN_NAME_UPPER
Target:     $target
Platform:   $platform
OS:         $os_version
Date:       $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Branch:     $REPO_BRANCH
Script:     build.sh
EOF
}

generate_config() {
    local platform="${1:-}"
    local conf_path="$OUTPUT_BASE/$CONFIG_FILE"
    if [[ -f "$conf_path" ]]; then
        info "Config already exists: $conf_path"
        return
    fi

    info "Generating $CONFIG_FILE..."
    local rpcuser rpcpassword peers=""
    rpcuser="rpcuser=$(LC_ALL=C tr -cd '[:alnum:]' < /dev/urandom | head -c 10)"
    rpcpassword="rpcpassword=$(LC_ALL=C tr -cd '[:alnum:]' < /dev/urandom | head -c 22)"

    # Ensure curl is available for peer fetching
    if ! command -v curl &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            info "Installing curl..."
            sudo apt-get install -y -qq curl 2>/dev/null || true
        fi
    fi

    # Fetch active peers from chainz cryptoid
    if command -v curl &>/dev/null; then
        local nodes
        nodes=$(curl -s "https://chainz.cryptoid.info/${CHAINZ_CODE}/api.dws?q=nodes" 2>/dev/null || true)
        if [[ -n "$nodes" ]]; then
            # Filter '^0\.' to exclude version strings (e.g. 0.8.9.7 from JSON "subver") — no valid public IP starts with 0
            peers=$(grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' <<< "$nodes" | grep -v '^0\.' | sed 's/^/addnode=/' || true)
        fi
    fi

    local upnp_line="upnp=1"
    if [[ "$platform" == "macos" ]]; then
        upnp_line="#upnp=1  # disabled on macOS (osxcross boost pthreads incompatibility)"
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
listen=1
daemon=1
server=1
txindex=0
$upnp_line
$peers
EOF
    success "Config written: $conf_path"
}

ensure_docker_image() {
    local image="$1"
    local docker_mode="$2"
    local dockerfile="$SCRIPT_DIR/docker/${3:-}"

    if [[ "$docker_mode" == "pull" ]]; then
        if docker image inspect "$image" >/dev/null 2>&1; then
            info "Image $image found locally."
        else
            info "Pulling $image from Docker Hub..."
            if docker pull "$image"; then
                success "Pulled $image"
            else
                error "Failed to pull $image"
                error "Try --build-docker to build locally, or check https://hub.docker.com/r/${image%%:*}"
                exit 1
            fi
        fi
    elif [[ "$docker_mode" == "build" ]]; then
        if [[ ! -f "$dockerfile" ]]; then
            error "Dockerfile not found: $dockerfile"
            error "Expected Dockerfiles in docker/ directory. See docker/README.md"
            exit 1
        fi
        info "Building $image locally from $(basename "$dockerfile")..."
        info "This may take a while on first build (Docker caches subsequent builds)."
        if docker build -t "$image" -f "$dockerfile" "$(dirname "$dockerfile")"; then
            success "Built $image"
        else
            error "Failed to build $image from $dockerfile"
            exit 1
        fi
    else
        error "Docker is required for this build. Use --pull-docker or --build-docker"
        error "  --pull-docker   Pull prebuilt image from Docker Hub"
        error "  --build-docker  Build image locally from repo Dockerfiles"
        exit 1
    fi
}

# =============================================================================
# COMMON PATCHES — applied to .pro file for all qmake builds
# =============================================================================

apply_pro_patches() {
    local pro_file="$1"
    local dep_prefix="${2:-}"  # e.g. /opt/compat, Homebrew prefix, or empty for system

    info "Patching .pro file: $pro_file"

    # Fix qmake conditional syntax: USE_UPNP:=1 -> USE_UPNP=1
    # Why: qmake uses = not := for variable assignment
    sedi "s/USE_UPNP:=1/USE_UPNP=1/" "$pro_file"

    # Fix lrelease path: \\lrelease.exe -> /lrelease
    # Why: Windows-specific path separator doesn't work on other platforms
    sedi 's|\\\\\\\\lrelease.exe|/lrelease|' "$pro_file"

    # Remove hardcoded boost lib suffix
    # Why: Suffix like -mgw54-mt-s-x32-1_71 is MinGW-specific; doesn't match installed Boost
    sedi 's/BOOST_LIB_SUFFIX=-mgw[^ ]*/BOOST_LIB_SUFFIX=/' "$pro_file"

    # Comment out isEmpty(BOOST_LIB_SUFFIX) auto-detection block
    # Why: Auto-detection tries Windows-style suffixes; we use unsuffixed Boost libs
    sedi '/isEmpty(BOOST_LIB_SUFFIX)/,/^}/s/^/# /' "$pro_file"

    # Remove hardcoded boost lib references with version-specific names
    # Why: These reference Windows MinGW Boost builds that don't exist on other platforms
    sedi '/-lboost_system-mgw[^ ]*/d' "$pro_file"

    # Add BOOST_BIND_GLOBAL_PLACEHOLDERS to suppress Boost.Bind deprecation warnings
    # Why: Boost 1.73+ deprecated global placeholders (_1, _2); this define suppresses the warning
    if ! grep -q 'BOOST_BIND_GLOBAL_PLACEHOLDERS' "$pro_file"; then
        sedi '/^DEFINES/s/$/ BOOST_BIND_GLOBAL_PLACEHOLDERS/' "$pro_file"
    fi

    # Replace dependency paths if a prefix is provided
    if [[ -n "$dep_prefix" ]]; then
        sedi "s|BOOST_INCLUDE_PATH=.*|BOOST_INCLUDE_PATH=$dep_prefix/include|" "$pro_file"
        sedi "s|BOOST_LIB_PATH=.*|BOOST_LIB_PATH=$dep_prefix/lib|" "$pro_file"
        sedi "s|BDB_INCLUDE_PATH=.*|BDB_INCLUDE_PATH=$dep_prefix/include|" "$pro_file"
        sedi "s|BDB_LIB_PATH=.*|BDB_LIB_PATH=$dep_prefix/lib|" "$pro_file"
        sedi "s|OPENSSL_INCLUDE_PATH=.*|OPENSSL_INCLUDE_PATH=$dep_prefix/include|" "$pro_file"
        sedi "s|OPENSSL_LIB_PATH=.*|OPENSSL_LIB_PATH=$dep_prefix/lib|" "$pro_file"
        sedi "s|MINIUPNPC_INCLUDE_PATH=.*|MINIUPNPC_INCLUDE_PATH=$dep_prefix/include|" "$pro_file"
        sedi "s|MINIUPNPC_LIB_PATH=.*|MINIUPNPC_LIB_PATH=$dep_prefix/lib|" "$pro_file"
    fi
}

# =============================================================================
# WINDOWS CROSS-COMPILE (Docker + MXE)
# =============================================================================

build_windows() {
    local target="$1"  # daemon, qt, or both
    local jobs="$2"
    local docker_mode="$3"
    local container_name="win-${COIN_NAME}-build"
    local output_dir="$OUTPUT_BASE/windows"

    echo ""
    echo "============================================"
    echo "  Windows Cross-Compile: $COIN_NAME_UPPER"
    echo "============================================"
    echo "  Image:  $DOCKER_WINDOWS"
    echo "  Target: $target"
    echo ""

    ensure_docker_image "$DOCKER_WINDOWS" "$docker_mode" "Dockerfile.mxe-base"
    mkdir -p "$output_dir/qt" "$output_dir/daemon"
    docker rm -f "$container_name" 2>/dev/null || true

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        info "Building Qt wallet for Windows..."

        docker create \
            --name "$container_name" \
            "$DOCKER_WINDOWS" \
            /bin/bash -c '
set -e

# Add MXE Qt5 tools to PATH (lrelease needed for translation files)
export PATH="/opt/mxe/usr/x86_64-w64-mingw32.static/qt5/bin:$PATH"

# Fix miniupnpc: remove upnpc.c.obj (contains main()) which overrides wallet main()
# Why: miniupnpc ships a demo program with its own main(); conflicts with wallet binary
x86_64-w64-mingw32.static-ar d '"$MXE_SYSROOT"'/lib/libminiupnpc.a upnpc.c.obj 2>/dev/null || true

echo ">>> Cloning from '"$REPO_URL"'..."
git clone --depth 1 -b '"$REPO_BRANCH"' '"$REPO_URL"' /build/'"$COIN_NAME"'
cd /build/'"$COIN_NAME"'

echo ">>> Patching .pro file..."

# Fix .rc icon references for Windows resource compiler (case-sensitive on Linux)
# Approach from tested lib/windows.sh: only lowercase if lowercase file exists
if [ -f src/qt/res/bitcoin-qt.rc ]; then
    # Fix wrong coin name in .rc (e.g. lithium .rc referencing Photon icons)
    for ico_ref in $(grep -oP "\"icons/[^\"]+\\.ico\"" src/qt/res/bitcoin-qt.rc | tr -d "\""); do
        ico_lower=$(echo "$ico_ref" | tr "[:upper:]" "[:lower:]")
        if [ "$ico_ref" != "$ico_lower" ] && [ -f "src/qt/res/$ico_lower" ]; then
            sed -i "s|$ico_ref|$ico_lower|g" src/qt/res/bitcoin-qt.rc
        fi
    done
fi

# Fix GCC uninitialized warning treated as error in MXE cross-compile
sed -i "s|QMAKE_CXXFLAGS_WARN_ON = .*|QMAKE_CXXFLAGS_WARN_ON = -fdiagnostics-show-option -Wall -Wextra -Wformat -Wformat-security -Wno-unused-parameter -Wno-maybe-uninitialized -Wstack-protector|" *.pro

# Fix Boost.Asio get_io_service() removed in Boost 1.70+ (MXE ships newer Boost)
if grep -q "get_io_service" src/bitcoinrpc.cpp 2>/dev/null; then
    sed -i "s|resolver(stream\\.get_io_service())|resolver((boost::asio::io_context\\&)stream.get_executor().context())|g" src/bitcoinrpc.cpp
    sed -i "s|acceptor->get_io_service()|((boost::asio::io_context\\&)acceptor->get_executor().context())|g" src/bitcoinrpc.cpp
fi

# Fix qmake conditional syntax: USE_UPNP:=1 -> USE_UPNP=1
sed -i "s/USE_UPNP:=1/USE_UPNP=1/" *.pro

# Fix lrelease path: replace any \\lrelease.exe or broken lrelease references
# Why: upstream .pro uses Windows path \\lrelease.exe which fails on Linux cross-compile
LRELEASE_BIN=$(find /opt/mxe -name "lrelease" -type f 2>/dev/null | head -1)
[ -z "$LRELEASE_BIN" ] && LRELEASE_BIN="lrelease"
sed -i "s|QMAKE_LRELEASE = .*|QMAKE_LRELEASE = $LRELEASE_BIN|" *.pro
# Also fix the system() call that runs lrelease during qmake
sed -i "s|system(.*QMAKE_LRELEASE.*)|# lrelease handled by Makefile rules|" *.pro

# Replace hardcoded C:/deps paths with /opt/compat
sed -i "s|BOOST_INCLUDE_PATH=.*|BOOST_INCLUDE_PATH=/opt/compat/include|" *.pro
sed -i "s|BOOST_LIB_PATH=.*|BOOST_LIB_PATH=/opt/compat/lib|" *.pro
sed -i "s|BDB_INCLUDE_PATH=.*|BDB_INCLUDE_PATH=/opt/compat/include|" *.pro
sed -i "s|BDB_LIB_PATH=.*|BDB_LIB_PATH=/opt/compat/lib|" *.pro
sed -i "s|OPENSSL_INCLUDE_PATH=.*|OPENSSL_INCLUDE_PATH=/opt/compat/include|" *.pro
sed -i "s|OPENSSL_LIB_PATH=.*|OPENSSL_LIB_PATH=/opt/compat/lib|" *.pro

# Point miniupnpc at MXE sysroot
sed -i "s|MINIUPNPC_INCLUDE_PATH=.*|MINIUPNPC_INCLUDE_PATH='"$MXE_SYSROOT"'/include|" *.pro
sed -i "s|MINIUPNPC_LIB_PATH=.*|MINIUPNPC_LIB_PATH='"$MXE_SYSROOT"'/lib|" *.pro

# Remove hardcoded boost lib suffix
# Why: Suffix like -mgw54-mt-s-x32-1_71 doesnt match our Boost build
sed -i "s/BOOST_LIB_SUFFIX=-mgw54-mt-s-x32-1_71/BOOST_LIB_SUFFIX=/" *.pro

# Comment out isEmpty(BOOST_LIB_SUFFIX) auto-detection block
sed -i "/isEmpty(BOOST_LIB_SUFFIX)/,/^}/s/^/# /" *.pro

# Remove hardcoded boost lib references
sed -i "/-lboost_system-mgw54-mt-s-x32-1_71/d" *.pro

# Add BOOST_BIND_GLOBAL_PLACEHOLDERS
# Why: Boost 1.73+ deprecated global placeholders; suppresses warnings
sed -i "/^DEFINES/s/$/ BOOST_BIND_GLOBAL_PLACEHOLDERS/" *.pro

echo ">>> Patching source files..."

# Fix pid_t redefinition
# Why: mingw-w64 already provides pid_t; redefining it causes compile error
sed -i "s|typedef int pid_t;|// pid_t provided by mingw-w64|" src/util.h

# Fix SOCKET typedef — only define on non-Windows
# Why: mingw-w64 provides SOCKET; redefining it causes compile error
sed -i "s|typedef u_int SOCKET;|#ifndef WIN32\ntypedef u_int SOCKET;\n#endif|" src/compat.h

# Add missing boost/bind.hpp includes
# Why: Boost 1.81+ requires explicit include for boost::bind
sed -i "/^#include \"clientmodel.h\"/a #include <boost/bind.hpp>" src/qt/clientmodel.cpp
sed -i "/^#include \"walletmodel.h\"/a #include <boost/bind.hpp>" src/qt/walletmodel.cpp

echo ">>> Writing LevelDB build_config.mk..."

# Why: LevelDB build_detect_platform doesnt work for cross-compilation; manual config needed
cat > src/leveldb/build_config.mk << '\''LEVELDB_EOF'\''
SOURCES=db/builder.cc db/c.cc db/db_impl.cc db/db_iter.cc db/dbformat.cc db/filename.cc db/log_reader.cc db/log_writer.cc db/memtable.cc db/repair.cc db/table_cache.cc db/version_edit.cc db/version_set.cc db/write_batch.cc table/block.cc table/block_builder.cc table/filter_block.cc table/format.cc table/iterator.cc table/merger.cc table/table.cc table/table_builder.cc table/two_level_iterator.cc util/arena.cc util/bloom.cc util/cache.cc util/coding.cc util/comparator.cc util/crc32c.cc util/env.cc util/env_win.cc util/filter_policy.cc util/hash.cc util/histogram.cc util/logging.cc util/options.cc util/status.cc port/port_win.cc
MEMENV_SOURCES=helpers/memenv/memenv.cc
CC=x86_64-w64-mingw32.static-gcc
CXX=x86_64-w64-mingw32.static-g++
PLATFORM=OS_WINDOWS
PLATFORM_LDFLAGS=-lshlwapi
PLATFORM_LIBS=
PLATFORM_CCFLAGS= -fno-builtin-memcmp -D_REENTRANT -DOS_WIN -DLEVELDB_PLATFORM_WINDOWS -DWINVER=0x0500 -D__USE_MINGW_ANSI_STDIO=1 -DLEVELDB_IS_BIG_ENDIAN=0
PLATFORM_CXXFLAGS= -fno-builtin-memcmp -D_REENTRANT -DOS_WIN -DLEVELDB_PLATFORM_WINDOWS -DWINVER=0x0500 -D__USE_MINGW_ANSI_STDIO=1 -DLEVELDB_IS_BIG_ENDIAN=0
LEVELDB_EOF

echo ">>> Running qmake..."
x86_64-w64-mingw32.static-qmake-qt5 *.pro \
    "USE_UPNP=1" \
    "USE_QRCODE=0" \
    "RELEASE=1"

echo ">>> Building with make..."
make -j'"$jobs"'

echo ">>> Stripping binary..."
x86_64-w64-mingw32.static-strip release/*.exe 2>/dev/null || x86_64-w64-mingw32.static-strip *.exe 2>/dev/null || true

echo ">>> Build complete!"
ls -lh release/ 2>/dev/null || ls -lh *.exe 2>/dev/null || true
'

        info "Starting build container: $container_name"
        docker start -a "$container_name"

        info "Extracting ${QT_NAME}.exe..."
        if docker cp "$container_name:/build/$COIN_NAME/release/${QT_NAME}.exe" "$output_dir/qt/${QT_NAME}.exe" 2>/dev/null ||
           docker cp "$container_name:/build/$COIN_NAME/release/${COIN_NAME_UPPER}-qt.exe" "$output_dir/qt/${QT_NAME}.exe" 2>/dev/null ||
           docker cp "$container_name:/build/$COIN_NAME/${QT_NAME}.exe" "$output_dir/qt/${QT_NAME}.exe" 2>/dev/null ||
           docker cp "$container_name:/build/$COIN_NAME/${COIN_NAME_UPPER}-qt.exe" "$output_dir/qt/${QT_NAME}.exe" 2>/dev/null; then
            success "Qt wallet extracted to $output_dir/qt/"
            ls -lh "$output_dir/qt/${QT_NAME}.exe"
        else
            error "Could not find built .exe in container"
            docker exec "$container_name" find /build/$COIN_NAME -name "*.exe" -type f 2>/dev/null || true
            docker rm -f "$container_name" 2>/dev/null || true
            exit 1
        fi

        write_build_info "$output_dir/qt" "windows-cross-compile" "qt" "Docker: $DOCKER_WINDOWS (MXE)"
        docker rm -f "$container_name" 2>/dev/null || true
    fi

    if [[ "$target" == "daemon" || "$target" == "both" ]]; then
        info "Building daemon for Windows..."
        local daemon_container="win-${COIN_NAME}-daemon"
        docker rm -f "$daemon_container" 2>/dev/null || true

        docker create \
            --name "$daemon_container" \
            "$DOCKER_WINDOWS" \
            /bin/bash -c '
set -e

export PATH="/opt/mxe/usr/bin:$PATH"
MXE_TARGET="x86_64-w64-mingw32.static"

# Fix miniupnpc: remove upnpc.c.obj (contains main())
${MXE_TARGET}-ar d '"$MXE_SYSROOT"'/lib/libminiupnpc.a upnpc.c.obj 2>/dev/null || true

echo ">>> Cloning from '"$REPO_URL"'..."
git clone --depth 1 -b '"$REPO_BRANCH"' '"$REPO_URL"' /build/'"$COIN_NAME"'
cd /build/'"$COIN_NAME"'

echo ">>> Patching source files..."

# Fix pid_t redefinition (mingw-w64 provides it)
sed -i "s|typedef int pid_t;|// pid_t provided by mingw-w64|" src/util.h

# Fix SOCKET typedef — only define on non-Windows
sed -i "s|typedef u_int SOCKET;|#ifndef WIN32\ntypedef u_int SOCKET;\n#endif|" src/compat.h

# Add missing boost/bind.hpp includes
for f in src/qt/clientmodel.cpp src/qt/walletmodel.cpp; do
    if [ -f "$f" ] && ! grep -q "boost/bind.hpp" "$f"; then
        sed -i "1a #include <boost/bind.hpp>" "$f"
    fi
done

# Fix Boost.Asio get_io_service() removed in Boost 1.70+
if grep -q "get_io_service" src/bitcoinrpc.cpp 2>/dev/null; then
    sed -i "s|resolver(stream\.get_io_service())|resolver((boost::asio::io_context\&)stream.get_executor().context())|g" src/bitcoinrpc.cpp
    sed -i "s|acceptor->get_io_service()|((boost::asio::io_context\&)acceptor->get_executor().context())|g" src/bitcoinrpc.cpp
fi

echo ">>> Patching makefile.unix for Windows cross-compile..."

# Remove GNU ld flags not supported by mingw
sed -i "s/-Wl,-B\$(LMODE)//g; s/-Wl,-B\$(LMODE2)//g" src/makefile.unix 2>/dev/null || true
sed -i "s/-Wl,-z,relro//g; s/-Wl,-z,now//g" src/makefile.unix 2>/dev/null || true
sed -i "s/-l dl//g" src/makefile.unix 2>/dev/null || true
sed -i "s/-l pthread//g" src/makefile.unix 2>/dev/null || true
# Append Windows system libs
echo "LIBS += -l ws2_32 -l mswsock -l shlwapi -l crypt32 -l iphlpapi -l kernel32" >> src/makefile.unix

echo ">>> Writing LevelDB build_config.mk..."

echo "#!/bin/sh" > src/leveldb/build_detect_platform
echo "touch \$1" >> src/leveldb/build_detect_platform
chmod +x src/leveldb/build_detect_platform

cat > src/leveldb/build_config.mk << '\''LEVELDB_EOF'\''
SOURCES=db/builder.cc db/c.cc db/db_impl.cc db/db_iter.cc db/dbformat.cc db/filename.cc db/log_reader.cc db/log_writer.cc db/memtable.cc db/repair.cc db/table_cache.cc db/version_edit.cc db/version_set.cc db/write_batch.cc table/block.cc table/block_builder.cc table/filter_block.cc table/format.cc table/iterator.cc table/merger.cc table/table.cc table/table_builder.cc table/two_level_iterator.cc util/arena.cc util/bloom.cc util/cache.cc util/coding.cc util/comparator.cc util/crc32c.cc util/env.cc util/env_win.cc util/filter_policy.cc util/hash.cc util/histogram.cc util/logging.cc util/options.cc util/status.cc port/port_win.cc
MEMENV_SOURCES=helpers/memenv/memenv.cc
CC=x86_64-w64-mingw32.static-gcc
CXX=x86_64-w64-mingw32.static-g++
AR=x86_64-w64-mingw32.static-ar
PLATFORM=OS_WINDOWS
PLATFORM_LDFLAGS=-lshlwapi
PLATFORM_LIBS=
PLATFORM_CCFLAGS= -fno-builtin-memcmp -D_REENTRANT -DOS_WIN -DLEVELDB_PLATFORM_WINDOWS -DWINVER=0x0500 -D__USE_MINGW_ANSI_STDIO=1 -DLEVELDB_IS_BIG_ENDIAN=0
PLATFORM_CXXFLAGS= -fno-builtin-memcmp -D_REENTRANT -DOS_WIN -DLEVELDB_PLATFORM_WINDOWS -DWINVER=0x0500 -D__USE_MINGW_ANSI_STDIO=1 -DLEVELDB_IS_BIG_ENDIAN=0
LEVELDB_EOF

# Check if Windows port files exist; fall back to posix if not
if [ ! -f src/leveldb/port/port_win.cc ] || [ ! -f src/leveldb/util/env_win.cc ]; then
    sed -i "s|port/port_win.cc|port/port_posix.cc|" src/leveldb/build_config.mk
    sed -i "s|util/env_win.cc|util/env_posix.cc|" src/leveldb/build_config.mk
    sed -i "s/OS_WINDOWS/OS_LINUX/g; s/LEVELDB_PLATFORM_WINDOWS/LEVELDB_PLATFORM_POSIX/g" src/leveldb/build_config.mk
fi

echo ">>> Building daemon with makefile.unix..."
cd src
make -f makefile.unix \
    CC=${MXE_TARGET}-gcc \
    CXX=${MXE_TARGET}-g++ \
    AR=${MXE_TARGET}-ar \
    RANLIB=${MXE_TARGET}-ranlib \
    STRIP=${MXE_TARGET}-strip \
    LINK=${MXE_TARGET}-g++ \
    BOOST_INCLUDE_PATH=/opt/compat/include \
    BOOST_LIB_PATH=/opt/compat/lib \
    BDB_INCLUDE_PATH=/opt/compat/include \
    BDB_LIB_PATH=/opt/compat/lib \
    OPENSSL_INCLUDE_PATH=/opt/compat/include \
    OPENSSL_LIB_PATH=/opt/compat/lib \
    MINIUPNPC_INCLUDE_PATH='"$MXE_SYSROOT"'/include \
    MINIUPNPC_LIB_PATH='"$MXE_SYSROOT"'/lib \
    CXXFLAGS="-I/opt/compat/include -DWIN32 -DMINIUPNP_STATICLIB -DBOOST_BIND_GLOBAL_PLACEHOLDERS -Wno-maybe-uninitialized" \
    LDFLAGS="-L/opt/compat/lib -L'"$MXE_SYSROOT"'/lib -static" \
    TARGET_PLATFORM=windows \
    USE_UPNP=1 \
    -j'"$jobs"'

echo ">>> Stripping daemon..."
${MXE_TARGET}-strip '"$DAEMON_NAME"'.exe 2>/dev/null || ${MXE_TARGET}-strip '"$DAEMON_NAME"' 2>/dev/null || true
# Rename to .exe if not already
[ ! -f '"$DAEMON_NAME"'.exe ] && [ -f '"$DAEMON_NAME"' ] && mv '"$DAEMON_NAME"' '"$DAEMON_NAME"'.exe

echo ">>> Daemon build complete!"
ls -lh '"$DAEMON_NAME"'.exe 2>/dev/null || ls -lh '"$DAEMON_NAME"' 2>/dev/null || true
'

        info "Starting daemon build container: $daemon_container"
        docker start -a "$daemon_container"

        info "Extracting ${DAEMON_NAME}.exe..."
        if docker cp "$daemon_container:/build/$COIN_NAME/src/${DAEMON_NAME}.exe" "$output_dir/daemon/${DAEMON_NAME}.exe" 2>/dev/null ||
           docker cp "$daemon_container:/build/$COIN_NAME/src/${DAEMON_NAME}" "$output_dir/daemon/${DAEMON_NAME}.exe" 2>/dev/null; then
            success "Windows daemon extracted to $output_dir/daemon/"
            ls -lh "$output_dir/daemon/${DAEMON_NAME}.exe"
        else
            error "Could not find daemon .exe in container"
            docker exec "$daemon_container" find /build/$COIN_NAME/src -name "*.exe" -o -name "$DAEMON_NAME" 2>/dev/null || true
        fi

        write_build_info "$output_dir/daemon" "windows-cross-compile" "daemon" "Docker: $DOCKER_WINDOWS (MXE)"
        docker rm -f "$daemon_container" 2>/dev/null || true
    fi

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL — Windows"
    echo "  Output: $output_dir/"
    echo "============================================"
}

# =============================================================================
# macOS CROSS-COMPILE (Docker + osxcross)
# =============================================================================

build_macos_cross() {
    local target="$1"
    local jobs="$2"
    local docker_mode="$3"
    local container_name="mac-${COIN_NAME}-build"
    local output_dir="$OUTPUT_BASE/macos"

    echo ""
    echo "============================================"
    echo "  macOS Cross-Compile: $COIN_NAME_UPPER"
    echo "============================================"
    echo "  Image:  $DOCKER_MACOS"
    echo "  Target: $target"
    echo ""

    ensure_docker_image "$DOCKER_MACOS" "$docker_mode" "Dockerfile.osxcross-base"
    mkdir -p "$output_dir/qt" "$output_dir/daemon"
    docker rm -f "$container_name" 2>/dev/null || true

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        info "Building Qt wallet for macOS..."

        # Copy local source to temp dir for volume-mount (uses already-patched files)
        info "Copying local source to temp build dir..."
        local tmpdir_macos
        tmpdir_macos=$(mktemp -d)
        cp -a "$SCRIPT_DIR/src" "$SCRIPT_DIR/share" "$tmpdir_macos/"
        cp -a "$SCRIPT_DIR"/*.pro "$tmpdir_macos/" 2>/dev/null || true

        docker create \
            --name "$container_name" \
            -v "$tmpdir_macos:/build/$COIN_NAME:rw" \
            "$DOCKER_MACOS" \
            /bin/bash -c '
set -e

HOST="'"$OSXCROSS_HOST"'"
PREFIX="'"$MACPORTS_PREFIX"'"
OSXCROSS="'"$OSXCROSS_TARGET"'"

cd /build/'"$COIN_NAME"'

echo ">>> Patching .pro file..."

PRO_FILE=$(find . -maxdepth 1 -name "*.pro" ! -iname "*-OSX*" ! -iname "*OSX*" | head -1)

# Fix qmake syntax
# Why: qmake uses = not := for variable assignment
sed -i "s/USE_UPNP:=1/USE_UPNP=1/" "$PRO_FILE"

# Fix lrelease path
# Why: Windows-specific path separator doesnt work on other platforms
sed -i "s|\\\\\\\\lrelease.exe|/lrelease|" "$PRO_FILE"

# Replace dependency paths with MacPorts cross-compiled prefix
sed -i "s|BOOST_INCLUDE_PATH=.*|BOOST_INCLUDE_PATH=$PREFIX/include|" "$PRO_FILE"
sed -i "s|BOOST_LIB_PATH=.*|BOOST_LIB_PATH=$PREFIX/lib|" "$PRO_FILE"
sed -i "s|BDB_INCLUDE_PATH=.*|BDB_INCLUDE_PATH=$PREFIX/include|" "$PRO_FILE"
sed -i "s|BDB_LIB_PATH=.*|BDB_LIB_PATH=$PREFIX/lib|" "$PRO_FILE"
sed -i "s|OPENSSL_INCLUDE_PATH=.*|OPENSSL_INCLUDE_PATH=$PREFIX/include|" "$PRO_FILE"
sed -i "s|OPENSSL_LIB_PATH=.*|OPENSSL_LIB_PATH=$PREFIX/lib|" "$PRO_FILE"
sed -i "s|MINIUPNPC_INCLUDE_PATH=.*|MINIUPNPC_INCLUDE_PATH=$PREFIX/include|" "$PRO_FILE"
sed -i "s|MINIUPNPC_LIB_PATH=.*|MINIUPNPC_LIB_PATH=$PREFIX/lib|" "$PRO_FILE"

# Remove hardcoded boost suffix
# Why: Suffix like -mgw54-mt-s-x32-1_71 is MinGW-specific
sed -i "s/BOOST_LIB_SUFFIX=-mgw[^ ]*/BOOST_LIB_SUFFIX=/" "$PRO_FILE"
sed -i "/isEmpty(BOOST_LIB_SUFFIX)/,/^}/ s/^/#/" "$PRO_FILE"
sed -i "/-lboost_system-mgw[^ ]*/d" "$PRO_FILE"

# Remove hardcoded Windows C: paths
sed -i "/^[A-Z_]*_PATH\s*=\s*[Cc]:/d" "$PRO_FILE"

# Add BOOST_BIND_GLOBAL_PLACEHOLDERS
# Why: Boost 1.73+ deprecated global placeholders
grep -q "BOOST_BIND_GLOBAL_PLACEHOLDERS" "$PRO_FILE" || \
    sed -i "/^DEFINES/s/$/ BOOST_BIND_GLOBAL_PLACEHOLDERS/" "$PRO_FILE"

echo ">>> Patching source files..."

# Add boost/bind.hpp includes
# Why: Boost 1.81+ requires explicit include for boost::bind
sed -i "/#include \"clientmodel.h\"/a #include <boost/bind.hpp>" src/qt/clientmodel.cpp
sed -i "/#include \"walletmodel.h\"/a #include <boost/bind.hpp>" src/qt/walletmodel.cpp

# Qualify filesystem:: with boost:: namespace
# Why: macOS clang is stricter about namespace resolution; unqualified fails
FILESYSTEM_FILES="src/bitcoinrpc.cpp src/util.cpp src/walletdb.cpp src/init.cpp src/wallet.cpp src/db.cpp src/net.cpp"
for f in $FILESYSTEM_FILES; do
    if [ -f "$f" ]; then
        sed -i "s/\bfilesystem::/boost::filesystem::/g" "$f"
        sed -i "s/boost::boost::filesystem::/boost::filesystem::/g" "$f"
    fi
done

# Fix deprecated Boost.Filesystem APIs (these are already applied in local source,
# but the macOS Boost version may need the newer API names)
sed -i "s/\.is_complete()/.is_absolute()/g" src/*.cpp
sed -i "s/copy_option::overwrite_if_exists/copy_options::overwrite_existing/g" src/*.cpp
sed -i "s|#include <boost/filesystem/convenience.hpp>|#include <boost/filesystem.hpp>|g" src/*.cpp

# Boost 1.80+ removed get_io_service() from sockets/acceptors/streams
# Why: Deprecated in Boost 1.70, removed in 1.80; use get_executor() instead
if [ -f src/bitcoinrpc.cpp ]; then
    sed -i "s/resolver(stream\.get_io_service())/resolver(stream.get_executor())/g" src/bitcoinrpc.cpp
    perl -i -pe '"'"'s/acceptor->get_io_service\(\)/static_cast<boost::asio::io_context\&>(acceptor->get_executor().context())/'"'"' src/bitcoinrpc.cpp
fi

# Fix C++11 string literal spacing for PRI macros
# Why: clang enforces C99/C11 macro spacing strictly
find src/ -name "*.cpp" -o -name "*.h" | \
    xargs sed -i -E "s/\"(PRI[a-zA-Z0-9]+)/\" \1/g"

echo ">>> Writing LevelDB build_config.mk..."

# Override build_detect_platform (doesnt work for cross-compilation)
echo "#!/bin/sh" > src/leveldb/build_detect_platform
echo "touch \$1" >> src/leveldb/build_detect_platform
chmod +x src/leveldb/build_detect_platform

cat > src/leveldb/build_config.mk << '\''LEVELDB_EOF'\''
SOURCES=db/builder.cc db/c.cc db/db_impl.cc db/db_iter.cc db/dbformat.cc db/dumpfile.cc db/filename.cc db/log_reader.cc db/log_writer.cc db/memtable.cc db/repair.cc db/table_cache.cc db/version_edit.cc db/version_set.cc db/write_batch.cc table/block.cc table/block_builder.cc table/filter_block.cc table/format.cc table/iterator.cc table/merger.cc table/table.cc table/table_builder.cc table/two_level_iterator.cc util/arena.cc util/bloom.cc util/cache.cc util/coding.cc util/comparator.cc util/crc32c.cc util/env.cc util/env_posix.cc util/filter_policy.cc util/hash.cc util/histogram.cc util/logging.cc util/options.cc util/status.cc port/port_posix.cc
MEMENV_SOURCES=helpers/memenv/memenv.cc
LEVELDB_EOF

# Set compiler paths in build_config.mk (needs variable expansion)
echo "CC=$OSXCROSS/bin/${HOST}-clang" >> src/leveldb/build_config.mk
echo "CXX=$OSXCROSS/bin/${HOST}-clang++" >> src/leveldb/build_config.mk
echo "PLATFORM=OS_MACOSX" >> src/leveldb/build_config.mk
echo "PLATFORM_LDFLAGS=" >> src/leveldb/build_config.mk
echo "PLATFORM_LIBS=" >> src/leveldb/build_config.mk
echo "PLATFORM_CCFLAGS= -DOS_MACOSX -DLEVELDB_PLATFORM_POSIX" >> src/leveldb/build_config.mk
echo "PLATFORM_CXXFLAGS= -DOS_MACOSX -DLEVELDB_PLATFORM_POSIX" >> src/leveldb/build_config.mk
echo "PLATFORM_SHARED_EXT=" >> src/leveldb/build_config.mk
echo "PLATFORM_SHARED_LDFLAGS=" >> src/leveldb/build_config.mk
echo "PLATFORM_SHARED_CFLAGS=" >> src/leveldb/build_config.mk
echo "AR=$OSXCROSS/bin/${HOST}-ar" >> src/leveldb/build_config.mk

# Regenerate bitcoin.icns from bitcoin.png to ensure correct coin branding
# Why: Repo may contain stale Bitcoin icns from upstream; must match bitcoin.png
# Uses Pillow ICNS writer (same approach as lib/macos.sh + convert-icon.sh)
ICONS_DIR="src/qt/res/icons"
if [ -f "$ICONS_DIR/bitcoin.png" ]; then
    echo ">>> Regenerating macOS icon from bitcoin.png..."
    rm -f "$ICONS_DIR/bitcoin.icns"
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq python3-pil >/dev/null 2>&1 || true
    python3 -c "
from PIL import Image
img = Image.open('"'"'$ICONS_DIR/bitcoin.png'"'"')
img.save('"'"'$ICONS_DIR/bitcoin.icns'"'"')
print('"'"'    Icon generated from bitcoin.png'"'"')
" 2>/dev/null || echo "    Warning: Pillow icon conversion failed; using existing icns"
fi

echo ">>> Running qmake..."
$PREFIX/qt5/bin/qmake "$PRO_FILE" \
    -spec macx-osxcross \
    "CONFIG+=release" \
    "QMAKE_CC=$OSXCROSS/bin/${HOST}-clang" \
    "QMAKE_CXX=$OSXCROSS/bin/${HOST}-clang++" \
    "QMAKE_LINK=$OSXCROSS/bin/${HOST}-clang++" \
    "QMAKE_AR=$OSXCROSS/bin/${HOST}-ar cqs" \
    "QMAKE_RANLIB=$OSXCROSS/bin/${HOST}-ranlib" \
    "QMAKE_LFLAGS+=-stdlib=libc++" \
    "QMAKE_CXXFLAGS+=-stdlib=libc++" \
    "USE_UPNP=1" \
    "USE_QRCODE=0"

# Fix AR path in generated Makefile
# Why: qmake sets AR with "cqs" suffix but LevelDB makefile expects bare ar command
sed -i "s|AR            = .*/ar cqs|AR            = $OSXCROSS/bin/${HOST}-ar|" Makefile

echo ">>> Building with make..."
make -j'"$jobs"' \
    CC=$OSXCROSS/bin/${HOST}-clang \
    CXX=$OSXCROSS/bin/${HOST}-clang++ \
    AR=$OSXCROSS/bin/${HOST}-ar

echo ">>> Stripping binary..."
BINARY_NAME="'"$COIN_NAME_UPPER"'-Qt"
$OSXCROSS/bin/${HOST}-strip ${BINARY_NAME}.app/Contents/MacOS/${BINARY_NAME} 2>/dev/null || \
    $OSXCROSS/bin/${HOST}-strip '"$COIN_NAME_UPPER"'-Qt.app/Contents/MacOS/* 2>/dev/null || true

# Fix Info.plist branding
# Why: qmake generates Bitcoin-Qt branding from upstream .pro; fix to match coin name
# CFBundleExecutable must match the actual binary name or macOS shows "damaged" error
sed -i "s|<string>Bitcoin-Qt</string>|<string>'"$COIN_NAME_UPPER"'-Qt</string>|g" \
    ${BINARY_NAME}.app/Contents/Info.plist 2>/dev/null || true
sed -i "s|org.bitcoinfoundation.Bitcoin-Qt|org.'"$COIN_NAME"'.'"$COIN_NAME_UPPER"'-Qt|g" \
    ${BINARY_NAME}.app/Contents/Info.plist 2>/dev/null || true
sed -i "s|org.bitcoinfoundation.BitcoinPayment|org.'"$COIN_NAME"'.'"$COIN_NAME_UPPER"'Payment|g" \
    ${BINARY_NAME}.app/Contents/Info.plist 2>/dev/null || true
sed -i "s|<string>bitcoin</string>|<string>'"$COIN_NAME"'</string>|g" \
    ${BINARY_NAME}.app/Contents/Info.plist 2>/dev/null || true
sed -i '"'"'s|\$VERSION|0.8.6|g'"'"' ${BINARY_NAME}.app/Contents/Info.plist 2>/dev/null || true
sed -i '"'"'s|\$YEAR|2024|g'"'"' ${BINARY_NAME}.app/Contents/Info.plist 2>/dev/null || true
sed -i "s|The Bitcoin developers|The '"$COIN_NAME_UPPER"' developers|g" \
    ${BINARY_NAME}.app/Contents/Info.plist 2>/dev/null || true

echo ">>> Build complete!"
ls -lh ${BINARY_NAME}.app/Contents/MacOS/ 2>/dev/null || true
file ${BINARY_NAME}.app/Contents/MacOS/* 2>/dev/null || true
'

        info "Starting build container: $container_name"
        docker start -a "$container_name"

        info "Extracting macOS .app bundle..."
        local app_name="${COIN_NAME_UPPER}-Qt.app"
        # Remove old .app to prevent docker cp from creating nested .app structure
        rm -rf "$output_dir/qt/$app_name" 2>/dev/null || true
        if docker cp "$container_name:/build/$COIN_NAME/$app_name" "$output_dir/qt/$app_name" 2>/dev/null; then
            # Ensure binaries inside .app bundles are executable (docker cp can lose +x)
            find "$output_dir/qt/$app_name" -path "*/Contents/MacOS/*" -type f -exec chmod +x {} + 2>/dev/null || true
            success "macOS app bundle extracted to $output_dir/qt/"
            ls -lh "$output_dir/qt/$app_name/Contents/MacOS/" 2>/dev/null || true
            file "$output_dir/qt/$app_name/Contents/MacOS/"* 2>/dev/null || true
        else
            error "Could not find .app bundle in container"
            docker exec "$container_name" find /build/$COIN_NAME -name "*.app" -type d 2>/dev/null || true
            docker rm -f "$container_name" 2>/dev/null || true
            docker run --rm -v "$tmpdir_macos:/cleanup" alpine rm -rf /cleanup 2>/dev/null || rm -rf "$tmpdir_macos" 2>/dev/null || true
            exit 1
        fi

        write_build_info "$output_dir/qt" "macos-cross-compile" "qt" "Docker: $DOCKER_MACOS (osxcross)"
        docker rm -f "$container_name" 2>/dev/null || true
        docker run --rm -v "$tmpdir_macos:/cleanup" alpine rm -rf /cleanup 2>/dev/null || rm -rf "$tmpdir_macos" 2>/dev/null || true
    fi

    if [[ "$target" == "daemon" || "$target" == "both" ]]; then
        info "Building daemon for macOS..."
        local daemon_container="mac-${COIN_NAME}-daemon"
        docker rm -f "$daemon_container" 2>/dev/null || true

        # Copy local source to temp dir for volume-mount
        info "Copying local source to temp build dir..."
        local tmpdir_daemon
        tmpdir_daemon=$(mktemp -d)
        cp -a "$SCRIPT_DIR/src" "$SCRIPT_DIR/share" "$tmpdir_daemon/"

        docker create \
            --name "$daemon_container" \
            -v "$tmpdir_daemon:/build/$COIN_NAME:rw" \
            "$DOCKER_MACOS" \
            /bin/bash -c '
set -e

HOST="'"$OSXCROSS_HOST"'"
PREFIX="'"$MACPORTS_PREFIX"'"
OSXCROSS="'"$OSXCROSS_TARGET"'"

cd /build/'"$COIN_NAME"'

echo ">>> Patching source files..."

# Add boost/bind.hpp includes
for f in src/qt/clientmodel.cpp src/qt/walletmodel.cpp; do
    if [ -f "$f" ] && ! grep -q "boost/bind.hpp" "$f"; then
        sed -i "1a #include <boost/bind.hpp>" "$f"
    fi
done

# Qualify filesystem:: with boost:: namespace
for f in src/bitcoinrpc.cpp src/util.cpp src/walletdb.cpp src/init.cpp src/wallet.cpp src/db.cpp src/net.cpp src/main.cpp; do
    if [ -f "$f" ]; then
        sed -i "s/\bfilesystem::/boost::filesystem::/g" "$f"
        sed -i "s/boost::boost::filesystem::/boost::filesystem::/g" "$f"
    fi
done

# Fix deprecated Boost.Filesystem APIs
sed -i "s/\.is_complete()/.is_absolute()/g" src/*.cpp 2>/dev/null || true
sed -i "s/copy_option::overwrite_if_exists/copy_options::overwrite_existing/g" src/*.cpp 2>/dev/null || true
sed -i "s|#include <boost/filesystem/convenience.hpp>|#include <boost/filesystem.hpp>|g" src/*.cpp 2>/dev/null || true

# Fix Boost.Asio get_io_service() removed in Boost 1.80+
if [ -f src/bitcoinrpc.cpp ]; then
    sed -i "s/resolver(stream\.get_io_service())/resolver(stream.get_executor())/g" src/bitcoinrpc.cpp
    perl -i -pe '"'"'s/acceptor->get_io_service\(\)/static_cast<boost::asio::io_context\&>(acceptor->get_executor().context())/'"'"' src/bitcoinrpc.cpp
fi

# Fix C++11 string literal spacing for PRI macros (clang strict)
find src/ -name "*.cpp" -o -name "*.h" | \
    xargs sed -i -E "s/\"(PRI[a-zA-Z0-9]+)/\" \1/g" 2>/dev/null || true

echo ">>> Patching makefile.unix for macOS cross-compile..."

# Fix makefile.unix: compile .c files with CC, not CXX (clang rejects void* casts)
if [ -f src/makefile.unix ]; then
    sed -i '"'"'/^obj\/%.o: %.c$/,/^\t\$(CXX)/ s/\$(CXX)/\$(CC)/'"'"' src/makefile.unix 2>/dev/null || true
    sed -i '"'"'/^obj\/%.o: %.c$/,/xCXXFLAGS/ s/xCXXFLAGS/xCFLAGS/'"'"' src/makefile.unix 2>/dev/null || true
fi

# Remove GNU ld flags not supported by Apple linker
if [ -f src/makefile.unix ]; then
    sed -i "s/-Wl,-B\$(LMODE)//g; s/-Wl,-B\$(LMODE2)//g" src/makefile.unix 2>/dev/null || true
    sed -i "s/-Wl,-z,relro//g; s/-Wl,-z,now//g" src/makefile.unix 2>/dev/null || true
    sed -i "s/-l dl//g" src/makefile.unix 2>/dev/null || true
fi

echo ">>> Writing LevelDB build_config.mk..."

echo "#!/bin/sh" > src/leveldb/build_detect_platform
echo "touch \$1" >> src/leveldb/build_detect_platform
chmod +x src/leveldb/build_detect_platform

cat > src/leveldb/build_config.mk << '\''LEVELDB_EOF'\''
SOURCES=db/builder.cc db/c.cc db/db_impl.cc db/db_iter.cc db/dbformat.cc db/dumpfile.cc db/filename.cc db/log_reader.cc db/log_writer.cc db/memtable.cc db/repair.cc db/table_cache.cc db/version_edit.cc db/version_set.cc db/write_batch.cc table/block.cc table/block_builder.cc table/filter_block.cc table/format.cc table/iterator.cc table/merger.cc table/table.cc table/table_builder.cc table/two_level_iterator.cc util/arena.cc util/bloom.cc util/cache.cc util/coding.cc util/comparator.cc util/crc32c.cc util/env.cc util/env_posix.cc util/filter_policy.cc util/hash.cc util/histogram.cc util/logging.cc util/options.cc util/status.cc port/port_posix.cc
MEMENV_SOURCES=helpers/memenv/memenv.cc
LEVELDB_EOF

echo "CC=$OSXCROSS/bin/${HOST}-clang" >> src/leveldb/build_config.mk
echo "CXX=$OSXCROSS/bin/${HOST}-clang++" >> src/leveldb/build_config.mk
echo "PLATFORM=OS_MACOSX" >> src/leveldb/build_config.mk
echo "PLATFORM_LDFLAGS=" >> src/leveldb/build_config.mk
echo "PLATFORM_LIBS=" >> src/leveldb/build_config.mk
echo "PLATFORM_CCFLAGS= -DOS_MACOSX -DLEVELDB_PLATFORM_POSIX" >> src/leveldb/build_config.mk
echo "PLATFORM_CXXFLAGS= -DOS_MACOSX -DLEVELDB_PLATFORM_POSIX" >> src/leveldb/build_config.mk
echo "PLATFORM_SHARED_EXT=" >> src/leveldb/build_config.mk
echo "PLATFORM_SHARED_LDFLAGS=" >> src/leveldb/build_config.mk
echo "PLATFORM_SHARED_CFLAGS=" >> src/leveldb/build_config.mk
echo "AR=$OSXCROSS/bin/${HOST}-ar" >> src/leveldb/build_config.mk

echo ">>> Building daemon with makefile.unix..."
cd src
make -f makefile.unix \
    CC=$OSXCROSS/bin/${HOST}-clang \
    CXX=$OSXCROSS/bin/${HOST}-clang++ \
    AR=$OSXCROSS/bin/${HOST}-ar \
    RANLIB=$OSXCROSS/bin/${HOST}-ranlib \
    STRIP=$OSXCROSS/bin/${HOST}-strip \
    LINK=$OSXCROSS/bin/${HOST}-clang++ \
    BOOST_INCLUDE_PATH=$PREFIX/include \
    BOOST_LIB_PATH=$PREFIX/lib \
    BDB_INCLUDE_PATH=$PREFIX/include \
    BDB_LIB_PATH=$PREFIX/lib \
    OPENSSL_INCLUDE_PATH=$PREFIX/include \
    OPENSSL_LIB_PATH=$PREFIX/lib \
    MINIUPNPC_INCLUDE_PATH=$PREFIX/include \
    MINIUPNPC_LIB_PATH=$PREFIX/lib \
    CXXFLAGS="-DMAC_OSX -DMSG_NOSIGNAL=0 -I$PREFIX/include -mmacosx-version-min=11.0 -DBOOST_BIND_GLOBAL_PLACEHOLDERS" \
    CFLAGS="-DMAC_OSX -DMSG_NOSIGNAL=0 -mmacosx-version-min=11.0" \
    LDFLAGS="-L$PREFIX/lib -mmacosx-version-min=11.0" \
    USE_UPNP=1 \
    STATIC=all \
    -j'"$jobs"'

echo ">>> Stripping daemon..."
$OSXCROSS/bin/${HOST}-strip '"$DAEMON_NAME"' 2>/dev/null || true

echo ">>> Daemon build complete!"
ls -lh '"$DAEMON_NAME"' 2>/dev/null || true
file '"$DAEMON_NAME"' 2>/dev/null || true
'

        info "Starting macOS daemon build container: $daemon_container"
        docker start -a "$daemon_container"

        info "Extracting macOS daemon..."
        if docker cp "$daemon_container:/build/$COIN_NAME/src/${DAEMON_NAME}" "$output_dir/daemon/${DAEMON_NAME}" 2>/dev/null; then
            # Ensure daemon binary is executable (docker cp can lose +x)
            chmod +x "$output_dir/daemon/${DAEMON_NAME}"
            success "macOS daemon extracted to $output_dir/daemon/"
            ls -lh "$output_dir/daemon/${DAEMON_NAME}"
        else
            error "Could not find daemon binary in container"
            docker exec "$daemon_container" find /build/$COIN_NAME/src -type f -executable -name "*d" 2>/dev/null || true
        fi

        write_build_info "$output_dir/daemon" "macos-cross-compile" "daemon" "Docker: $DOCKER_MACOS (osxcross)"
        docker rm -f "$daemon_container" 2>/dev/null || true
        docker run --rm -v "$tmpdir_daemon:/cleanup" alpine rm -rf /cleanup 2>/dev/null || rm -rf "$tmpdir_daemon" 2>/dev/null || true
    fi

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL — macOS"
    echo "  Output: $output_dir/"
    echo "============================================"
}

# =============================================================================
# APPIMAGE BUILD (Docker + Ubuntu 22.04)
# =============================================================================

build_appimage() {
    local jobs="$1"
    local docker_mode="$2"
    local container_name="appimage-${COIN_NAME}-build"
    local output_dir="$OUTPUT_BASE/linux-appimage/qt"

    echo ""
    echo "============================================"
    echo "  AppImage Build: $COIN_NAME_UPPER"
    echo "============================================"
    echo "  Image:  $DOCKER_APPIMAGE"
    echo ""

    ensure_docker_image "$DOCKER_APPIMAGE" "$docker_mode" "Dockerfile.appimage-base"
    mkdir -p "$output_dir"
    docker rm -f "$container_name" 2>/dev/null || true

    info "Building AppImage..."

    # Copy local source to temp dir for volume-mount (uses already-patched files)
    info "Copying local source to temp build dir..."
    local tmpdir_appimage
    tmpdir_appimage=$(mktemp -d)
    cp -a "$SCRIPT_DIR/src" "$SCRIPT_DIR/share" "$tmpdir_appimage/"
    cp -a "$SCRIPT_DIR"/*.pro "$tmpdir_appimage/" 2>/dev/null || true

    docker create \
        --name "$container_name" \
        -v "$tmpdir_appimage:/build/$COIN_NAME:rw" \
        "$DOCKER_APPIMAGE" \
        /bin/bash -c '
set -e

cd /build/'"$COIN_NAME"'

PRO_FILE=$(find . -maxdepth 1 -name "*.pro" ! -iname "*-OSX*" ! -iname "*OSX*" | head -1)

echo ">>> Patching .pro file: $PRO_FILE"

# Fix qmake syntax
sed -i "s/USE_UPNP:=1/USE_UPNP=1/" "$PRO_FILE"

# Remove hardcoded boost suffix
sed -i "s/BOOST_LIB_SUFFIX=-mgw[^ ]*/BOOST_LIB_SUFFIX=/" "$PRO_FILE"
sed -i "/-lboost_system-mgw[^ ]*/d" "$PRO_FILE"
sed -i "/isEmpty(BOOST_LIB_SUFFIX)/,/^}/s/^/# /" "$PRO_FILE"

# Add BOOST_BIND_GLOBAL_PLACEHOLDERS
# Why: Boost 1.73+ deprecated global placeholders
grep -q "BOOST_BIND_GLOBAL_PLACEHOLDERS" "$PRO_FILE" || \
    sed -i "/^DEFINES/s/$/ BOOST_BIND_GLOBAL_PLACEHOLDERS/" "$PRO_FILE"

# Remove pre-committed LevelDB config (let build_detect_platform generate it)
# Why: Pre-committed config may target wrong platform
rm -f src/leveldb/build_config.mk
chmod +x src/leveldb/build_detect_platform 2>/dev/null || true

# Add -ldl for static OpenSSL linking
# Why: OpenSSL uses dlopen internally; needs -ldl on Linux
grep -q "\-ldl" "$PRO_FILE" || echo "unix:!macx:LIBS += -ldl" >> "$PRO_FILE"

# Add -lboost_chrono (needed on Ubuntu 22.04)
# Why: Boost.Thread depends on Boost.Chrono; not auto-linked on newer Ubuntu
grep -q "unix.*lboost_chrono" "$PRO_FILE" || echo "unix:!macx:LIBS += -lboost_chrono" >> "$PRO_FILE"

# Boost 1.74+ removed get_io_service() from sockets/acceptors/streams
# Why: Ubuntu 22.04 ships Boost 1.74; get_io_service() was removed, use get_executor()
if [ -f src/bitcoinrpc.cpp ]; then
    sed -i "s/resolver(stream\.get_io_service())/resolver(stream.get_executor())/g" src/bitcoinrpc.cpp
    perl -i -pe '"'"'s/acceptor->get_io_service\(\)/static_cast<boost::asio::io_context\&>(acceptor->get_executor().context())/'"'"' src/bitcoinrpc.cpp
fi

echo ">>> Building Qt wallet..."
# Try qmake-qt5 first (Ubuntu 18.04), fall back to qmake (Ubuntu 22.04+)
QMAKE=$(command -v qmake-qt5 2>/dev/null || command -v qmake 2>/dev/null || echo "/usr/lib/qt5/bin/qmake")
echo "Using: $QMAKE"
$QMAKE "$PRO_FILE" \
    "USE_QRCODE=0" \
    "USE_UPNP=1" \
    "RELEASE=1"

make -j'"$jobs"'

QT_BIN=$(find . -name "'"$QT_NAME"'" -o -name "'"$COIN_NAME_UPPER"'-qt" | head -1)
if [ -z "$QT_BIN" ]; then
    QT_BIN=$(find release/ -type f -executable 2>/dev/null | head -1)
fi

if [ -z "$QT_BIN" ]; then
    echo "ERROR: Could not find built Qt binary"
    find . -type f -executable -name "*qt*" -o -name "*Qt*" 2>/dev/null
    exit 1
fi

strip "$QT_BIN" 2>/dev/null || true

echo ">>> Creating AppDir..."
APPDIR=/build/appdir
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/plugins" \
    "$APPDIR/usr/share/glib-2.0/schemas" "$APPDIR/etc"

cp "$QT_BIN" "$APPDIR/usr/bin/'"$QT_NAME"'"

# Bundle Qt plugins (dynamic discovery like lib/appimage.sh)
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
                # Skip glibc/core runtime — always present on host
                ;;
            libfontconfig.so*|libfreetype.so*)
                # DO NOT bundle — old versions crash on variable-weight fonts
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

# Create qt.conf to tell Qt where to find plugins
cat > "$APPDIR/usr/bin/qt.conf" << '\''QTCONF'\''
[Paths]
Plugins = ../plugins
QTCONF

# GSettings schema (cross-Ubuntu compatibility)
# Why: antialiasing key moved to .deprecated schema in newer GNOME; apps crash without it
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

# Minimal OpenSSL config (avoids host OpenSSL 3.0 conflicts)
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

# Desktop file (in AppDir root + usr/share/applications)
cat > "$APPDIR/'"$COIN_NAME"'.desktop" << '\''DESKTOP_EOF'\''
[Desktop Entry]
Type=Application
Name='"$COIN_NAME_UPPER"'
Comment='"$COIN_NAME_UPPER"' Cryptocurrency Wallet
Exec='"$QT_NAME"'
Icon='"$COIN_NAME"'
Categories=Network;Finance;
Terminal=false
StartupWMClass='"$QT_NAME"'
DESKTOP_EOF
mkdir -p "$APPDIR/usr/share/applications"
cp "$APPDIR/'"$COIN_NAME"'.desktop" "$APPDIR/usr/share/applications/"

# Icon (use existing or create placeholder)
ICON_DIR="$APPDIR/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$ICON_DIR"
if [ -f src/qt/res/icons/bitcoin.png ]; then
    cp src/qt/res/icons/bitcoin.png "$ICON_DIR/'"$COIN_NAME"'.png"
else
    # Minimal 1x1 placeholder PNG
    echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==" | base64 -d > "$ICON_DIR/'"$COIN_NAME"'.png"
fi
# Symlink in root (required by AppImage spec)
ln -sf "usr/share/icons/hicolor/256x256/apps/'"$COIN_NAME"'.png" "$APPDIR/'"$COIN_NAME"'.png"

# AppRun script with desktop integration
cat > "$APPDIR/AppRun" << '\''APPRUN_EOF'\''
#!/bin/bash
APPDIR="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$APPDIR/usr/lib:$LD_LIBRARY_PATH"
export PATH="$APPDIR/usr/bin:$PATH"

# Use bundled GSettings schemas
export GSETTINGS_SCHEMA_DIR="$APPDIR/usr/share/glib-2.0/schemas"
export GSETTINGS_BACKEND=memory
export GIO_MODULE_DIR="$APPDIR/usr/lib/gio/modules"

# Qt plugin paths
if [ -d "$APPDIR/usr/plugins" ]; then
    export QT_PLUGIN_PATH="$APPDIR/usr/plugins"
fi

# Force X11 for older Qt builds; use Fusion style (GTK3 theme plugin removed)
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}"
export QT_STYLE_OVERRIDE=Fusion
export XDG_DATA_DIRS="$APPDIR/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

# Prevent host OpenSSL 3.0 config from interfering
export OPENSSL_CONF="$APPDIR/etc/openssl.cnf"

# Desktop integration — register icon so GNOME dock shows coin logo
_ICON_NAME="'"$COIN_NAME"'"
_QT_NAME="'"$QT_NAME"'"
_WM_CLASS="'"$COIN_NAME_UPPER"'-Qt"
_COIN_NAME="'"$COIN_NAME_UPPER"'"
_APPIMAGE_PATH="${APPIMAGE:-$0}"
_ICON_SRC="$APPDIR/usr/share/icons/hicolor/256x256/apps/${_ICON_NAME}.png"
_ICON_DST="$HOME/.local/share/icons/hicolor/256x256/apps/${_ICON_NAME}.png"
_DESKTOP_DST="$HOME/.local/share/applications/${_QT_NAME}-appimage.desktop"

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
    "/build/output/'"$COIN_NAME_UPPER"'-x86_64.AppImage"
chmod +x "/build/output/'"$COIN_NAME_UPPER"'-x86_64.AppImage"

echo ">>> AppImage build complete!"
ls -lh /build/output/
'

    info "Starting build container: $container_name"
    docker start -a "$container_name"

    info "Extracting AppImage..."
    if docker cp "$container_name:/build/output/${COIN_NAME_UPPER}-x86_64.AppImage" "$output_dir/${COIN_NAME_UPPER}-x86_64.AppImage" 2>/dev/null; then
        success "AppImage extracted to $output_dir/"
        ls -lh "$output_dir/${COIN_NAME_UPPER}-x86_64.AppImage"
    else
        error "Could not find AppImage in container"
        docker rm -f "$container_name" 2>/dev/null || true
        exit 1
    fi

    write_build_info "$output_dir" "appimage" "qt" "Docker: $DOCKER_APPIMAGE"
    docker rm -f "$container_name" 2>/dev/null || true

    # Clean up temp dir (may contain root-owned build artifacts)
    docker run --rm -v "$tmpdir_appimage:/cleanup" alpine rm -rf /cleanup 2>/dev/null || rm -rf "$tmpdir_appimage" 2>/dev/null || true

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL — AppImage"
    echo "  Output: $output_dir/${COIN_NAME_UPPER}-x86_64.AppImage"
    echo "============================================"
}

# =============================================================================
# NATIVE BUILD (Linux with Docker, or direct on Linux/macOS/Windows)
# =============================================================================

build_native_docker() {
    local target="$1"
    local jobs="$2"
    local docker_mode="$3"
    local output_dir="$OUTPUT_BASE/native"

    mkdir -p "$output_dir/daemon" "$output_dir/qt"

    # Both daemon and Qt use native-base:18.04 (has build tools + Qt5 dev packages)

    if [[ "$target" == "daemon" || "$target" == "both" ]]; then
        local container_name="native-${COIN_NAME}-daemon"

        echo ""
        echo "============================================"
        echo "  Native Daemon Build (Docker): $COIN_NAME_UPPER"
        echo "============================================"
        echo "  Image:  $DOCKER_NATIVE"
        echo ""

        ensure_docker_image "$DOCKER_NATIVE" "$docker_mode" "Dockerfile.native-base"
        docker rm -f "$container_name" 2>/dev/null || true

        # Mount local source into container (uses already-patched local files)
        info "Copying local source to temp build dir..."
        local tmpdir
        tmpdir=$(mktemp -d)
        cp -a "$SCRIPT_DIR/src" "$SCRIPT_DIR/share" "$tmpdir/"
        cp -a "$SCRIPT_DIR"/*.pro "$tmpdir/" 2>/dev/null || true

        docker run --rm --name "$container_name" \
            -v "$tmpdir:/build/$COIN_NAME:rw" \
            -v "$output_dir/daemon:/build/output/daemon:rw" \
            "$DOCKER_NATIVE" \
            /bin/bash -c '
set -e

cd /build/'"$COIN_NAME"'

echo ">>> Applying Boost 1.65 compatibility patches (Ubuntu 18.04)..."

# Boost 1.65 uses io_service, not io_context (added in Boost 1.66+)
# Why: Ubuntu 18.04 ships Boost 1.65; code references newer API that doesnt exist
for src_file in $(grep -rl "boost::asio::io_context" src/ 2>/dev/null); do
    sed -i "s/boost::asio::io_context/boost::asio::io_service/g" "$src_file"
    sed -i "s/get_executor()\.context()/get_io_service()/g" "$src_file"
done

# Boost 1.65 uses copy_option not copy_options
for src_file in $(grep -rl "copy_options::overwrite_existing" src/ 2>/dev/null); do
    sed -i "s/copy_options::overwrite_existing/copy_option::overwrite_if_exists/g" "$src_file"
done

echo ">>> Building daemon..."
cd src
rm -f leveldb/build_config.mk
chmod +x leveldb/build_detect_platform 2>/dev/null || true

make -f makefile.unix \
    USE_UPNP=1 \
    CXXFLAGS="-DBOOST_BIND_GLOBAL_PLACEHOLDERS" \
    -j'"$jobs"'

strip '"$DAEMON_NAME"' 2>/dev/null || true
echo ">>> Daemon build complete!"
ls -lh '"$DAEMON_NAME"'
cp '"$DAEMON_NAME"' /build/output/daemon/
'

        if [[ -f "$output_dir/daemon/$DAEMON_NAME" ]]; then
            success "Daemon built: $output_dir/daemon/$DAEMON_NAME"
            ls -lh "$output_dir/daemon/$DAEMON_NAME"
        else
            warn "Could not find daemon binary"
        fi

        write_build_info "$output_dir/daemon" "native-docker" "daemon" "Docker: $DOCKER_NATIVE (Ubuntu 18.04)"
        docker run --rm -v "$tmpdir:/cleanup" alpine rm -rf /cleanup 2>/dev/null || rm -rf "$tmpdir" 2>/dev/null || true

        echo ""
        echo "============================================"
        echo "  BUILD SUCCESSFUL — Native Daemon (Docker)"
        echo "  Output: $output_dir/daemon/"
        echo "============================================"
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        local container_name="native-${COIN_NAME}-qt"

        echo ""
        echo "============================================"
        echo "  Native Qt Build (Docker): $COIN_NAME_UPPER"
        echo "============================================"
        echo "  Image:  $DOCKER_NATIVE (Ubuntu 18.04)"
        echo ""

        ensure_docker_image "$DOCKER_NATIVE" "$docker_mode" "Dockerfile.native-base"
        docker rm -f "$container_name" 2>/dev/null || true

        # Mount local source into container (uses already-patched local files)
        info "Copying local source to temp build dir..."
        local tmpdir_qt
        tmpdir_qt=$(mktemp -d)
        cp -a "$SCRIPT_DIR/src" "$SCRIPT_DIR/share" "$tmpdir_qt/"
        cp -a "$SCRIPT_DIR"/*.pro "$tmpdir_qt/" 2>/dev/null || true

        docker run --rm --name "$container_name" \
            -v "$tmpdir_qt:/build/$COIN_NAME:rw" \
            -v "$output_dir/qt:/build/output/qt:rw" \
            "$DOCKER_NATIVE" \
            /bin/bash -c '
set -e

cd /build/'"$COIN_NAME"'

echo ">>> Building Qt wallet..."
PRO_FILE=$(find . -maxdepth 1 -name "*.pro" ! -iname "*-OSX*" | head -1)

# Fix qmake syntax
sed -i "s/USE_UPNP:=1/USE_UPNP=1/" "$PRO_FILE"

# Remove Windows paths block
# Why: Hardcoded C:/deps paths break Linux builds
sed -i "/# Start of Windows Path/,/# End of Windows Path/d" "$PRO_FILE"

# Remove hardcoded boost suffix
# Why: Suffix like -mgw54-mt-s-x32-1_71 is MinGW-specific
sed -i "s/BOOST_LIB_SUFFIX=-mgw[^ ]*/BOOST_LIB_SUFFIX=/" "$PRO_FILE"
sed -i "/-lboost_system-mgw[^ ]*/d" "$PRO_FILE"
sed -i "/isEmpty(BOOST_LIB_SUFFIX)/,/^}/s/^/# /" "$PRO_FILE"

# Remove hardcoded Windows C: paths from include/lib paths
sed -i "/^[A-Z_]*_PATH\s*=\s*[Cc]:/d" "$PRO_FILE"

# Add BOOST_BIND_GLOBAL_PLACEHOLDERS
# Why: Boost 1.73+ deprecated global placeholders
grep -q "BOOST_BIND_GLOBAL_PLACEHOLDERS" "$PRO_FILE" || \
    sed -i "/^DEFINES/s/$/ BOOST_BIND_GLOBAL_PLACEHOLDERS/" "$PRO_FILE"

# Remove pre-committed LevelDB config
# Why: Let build_detect_platform generate correct config for this platform
rm -f src/leveldb/build_config.mk
chmod +x src/leveldb/build_detect_platform 2>/dev/null || true

# Add -ldl for static OpenSSL linking
# Why: OpenSSL uses dlopen internally; needs -ldl on Linux
grep -q "\-ldl" "$PRO_FILE" || echo "unix:!macx:LIBS += -ldl" >> "$PRO_FILE"

# Add -lboost_chrono
# Why: Boost.Thread depends on Boost.Chrono; not always auto-linked
grep -q "unix.*lboost_chrono" "$PRO_FILE" || echo "unix:!macx:LIBS += -lboost_chrono" >> "$PRO_FILE"

# Boost 1.65 uses io_service, not io_context (added in Boost 1.66+)
# Why: Ubuntu 18.04 ships Boost 1.65; ensure source uses old API names
for src_file in $(grep -rl "boost::asio::io_context" src/ 2>/dev/null); do
    sed -i "s/boost::asio::io_context/boost::asio::io_service/g" "$src_file"
    sed -i "s/get_executor()\.context()/get_io_service()/g" "$src_file"
done

# Boost 1.65 uses copy_option not copy_options
for src_file in $(grep -rl "copy_options::overwrite_existing" src/ 2>/dev/null); do
    sed -i "s/copy_options::overwrite_existing/copy_option::overwrite_if_exists/g" "$src_file"
done

echo ">>> Running qmake..."
# Try qmake-qt5 first (Ubuntu 18.04), fall back to qmake (Ubuntu 22.04+)
QMAKE=$(command -v qmake-qt5 2>/dev/null || command -v qmake 2>/dev/null || echo "/usr/lib/qt5/bin/qmake")
echo "Using: $QMAKE"
$QMAKE "$PRO_FILE" \
    "USE_QRCODE=0" \
    "USE_UPNP=1" \
    "RELEASE=1"

echo ">>> Building with make..."
make -j'"$jobs"'

QT_BIN=$(find release/ -type f -executable 2>/dev/null | head -1)
[ -z "$QT_BIN" ] && QT_BIN=$(find . -maxdepth 1 -type f -executable \( -name "*qt*" -o -name "*Qt*" \) 2>/dev/null | head -1)
strip "$QT_BIN" 2>/dev/null || true
cp "$QT_BIN" /build/output/qt/'"$QT_NAME"'
echo ">>> Qt wallet build complete!"
ls -lh /build/output/qt/
'

        if [[ -f "$output_dir/qt/$QT_NAME" ]]; then
            success "Qt wallet built: $output_dir/qt/$QT_NAME"
            ls -lh "$output_dir/qt/$QT_NAME"
        else
            warn "Could not find Qt binary"
        fi

        write_build_info "$output_dir/qt" "native-docker" "qt" "Docker: $DOCKER_NATIVE (Ubuntu 18.04)"
        docker run --rm -v "$tmpdir_qt:/cleanup" alpine rm -rf /cleanup 2>/dev/null || rm -rf "$tmpdir_qt" 2>/dev/null || true

        echo ""
        echo "============================================"
        echo "  BUILD SUCCESSFUL — Native Qt (Docker)"
        echo "  Output: $output_dir/qt/"
        echo "============================================"
    fi
}

build_native_direct() {
    local target="$1"
    local jobs="$2"
    local host_os
    host_os=$(detect_os)
    local os_version
    os_version=$(detect_os_version "$host_os")

    echo ""
    echo "============================================"
    echo "  Native Build (Direct): $COIN_NAME_UPPER"
    echo "============================================"
    echo "  OS:     $os_version"
    echo "  Target: $target"
    echo ""

    case "$host_os" in
        linux)
            build_native_linux_direct "$target" "$jobs" "$os_version"
            ;;
        macos)
            build_native_macos "$target" "$jobs" "$os_version"
            ;;
        windows)
            build_native_windows "$target" "$jobs" "$os_version"
            ;;
    esac
}

build_native_linux_direct() {
    local target="$1"
    local jobs="$2"
    local os_version="$3"
    local output_dir="$OUTPUT_BASE/native"

    # Install build + runtime dependencies
    # Build deps: compilers, headers, static libs for compiling
    # Runtime deps: shared libs, MIME database, XCB platform plugin for Qt display
    local build_deps="build-essential libssl-dev libboost-all-dev libminiupnpc-dev"
    local qt_build_deps="qt5-qmake qtbase5-dev qttools5-dev-tools"
    local qt_runtime_deps="shared-mime-info libqt5widgets5 libqt5gui5 libqt5network5 libqt5dbus5"
    local bdb_deps=""

    # BDB 4.8 is preferred but not always available; fall back to 5.3
    if apt-cache show libdb4.8-dev &>/dev/null 2>&1; then
        bdb_deps="libdb4.8-dev libdb4.8++-dev"
    elif apt-cache show libdb5.3-dev &>/dev/null 2>&1; then
        bdb_deps="libdb5.3-dev libdb5.3++-dev"
    fi

    local all_deps="$build_deps $bdb_deps"
    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        all_deps="$all_deps $qt_build_deps $qt_runtime_deps"
    fi

    info "Checking and installing dependencies..."
    local missing_pkgs=()
    for pkg in $all_deps; do
        dpkg -s "$pkg" &>/dev/null 2>&1 || missing_pkgs+=("$pkg")
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        info "Installing missing packages: ${missing_pkgs[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${missing_pkgs[@]}"
    fi

    mkdir -p "$output_dir/daemon" "$output_dir/qt"

    if [[ "$target" == "daemon" || "$target" == "both" ]]; then
        info "Building daemon..."
        cd "$SCRIPT_DIR/src"

        # Remove pre-committed LevelDB config
        rm -f leveldb/build_config.mk
        chmod +x leveldb/build_detect_platform 2>/dev/null || true

        make -f makefile.unix \
            USE_UPNP=1 \
            CXXFLAGS="-DBOOST_BIND_GLOBAL_PLACEHOLDERS" \
            -j"$jobs"

        strip "$DAEMON_NAME" 2>/dev/null || true
        cp "$DAEMON_NAME" "$output_dir/daemon/"
        success "Daemon: $output_dir/daemon/$DAEMON_NAME"
        ls -lh "$output_dir/daemon/$DAEMON_NAME"
        cd "$SCRIPT_DIR"
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        info "Building Qt wallet..."
        cd "$SCRIPT_DIR"

        local pro_file
        pro_file=$(find . -maxdepth 1 -name "*.pro" ! -iname "*-OSX*" | head -1)
        apply_pro_patches "$pro_file"

        rm -f src/leveldb/build_config.mk
        chmod +x src/leveldb/build_detect_platform 2>/dev/null || true

        grep -q "\-ldl" "$pro_file" || echo "unix:!macx:LIBS += -ldl" >> "$pro_file"

        # Find qmake: try qmake-qt5, then /usr/lib/qt5/bin/qmake, then system qmake
        # Why: /usr/bin/qmake is often qtchooser which fails without QT_SELECT=qt5
        local qmake_bin
        if command -v qmake-qt5 &>/dev/null; then
            qmake_bin="qmake-qt5"
        elif [[ -x /usr/lib/qt5/bin/qmake ]]; then
            qmake_bin="/usr/lib/qt5/bin/qmake"
        else
            qmake_bin="qmake"
            export QT_SELECT=qt5
        fi

        "$qmake_bin" "$pro_file" \
            "USE_QRCODE=0" \
            "USE_UPNP=1" \
            "RELEASE=1"

        make -j"$jobs"

        local qt_bin=""
        qt_bin=$(find release/ -type f -executable 2>/dev/null | head -1 || true)
        [[ -z "$qt_bin" ]] && qt_bin=$(find . -maxdepth 1 -name "*qt*" -type f -executable 2>/dev/null | head -1 || true)
        if [[ -n "$qt_bin" ]]; then
            strip "$qt_bin" 2>/dev/null || true
            cp "$qt_bin" "$output_dir/qt/$QT_NAME"
            success "Qt wallet: $output_dir/qt/$QT_NAME"
            ls -lh "$output_dir/qt/$QT_NAME"
        else
            error "Qt binary not found after build"
            exit 1
        fi
    fi

    write_build_info "$output_dir" "native-linux" "$target" "$os_version"

    # Install .desktop launcher + icon for Activities search (Linux only, Qt builds)
    if [[ "$target" == "qt" || "$target" == "both" ]] && [[ -f "$output_dir/qt/$QT_NAME" ]]; then
        info "Installing desktop launcher and icon..."
        local icon_dir="$HOME/.local/share/icons/hicolor/256x256/apps"
        local app_dir="$HOME/.local/share/applications"
        mkdir -p "$icon_dir" "$app_dir"

        # Copy coin icon from source tree
        local icon_src=""
        for search in "$SCRIPT_DIR/src/qt/res/icons/bitcoin.png" \
                      "$SCRIPT_DIR/src/qt/res/icons/${COIN_NAME}.png"; do
            [[ -f "$search" ]] && icon_src="$search" && break
        done
        if [[ -n "$icon_src" ]]; then
            if command -v convert &>/dev/null; then
                convert "$icon_src" -resize 256x256 -background none -gravity center -extent 256x256 "$icon_dir/${QT_NAME}.png"
            else
                cp "$icon_src" "$icon_dir/${QT_NAME}.png"
            fi
        fi

        # Create .desktop file
        local qt_path
        qt_path="$(readlink -f "$output_dir/qt/$QT_NAME")"
        cat > "$app_dir/${QT_NAME}.desktop" << DESK_EOF
[Desktop Entry]
Type=Application
Name=$COIN_NAME_UPPER Qt
Comment=$COIN_NAME_UPPER Cryptocurrency Wallet
Exec=$qt_path
Icon=${QT_NAME}
Terminal=false
Categories=Finance;Network;
StartupWMClass=${QT_NAME}
DESK_EOF
        chmod +x "$app_dir/${QT_NAME}.desktop"
        if [[ ! -f "$HOME/.local/share/icons/hicolor/index.theme" ]]; then
            cat > "$HOME/.local/share/icons/hicolor/index.theme" << 'THEME_EOF'
[Icon Theme]
Name=Hicolor
Comment=Fallback Icon Theme
Directories=256x256/apps

[256x256/apps]
Size=256
Context=Applications
Type=Fixed
THEME_EOF
        fi
        gtk-update-icon-cache -f "$HOME/.local/share/icons/hicolor/" 2>/dev/null || true
        update-desktop-database "$app_dir" 2>/dev/null || true
        success "Desktop launcher installed — search '$COIN_NAME_UPPER' in Activities"
    fi

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL — Native Linux"
    echo "  OS:     $os_version"
    echo "  Output: $output_dir/"
    echo "============================================"
}

build_native_macos() {
    local target="$1"
    local jobs="$2"
    local os_version="$3"
    local output_dir="$OUTPUT_BASE/macos"

    # Check for Homebrew
    if ! command -v brew &>/dev/null; then
        error "Homebrew not found. Install from https://brew.sh"
        exit 1
    fi

    local brew_prefix
    brew_prefix=$(brew --prefix)

    # Check dependencies (openssl@3 is the current Homebrew formula)
    local missing=()
    for pkg in openssl@3 boost@1.85 miniupnpc berkeley-db@4 qt@5; do
        brew list "$pkg" &>/dev/null || missing+=("$pkg")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing Homebrew packages: ${missing[*]}"
        echo "Install with: brew install ${missing[*]}"
        exit 1
    fi

    local openssl_prefix boost_prefix bdb_prefix qt5_prefix miniupnpc_prefix
    openssl_prefix=$(brew --prefix openssl@3)
    boost_prefix=$(brew --prefix boost@1.85)
    bdb_prefix=$(brew --prefix berkeley-db@4)
    qt5_prefix=$(brew --prefix qt@5)
    miniupnpc_prefix=$(brew --prefix miniupnpc)

    mkdir -p "$output_dir/daemon" "$output_dir/qt"

    # Apply macOS-specific source patches
    info "Applying macOS source patches..."

    # Filesystem namespace disambiguation
    # Why: macOS clang exposes std::filesystem which conflicts with boost::filesystem
    local fs_files="$SCRIPT_DIR/src/bitcoinrpc.cpp $SCRIPT_DIR/src/util.cpp $SCRIPT_DIR/src/walletdb.cpp $SCRIPT_DIR/src/init.cpp $SCRIPT_DIR/src/wallet.cpp $SCRIPT_DIR/src/db.cpp $SCRIPT_DIR/src/net.cpp $SCRIPT_DIR/src/main.cpp"
    for f in $fs_files; do
        if [[ -f "$f" ]]; then
            # Replace all filesystem:: with boost::filesystem::, then fix any double-qualification
            # (no \b — not supported by macOS BSD sed)
            sedi 's/filesystem::/boost::filesystem::/g' "$f"
            sedi 's/boost::boost::filesystem::/boost::filesystem::/g' "$f"
        fi
    done

    # miniupnpc 2.2+ API change: UPNP_GetValidIGD now requires wanaddr params
    # Why: Homebrew miniupnpc 2.2+ changed the function signature to include WAN address output
    if [[ -f "$SCRIPT_DIR/src/net.cpp" ]]; then
        if grep -q 'UPNP_GetValidIGD(devlist, &urls, &data, lanaddr, sizeof(lanaddr));' "$SCRIPT_DIR/src/net.cpp"; then
            perl -i -pe 's/r = UPNP_GetValidIGD\(devlist, &urls, &data, lanaddr, sizeof\(lanaddr\)\);/char wanaddr[64] = ""; r = UPNP_GetValidIGD(devlist, \&urls, \&data, lanaddr, sizeof(lanaddr), wanaddr, sizeof(wanaddr));/' "$SCRIPT_DIR/src/net.cpp"
        fi
    fi

    # Boost 1.80+ removed get_io_service() from sockets/acceptors/streams
    # Why: Deprecated in Boost 1.70, removed in 1.80; use get_executor() instead
    if [[ -f "$SCRIPT_DIR/src/bitcoinrpc.cpp" ]]; then
        # resolver construction: stream.get_io_service() → stream.get_executor()
        sedi 's/resolver(stream\.get_io_service())/resolver(stream.get_executor())/g' "$SCRIPT_DIR/src/bitcoinrpc.cpp"
        # AcceptedConnectionImpl: acceptor->get_io_service() → io_context from executor
        perl -i -pe 's/acceptor->get_io_service\(\)/static_cast<boost::asio::io_context\&>(acceptor->get_executor().context())/' "$SCRIPT_DIR/src/bitcoinrpc.cpp"
    fi

    # Boost 1.74+ renamed copy_option to copy_options, overwrite_if_exists to overwrite_existing
    # Why: Old Boost filesystem v2 API removed; v3 uses copy_options enum class
    for src_file in $(grep -rl "copy_option::overwrite_if_exists" "$SCRIPT_DIR/src/" 2>/dev/null); do
        sedi 's/copy_option::overwrite_if_exists/copy_options::overwrite_existing/g' "$src_file"
    done

    # Patch makefile.unix for macOS compatibility
    info "Patching makefile.unix for macOS..."
    if [[ -f "$SCRIPT_DIR/src/makefile.unix" ]]; then
        # Use perl for reliable makefile patching (line-by-line)
        perl -i -pe '
            # Compile .c files with CC instead of CXX
            # Why: blake.c uses C void* implicit conversion which clang++ rejects
            s/\$\(CXX\) -c \$\(xCXXFLAGS\) -fpermissive/\$(CC) -c -O2 -pthread -fPIC \$(DEFS) \$(CXXFLAGS)/;
            # Remove lines with -Wl,-B flags (macOS ld64 does not support them)
            if (/^\s*-Wl,-B\$\(LMODE2?\)/) { $_ = ""; next }
            # Remove -l dl line (macOS has dlopen in libSystem)
            if (/^\s*-l dl/) { $_ = ""; next }
            # Remove -Wl,-z,relro -Wl,-z,now (Linux-only hardening)
            s/-Wl,-z,relro -Wl,-z,now//;
        ' "$SCRIPT_DIR/src/makefile.unix"
    fi

    if [[ "$target" == "daemon" || "$target" == "both" ]]; then
        info "Building daemon..."
        cd "$SCRIPT_DIR/src"

        rm -f leveldb/build_config.mk

        # Write macOS LevelDB config
        cat > leveldb/build_config.mk <<LEVELDB_EOF
SOURCES=db/builder.cc db/c.cc db/db_impl.cc db/db_iter.cc db/dbformat.cc db/dumpfile.cc db/filename.cc db/log_reader.cc db/log_writer.cc db/memtable.cc db/repair.cc db/table_cache.cc db/version_edit.cc db/version_set.cc db/write_batch.cc table/block.cc table/block_builder.cc table/filter_block.cc table/format.cc table/iterator.cc table/merger.cc table/table.cc table/table_builder.cc table/two_level_iterator.cc util/arena.cc util/bloom.cc util/cache.cc util/coding.cc util/comparator.cc util/crc32c.cc util/env.cc util/env_posix.cc util/filter_policy.cc util/hash.cc util/histogram.cc util/logging.cc util/options.cc util/status.cc port/port_posix.cc
MEMENV_SOURCES=helpers/memenv/memenv.cc
CC=clang
CXX=clang++
PLATFORM=OS_MACOSX
PLATFORM_LDFLAGS=
PLATFORM_LIBS=
PLATFORM_CCFLAGS= -DOS_MACOSX -DLEVELDB_PLATFORM_POSIX
PLATFORM_CXXFLAGS= -DOS_MACOSX -DLEVELDB_PLATFORM_POSIX
LEVELDB_EOF

        # Detect if boost_thread needs -mt suffix (Homebrew boost@1.85 has thread-mt only)
        local boost_suffix=""
        if [[ ! -f "$boost_prefix/lib/libboost_thread.dylib" && -f "$boost_prefix/lib/libboost_thread-mt.dylib" ]]; then
            boost_suffix="-mt"
        fi

        make -f makefile.unix \
            USE_UPNP=1 \
            BOOST_LIB_SUFFIX="$boost_suffix" \
            CXXFLAGS="-DBOOST_BIND_GLOBAL_PLACEHOLDERS -I$boost_prefix/include -I$openssl_prefix/include -I$bdb_prefix/include -I$miniupnpc_prefix/include" \
            LDFLAGS="-L$boost_prefix/lib -L$openssl_prefix/lib -L$bdb_prefix/lib -L$miniupnpc_prefix/lib" \
            -j"$jobs"

        strip "$DAEMON_NAME" 2>/dev/null || true
        cp "$DAEMON_NAME" "$output_dir/daemon/"

        success "Daemon: $output_dir/daemon/$DAEMON_NAME"
        ls -lh "$output_dir/daemon/$DAEMON_NAME"
        cd "$SCRIPT_DIR"
    fi

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        info "Building Qt wallet..."
        cd "$SCRIPT_DIR"

        local pro_file
        pro_file=$(find . -maxdepth 1 -name "*.pro" ! -iname "*-OSX*" | head -1)

        # Apply patches with Homebrew prefix
        apply_pro_patches "$pro_file"

        # Remove ancient macOS 10.5/i386 deployment target (uses SDK that doesn't exist)
        # Why: .pro targets macOS 10.5 32-bit with /Developer/SDKs/ path; modern macOS uses current SDK
        sedi '/mmacosx-version-min=10\.5/d' "$pro_file"
        # Remove 32-bit arch flag (i386 is dead on macOS 10.15+)
        sedi '/arch i386/d' "$pro_file"

        # Set Homebrew-specific dependency paths (individual prefixes since keg-only pkgs differ)
        sedi "s|BOOST_INCLUDE_PATH=.*|BOOST_INCLUDE_PATH=$boost_prefix/include|" "$pro_file"
        sedi "s|BOOST_LIB_PATH=.*|BOOST_LIB_PATH=$boost_prefix/lib|" "$pro_file"
        sedi "s|BDB_INCLUDE_PATH=.*|BDB_INCLUDE_PATH=$bdb_prefix/include|" "$pro_file"
        sedi "s|BDB_LIB_PATH=.*|BDB_LIB_PATH=$bdb_prefix/lib|" "$pro_file"
        sedi "s|OPENSSL_INCLUDE_PATH=.*|OPENSSL_INCLUDE_PATH=$openssl_prefix/include|" "$pro_file"
        sedi "s|OPENSSL_LIB_PATH=.*|OPENSSL_LIB_PATH=$openssl_prefix/lib|" "$pro_file"
        sedi "s|MINIUPNPC_INCLUDE_PATH=.*|MINIUPNPC_INCLUDE_PATH=$miniupnpc_prefix/include|" "$pro_file"
        sedi "s|MINIUPNPC_LIB_PATH=.*|MINIUPNPC_LIB_PATH=$miniupnpc_prefix/lib|" "$pro_file"

        rm -f src/leveldb/build_config.mk

        # Write macOS LevelDB config (same as daemon build)
        cat > src/leveldb/build_config.mk <<LEVELDB_QT_EOF
SOURCES=db/builder.cc db/c.cc db/db_impl.cc db/db_iter.cc db/dbformat.cc db/dumpfile.cc db/filename.cc db/log_reader.cc db/log_writer.cc db/memtable.cc db/repair.cc db/table_cache.cc db/version_edit.cc db/version_set.cc db/write_batch.cc table/block.cc table/block_builder.cc table/filter_block.cc table/format.cc table/iterator.cc table/merger.cc table/table.cc table/table_builder.cc table/two_level_iterator.cc util/arena.cc util/bloom.cc util/cache.cc util/coding.cc util/comparator.cc util/crc32c.cc util/env.cc util/env_posix.cc util/filter_policy.cc util/hash.cc util/histogram.cc util/logging.cc util/options.cc util/status.cc port/port_posix.cc
MEMENV_SOURCES=helpers/memenv/memenv.cc
CC=clang
CXX=clang++
PLATFORM=OS_MACOSX
PLATFORM_LDFLAGS=
PLATFORM_LIBS=
PLATFORM_CCFLAGS= -DOS_MACOSX -DLEVELDB_PLATFORM_POSIX
PLATFORM_CXXFLAGS= -DOS_MACOSX -DLEVELDB_PLATFORM_POSIX
LEVELDB_QT_EOF

        # Regenerate bitcoin.icns from bitcoin.png to ensure correct coin branding
        # Why: The repo may contain stale Bitcoin icns from upstream; must match bitcoin.png
        # Uses macOS native sips + iconutil (same approach as lib/macos.sh convert-icon.sh)
        local icons_dir="$SCRIPT_DIR/src/qt/res/icons"
        if [[ -f "$icons_dir/bitcoin.png" ]]; then
            info "Regenerating macOS icon from bitcoin.png..."
            rm -f "$icons_dir/bitcoin.icns"
            local iconset_dir
            iconset_dir=$(mktemp -d)/coin.iconset
            mkdir -p "$iconset_dir"
            for size in 16 32 128 256 512; do
                sips -z $size $size "$icons_dir/bitcoin.png" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null 2>&1
                local size2=$((size * 2))
                sips -z $size2 $size2 "$icons_dir/bitcoin.png" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null 2>&1
            done
            iconutil -c icns "$iconset_dir" -o "$icons_dir/bitcoin.icns" 2>/dev/null || true
            if [[ -f "$icons_dir/bitcoin.icns" ]]; then
                success "Icon generated: $(ls -lh "$icons_dir/bitcoin.icns" | awk '{print $5}')"
            else
                warn "iconutil failed; using existing bitcoin.icns from repo"
            fi
            rm -rf "$(dirname "$iconset_dir")"
        fi

        # Detect if boost libs need -mt suffix (Homebrew boost@1.85 has thread-mt only)
        local boost_suffix=""
        if [[ ! -f "$boost_prefix/lib/libboost_thread.dylib" && -f "$boost_prefix/lib/libboost_thread-mt.dylib" ]]; then
            boost_suffix="-mt"
        fi

        "$qt5_prefix/bin/qmake" "$pro_file" \
            "USE_QRCODE=0" \
            "USE_UPNP=1" \
            "RELEASE=1" \
            "BOOST_LIB_SUFFIX=$boost_suffix" \
            "BOOST_THREAD_LIB_SUFFIX=$boost_suffix"

        make -j"$jobs"

        local qt_bin
        qt_bin=$(find . -name "${COIN_NAME_UPPER}-Qt.app" -type d 2>/dev/null | head -1)
        if [[ -n "$qt_bin" ]]; then
            # Fix Info.plist: update executable name, identifiers, and version
            # Why: The .pro file generates Info.plist with Bitcoin-Qt defaults;
            # macOS looks for the CFBundleExecutable binary name and fails if wrong
            local app_plist="$qt_bin/Contents/Info.plist"
            if [[ -f "$app_plist" ]]; then
                sedi "s|<string>Bitcoin-Qt</string>|<string>${COIN_NAME_UPPER}-Qt</string>|g" "$app_plist"
                sedi "s|org.bitcoinfoundation.Bitcoin-Qt|org.${COIN_NAME}.${COIN_NAME_UPPER}-Qt|g" "$app_plist"
                sedi "s|org.bitcoinfoundation.BitcoinPayment|org.${COIN_NAME}.${COIN_NAME_UPPER}Payment|g" "$app_plist"
                sedi "s|<string>bitcoin</string>|<string>${COIN_NAME}</string>|g" "$app_plist"
                sedi 's|\$VERSION|0.8.6|g' "$app_plist"
                sedi 's|\$YEAR|2024|g' "$app_plist"
                sedi "s|The Bitcoin developers|The ${COIN_NAME_UPPER} developers|g" "$app_plist"
            fi

            # Strip the binary
            strip "$qt_bin/Contents/MacOS/${COIN_NAME_UPPER}-Qt" 2>/dev/null || true

            # Ad-hoc code sign (required by macOS Catalina+)
            # Why: Unsigned .app bundles get "damaged or incomplete" error from Gatekeeper
            codesign --force --deep --sign - "$qt_bin" 2>/dev/null || true

            cp -r "$qt_bin" "$output_dir/qt/"
            success "Qt wallet: $output_dir/qt/"
        else
            qt_bin=$(find release/ -type f -executable 2>/dev/null | head -1 || true)
            [[ -z "$qt_bin" ]] && qt_bin=$(find . -maxdepth 1 -name "*qt*" -type f -executable 2>/dev/null | head -1 || true)
            strip "$qt_bin" 2>/dev/null || true
            cp "$qt_bin" "$output_dir/qt/$QT_NAME"
            success "Qt wallet: $output_dir/qt/$QT_NAME"
        fi
    fi

    write_build_info "$output_dir" "native-macos" "$target" "$os_version"

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL — Native macOS"
    echo "  OS:     $os_version"
    echo "  Output: $output_dir/"
    echo "============================================"
}

build_native_windows() {
    local target="$1"
    local jobs="$2"
    local os_version="${3:-Windows}"
    local output_dir="$OUTPUT_BASE/native"

    echo ""
    echo "============================================"
    echo "  Native Windows Build: $COIN_NAME_UPPER"
    echo "============================================"
    echo "  Target: $target"
    echo ""

    # Must be running inside MSYS2 MinGW64
    if [[ -z "${MSYSTEM:-}" ]] || [[ "$MSYSTEM" != "MINGW64" ]]; then
        error "Native Windows builds must run from the MSYS2 MinGW64 shell."
        echo ""
        echo "  Open 'MSYS2 MinGW64' from the Start menu and re-run this script."
        echo ""
        exit 1
    fi

    # Check key dependencies
    local missing=()
    command -v gcc &>/dev/null || missing+=("mingw-w64-x86_64-gcc")
    command -v qmake &>/dev/null || missing+=("mingw-w64-x86_64-qt5-base")
    command -v make &>/dev/null || missing+=("make")
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing packages: ${missing[*]}"
        echo ""
        echo "  Install with:"
        echo "    pacman -S --needed ${missing[*]}"
        echo ""
        exit 1
    fi

    mkdir -p "$output_dir/qt" "$output_dir/daemon"

    # Helper: in-place edit using perl (sed -i fails on NTFS due to file locking)
    edit() { perl -i -pe "$1" "$2"; }

    local MINGW_PREFIX="/mingw64"

    if [[ "$target" == "qt" || "$target" == "both" ]]; then
        info "Building Qt wallet..."

        # Clean previous build
        make clean 2>/dev/null || true
        make distclean 2>/dev/null || true
        rm -f Makefile "${QT_NAME}.exe" release/*.exe 2>/dev/null || true
        mkdir -p build release

        # Fix line endings on key files
        perl -i -pe 's/\r$//' *.pro src/util.h src/compat.h src/bitcoinrpc.cpp 2>/dev/null || true

        local PRO_FILE
        PRO_FILE=$(ls -1 *.pro 2>/dev/null | head -1)
        if [[ -z "$PRO_FILE" ]]; then
            error "No .pro file found"
            exit 1
        fi
        info "Patching $PRO_FILE..."

        # Fix qmake assignment syntax
        edit 's/USE_UPNP:=1/USE_UPNP=1/' "$PRO_FILE"

        # Fix lrelease path
        edit 's|\\\\lrelease\.exe|/lrelease|' "$PRO_FILE"

        # Set boost lib suffix to -mt (MSYS2 MinGW64 uses -mt suffix)
        edit 's/^BOOST_LIB_SUFFIX=.*/BOOST_LIB_SUFFIX=-mt/' "$PRO_FILE"

        # Comment out isEmpty(BOOST_LIB_SUFFIX) auto-detection block
        perl -i -0pe 's/(isEmpty\(BOOST_LIB_SUFFIX\).*?\n\})/# $1/s' "$PRO_FILE" 2>/dev/null || true

        # Remove hardcoded boost lib references
        edit '/-lboost_system-mgw/d' "$PRO_FILE"

        # Add BOOST_BIND_GLOBAL_PLACEHOLDERS
        grep -q 'BOOST_BIND_GLOBAL_PLACEHOLDERS' "$PRO_FILE" || \
            edit 's/^(DEFINES.*)/$1 BOOST_BIND_GLOBAL_PLACEHOLDERS/' "$PRO_FILE"

        # Point dependency paths to MinGW sysroot
        edit "s|BOOST_INCLUDE_PATH=.*|BOOST_INCLUDE_PATH=$MINGW_PREFIX/include|" "$PRO_FILE"
        edit "s|BOOST_LIB_PATH=.*|BOOST_LIB_PATH=$MINGW_PREFIX/lib|" "$PRO_FILE"
        edit "s|BDB_INCLUDE_PATH=.*|BDB_INCLUDE_PATH=$MINGW_PREFIX/include|" "$PRO_FILE"
        edit "s|BDB_LIB_PATH=.*|BDB_LIB_PATH=$MINGW_PREFIX/lib|" "$PRO_FILE"
        edit "s|OPENSSL_INCLUDE_PATH=.*|OPENSSL_INCLUDE_PATH=$MINGW_PREFIX/include|" "$PRO_FILE"
        edit "s|OPENSSL_LIB_PATH=.*|OPENSSL_LIB_PATH=$MINGW_PREFIX/lib|" "$PRO_FILE"
        edit "s|MINIUPNPC_INCLUDE_PATH=.*|MINIUPNPC_INCLUDE_PATH=$MINGW_PREFIX/include|" "$PRO_FILE"
        edit "s|MINIUPNPC_LIB_PATH=.*|MINIUPNPC_LIB_PATH=$MINGW_PREFIX/lib|" "$PRO_FILE"

        # Add -lcrypt32 for OpenSSL 3.x Windows Certificate Store support
        grep -q 'lcrypt32' "$PRO_FILE" || echo 'win32:LIBS += -lcrypt32' >> "$PRO_FILE"

        # Fix pid_t redefinition — mingw-w64 already provides pid_t
        info "Fixing pid_t and SOCKET conflicts..."
        edit 's/typedef int pid_t;/\/\/ pid_t provided by mingw-w64/' src/util.h

        # Fix SOCKET typedef — wrap in #ifndef so it only applies on non-Windows
        perl -i -pe 's/^typedef u_int SOCKET;/#ifndef WIN32\ntypedef u_int SOCKET;\n#endif/' src/compat.h

        # Fix Boost 1.80+ get_io_service() removal
        info "Fixing Boost get_io_service()..."
        if [[ -f src/bitcoinrpc.cpp ]]; then
            edit 's/resolver\(stream\.get_io_service\(\)\)/resolver(stream.get_executor())/' src/bitcoinrpc.cpp
            perl -i -pe 's/acceptor->get_io_service\(\)/static_cast<boost::asio::io_context\&>(acceptor->get_executor().context())/' src/bitcoinrpc.cpp
        fi

        # Write Windows LevelDB config for MinGW
        info "Writing LevelDB build_config.mk"
        cat > src/leveldb/build_config.mk << 'LEVELDB_EOF'
SOURCES=db/builder.cc db/c.cc db/db_impl.cc db/db_iter.cc db/dbformat.cc db/filename.cc db/log_reader.cc db/log_writer.cc db/memtable.cc db/repair.cc db/table_cache.cc db/version_edit.cc db/version_set.cc db/write_batch.cc table/block.cc table/block_builder.cc table/filter_block.cc table/format.cc table/iterator.cc table/merger.cc table/table.cc table/table_builder.cc table/two_level_iterator.cc util/arena.cc util/bloom.cc util/cache.cc util/coding.cc util/comparator.cc util/crc32c.cc util/env.cc util/env_win.cc util/filter_policy.cc util/hash.cc util/histogram.cc util/options.cc util/status.cc port/port_win.cc
MEMENV_SOURCES=helpers/memenv/memenv.cc
CC=gcc
CXX=g++
PLATFORM=OS_WINDOWS
PLATFORM_LDFLAGS=-lshlwapi
PLATFORM_LIBS=
PLATFORM_CCFLAGS= -fno-builtin-memcmp -D_REENTRANT -DOS_WIN -DLEVELDB_PLATFORM_WINDOWS -DWINVER=0x0500 -D__USE_MINGW_ANSI_STDIO=1 -DLEVELDB_IS_BIG_ENDIAN=0
PLATFORM_CXXFLAGS= -fno-builtin-memcmp -D_REENTRANT -DOS_WIN -DLEVELDB_PLATFORM_WINDOWS -DWINVER=0x0500 -D__USE_MINGW_ANSI_STDIO=1 -DLEVELDB_IS_BIG_ENDIAN=0
LEVELDB_EOF

        # Build with shared Qt5 (MSYS2 qt5-static has UCRT/MSVCRT mismatch)
        # For a single-file static exe, use Docker cross-compile: ./build.sh --windows --qt --pull-docker
        info "Running qmake..."
        qmake "$PRO_FILE" "USE_UPNP=1" "USE_QRCODE=0" "RELEASE=1"

        info "Building (jobs: $jobs)..."
        make -j"$jobs"

        # Find and strip the exe
        local QT_BIN
        QT_BIN=$(find release/ -name "*.exe" 2>/dev/null | head -1)
        [[ -z "$QT_BIN" ]] && QT_BIN=$(find . -maxdepth 1 -name "*.exe" 2>/dev/null | head -1)
        if [[ -z "$QT_BIN" ]]; then
            error "No .exe found after build"
            exit 1
        fi
        strip "$QT_BIN" 2>/dev/null || true

        # Bundle exe + all MinGW DLL deps into output folder
        mkdir -p "$output_dir/qt/platforms"
        cp "$QT_BIN" "$output_dir/qt/${QT_NAME}.exe"

        info "Bundling DLL dependencies..."
        ldd "$QT_BIN" | grep mingw64 | awk '{print $3}' | while read dll; do
            cp "$dll" "$output_dir/qt/" && echo "  Bundled $(basename "$dll")"
        done

        # Qt platform plugin (required for Windows rendering)
        cp /mingw64/share/qt5/plugins/platforms/qwindows.dll "$output_dir/qt/platforms/"

        success "Qt wallet: $output_dir/qt/${QT_NAME}.exe"
        ls -lh "$output_dir/qt/${QT_NAME}.exe"
    fi

    if [[ "$target" == "daemon" || "$target" == "both" ]]; then
        warn "Windows native daemon build not yet implemented"
    fi

    os_version="MINGW64 / Windows ($(uname -r 2>/dev/null || echo Windows))"
    write_build_info "$output_dir" "native" "$target" "$os_version"

    echo ""
    echo "============================================"
    echo "  BUILD SUCCESSFUL — Native Windows"
    echo "  Output: $output_dir/"
    echo "============================================"
}

# =============================================================================
# MAIN — Parse arguments and dispatch
# =============================================================================

main() {
    local platform=""
    local target="both"
    local docker_mode="none"  # none, pull, build
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
    echo "  $COIN_NAME_UPPER Build System"
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
    generate_config "$platform"
}

main "$@"
