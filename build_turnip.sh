#!/bin/bash -e
set -o pipefail

###############################################################################
# ZT740 Turnip PERF v2
# Snapdragon 8 Gen 2 / Adreno 740
#
# Based on working The412Banner-style build.
# Experiment:
#   + Meson LTO
#
# No GPU-specific patches.
###############################################################################

deps="ninja patchelf unzip curl pip flex bison zip git perl glslangValidator python3"

workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r28"
target_sdk="35"


check_deps() {
    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "Missing: $dep"
            exit 1
        fi
    done

    pip install meson mako --break-system-packages &> /dev/null || true
}


prepare_ndk() {
    mkdir -p "$workdir"
    cd "$workdir"

    if [ ! -d "$ndkver" ]; then
        echo "Downloading Android NDK..."

        curl -L \
            "https://dl.google.com/android/repository/${ndkver}-linux.zip" \
            --output "${ndkver}-linux.zip"

        echo "Extracting Android NDK..."
        unzip -q "${ndkver}-linux.zip"
    fi

    export ANDROID_NDK_HOME="$workdir/$ndkver"
}


compile_mesa() {

    local repo_url="https://gitlab.freedesktop.org/mesa/mesa.git"
    local branch="main"

    local build_name="ZT740 PERF v2 LTO - Adreno 740"
    local output_tag="ZT740-PERF-v2-LTO"


    echo "========================================"
    echo "ZT740 TURNIP PERF v2"
    echo "Snapdragon 8 Gen 2 / Adreno 740"
    echo "LTO ENABLED"
    echo "========================================"


    cd "$workdir"

    echo "Cloning Mesa Main..."

    rm -rf mesa

    git clone \
        --depth 100 \
        -b "$branch" \
        "$repo_url" \
        mesa

    cd mesa


    echo "Preparing SPIR-V subprojects..."

    mkdir -p subprojects
    cd subprojects

    rm -rf spirv-tools spirv-headers

    git clone --depth=1 \
        https://github.com/KhronosGroup/SPIRV-Tools.git \
        spirv-tools

    git clone --depth=1 \
        https://github.com/KhronosGroup/SPIRV-Headers.git \
        spirv-headers

    cd ..


    local build_dir="$workdir/mesa/build"

    rm -rf "$build_dir"


    local ndk_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local ndk_sys="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"


    local cver="35"

    if [ ! -f "$ndk_bin/aarch64-linux-android${cver}-clang" ]; then
        cver="34"
    fi


    echo "Creating Android cross file..."


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


    # Same basic flags as the working BASE build.
    export CFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations"
    export CXXFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations"


    echo "Configuring Mesa with LTO..."


    meson setup "$build_dir" \
        --cross-file android-cross.txt \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version="$target_sdk" \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dfreedreno-kmds=kgsl \
        -Dvulkan-beta=true \
        -Db_lto=true \
        -Degl=disabled \
        -Dglx=disabled \
        -Ddefault_library=shared \
        -Dzstd=disabled \
        -Dwerror=false \
        --force-fallback-for=spirv-tools,spirv-headers


    echo "========================================"
    echo "Building Turnip with LTO..."
    echo "========================================"


    ninja -C "$build_dir"


    local lib="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"


    if [ ! -f "$lib" ]; then
        echo "BUILD FAILED"
        echo "Turnip library not found:"
        echo "$lib"
        exit 1
    fi


    echo "Driver found:"
    ls -lh "$lib"


    local pkg_dir="$workdir/pkg_$output_tag"

    rm -rf "$pkg_dir"
    mkdir -p "$pkg_dir"


    cp "$lib" "$pkg_dir/vulkan.ad07XX.so"

    cd "$pkg_dir"


    echo "Setting SONAME..."

    patchelf \
        --set-soname "vulkan.adreno.so" \
        vulkan.ad07XX.so


    echo "Creating meta.json..."


    cat > meta.json <<EOF
{
  "schemaVersion": 1,
  "name": "$build_name",
  "description": "Mesa Main Turnip with LTO for Snapdragon 8 Gen 2 / Adreno 740",
  "author": "blackorange-sketch",
  "packageVersion": "2",
  "vendor": "Mesa",
  "driverVersion": "$output_tag",
  "minApi": 28,
  "libraryName": "vulkan.ad07XX.so"
}
EOF


    echo "Creating driver package..."


    zip -9 \
        "$workdir/Turnip-${output_tag}.zip" \
        vulkan.ad07XX.so \
        meta.json


    echo
    echo "========================================"
    echo "BUILD COMPLETE"
    echo "========================================"

    echo "Output:"
    echo "$workdir/Turnip-${output_tag}.zip"

    ls -lh "$workdir/Turnip-${output_tag}.zip"
}


check_deps
prepare_ndk
compile_mesa
