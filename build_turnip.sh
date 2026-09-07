#!/bin/bash -e
set -o pipefail

###############################################################################
# ZT740 Turnip AURORA COMPAT v1
# Snapdragon 8 Gen 2 / Adreno 740
#
# Based on The412Banner A6xx/A7xx build method
#
# Mesa Main +:
#   0004-depth-extensions.patch
#   0005-a740-aurora-performance.patch
#
# Target:
#   Eden / Android / Adreno 740
###############################################################################

deps="ninja patchelf unzip curl pip flex bison zip git perl glslangValidator python3"

workdir="$(pwd)/turnip_workdir"

ndkver="android-ndk-r28"
target_sdk="35"

script_dir="$(cd "$(dirname "$0")" && pwd)"
patch_dir="$script_dir/patches"


check_deps() {
    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "Missing dependency: $dep"
            exit 1
        fi
    done

    pip install meson mako --break-system-packages &> /dev/null || true
}


check_patches() {

    echo
    echo "========================================"
    echo "Checking required patches..."
    echo "========================================"

    local required_patches=(
        "0004-depth-extensions.patch"
        "0005-a740-aurora-performance.patch"
        "0006-emulator-compat-driconf.patch"
    )

    for patch in "${required_patches[@]}"; do

        if [ ! -f "$patch_dir/$patch" ]; then

            echo
            echo "ERROR: Required patch not found:"
            echo "$patch_dir/$patch"

            exit 1
        fi

        echo "Found: $patch"

    done
}


prepare_ndk() {

    mkdir -p "$workdir"

    cd "$workdir"


    if [ ! -d "$ndkver" ]; then

        echo "Downloading Android NDK r28..."

        curl -L \
            "https://dl.google.com/android/repository/${ndkver}-linux.zip" \
            --output "${ndkver}-linux.zip"


        echo "Extracting Android NDK..."

        unzip -q "${ndkver}-linux.zip"

    fi


    export ANDROID_NDK_HOME="$workdir/$ndkver"


    echo
    echo "ANDROID_NDK_HOME=$ANDROID_NDK_HOME"
}


apply_patch() {

    local patch="$1"

    echo
    echo "========================================"
    echo "Checking patch:"
    echo "$(basename "$patch")"
    echo "========================================"


    if ! git apply --check "$patch"; then

        echo
        echo "========================================"
        echo "PATCH COMPATIBILITY ERROR"
        echo "========================================"

        echo
        echo "Patch cannot be applied cleanly:"
        echo "$patch"

        echo
        echo "Mesa Main has probably changed."

        exit 1

    fi


    echo "Patch check OK."


    echo "Applying patch..."


    git apply \
        --verbose \
        "$patch"


    echo
    echo "Patch applied successfully."
}


compile_mesa() {

    local repo_url="https://gitlab.freedesktop.org/mesa/mesa.git"
    local branch="main"

    local build_name="ZT740 AURORA COMPAT v1 - Adreno 740"
    local output_tag="ZT740-AURORA-COMPAT-v1"


    echo
    echo "========================================"
    echo "ZT740 TURNIP AURORA COMPAT v1"
    echo "========================================"

    echo "GPU: Adreno 740"
    echo "SoC: Snapdragon 8 Gen 2"
    echo "Mesa: Main"
    echo "NDK: r28"
    echo "SDK: $target_sdk"

    echo
    echo "Enabled patches:"
    echo "  0004-depth-extensions.patch"
    echo "  0005-a740-aurora-performance.patch"

    echo "========================================"


    echo
    echo "Cloning Mesa Main..."


    cd "$workdir"


    rm -rf mesa


    git clone \
        --depth 100 \
        -b "$branch" \
        "$repo_url" \
        mesa


    cd mesa


    echo
    echo "Mesa commit:"


    git rev-parse HEAD


    echo
    echo "Mesa commit short:"


    git rev-parse --short HEAD


    echo
    echo "========================================"
    echo "Applying ZT740 patches"
    echo "========================================"


    apply_patch "$patch_dir/0004-depth-extensions.patch"

    apply_patch "$patch_dir/0005-a740-aurora-performance.patch"
    apply_patch "$patch_dir/0006-emulator-compat-driconf.patch"


    echo
    echo "========================================"
    echo "Applied patches:"
    echo "========================================"


    git diff --stat


    echo
    echo "Preparing SPIR-V subprojects..."


    mkdir -p subprojects


    cd subprojects


    rm -rf spirv-tools
    rm -rf spirv-headers


    git clone \
        --depth=1 \
        https://github.com/KhronosGroup/SPIRV-Tools.git \
        spirv-tools


    git clone \
        --depth=1 \
        https://github.com/KhronosGroup/SPIRV-Headers.git \
        spirv-headers


    cd ..


    local build_dir="$workdir/mesa/build"


    rm -rf "$build_dir"


    echo
    echo "Preparing Android cross file..."


    local ndk_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"

    local ndk_sys="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"


    local cver="35"


    if [ ! -f "$ndk_bin/aarch64-linux-android${cver}-clang" ]; then

        echo "API 35 compiler not found."

        cver="34"

    fi


    echo "Using Android API compiler: $cver"


    cat <<EOF > android-cross.txt
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['ccache', '$ndk_bin/aarch64-linux-android${cver}-clang', '--sysroot=$ndk_sys']
cpp = ['ccache', '$ndk_bin/aarch64-linux-android${cver}-clang++', '--sysroot=$ndk_sys']
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
    echo "Android cross file:"


    cat android-cross.txt


    echo
    echo "Applying compiler flags..."


    export CFLAGS="-O3 -D__ANDROID__ -Wno-error -Wno-deprecated-declarations"

    export CXXFLAGS="-O3 -D__ANDROID__ -Wno-error -Wno-deprecated-declarations"


    echo
    echo "========================================"
    echo "Configuring Mesa..."
    echo "========================================"


    meson setup "$build_dir" \
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


    echo
    echo "========================================"
    echo "Building Turnip..."
    echo "========================================"


    ninja -C "$build_dir"


    local lib="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"


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
    echo "Turnip library found"
    echo "========================================"


    echo "$lib"


    ls -lh "$lib"


    echo
    echo "Checking library..."


    file "$lib"


    echo
    echo "ELF architecture:"


    readelf -h "$lib" | \
        grep -E "Class|Machine|OS/ABI"


    local pkg_dir="$workdir/pkg_$output_tag"


    rm -rf "$pkg_dir"


    mkdir -p "$pkg_dir"


    echo
    echo "========================================"
    echo "Creating Eden driver package..."
    echo "========================================"


    cp "$lib" \
        "$pkg_dir/vulkan.ad07XX.so"


    cd "$pkg_dir"


    echo
    echo "Setting SONAME..."


    patchelf \
        --set-soname "vulkan.adreno.so" \
        vulkan.ad07XX.so


    echo
    echo "SONAME:"


    readelf -d vulkan.ad07XX.so | \
        grep SONAME || true


    echo
    echo "Creating meta.json..."


    cat > meta.json <<EOF
{
  "schemaVersion": 1,
  "name": "$build_name",
  "description": "Mesa Main Turnip with Aurora A740 performance and depth compatibility extensions",
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


    echo
    echo "Creating ZIP package..."


    zip -9 \
        "$workdir/Turnip-${output_tag}.zip" \
        vulkan.ad07XX.so \
        meta.json


    echo
    echo "========================================"
    echo "BUILD COMPLETE"
    echo "========================================"


    echo
    echo "Driver:"


    echo "$workdir/Turnip-${output_tag}.zip"


    echo


    ls -lh \
        "$workdir/Turnip-${output_tag}.zip"


    echo
}


check_deps

check_patches

prepare_ndk

compile_mesa
