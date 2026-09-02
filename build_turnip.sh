#!/bin/bash
set -euo pipefail

###############################################################################
# ZT740 Turnip Build Script
# Snapdragon 8 Gen 2 / Adreno 740
# Android / Eden
###############################################################################

WORKDIR="${WORKDIR:-$(pwd)/turnip_workdir}"

ANDROID_API="${ANDROID_API:-28}"
NDK_VERSION="${NDK_VERSION:-29.0.14206865}"

MESA_REPO="https://gitlab.freedesktop.org/mesa/mesa.git"
MESA_BRANCH="${MESA_BRANCH:-main}"

BUILD_DIR="$WORKDIR/mesa/build-android-aarch64"
INSTALL_DIR="$WORKDIR/install"
PACKAGE_DIR="$WORKDIR/release"

die() {
    echo
    echo "ERROR: $*"
    exit 1
}

log() {
    echo
    echo "================================================================"
    echo "$*"
    echo "================================================================"
}

check_deps() {
    log "Checking dependencies"

    local deps=(
        git python3 ninja meson flex bison pkg-config
        glslangValidator zip unzip curl file readelf
    )

    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if [ "${#missing[@]}" -ne 0 ]; then
        echo "Missing dependencies:"
        printf '  %s\n' "${missing[@]}"
        die "Install the missing packages before running the build."
    fi

    if command -v ccache >/dev/null 2>&1; then
        echo "ccache: available"
    else
        echo "ccache: not available; continuing without it."
    fi
}

check_python_packages() {
    log "Checking Python packages"

    if ! python3 -c "import mako" >/dev/null 2>&1; then
        python3 -m pip install --user --upgrade mako
    fi

    if ! python3 -c "import mesonbuild" >/dev/null 2>&1; then
        die "Meson Python module not found."
    fi
}

find_ndk() {
    log "Locating Android NDK"

    if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ]; then
        return
    fi

    if [ -n "${ANDROID_NDK_ROOT:-}" ] && [ -d "$ANDROID_NDK_ROOT" ]; then
        export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
        return
    fi

    if [ -n "${ANDROID_HOME:-}" ] && [ -d "$ANDROID_HOME/ndk/$NDK_VERSION" ]; then
        export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$NDK_VERSION"
        return
    fi

    if [ -n "${ANDROID_SDK_ROOT:-}" ] && [ -d "$ANDROID_SDK_ROOT/ndk/$NDK_VERSION" ]; then
        export ANDROID_NDK_HOME="$ANDROID_SDK_ROOT/ndk/$NDK_VERSION"
        return
    fi

    die "Android NDK $NDK_VERSION not found."
}

validate_ndk() {
    log "Validating Android NDK"

    local ndk_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local clang="$ndk_bin/aarch64-linux-android${ANDROID_API}-clang"

    [ -f "$clang" ] || die "Android clang not found: $clang"

    "$clang" --version | head -n 1
}

prepare_workdir() {
    log "Preparing work directory"

    mkdir -p "$WORKDIR"

    rm -rf "$WORKDIR/mesa"
    rm -rf "$BUILD_DIR"
    rm -rf "$INSTALL_DIR"
    rm -rf "$PACKAGE_DIR"

    mkdir -p "$INSTALL_DIR" "$PACKAGE_DIR"
}

clone_mesa() {
    log "Cloning Mesa"

    cd "$WORKDIR"

    if git clone --depth=1 -b "$MESA_BRANCH" "$MESA_REPO" mesa; then
        :
    else
        echo "Git clone failed; trying Mesa archive..."

        rm -rf mesa
        mkdir -p mesa

        curl -L --retry 5 --retry-delay 5             -o mesa-main.tar.gz             "https://gitlab.freedesktop.org/mesa/mesa/-/archive/main/mesa-main.tar.gz"

        tar -xzf mesa-main.tar.gz --strip-components=1 -C mesa
        rm -f mesa-main.tar.gz
    fi

    cd "$WORKDIR/mesa"

    if [ -d ".git" ]; then
        git rev-parse HEAD > "$WORKDIR/mesa_commit.txt"
    else
        echo "archive" > "$WORKDIR/mesa_commit.txt"
    fi

    cat "$WORKDIR/mesa_commit.txt"
}

create_cross_files() {
    log "Creating Meson cross files"

    local ndk_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local clang="$ndk_bin/aarch64-linux-android${ANDROID_API}-clang"
    local clangxx="$ndk_bin/aarch64-linux-android${ANDROID_API}-clang++"

    if command -v ccache >/dev/null 2>&1; then
        cat > "$WORKDIR/android-aarch64.txt" <<EOF
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['ccache', '$clang', '-O3', '-mcpu=cortex-x3', '-mtune=cortex-x3', '-march=armv8.5-a']
cpp = ['ccache', '$clangxx', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments', '-O3', '-mcpu=cortex-x3', '-mtune=cortex-x3', '-march=armv8.5-a', '-fno-exceptions', '-fno-unwind-tables']
c_ld = '$ndk_bin/ld.lld'
cpp_ld = '$ndk_bin/ld.lld'
strip = '$ndk_bin/llvm-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

        cat > "$WORKDIR/native.txt" <<'EOF'
[binaries]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'lld'
cpp_ld = 'lld'
EOF
    else
        cat > "$WORKDIR/android-aarch64.txt" <<EOF
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['$clang', '-O3', '-mcpu=cortex-x3', '-mtune=cortex-x3', '-march=armv8.5-a']
cpp = ['$clangxx', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments', '-O3', '-mcpu=cortex-x3', '-mtune=cortex-x3', '-march=armv8.5-a', '-fno-exceptions', '-fno-unwind-tables']
c_ld = '$ndk_bin/ld.lld'
cpp_ld = '$ndk_bin/ld.lld'
strip = '$ndk_bin/llvm-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

        cat > "$WORKDIR/native.txt" <<'EOF'
[binaries]
c = 'clang'
cpp = 'clang++'
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'lld'
cpp_ld = 'lld'
EOF
    fi
}

configure_mesa() {
    log "Configuring Mesa"

    cd "$WORKDIR/mesa"

    export CFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations"
    export CXXFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations"

    meson setup "$BUILD_DIR"         --cross-file "$WORKDIR/android-aarch64.txt"         --native-file "$WORKDIR/native.txt"         --prefix "$INSTALL_DIR"         -Dbuildtype=release         -Dplatforms=android         -Dplatform-sdk-version="$ANDROID_API"         -Dandroid-stub=true         -Dandroid-libbacktrace=disabled         -Dgallium-drivers=         -Dvulkan-drivers=freedreno         -Dvulkan-beta=true         -Dfreedreno-kmds=kgsl         -Degl=disabled         -Dglx=disabled         -Dstrip=true         -Dwerror=false
}

build_mesa() {
    log "Building Turnip"

    ninja -C "$BUILD_DIR"

    command -v ccache >/dev/null 2>&1 && ccache -s || true
}

locate_driver() {
    log "Locating Vulkan driver"

    DRIVER=""

    local candidates=(
        "$BUILD_DIR/src/freedreno/vulkan/libvulkan_freedreno.so"
        "$INSTALL_DIR/lib/libvulkan_freedreno.so"
        "$INSTALL_DIR/lib64/libvulkan_freedreno.so"
    )

    for candidate in "${candidates[@]}"; do
        if [ -f "$candidate" ]; then
            DRIVER="$candidate"
            break
        fi
    done

    if [ -z "$DRIVER" ]; then
        DRIVER="$(find "$BUILD_DIR" -type f -name libvulkan_freedreno.so -print -quit || true)"
    fi

    [ -n "$DRIVER" ] || die "libvulkan_freedreno.so was not found."

    printf '%s\n' "$DRIVER" > "$WORKDIR/driver_path.txt"
    echo "Driver: $DRIVER"
}

verify_driver() {
    log "Verifying Vulkan driver"

    DRIVER="$(cat "$WORKDIR/driver_path.txt")"

    file "$DRIVER"

    local needed
    needed="$(readelf -d "$DRIVER")"

    echo "$needed" | grep "NEEDED" || true

    if echo "$needed" | grep -q "libc++_shared.so"; then
        die "Driver depends on libc++_shared.so"
    fi

    local dynsym
    dynsym="$(readelf --dyn-syms -W "$DRIVER")"

    if echo "$dynsym" | grep -q "vkGetInstanceProcAddr\|vk_icdGetInstanceProcAddr"; then
        echo "Vulkan ICD symbol: OK"
    else
        echo "WARNING: Vulkan ICD symbol was not detected."
    fi
}

create_package() {
    log "Creating Eden package"

    DRIVER="$(cat "$WORKDIR/driver_path.txt")"
    local mesa_hash
    mesa_hash="$(cat "$WORKDIR/mesa_commit.txt")"

    local mesa_short
    if [ "$mesa_hash" = "archive" ]; then
        mesa_short="archive"
    else
        mesa_short="${mesa_hash:0:12}"
    fi

    local date
    date="$(date -u +%Y%m%d)"

    local output_name="ZT740-Turnip-${date}-${mesa_short}.zip"

    rm -rf "$PACKAGE_DIR"
    mkdir -p "$PACKAGE_DIR"

    cp "$DRIVER" "$PACKAGE_DIR/libvulkan_freedreno.so"

    cat > "$PACKAGE_DIR/meta.json" <<EOF
{
  "schemaVersion": 1,
  "name": "ZT740 Optimized",
  "description": "Optimized Mesa Turnip for Snapdragon 8 Gen 2 / Adreno 740 (Eden)",
  "author": "blackorange-sketch",
  "packageVersion": "1.0",
  "vendor": "Mesa",
  "driverVersion": "Mesa-${mesa_short}",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

    (
        cd "$PACKAGE_DIR"
        zip -9 "$WORKDIR/$output_name"             libvulkan_freedreno.so             meta.json
    )

    echo "Package: $WORKDIR/$output_name"
    unzip -l "$WORKDIR/$output_name"
}

summary() {
    log "BUILD SUMMARY"

    echo "Target: Snapdragon 8 Gen 2 / Adreno 740"
    echo "Android API: $ANDROID_API"
    echo "NDK: $NDK_VERSION"
    echo "Mesa: $(cat "$WORKDIR/mesa_commit.txt")"

    ls -lh "$WORKDIR"/*.zip 2>/dev/null || true

    echo
    echo "BUILD SUCCESSFUL"
}

main() {
    log "ZT740 Turnip Build"

    check_deps
    check_python_packages
    find_ndk
    validate_ndk
    prepare_workdir
    clone_mesa
    create_cross_files
    configure_mesa
    build_mesa
    locate_driver
    verify_driver
    create_package
    summary
}

main "$@"
