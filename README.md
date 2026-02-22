<p align="center">
  <img src="src/qt/res/icons/bitcoin.png" alt="Blakecoin" width="95">
</p>

## About Blakecoin (0.15.2)

Blakecoin is the original Blake-256 coin and parent chain for [Photon](https://github.com/BlueDragon747/photon), [BlakeBitcoin](https://github.com/BlakeBitcoin/BlakeBitcoin), [Electron](https://github.com/BlueDragon747/Electron-ELT), [Universal Molecule](https://github.com/BlueDragon747/universalmol), and [Lithium](https://github.com/BlueDragon747/lithium). It is a digital currency using peer-to-peer technology with no central authority.

This is the **0.15.2 fork** — a full backport to Bitcoin Core 0.15.2 with HD wallet support, modern RPC, and autotools build system.

- Uses the **Blake-256** hashing algorithm — a SHA-3 candidate faster than Scrypt, SHA-256D, Keccak, and Groestl
- Forked from **Bitcoin Core 0.15.2** (autotools build system, HD wallets)
- Optimized 8-round Blake-256 with reduced double-hashing for efficiency
- Maintains proven ECDSA security
- Website: https://blakecoin.org

| Network Info | |
|---|---|
| Algorithm | Blake-256 (8 rounds) |
| Block time | 2 minutes |
| Block reward | 25 BLC |
| Difficulty retarget | Every 20 blocks |
| Default port | 8773 |
| RPC port | 8772 |
| Max supply | 7,000,000,000 BLC |

---

## Quick Start (Ubuntu 20.04+)

```bash
git clone https://github.com/SidGrip/Blakecoin.git -b 0.15.2
cd Blakecoin
./build.sh --native --both --no-docker
```

- Dependencies are **auto-installed** by `build.sh` (requires sudo)
- Builds the daemon (`blakecoind`, `blakecoin-cli`, `blakecoin-tx`) and Qt wallet (`blakecoin-qt`)
- Binaries go to `outputs/native/`
- Auto-generates `outputs/blakecoin.conf` with random RPC credentials and live peers
- On Linux, Qt builds automatically install a `.desktop` launcher and icon so the wallet appears in Activities search
- Works on Ubuntu 20.04 (GCC 9, Boost 1.71), 22.04 (GCC 11, Boost 1.74), and 24.04 (GCC 14, Boost 1.83)
- BDB version auto-detected — installs BDB 4.8 on Ubuntu 20.04 for portable wallets, falls back to system BDB with `--with-incompatible-bdb` on 22.04/24.04

## Build Options

```
./build.sh [PLATFORM] [TARGET] [OPTIONS]

Platforms:
  --native          Build on Linux/Ubuntu 20.04+, macOS, or Windows
  --appimage        Portable Linux AppImage (requires Docker)
  --windows         Cross-compile for Windows from Linux (requires Docker)
  --macos           Cross-compile for macOS from Linux (requires Docker)

Targets:
  --daemon          Daemon only (blakecoind + blakecoin-cli + blakecoin-tx)
  --qt              Qt wallet only (blakecoin-qt)
  --both            Both (default)

Docker options (for --appimage, --windows, --macos, or --native on Linux):
  --pull-docker     Pull prebuilt Docker images from Docker Hub
  --build-docker    Build Docker images locally from repo Dockerfiles
  --no-docker       For --native on Linux: skip Docker, build directly on host

Other options:
  --jobs N          Parallel make jobs (default: CPU cores - 1)
```

## Platform Build Instructions

### Linux (Native)

Build directly on the host — dependencies are auto-installed via apt:

```bash
./build.sh --native --both --no-docker       # Daemon + Qt (auto-installs deps)
./build.sh --native --qt --no-docker         # Qt wallet only
./build.sh --native --daemon --no-docker     # Daemon only
```

### Linux (Docker)

Use `--pull-docker` to pull prebuilt images from Docker Hub, or `--build-docker` to build them locally from the Dockerfiles in `docker/`.

```bash
./build.sh --native --both --pull-docker      # Daemon + Qt (Docker, pull from Hub)
./build.sh --appimage --pull-docker           # Portable AppImage
./build.sh --appimage --build-docker          # AppImage (build image locally)
```

### Windows

There are two ways to build for Windows:

**Native (MSYS2/MinGW64)** — builds on Windows directly.

Install [MSYS2](https://www.msys2.org), then from the MINGW64 shell:

```bash
pacman -S mingw-w64-x86_64-gcc mingw-w64-x86_64-boost \
  mingw-w64-x86_64-openssl mingw-w64-x86_64-qt5-base \
  mingw-w64-x86_64-qt5-tools mingw-w64-x86_64-miniupnpc \
  mingw-w64-x86_64-db mingw-w64-x86_64-libevent \
  mingw-w64-x86_64-protobuf autoconf automake libtool
```

Then build:

```bash
./build.sh --native --both          # Daemon + Qt wallet
./build.sh --native --qt            # Qt wallet only
./build.sh --native --daemon        # Daemon only
```

**Docker cross-compile (from Linux)** — uses MXE (M Cross Environment) to cross-compile fully static Windows executables from Linux.

```bash
./build.sh --windows --both --pull-docker     # Daemon + Qt (pull from Hub)
./build.sh --windows --qt --pull-docker       # Qt wallet only
./build.sh --windows --daemon --pull-docker   # Daemon only
./build.sh --windows --both --build-docker    # Build MXE image locally first
```

### macOS

There are two ways to build for macOS:

**Native (Homebrew)** — builds directly on a Mac.

Install dependencies:

```bash
brew install openssl boost miniupnpc berkeley-db@4 qt@5 libevent protobuf pkg-config automake autoconf libtool
```

Then build:

```bash
./build.sh --native --both          # Daemon + Qt wallet
./build.sh --native --qt            # Qt wallet only
./build.sh --native --daemon        # Daemon only
```

**Docker cross-compile (from Linux)** — uses osxcross with clang to cross-compile macOS binaries from Linux.

```bash
./build.sh --macos --both --pull-docker     # Daemon + Qt (pull from Hub)
./build.sh --macos --qt --pull-docker       # Qt wallet only
./build.sh --macos --daemon --pull-docker   # Daemon only
./build.sh --macos --both --build-docker    # Build osxcross image locally first
```

---

## Output Structure

```
outputs/
├── blakecoin.conf      Auto-generated config with RPC credentials and peers
├── native/
│   ├── daemon/         blakecoind-0.15.2, blakecoin-cli-0.15.2, blakecoin-tx-0.15.2
│   └── qt/             blakecoin-qt-0.15.2
├── linux-appimage/
│   └── qt/             Blakecoin-0.15.2-x86_64.AppImage
├── windows/
│   ├── daemon/         blakecoind-0.15.2.exe, blakecoin-cli-0.15.2.exe, blakecoin-tx-0.15.2.exe
│   └── qt/             blakecoin-qt-0.15.2.exe
└── macos/
    ├── daemon/         blakecoind-0.15.2, blakecoin-cli-0.15.2, blakecoin-tx-0.15.2
    └── qt/             Blakecoin-Qt.app
```

Each output directory includes a `build-info.txt` with OS version and build details.

## Docker Images

These are shared with the 0.8.x Blake-family coins. Use `--pull-docker` to pull prebuilt images from Docker Hub, or `--build-docker` to build locally from the Dockerfiles in `docker/`.

| Image | Platform | Description |
|-------|----------|-------------|
| `sidgrip/appimage-base:22.04` | Native Linux + AppImage | Ubuntu 22.04 build environment |
| `sidgrip/mxe-base:latest` | Windows cross-compile | MXE with Qt5, Boost, OpenSSL (fully static) |
| `sidgrip/osxcross-base:latest` | macOS cross-compile | osxcross clang-18 with macOS SDK |

---

## Multi-Coin Builder

For building wallets for all Blake-family coins [Blakecoin](https://github.com/BlueDragon747/Blakecoin), [Photon](https://github.com/BlueDragon747/photon), [BlakeBitcoin](https://github.com/BlakeBitcoin/BlakeBitcoin), [Electron](https://github.com/BlueDragon747/Electron-ELT), [Universal Molecule](https://github.com/BlueDragon747/universalmol), [Lithium](https://github.com/BlueDragon747/lithium), see the [Blakestream Installer](https://github.com/SidGrip/Blakestream-Installer).

## License

Blakecoin is released under the terms of the MIT license. See `COPYING` for more information.
