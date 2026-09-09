#!/bin/bash -e
set -o pipefail

###############################################################################
# ZT740 Turnip PERF v2.2
# Snapdragon 8 Gen 2 / Adreno 740
#
# Mesa Main + Android NDK r28
#
# Optimizations:
#   -O3
#   Meson optimization=3
#   Shader cache default = 4G
#
# Patches:
#   0004-depth-extensions.patch
#   0005-a740-aurora-performance.patch
#   0006-emulator-compat-driconf.patch
#
# No Quest 3 UBWC patch.
###############################################################################

deps="ninja patchelf unzip curl pip flex bison zip git perl glslangValidator python3"

workdir="$(pwd)/turnip_workdir"

ndkver="android-ndk-r28"
target_sdk="35"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
patch_dir="$script_dir/patches"


###############################################################################
# DEPENDENCIES
###############################################################################

check_deps() {

    echo "Checking dependencies..."

    for dep in $deps; do

        if ! command -v "$dep" >/dev/null 2>&1; then

            echo
            echo "ERROR: Missing dependency: $dep"
            echo

            exit 1

        fi

    done


    if command -v ccache >/dev/null 2>&1; then

        echo "ccache found."

        use_ccache=1

    else

        echo "ccache not found. Building without ccache."

        use_ccache=0

    fi


    echo "Installing Python build dependencies..."

    pip install \
        meson \
        mako \
        --break-system-packages \
        &> /dev/null || true


    echo "Dependencies OK."

}


###############################################################################
# PREPARE ANDROID NDK
###############################################################################

prepare_ndk() {

    mkdir -p "$workdir"

    cd "$workdir"


    if [ ! -d "$ndkver" ]; then

        echo
        echo "Downloading Android NDK r28..."

        curl -L \
            "https://dl.google.com/android/repository/${ndkver}-linux.zip" \
            --output "${ndkver}-linux.zip"


        echo
        echo "Extracting Android NDK..."

        unzip -q \
            "${ndkver}-linux.zip"

    else

        echo
        echo "Android NDK already exists."

    fi


    export ANDROID_NDK_HOME="$workdir/$ndkver"


    echo
    echo "ANDROID_NDK_HOME=$ANDROID_NDK_HOME"

}


###############################################################################
# CHECK PATCHES
###############################################################################

check_patches() {

    echo
    echo "Checking patches..."


    if [ ! -d "$patch_dir" ]; then

        echo
        echo "ERROR: patches directory not found:"
        echo "$patch_dir"
        echo

        exit 1

    fi


    local required_patches="
0004-depth-extensions.patch
0005-a740-aurora-performance.patch
0006-emulator-compat-driconf.patch
"


    for patch in $required_patches; do

        if [ ! -f "$patch_dir/$patch" ]; then

            echo
            echo "ERROR: Patch not found:"
            echo "$patch_dir/$patch"
            echo

            exit 1

        fi


        echo "Found: $patch"

    done


    echo
    echo "All patches found."

}


###############################################################################
# APPLY PATCHES
###############################################################################

apply_patches() {

    echo
    echo "========================================"
    echo "Applying Mesa patches"
    echo "========================================"


    local patches="
0004-depth-extensions.patch
0005-a740-aurora-performance.patch
0006-emulator-compat-driconf.patch
"


    for patch in $patches; do

        echo
        echo "Applying:"
        echo "$patch"


        git apply \
            --check \
            "$patch_dir/$patch"


        git apply \
            "$patch_dir/$patch"


        echo "Applied successfully."

    done

}


###############################################################################
# BUILD MESA / TURNIP
###############################################################################

compile_mesa() {


    local repo_url="https://gitlab.freedesktop.org/mesa/mesa.git"

    local branch="main"


    local build_name="ZT740 PERF v2.2 - Adreno 740"

    local output_tag="ZT740-PERF-v2.2"


    echo
    echo "========================================"
    echo "ZT740 TURNIP PERF v2.2"
    echo "========================================"
    echo
    echo "GPU:"
    echo "Adreno 740"
    echo
    echo "SoC:"
    echo "Snapdragon 8 Gen 2"
    echo
    echo "Optimization:"
    echo "O3"
    echo
    echo "Shader Cache:"
    echo "4G"
    echo
    echo "Mesa:"
    echo "main"
    echo
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


    git log \
        -1 \
        --oneline


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


    echo
    echo "Applying patches..."


    apply_patches


    local build_dir="$workdir/mesa/build"


    rm -rf "$build_dir"


    echo
    echo "Preparing Android cross file..."


    local ndk_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"


    local ndk_sys="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"


    local cver="35"


    if [ ! -f "$ndk_bin/aarch64-linux-android${cver}-clang" ]; then

        echo
        echo "API ${cver} compiler not found."

        cver="34"

    fi


    echo
    echo "Using Android API compiler:"
    echo "$cver"


    if [ "$use_ccache" = "1" ]; then


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


    else


        cat <<EOF > android-cross.txt

[binaries]

ar = '$ndk_bin/llvm-ar'

c = [
    '$ndk_bin/aarch64-linux-android${cver}-clang',
    '--sysroot=$ndk_sys'
]

cpp = [
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


    fi


    echo
    echo "Applying compiler flags..."


    export CFLAGS="-O3 -D__ANDROID__ -Wno-error -Wno-deprecated-declarations"


    export CXXFLAGS="-O3 -D__ANDROID__ -Wno-error -Wno-deprecated-declarations"


    echo
    echo "CFLAGS=$CFLAGS"

    echo
    echo "CXXFLAGS=$CXXFLAGS"


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
        -Dshader-cache-max-size=4G \
        -Dzstd=disabled \
        -Dwerror=false \
        --force-fallback-for=spirv-tools,spirv-headers


    echo
    echo "========================================"
    echo "Building Turnip"
    echo "========================================"


    ninja \
        -C "$build_dir"


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
    echo "TURNIP LIBRARY FOUND"
    echo "========================================"


    echo


    ls -lh "$lib"


    local pkg_dir="$workdir/pkg_$output_tag"


    rm -rf "$pkg_dir"


    mkdir -p "$pkg_dir"


    echo
    echo "Creating Eden driver package..."


    cp \
        "$lib" \
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
  "description": "Mesa Main Turnip PERF v2.2 for Snapdragon 8 Gen 2 / Adreno 740",
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


    zip \
        -9 \
        "$workdir/Turnip-${output_tag}.zip" \
        vulkan.ad07XX.so \
        meta.json


    echo
    echo "========================================"
    echo "BUILD COMPLETE"
    echo "========================================"


    echo
    echo "Driver package:"


    echo
    echo "$workdir/Turnip-${output_tag}.zip"


    echo


    ls -lh \
        "$workdir/Turnip-${output_tag}.zip"


    echo

}


###############################################################################
# MAIN
###############################################################################

check_deps

check_patches

prepare_ndk

compile_mesa
