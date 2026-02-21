<p align="center">
  <img src="src/qt/res/icons/bitcoin.png" alt="Blakecoin" width="128">
</p>
## About Blakecoin

Blakecoin is the original Blake-256 coin and parent chain for [Photon](https://github.com/BlueDragon747/photon), [BlakeBitcoin](https://github.com/BlakeBitcoin/BlakeBitcoin), [Electron](https://github.com/BlueDragon747/Electron-ELT), [Universal Molecule](https://github.com/BlueDragon747/universalmol), and [Lithium](https://github.com/BlueDragon747/lithium). It is a digital currency using peer-to-peer technology with no central authority.

- Uses the **Blake-256** hashing algorithm — a SHA-3 candidate faster than Scrypt, SHA-256D, Keccak, and Groestl
- Forked from **Bitcoin 0.8.6**
- Optimized 8-round Blake-256 with reduced double-hashing for efficiency
- Maintains proven ECDSA security
- Website: https://blakecoin.org

| Network Info | |
|---|---|
| Algorithm | Blake-256 (8 rounds) |
| Block time | 2 minutes |
| Block reward | 25 BLC |
| Difficulty retarget | Every 20 blocks |
| Default port | 8333 |
| RPC port | 8332 |
| Max supply | 7,000,000,000 BLC |

---

## Quick Start (Ubuntu 18.04)

```bash
git clone https://github.com/SidGrip/Blakecoin.git
cd Blakecoin
sudo apt install build-essential libssl-dev libboost-all-dev \
  libdb4.8-dev libdb4.8++-dev libminiupnpc-dev \
  qt5-qmake qtbase5-dev qttools5-dev-tools
./build.sh --native --both
```

- Builds both the daemon (`blakecoind`) and Qt wallet (`blakecoin-qt`) natively on Ubuntu 18.04
- Binaries go to `outputs/native/`
- On Linux, Qt builds automatically install a `.desktop` launcher and icon so the wallet appears in Activities search
- For other Ubuntu versions, use Docker or AppImage
- See below for macOS, Windows, and other build options

## Build Options

```
./build.sh [PLATFORM] [TARGET] [OPTIONS]

Platforms:
  --native          Build on this machine (Linux/Ubuntu 18.04, macOS, or Windows)
  --appimage        Portable Linux AppImage (requires Docker)
  --windows         Cross-compile for Windows from Linux (requires Docker)
  --macos           Cross-compile for macOS from Linux (requires Docker)

Targets:
  --daemon          Daemon only (blakecoind)
  --qt              Qt wallet only (blakecoin-qt)
  --both            Both (default)

Docker options (for --appimage, --windows, --macos, or --native on Linux):
  --pull-docker     Pull prebuilt Docker images from Docker Hub
  --build-docker    Build Docker images locally from repo Dockerfiles

Other options:
  --jobs N          Parallel make jobs (default: CPU cores - 1)
```

## Platform Build Instructions

### Linux (Docker)

Use `--pull-docker` to pull prebuilt images from Docker Hub, or `--build-docker` to build them locally from the Dockerfiles in `docker/`.

```bash
./build.sh --native --both --pull-docker      # Daemon + Qt (pull from Hub)
./build.sh --native --qt --pull-docker        # Qt wallet only
./build.sh --native --daemon --pull-docker    # Daemon only
./build.sh --native --both --build-docker     # Build Docker image locally first
./build.sh --appimage --pull-docker           # Portable AppImage
./build.sh --appimage --build-docker          # AppImage (build image locally)
```


### Windows

There are two ways to build for Windows:

**Native (MSYS2/MinGW64)** — builds on Windows directly. Produces a ~10MB exe with DLLs bundled alongside it in the output folder.

Install [MSYS2](https://www.msys2.org), then from the MINGW64 shell:

```bash
pacman -S mingw-w64-x86_64-gcc mingw-w64-x86_64-boost \
  mingw-w64-x86_64-openssl mingw-w64-x86_64-qt5-base \
  mingw-w64-x86_64-qt5-tools mingw-w64-x86_64-miniupnpc \
  mingw-w64-x86_64-db
```

Then build:

```bash
./build.sh --native --both          # Daemon + Qt wallet
./build.sh --native --qt            # Qt wallet only
./build.sh --native --daemon        # Daemon only
```

**Docker cross-compile (from Linux)** — builds a single ~30MB static exe with no DLL dependencies.

```bash
./build.sh --windows --both --pull-docker     # Daemon + Qt (pull from Hub)
./build.sh --windows --qt --pull-docker       # Qt wallet only
./build.sh --windows --daemon --pull-docker   # Daemon only
./build.sh --windows --both --build-docker     # Build MXE image locally first
./build.sh --windows --qt --build-docker      # Qt only (build image locally)
./build.sh --windows --daemon --build-docker  # Daemon only (build image locally)
```

Uses `sidgrip/mxe-base:latest` Docker image with MXE cross-compiler. Everything (Qt, Boost, OpenSSL, etc.) is statically linked into one self-contained exe.

> **Why the difference?**
>
> - MXE compiles all dependencies from source with the same toolchain, so everything links statically into one binary
> - MSYS2's static Qt5 package uses a different C runtime (UCRT) than the MinGW64 toolchain (MSVCRT), making fully static linking impossible
> - The native build auto-bundles all required DLLs in the output folder instead

### macOS

There are two ways to build for macOS:

**Native (Homebrew)** — builds directly on a Mac.

Install dependencies:

```bash
brew install openssl boost@1.85 miniupnpc berkeley-db@4 qt@5
```

Then build:

```bash
./build.sh --native --both          # Daemon + Qt wallet
./build.sh --native --qt            # Qt wallet only
./build.sh --native --daemon        # Daemon only
```

**Docker cross-compile (from Linux)** — builds a macOS binary from a Linux host.

```bash
./build.sh --macos --both --pull-docker     # Daemon + Qt (pull from Hub)
./build.sh --macos --qt --pull-docker       # Qt wallet only
./build.sh --macos --daemon --pull-docker   # Daemon only
./build.sh --macos --both --build-docker    # Build osxcross image locally first
./build.sh --macos --qt --build-docker     # Qt only (build image locally)
./build.sh --macos --daemon --build-docker # Daemon only (build image locally)
```

Uses `sidgrip/osxcross-base:latest` Docker image with osxcross cross-compiler.

---

## Output Structure

```
outputs/
├── native/
│   ├── daemon/         blakecoind
│   └── qt/             blakecoin-qt
├── linux-appimage/
│   └── qt/             Blakecoin-x86_64.AppImage
├── windows/
│   ├── daemon/
│   └── qt/             blakecoin-qt.exe
└── macos/
    ├── daemon/         blakecoind
    └── qt/             Blakecoin-Qt.app
```

Each output directory includes a `build-info.txt` with OS version and build details.

## Docker Images

Use `--pull-docker` to pull prebuilt images from Docker Hub, or `--build-docker` to build locally from the Dockerfiles in `docker/`.

| Image | Platform | Hub Size | Local Build Time |
|-------|----------|----------|-----------------|
| `sidgrip/daemon-base:18.04` | Linux native builds (daemon + Qt) | ~450 MB | ~10 min |
| `sidgrip/appimage-base:22.04` | Linux AppImage | ~515 MB | ~15 min |
| `sidgrip/mxe-base:latest` | Windows cross-compile | ~4.2 GB | ~2-4 hours |
| `sidgrip/osxcross-base:latest` | macOS cross-compile | ~7.2 GB | ~1-2 hours |

Local builds are cached by Docker — subsequent builds are instant.

> **macOS `--build-docker` note:**
>
> - The macOS cross-compile Dockerfile requires an Apple SDK tarball that **cannot be redistributed**
> - Place `MacOSX26.2.sdk.tar.xz` in `docker/sdk/` before running `--build-docker`
> - Extract it from [Xcode](https://developer.apple.com/download/all/): `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/`
> - Using `--pull-docker` does **not** require the SDK — it is already included in the prebuilt Docker Hub image

---

## Multi-Coin Builder

For building wallets for all Blake-family coins [Blakecoin](https://github.com/BlueDragon747/Blakecoin), [Photon](https://github.com/BlueDragon747/photon), [BlakeBitcoin](https://github.com/BlakeBitcoin/BlakeBitcoin), [Electron](https://github.com/BlueDragon747/Electron-ELT), [Universal Molecule](https://github.com/BlueDragon747/universalmol), [Lithium](https://github.com/BlueDragon747/lithium), see the [Blakestream Installer](https://github.com/SidGrip/Blakestream-Installer).

## License

Blakecoin is released under the terms of the MIT license. See `COPYING` for more information.
