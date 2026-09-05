#!/bin/bash -e
set -o pipefail

###############################################################################
# ZT740 Turnip PERF v1
# Snapdragon 8 Gen 2 / Adreno 740
#
# Based on The412Banner A6xx/A7xx build method
# Safe compiler optimization experiment:
#   -O3
#   Meson optimization level 3
#
# No device-specific Mesa patches.
###############################################################################

deps="ninja patchelf unzip curl pip flex bison zip git perl glslangValidator python3"

workdir="$(pwd)/turnip_workdir"

ndkver="android-ndk-r28"
target_sdk="35"


check_deps() {
    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "Missing dependency: $dep"
            exit 1
        fi
    done

    pip install meson mako --break-system-packages &> /dev/null || true
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

    echo "ANDROID_NDK_HOME=$ANDROID_NDK_HOME"
}


compile_mesa() {

    local repo_url="https://gitlab.freedesktop.org/mesa/mesa.git"
    local branch="main"

    local build_name="ZT740 PERF v1 - Adreno 740"
    local output_tag="ZT740-PERF-v1"

    echo "========================================"
    echo "ZT740 TURNIP PERF v1"
    echo "Snapdragon 8 Gen 2 / Adreno 740"
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
        cver="34"
    fi


    cat <<EOF > android-cross.txt

[binaries]

ar = '$ndk_bin/llvm-ar'

c = [
    'ccache',
    '$ndk_bin/aarch64-linux-android${cver}-clang',
    '--sysroot=$ndk_sys'
]

cpp = [
    'ccache',
    '$ndk_bin/aarch64-linux-android${cver}-clang++',
    '--sysroot=$ndk_sys'
]

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
    echo "Applying compiler flags..."

    export CFLAGS="-O3 -D__ANDROID__ -Wno-error -Wno-deprecated-declarations"

    export CXXFLAGS="-O3 -D__ANDROID__ -Wno-error -Wno-deprecated-declarations"


    echo
    echo "Configuring Mesa..."


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
        echo "Turnip library not found:"
        echo "$lib"
        echo "========================================"

        exit 1

    fi


    echo
    echo "Turnip library found:"
    echo "$lib"

    ls -lh "$lib"


    local pkg_dir="$workdir/pkg_$output_tag"


    rm -rf "$pkg_dir"

    mkdir -p "$pkg_dir"


    echo
    echo "Creating Eden driver package..."


    cp "$lib" \
        "$pkg_dir/vulkan.ad07XX.so"


    cd "$pkg_dir"


    echo
    echo "Setting SONAME..."


    patchelf \
        --set-soname "vulkan.adreno.so" \
        vulkan.ad07XX.so


    echo
    echo "Creating meta.json..."


    cat > meta.json <<EOF
{
  "schemaVersion": 1,
  "name": "$build_name",
  "description": "Mesa Main Turnip PERF v1 for Snapdragon 8 Gen 2 / Adreno 740",
  "author": "blackorange-sketch",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "$output_tag",
  "minApi": 28,
  "libraryName": "vulkan.ad07XX.so"
}
EOF


    echo
    echo "Creating ZIP package..."


    cd "$pkg_dir"


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

prepare_ndk

compile_mesa
