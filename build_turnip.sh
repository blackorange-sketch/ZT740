#!/bin/bash -e
set -o pipefail

###############################################################################
# ZT740 Turnip PERF v2.2.1
#
# Target:
#   Snapdragon 8 Gen 2
#   Adreno 740 / FD740
#
# Mesa:
#   $MESA_REF (default: main). Set MESA_REF=<sha|tag|branch> to pin a build.
#   The exact commit is written to meta.json and turnip_workdir/mesa_commit.txt
#
# Android:
#   NDK r28
#   platform-sdk-version 35, compiler target API 29 (COMPILE_API)
#
# Build:
#   -O3
#   Meson optimization=3
#   Shader cache max size = 4G
#
# Patches:
#   see the PATCHES array below (single source of truth)
#
# Deliberately NOT in the series (kept in patches/ for reference):
#   0007-a740-ubwc-hint.patch
#   0010-force-skip-cche.patch
#
# LTO:
#   disabled
#
# ccache:
#   optional
###############################################################################

set -u


###############################################################################
# PATHS / VARIABLES
###############################################################################

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

workdir="$script_dir/turnip_workdir"

patch_dir="$script_dir/patches"

ndkver="android-ndk-r28"

# Vulkan/Android platform headers level (meson -Dplatform-sdk-version)
target_sdk="35"

# Compiler target API (clang triple level). Kept low so the .so also loads on
# Android 10-14; Amaral's CI uses 29 with platform-sdk-version 35/36.
compile_api="${COMPILE_API:-29}"

mesa_repo="https://gitlab.freedesktop.org/mesa/mesa.git"

mesa_ref="${MESA_REF:-main}"

output_tag="ZT740-PERF-v2.2.1"

# Patch series, applied in this order. Single source of truth for both
# check_patches and apply_patches.
PATCHES=(
    0004-depth-extensions.patch
    0005-a740-aurora-performance.patch
    0006-emulator-compat-driconf.patch
    0009-a740-compute-flush-opt.patch
    0009-a740-compute-flush-opt-v3.patch
)

build_name="ZT740 PERF v2.2.1 - Adreno 740"


###############################################################################
# DEPENDENCIES
###############################################################################

check_deps() {

    echo
    echo "========================================"
    echo "Checking dependencies"
    echo "========================================"
    echo

    local deps
    deps="ninja patchelf unzip curl pip flex bison zip git perl glslangValidator python3"

    local dep

    for dep in $deps; do

        if ! command -v "$dep" >/dev/null 2>&1; then

            echo
            echo "ERROR: Missing dependency: $dep"
            echo

            exit 1
        fi

        echo "OK: $dep"

    done


    if command -v ccache >/dev/null 2>&1; then

        echo
        echo "ccache: available"

        export USE_CCACHE=1

    else

        echo
        echo "ccache: not installed"

        echo "Building without ccache."

        export USE_CCACHE=0

    fi


    echo
    echo "Installing Meson/Mako..."

    pip install \
        meson \
        mako \
        --break-system-packages


    echo
    echo "Dependencies OK."

}


###############################################################################
# PATCH CHECK
###############################################################################

check_patches() {

    echo
    echo "========================================"
    echo "Checking patches"
    echo "========================================"
    echo


    local patch

    for patch in "${PATCHES[@]}"
    do

        if [ ! -f "$patch_dir/$patch" ]; then

            echo
            echo "ERROR: Patch not found:"
            echo "$patch_dir/$patch"
            echo

            exit 1
        fi

        echo "OK: $patch"

    done


    for patch in "$patch_dir"/*.patch; do

        local base
        base="$(basename "$patch")"

        case " ${PATCHES[*]} " in
            *" $base "*) ;;
            *) echo "NOTE: $base is in patches/ but NOT in the series (skipped)" ;;
        esac

    done

    echo
    echo "Patch set OK."

}


###############################################################################
# NDK
###############################################################################

prepare_ndk() {

    echo
    echo "========================================"
    echo "Preparing Android NDK"
    echo "========================================"
    echo


    mkdir -p "$workdir"

    cd "$workdir"


    if [ ! -d "$ndkver" ]; then

        echo "Downloading $ndkver..."

        curl -L \
            "https://dl.google.com/android/repository/${ndkver}-linux.zip" \
            -o "${ndkver}-linux.zip"


        echo
        echo "Extracting NDK..."

        unzip -q \
            "${ndkver}-linux.zip"

    else

        echo "NDK already exists."

    fi


    export ANDROID_NDK_HOME="$workdir/$ndkver"


    if [ ! -d "$ANDROID_NDK_HOME" ]; then

        echo
        echo "ERROR: NDK directory not found:"
        echo "$ANDROID_NDK_HOME"

        exit 1
    fi


    echo
    echo "ANDROID_NDK_HOME:"
    echo "$ANDROID_NDK_HOME"

}


###############################################################################
# MESA
###############################################################################

prepare_mesa() {

    echo
    echo "========================================"
    echo "Cloning Mesa"
    echo "========================================"
    echo


    cd "$workdir"


    rm -rf mesa


    git init -q mesa

    cd mesa

    git remote add origin "$mesa_repo"

    echo "Fetching Mesa ref: $mesa_ref"

    if ! git fetch --depth 100 origin "$mesa_ref"; then

        echo
        echo "ERROR: could not fetch Mesa ref: $mesa_ref"
        echo "(branches, tags and full commit SHAs are accepted)"

        exit 1
    fi

    git checkout -q FETCH_HEAD


    echo
    echo "Mesa commit:"

    MESA_COMMIT="$(git rev-parse HEAD)"

    echo "$MESA_COMMIT"

    git log -1 --oneline

    echo "$MESA_COMMIT" > "$workdir/mesa_commit.txt"


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

}


###############################################################################
# APPLY PATCHES
###############################################################################

apply_patches() {

    echo
    echo "========================================"
    echo "Applying Mesa patches"
    echo "========================================"
    echo


    local patch

    for patch in "${PATCHES[@]}"
    do

        echo
        echo "Checking:"
        echo "$patch"


        git apply \
            --check \
            "$patch_dir/$patch"


        echo "Applying:"
        echo "$patch"


        git apply \
            "$patch_dir/$patch"


        echo "OK."

    done


    echo
    echo "All patches applied successfully."

}


###############################################################################
# TOOLCHAIN
###############################################################################

prepare_toolchain() {

    echo
    echo "========================================"
    echo "Preparing Android toolchain"
    echo "========================================"
    echo


    export NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"

    export NDK_SYS="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"


    if [ ! -d "$NDK_BIN" ]; then

        echo
        echo "ERROR: NDK toolchain not found:"
        echo "$NDK_BIN"

        exit 1
    fi


    export CVER="$compile_api"


    if [ ! -x "$NDK_BIN/aarch64-linux-android${CVER}-clang" ]; then

        echo
        echo "Android API $CVER compiler not found."

        echo "Trying API 29..."

        export CVER="29"

    fi


    if [ ! -x "$NDK_BIN/aarch64-linux-android${CVER}-clang" ]; then

        echo
        echo "ERROR: Android clang compiler not found."

        echo
        echo "Checked:"
        echo "$NDK_BIN/aarch64-linux-android${compile_api}-clang"
        echo "$NDK_BIN/aarch64-linux-android29-clang"

        exit 1
    fi


    if [ ! -x "$NDK_BIN/llvm-ar" ]; then

        echo
        echo "ERROR: llvm-ar not found:"
        echo "$NDK_BIN/llvm-ar"

        exit 1
    fi


    if [ ! -x "$NDK_BIN/aarch64-linux-android${CVER}-clang++" ]; then

        echo
        echo "ERROR: clang++ not found."

        exit 1
    fi


    echo "NDK_BIN:"
    echo "$NDK_BIN"

    echo

    echo "NDK_SYS:"
    echo "$NDK_SYS"

    echo

    echo "Android API:"
    echo "$CVER"


    echo
    echo "========== clang =========="

    "$NDK_BIN/aarch64-linux-android${CVER}-clang" \
        --version


    echo
    echo "========== llvm-ar =========="

    "$NDK_BIN/llvm-ar" \
        --version


    echo
    echo "=============================="

}


###############################################################################
# CROSS FILE
###############################################################################

create_cross_file() {

    echo
    echo "========================================"
    echo "Creating Meson cross file"
    echo "========================================"
    echo


    cd "$workdir/mesa"


    if [ "$USE_CCACHE" = "1" ]; then

        cat > android-cross.txt <<EOF
[binaries]
ar = '$NDK_BIN/llvm-ar'
c = ['ccache', '$NDK_BIN/aarch64-linux-android${CVER}-clang']
cpp = ['ccache', '$NDK_BIN/aarch64-linux-android${CVER}-clang++']
strip = '$NDK_BIN/llvm-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'

[built-in options]
c_args = ['--sysroot=$NDK_SYS']
cpp_args = ['--sysroot=$NDK_SYS']
c_link_args = ['-static-libstdc++']
cpp_link_args = ['-static-libstdc++']
EOF

    else

        cat > android-cross.txt <<EOF
[binaries]
ar = '$NDK_BIN/llvm-ar'
c = ['$NDK_BIN/aarch64-linux-android${CVER}-clang']
cpp = ['$NDK_BIN/aarch64-linux-android${CVER}-clang++']
strip = '$NDK_BIN/llvm-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'

[built-in options]
c_args = ['--sysroot=$NDK_SYS']
cpp_args = ['--sysroot=$NDK_SYS']
c_link_args = ['-static-libstdc++']
cpp_link_args = ['-static-libstdc++']
EOF

    fi


    echo
    echo "android-cross.txt:"
    echo

    cat android-cross.txt

    echo

}


###############################################################################
# BUILD
###############################################################################

build_mesa() {

    echo
    echo "========================================"
    echo "Configuring Mesa"
    echo "========================================"
    echo


    local build_dir="$workdir/mesa/build"


    rm -rf "$build_dir"


    cd "$workdir/mesa"


    export CFLAGS="-O3 -D__ANDROID__ -Wno-error -Wno-deprecated-declarations"

    export CXXFLAGS="-O3 -D__ANDROID__ -Wno-error -Wno-deprecated-declarations"


    echo "CFLAGS:"
    echo "$CFLAGS"

    echo

    echo "CXXFLAGS:"
    echo "$CXXFLAGS"


    echo
    echo "Running Meson..."

    echo


    meson setup \
        "$build_dir" \
        --cross-file android-cross.txt \
        --buildtype=release \
        --optimization=3 \
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
        -Dshader-cache-max-size=4G \
        -Db_ndebug=true \
        -Dstrip=true \
        -Dandroid-libbacktrace=disabled \
        -Dvideo-codecs= \
        -Dzstd=disabled \
        -Dwerror=false \
        --force-fallback-for=spirv-tools,spirv-headers


    echo
    echo "========================================"
    echo "Building Turnip"
    echo "========================================"
    echo


    ninja \
        -C "$build_dir"


    echo
    echo "Ninja build completed."


}


###############################################################################
# FIND DRIVER
###############################################################################

find_driver() {

    echo
    echo "========================================"
    echo "Locating Turnip library"
    echo "========================================"
    echo


    local build_dir="$workdir/mesa/build"


    DRIVER="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"


    if [ ! -f "$DRIVER" ]; then

        echo
        echo "ERROR: Turnip library not found:"
        echo "$DRIVER"
        echo

        echo "Searching for libvulkan_freedreno.so..."

        find "$build_dir" \
            -name "libvulkan_freedreno.so" \
            -print


        exit 1
    fi


    echo
    echo "Turnip driver found:"
    echo "$DRIVER"


    ls -lh "$DRIVER"

}


###############################################################################
# PACKAGE
###############################################################################

package_driver() {

    echo
    echo "========================================"
    echo "Packaging Eden driver"
    echo "========================================"
    echo


    local pkg_dir="$workdir/pkg_$output_tag"

    local zip_file="$workdir/Turnip-${output_tag}.zip"


    rm -rf "$pkg_dir"

    rm -f "$zip_file"


    mkdir -p "$pkg_dir"


    cp \
        "$DRIVER" \
        "$pkg_dir/vulkan.ad07XX.so"


    cd "$pkg_dir"


    echo
    echo "Setting SONAME..."


    patchelf \
        --set-soname \
        "vulkan.adreno.so" \
        vulkan.ad07XX.so


    echo
    echo "Creating meta.json..."


    cat > meta.json <<EOF
{
  "schemaVersion": 1,
  "name": "$build_name",
  "description": "Mesa ${MESA_COMMIT:0:10} Turnip PERF v2.2.1 for Snapdragon 8 Gen 2 / Adreno 740",
  "author": "blackorange-sketch",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "$output_tag",
  "minApi": 29,
  "libraryName": "vulkan.ad07XX.so"
}
EOF


    echo
    echo "meta.json:"
    cat meta.json


    echo
    echo "Creating ZIP..."


    zip \
        -9 \
        "$zip_file" \
        vulkan.ad07XX.so \
        meta.json


    echo
    echo "========================================"
    echo "PACKAGE CREATED"
    echo "========================================"
    echo


    ls -lh "$zip_file"


    echo
    echo "Contents:"
    echo


    unzip -l "$zip_file"


    echo
    echo "Driver package:"
    echo "$zip_file"


}


###############################################################################
# MAIN
###############################################################################

echo
echo "########################################"
echo "#                                      #"
echo "#       ZT740 TURNIP PERF v2.2.1       #"
echo "#                                      #"
echo "########################################"
echo


check_deps

check_patches

prepare_ndk

prepare_mesa

apply_patches

prepare_toolchain

create_cross_file

build_mesa

find_driver

package_driver


echo
echo "========================================"
echo "ZT740 PERF v2.2.1 BUILD SUCCESS"
echo "========================================"
echo
