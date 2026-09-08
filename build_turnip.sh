#!/bin/bash -e
set -o pipefail

###############################################################################
# ZT740 Turnip PERF v2.1
#
# Target:
#   Snapdragon 8 Gen 2
#   Adreno 740 / FD740
#
# Based on:
#   Mesa Main
#   The412Banner A6xx/A7xx build approach
#
# Optimizations:
#   -O3
#   Mesa optimization level 3
#
# Patches:
#   0004 - Depth extensions
#   0005 - A740 Aurora performance
#   0006 - Emulator compatibility driconf
#   0007 - A740 UBWC hint
#
# No LTO:
#   Mesa explicitly does not support LTO builds.
###############################################################################

deps="ninja patchelf unzip curl pip flex bison zip git perl glslangValidator python3"

workdir="$(pwd)/turnip_workdir"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
patch_dir="$script_dir/patches"

ndkver="android-ndk-r28"
target_sdk="35"


###############################################################################
# Dependencies
###############################################################################

check_deps() {

    echo "========================================"
    echo "Checking dependencies"
    echo "========================================"

    for dep in $deps; do

        if ! command -v "$dep" >/dev/null 2>&1; then

            echo
            echo "ERROR: Missing dependency: $dep"
            echo
            echo "Install the missing package and run again."

            exit 1

        fi

    done


    echo "Installing Python build dependencies..."

    pip install meson mako --break-system-packages


    echo "Dependencies OK."
}


###############################################################################
# Android NDK
###############################################################################

prepare_ndk() {

    echo
    echo "========================================"
    echo "Preparing Android NDK"
    echo "========================================"

    mkdir -p "$workdir"

    cd "$workdir"


    if [ ! -d "$ndkver" ]; then

        echo "Downloading Android NDK r28..."

        curl -L \
            "https://dl.google.com/android/repository/${ndkver}-linux.zip" \
            --output "${ndkver}-linux.zip"


        echo
        echo "Extracting Android NDK..."

        unzip -q "${ndkver}-linux.zip"

    else

        echo "Android NDK already exists."

    fi


    export ANDROID_NDK_HOME="$workdir/$ndkver"


    echo
    echo "ANDROID_NDK_HOME:"
    echo "$ANDROID_NDK_HOME"

}


###############################################################################
# Mesa Build
###############################################################################

compile_mesa() {


    local repo_url="https://gitlab.freedesktop.org/mesa/mesa.git"

    local branch="main"


    local build_name="ZT740 PERF v2.1 - Adreno 740"

    local output_tag="ZT740-PERF-v2.1"


    echo
    echo "========================================"
    echo "ZT740 TURNIP PERF v2.1"
    echo "========================================"

    echo
    echo "Target:"
    echo "Snapdragon 8 Gen 2"
    echo "Adreno 740 / FD740"

    echo
    echo "Mesa branch:"
    echo "$branch"

    echo
    echo "Optimization:"
    echo "-O3"

    echo
    echo "========================================"


    cd "$workdir"


    ############################################################################
    # Clone Mesa
    ############################################################################


    echo
    echo "Cloning Mesa Main..."


    rm -rf mesa


    git clone \
        --depth 100 \
        -b "$branch" \
        "$repo_url" \
        mesa


    cd mesa

    
echo
echo "Applying Mesa patches..."

for patch in \
    "$patch_dir/0004-depth-extensions.patch" \
    "$patch_dir/0005-a740-aurora-performance.patch" \
    "$patch_dir/0006-emulator-compat-driconf.patch" \
    "$patch_dir/0007-a740-ubwc-hint.patch"
do
    if [ ! -f "$patch" ]; then
        echo "ERROR: Patch not found:"
        echo "$patch"
        exit 1
    fi

    echo "Applying $(basename "$patch")..."

    git apply --check "$patch"
    git apply "$patch"
done

echo "All patches applied successfully."

    echo
    echo "Mesa commit:"

    git log -1 --oneline


    ############################################################################
    # SPIR-V dependencies
    ############################################################################


    echo
    echo "Preparing SPIR-V subprojects..."


    mkdir -p subprojects


    cd subprojects


    rm -rf spirv-tools

    rm -rf spirv-headers


    echo
    echo "Cloning SPIRV-Tools..."


    git clone \
        --depth=1 \
        https://github.com/KhronosGroup/SPIRV-Tools.git \
        spirv-tools


    echo
    echo "Cloning SPIRV-Headers..."


    git clone \
        --depth=1 \
        https://github.com/KhronosGroup/SPIRV-Headers.git \
        spirv-headers


    cd ..


    ############################################################################
    # Apply patches
    ############################################################################


    echo
    echo "========================================"
    echo "Applying patches"
    echo "========================================"


    local patch_dir


    patch_dir="$(cd "$(dirname "$0")" && pwd)/patches"


    echo
    echo "Patch directory:"

    echo "$patch_dir"


    apply_patch() {

        local patch="$1"

        echo
        echo "Applying: $(basename "$patch")"


        if [ ! -f "$patch" ]; then

            echo
            echo "ERROR: Patch not found:"
            echo "$patch"

            exit 1

        fi


        git apply --check "$patch"


        git apply "$patch"


        echo "OK"

    }


    apply_patch \
        "$patch_dir/0004-depth-extensions.patch"


    apply_patch \
        "$patch_dir/0005-a740-aurora-performance.patch"


    apply_patch \
        "$patch_dir/0006-emulator-compat-driconf.patch"


    apply_patch \
        "$patch_dir/0007-a740-ubwc-hint.patch"


    echo
    echo "All patches applied successfully."


    ############################################################################
    # Build directory
    ############################################################################


    local build_dir="$workdir/mesa/build"


    rm -rf "$build_dir"


    ############################################################################
    # Android toolchain
    ############################################################################


    echo
    echo "========================================"
    echo "Preparing Android cross compilation"
    echo "========================================"


    local ndk_bin

    local ndk_sys


    ndk_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"


    ndk_sys="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"


    if [ ! -d "$ndk_bin" ]; then

        echo
        echo "ERROR: NDK toolchain directory not found:"
        echo "$ndk_bin"

        exit 1

    fi


    local cver="$target_sdk"


    if [ ! -f \
        "$ndk_bin/aarch64-linux-android${cver}-clang" ]; then


        echo
        echo "API ${cver} compiler not found."

        echo "Trying API 34..."


        cver="34"

    fi


    if [ ! -f \
        "$ndk_bin/aarch64-linux-android${cver}-clang" ]; then


        echo
        echo "ERROR: Android clang compiler not found."

        echo
        echo "Expected:"
        echo "$ndk_bin/aarch64-linux-android${cver}-clang"

        exit 1

    fi


    echo
    echo "NDK bin:"
    echo "$ndk_bin"

    echo
    echo "NDK sysroot:"
    echo "$ndk_sys"

    echo
    echo "Target API:"
    echo "$cver"


    ############################################################################
    # Meson cross file
    ############################################################################


    echo
    echo "Creating android-cross.txt..."


    cat > android-cross.txt <<EOF
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['$ndk_bin/aarch64-linux-android${cver}-clang', '--sysroot=$ndk_sys']
cpp = ['$ndk_bin/aarch64-linux-android${cver}-clang++', '--sysroot=$ndk_sys']
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


    echo
    echo "Cross file created."


    cat android-cross.txt


    ############################################################################
    # Compiler flags
    ############################################################################


    echo
    echo "========================================"
    echo "Applying compiler flags"
    echo "========================================"


    export CFLAGS="\
-O3 \
-D__ANDROID__ \
-Wno-error \
-Wno-deprecated-declarations"


    export CXXFLAGS="\
-O3 \
-D__ANDROID__ \
-Wno-error \
-Wno-deprecated-declarations"


    echo

    echo "CFLAGS:"

    echo "$CFLAGS"


    echo

    echo "CXXFLAGS:"

    echo "$CXXFLAGS"


    ############################################################################
    # Meson
    ############################################################################


    echo
    echo "========================================"
    echo "Configuring Mesa"
    echo "========================================"


    meson setup \
        "$build_dir" \
        --cross-file android-cross.txt \
        -Dbuildtype=release \
        -Doptimization=3 \
        -Dplatforms=android \
        -Dplatform-sdk-version="$target_sdk" \
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


    ############################################################################
    # Build
    ############################################################################


    echo
    echo "========================================"
    echo "Building Turnip"
    echo "========================================"


    ninja -C "$build_dir"


    ############################################################################
    # Check output
    ############################################################################


    local lib


    lib="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"


    if [ ! -f "$lib" ]; then


        echo
        echo "========================================"

        echo "BUILD FAILED"

        echo "========================================"

        echo

        echo "Turnip library not found:"

        echo "$lib"


        exit 1


    fi


    echo
    echo "========================================"

    echo "TURNIP BUILD SUCCESSFUL"

    echo "========================================"


    echo
    echo "Library:"


    echo "$lib"


    echo


    ls -lh "$lib"


    ############################################################################
    # Package
    ############################################################################


    local pkg_dir


    pkg_dir="$workdir/pkg_$output_tag"


    rm -rf "$pkg_dir"


    mkdir -p "$pkg_dir"


    echo
    echo "========================================"

    echo "Creating Eden driver package"

    echo "========================================"


    cp \
        "$lib" \
        "$pkg_dir/vulkan.ad07XX.so"


    cd "$pkg_dir"


    echo
    echo "Setting SONAME..."


    patchelf \
        --set-soname "vulkan.adreno.so" \
        vulkan.ad07XX.so


    echo
    echo "SONAME:"


    readelf \
        -d vulkan.ad07XX.so \
        | grep SONAME \
        || true


    ############################################################################
    # meta.json
    ############################################################################


    echo
    echo "Creating meta.json..."


    cat > meta.json <<EOF
{
  "schemaVersion": 1,
  "name": "$build_name",
  "description": "Mesa Main Turnip PERF v2.1 for Snapdragon 8 Gen 2 / Adreno 740",
  "author": "blackorange-sketch",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "$output_tag",
  "minApi": 28,
  "libraryName": "vulkan.ad07XX.so"
}
EOF


    echo
    echo "meta.json:"


    cat meta.json


    ############################################################################
    # ZIP
    ############################################################################


    echo
    echo "Creating ZIP package..."


    cd "$pkg_dir"


    zip \
        -9 \
        "$workdir/Turnip-${output_tag}.zip" \
        vulkan.ad07XX.so \
        meta.json


    ############################################################################
    # Verify package
    ############################################################################


    echo
    echo "========================================"

    echo "BUILD COMPLETE"

    echo "========================================"


    echo
    echo "Driver package:"


    echo "$workdir/Turnip-${output_tag}.zip"


    echo


    ls -lh \
        "$workdir/Turnip-${output_tag}.zip"


    echo


    echo "Package contents:"


    unzip \
        -l \
        "$workdir/Turnip-${output_tag}.zip"


    echo


    echo "========================================"

    echo "ZT740 TURNIP PERF v2.1 COMPLETE"

    echo "========================================"

}


###############################################################################
# Main
###############################################################################


check_deps


prepare_ndk


compile_mesa
