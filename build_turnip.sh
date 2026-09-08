#!/bin/bash
set -e
set -o pipefail

# ============================================================
# ZT740 Turnip Builder v2
# Target: Snapdragon 8 Gen 2 / Adreno 740
# Emulator: Eden
# Android: AArch64
# Mesa: main
# NDK: r28
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORKDIR="$SCRIPT_DIR/turnip_workdir"
NDK_DIR="$WORKDIR/android-ndk-r28"
MESA_DIR="$WORKDIR/mesa"
BUILD_DIR="$WORKDIR/mesa-build"
PACKAGE_DIR="$WORKDIR/package"

NDK_VERSION="android-ndk-r28"
NDK_ZIP="$WORKDIR/android-ndk-r28-linux.zip"

TARGET_SDK="35"
TARGET_API="35"

MESA_REPO="https://gitlab.freedesktop.org/mesa/mesa.git"
MESA_BRANCH="main"

# ------------------------------------------------------------
# Output
# ------------------------------------------------------------

OUTPUT_DIR="$SCRIPT_DIR/releases"

mkdir -p "$OUTPUT_DIR"

OUTPUT_ZIP="$OUTPUT_DIR/ZT740-PERF-v2.zip"

# ------------------------------------------------------------
# Patches
# ------------------------------------------------------------

PATCH_DIR="$SCRIPT_DIR/patches"

PATCHES=(
    "0004-depth-extensions.patch"
    "0005-a740-aurora-performance.patch"
    "0006-emulator-compat-driconf.patch"
    "0007-a740-ubwc-hint.patch"
)

# ------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------

check_deps() {

    echo
    echo "============================================================"
    echo "Checking build dependencies"
    echo "============================================================"

    local deps=(
        ninja
        meson
        patchelf
        unzip
        curl
        flex
        bison
        zip
        git
        perl
        python3
        glslangValidator
        llvm-ar
        clang
        ccache
    )

    for dep in "${deps[@]}"; do

        if ! command -v "$dep" >/dev/null 2>&1; then
            echo
            echo "ERROR: Missing dependency: $dep"
            echo
            echo "Install the missing package and run again."
            exit 1
        fi

    done

    echo
    echo "All dependencies found."
}

# ------------------------------------------------------------
# Check patches
# ------------------------------------------------------------

check_patches() {

    echo
    echo "============================================================"
    echo "Checking ZT740 patches"
    echo "============================================================"

    for patch_name in "${PATCHES[@]}"; do

        patch="$PATCH_DIR/$patch_name"

        if [ ! -f "$patch" ]; then
            echo
            echo "ERROR: Missing patch:"
            echo "$patch"
            exit 1
        fi

        echo "Found: $patch_name"

    done

    echo
    echo "All patches found."
}

# ------------------------------------------------------------
# Prepare NDK
# ------------------------------------------------------------

prepare_ndk() {

    echo
    echo "============================================================"
    echo "Preparing Android NDK"
    echo "============================================================"

    mkdir -p "$WORKDIR"

    if [ -d "$NDK_DIR" ]; then
        echo "NDK already exists:"
        echo "$NDK_DIR"
        return
    fi

    if [ ! -f "$NDK_ZIP" ]; then

        echo "Downloading Android NDK r28..."

        curl -L \
            -o "$NDK_ZIP" \
            "https://dl.google.com/android/repository/android-ndk-r28-linux.zip"

    fi

    echo "Extracting NDK..."

    unzip -q "$NDK_ZIP" -d "$WORKDIR"

    if [ ! -d "$NDK_DIR" ]; then
        echo
        echo "ERROR: NDK extraction failed."
        exit 1
    fi

    echo "NDK ready."
}

# ------------------------------------------------------------
# Clone Mesa
# ------------------------------------------------------------

prepare_mesa() {

    echo
    echo "============================================================"
    echo "Preparing Mesa"
    echo "============================================================"

    rm -rf "$MESA_DIR"
    rm -rf "$BUILD_DIR"

    echo "Cloning Mesa main..."

    git clone \
        --depth 1 \
        --branch "$MESA_BRANCH" \
        "$MESA_REPO" \
        "$MESA_DIR"

    cd "$MESA_DIR"

    MESA_COMMIT="$(git rev-parse HEAD)"

    echo
    echo "Mesa commit:"
    echo "$MESA_COMMIT"

    echo
    echo "Mesa version:"
    git describe --always --dirty 2>/dev/null || true
}

# ------------------------------------------------------------
# Prepare SPIR-V dependencies
# ------------------------------------------------------------

prepare_spirv() {

    echo
    echo "============================================================"
    echo "Preparing SPIR-V dependencies"
    echo "============================================================"

    cd "$MESA_DIR"

    if [ ! -d "subprojects/SPIRV-Tools" ]; then

        echo "Cloning SPIRV-Tools..."

        git clone \
            --depth 1 \
            https://github.com/KhronosGroup/SPIRV-Tools.git \
            subprojects/SPIRV-Tools

    fi

    if [ ! -d "subprojects/spirv-headers" ]; then

        echo "Cloning SPIR-V-Headers..."

        git clone \
            --depth 1 \
            https://github.com/KhronosGroup/SPIRV-Headers.git \
            subprojects/spirv-headers

    fi
}

# ------------------------------------------------------------
# Apply patches
# ------------------------------------------------------------

apply_patches() {

    echo
    echo "============================================================"
    echo "Checking and applying ZT740 patches"
    echo "============================================================"

    cd "$MESA_DIR"

    for patch_name in "${PATCHES[@]}"; do

        patch="$PATCH_DIR/$patch_name"

        echo
        echo "------------------------------------------------------------"
        echo "Checking $patch_name"
        echo "------------------------------------------------------------"

        if ! git apply --check "$patch"; then

            echo
            echo "============================================================"
            echo "ERROR: Patch check failed"
            echo "============================================================"
            echo
            echo "Patch:"
            echo "$patch_name"
            echo
            echo "Mesa commit:"
            echo "$MESA_COMMIT"
            echo
            echo "The patch was NOT applied."
            echo
            echo "Do NOT bypass this with --reject or --3way."
            echo "Review the patch against this Mesa revision."
            echo

            exit 1
        fi

        echo "Check OK."

        echo
        echo "Applying $patch_name..."

        git apply "$patch"

        echo "Applied successfully."

    done

    echo
    echo "============================================================"
    echo "All ZT740 patches applied successfully."
    echo "============================================================"

    echo
    echo "Applied patches:"

    for patch_name in "${PATCHES[@]}"; do
        echo "  - $patch_name"
    done
}

# ------------------------------------------------------------
# Android cross file
# ------------------------------------------------------------

create_cross_file() {

    echo
    echo "============================================================"
    echo "Creating Android cross file"
    echo "============================================================"

    local ndk_bin="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local ndk_sys="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

    if [ ! -d "$ndk_bin" ]; then
        echo
        echo "ERROR: NDK LLVM toolchain not found:"
        echo "$ndk_bin"
        exit 1
    fi

    cat > "$MESA_DIR/android-cross.txt" <<EOF
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['ccache', '$ndk_bin/aarch64-linux-android${TARGET_API}-clang', '--sysroot=$ndk_sys']
cpp = ['ccache', '$ndk_bin/aarch64-linux-android${TARGET_API}-clang++', '--sysroot=$ndk_sys']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk_bin/aarch64-linux-android-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'

[built-in options]
c_link_args = ['-static-libstdc++']
cpp_link_args = ['-static-libstdc++']
EOF

    echo "Cross file created:"
    echo "$MESA_DIR/android-cross.txt"
}

# ------------------------------------------------------------
# Build Mesa
# ------------------------------------------------------------

compile_mesa() {

    echo
    echo "============================================================"
    echo "Configuring Mesa"
    echo "============================================================"

    cd "$MESA_DIR"

    local ndk_bin="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin"

    export PATH="$ndk_bin:$PATH"

    export CCACHE_DIR="$WORKDIR/ccache"

    export CFLAGS="-O3 -D__ANDROID__ -Wno-error -Wno-deprecated-declarations"
    export CXXFLAGS="-O3 -D__ANDROID__ -Wno-error -Wno-deprecated-declarations"

    mkdir -p "$CCACHE_DIR"

    meson setup "$BUILD_DIR" \
        --cross-file android-cross.txt \
        -Dbuildtype=release \
        -Doptimization=3 \
        -Dplatforms=android \
        -Dplatform-sdk-version="$TARGET_SDK" \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dglx=disabled \
        -Dvulkan-beta=true \
        -Ddefault_library=shared \
        -Dzstd=disabled \
        -Dwerror=false \
        --force-fallback-for=spirv-tools,spirv-headers

    echo
    echo "============================================================"
    echo "Building Mesa"
    echo "============================================================"

    ninja \
        -C "$BUILD_DIR" \
        -j"$(nproc)"

    echo
    echo "Mesa build completed."
}

# ------------------------------------------------------------
# Find Vulkan library
# ------------------------------------------------------------

find_vulkan_library() {

    echo
    echo "============================================================"
    echo "Locating Turnip Vulkan library"
    echo "============================================================"

    local candidates=(
        "$BUILD_DIR/src/freedreno/vulkan/libvulkan_freedreno.so"
        "$BUILD_DIR/src/freedreno/vulkan/libvulkan_freedreno.so.1"
        "$BUILD_DIR/src/freedreno/vulkan/libvulkan_freedreno.so.1.0.0"
    )

    VULKAN_LIB=""

    for candidate in "${candidates[@]}"; do

        if [ -f "$candidate" ]; then
            VULKAN_LIB="$candidate"
            break
        fi

    done

    if [ -z "$VULKAN_LIB" ]; then

        VULKAN_LIB="$(find "$BUILD_DIR" \
            -type f \
            \( \
                -name "libvulkan_freedreno.so" \
                -o -name "libvulkan_freedreno.so.*" \
            \) \
            | head -n 1)"

    fi

    if [ -z "$VULKAN_LIB" ] || [ ! -f "$VULKAN_LIB" ]; then

        echo
        echo "ERROR: Could not find Turnip Vulkan library."
        echo
        echo "Searching build tree:"
        find "$BUILD_DIR" -type f -name "*.so" | head -50
        exit 1

    fi

    echo
    echo "Found:"
    echo "$VULKAN_LIB"
}

# ------------------------------------------------------------
# Package
# ------------------------------------------------------------

package_driver() {

    echo
    echo "============================================================"
    echo "Packaging ZT740 PERF v2"
    echo "============================================================"

    rm -rf "$PACKAGE_DIR"
    mkdir -p "$PACKAGE_DIR"

    local output_lib="$PACKAGE_DIR/vulkan.ad07XX.so"

    cp "$VULKAN_LIB" "$output_lib"

    echo
    echo "Setting SONAME..."

    patchelf \
        --set-soname "vulkan.adreno.so" \
        "$output_lib"

    local driver_version

    driver_version="$(
        cd "$MESA_DIR"
        git describe --always --dirty 2>/dev/null || echo "$MESA_COMMIT"
    )"

    cat > "$PACKAGE_DIR/meta.json" <<EOF
{
    "schemaVersion": 1,
    "name": "ZT740 PERF v2",
    "description": "Custom Mesa Turnip driver for Snapdragon 8 Gen 2 / Adreno 740 with A740 performance, depth, UBWC and Eden Zelda compatibility patches.",
    "author": "blackorange-sketch",
    "packageVersion": "2",
    "vendor": "Mesa",
    "driverVersion": "$driver_version",
    "minApi": 28,
    "libraryName": "vulkan.ad07XX.so"
}
EOF

    echo
    echo "Package contents:"
    ls -lh "$PACKAGE_DIR"

    rm -f "$OUTPUT_ZIP"

    cd "$PACKAGE_DIR"

    zip -9 \
        "$OUTPUT_ZIP" \
        vulkan.ad07XX.so \
        meta.json

    echo
    echo "============================================================"
    echo "Package created"
    echo "============================================================"

    ls -lh "$OUTPUT_ZIP"
}

# ------------------------------------------------------------
# Build information
# ------------------------------------------------------------

write_build_info() {

    local info_file="$PACKAGE_DIR/build-info.txt"

    cat > "$info_file" <<EOF
ZT740 PERF v2
==============

Target:
Snapdragon 8 Gen 2 / Adreno 740

Mesa:
$MESA_COMMIT

NDK:
$NDK_VERSION

Android API:
$TARGET_API

Optimization:
-O3

Mesa optimization:
-Doptimization=3

Vulkan:
freedreno / Turnip

KMD:
KGSL

Patches:
0004-depth-extensions.patch
0005-a740-aurora-performance.patch
0006-emulator-compat-driconf.patch
0007-a740-ubwc-hint.patch

LTO:
disabled

Global SYSMEM forcing:
disabled

Turnip autotuner:
enabled
EOF

    cd "$PACKAGE_DIR"

    zip -9 \
        "$OUTPUT_ZIP" \
        build-info.txt
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

main() {

    echo
    echo "============================================================"
    echo "        ZT740 PERF v2 TURNIP BUILDER"
    echo "============================================================"
    echo
    echo "Target : Snapdragon 8 Gen 2 / Adreno 740"
    echo "Eden   : Vulkan / Turnip"
    echo "Mesa   : main"
    echo "NDK    : r28"
    echo "SDK    : $TARGET_SDK"
    echo

    check_deps
    check_patches
    prepare_ndk
    prepare_mesa
    prepare_spirv
    apply_patches
    create_cross_file
    compile_mesa
    find_vulkan_library
    package_driver
    write_build_info

    echo
    echo "============================================================"
    echo "             BUILD SUCCESSFUL"
    echo "============================================================"
    echo
    echo "Output:"
    echo "$OUTPUT_ZIP"
    echo
}

main "$@"
