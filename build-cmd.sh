#!/usr/bin/env bash

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# bleat on references to undefined shell variables
set -u

TOP="$(cd "$(dirname "$0")"; pwd)"

PROJECT=libxml2
LICENSE=Copyright
SOURCE_DIR="$PROJECT"

if [ -z "$AUTOBUILD" ] ; then
    exit 1
fi

if [ "$OSTYPE" = "cygwin" ] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

stage="$(pwd)"
[ -f "$stage"/packages/include/zlib/zlib.h ] || \
{ echo "You haven't installed packages yet." 1>&2; exit 1; }

# load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

# Different upstream versions seem to check in different snapshots in time of
# the configure script.
for confile in configure.in configure configure.ac
do configure="${TOP}/${PROJECT}/${confile}"
    [ -r "$configure" ] && break
done
# If none of the above exist, stop for a human coder to figure out.
[ -r "$configure" ] || { echo "Can't find configure script for version info" 1>&2; exit 1; }

major_version="$(sed -n -E 's/LIBXML_MAJOR_VERSION=([0-9]+)/\1/p' "$configure")"
minor_version="$(sed -n -E 's/LIBXML_MINOR_VERSION=([0-9]+)/\1/p' "$configure")"
micro_version="$(sed -n -E 's/LIBXML_MICRO_VERSION=([0-9]+)/\1/p' "$configure")"
version="${major_version}.${minor_version}.${micro_version}"
echo "${version}" > "${stage}/VERSION.txt"

# Setup staging dirs
mkdir -p "$stage/include"
mkdir -p "$stage/lib/debug"
mkdir -p "$stage/lib/release"

pushd "$TOP/$SOURCE_DIR"
case "$AUTOBUILD_PLATFORM" in
    
    windows*)
        load_vsvars
        
        mkdir -p "build_debug"
        pushd "build_debug"
            cmake -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$AUTOBUILD_WIN_VSPLATFORM" .. \
                -DCMAKE_INSTALL_PREFIX="$(cygpath -m $stage)/debug" \
                -DBUILD_SHARED_LIBS=OFF \
                -DLIBXML2_WITH_ICONV=OFF \
                -DLIBXML2_WITH_LZMA=OFF \
                -DLIBXML2_WITH_PYTHON=OFF \
                -DLIBXML2_WITH_ZLIB=ON \
                -DZLIB_INCLUDE_DIRS="$(cygpath -m $stage)/packages/include/zlib/" \
                -DZLIB_LIBRARIES="$(cygpath -m $stage)/packages/lib/debug/zlibd.lib" \
                -DZLIB_LIBRARY_DIRS="$(cygpath -m $stage)/packages/lib"

            cmake --build . --config Debug --clean-first
            cmake --install . --config Debug

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                ctest -C Debug
            fi
        popd

        mkdir -p "build_release"
        pushd "build_release"
            cmake -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$AUTOBUILD_WIN_VSPLATFORM" .. \
                -DCMAKE_INSTALL_PREFIX="$(cygpath -m $stage)/release" \
                -DBUILD_SHARED_LIBS=OFF \
                -DLIBXML2_WITH_ICONV=OFF \
                -DLIBXML2_WITH_LZMA=OFF \
                -DLIBXML2_WITH_PYTHON=OFF \
                -DLIBXML2_WITH_ZLIB=ON \
                -DZLIB_INCLUDE_DIRS="$(cygpath -m $stage)/packages/include/zlib/" \
                -DZLIB_LIBRARIES="$(cygpath -m $stage)/packages/lib/release/zlib.lib" \
                -DZLIB_LIBRARY_DIRS="$(cygpath -m $stage)/packages/lib"

            cmake --build . --config Release --clean-first
            cmake --install . --config Release

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                ctest -C Release
            fi
        popd

        # Copy libraries
        cp -a ${stage}/debug/lib/libxml2sd.lib ${stage}/lib/debug/libxml2.lib
        cp -a ${stage}/release/lib/libxml2s.lib ${stage}/lib/release/libxml2.lib

        # copy headers
        cp -a $stage/release/include/* $stage/include/
    ;;
    
    linux*)
        # Linux build environment at Linden comes pre-polluted with stuff that can
        # seriously damage 3rd-party builds.  Environmental garbage you can expect
        # includes:
        #
        #    DISTCC_POTENTIAL_HOSTS     arch           root        CXXFLAGS
        #    DISTCC_LOCATION            top            branch      CC
        #    DISTCC_HOSTS               build_name     suffix      CXX
        #    LSDISTCC_ARGS              repo           prefix      CFLAGS
        #    cxx_version                AUTOBUILD      SIGN        CPPFLAGS
        #
        # So, clear out bits that shouldn't affect our configure-directed build
        # but which do nonetheless.
        #
        unset DISTCC_HOSTS CC CXX CFLAGS CPPFLAGS CXXFLAGS
        
        # Default target per --address-size
        opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE}"
        DEBUG_COMMON_FLAGS="$opts -Og -g -fPIC"
        RELEASE_COMMON_FLAGS="$opts -O3 -g -fPIC -fstack-protector-strong"
        DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
        RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
        DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
        RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
        DEBUG_CPPFLAGS="-DPIC"
        RELEASE_CPPFLAGS="-DPIC -D_FORTIFY_SOURCE=2"
        
        # Handle any deliberate platform targeting
        if [ -z "${TARGET_CPPFLAGS:-}" ]; then
            # Remove sysroot contamination from build environment
            unset CPPFLAGS
        else
            # Incorporate special pre-processing flags
            export CPPFLAGS="$TARGET_CPPFLAGS"
        fi
        
        mkdir -p "build_debug"
        pushd "build_debug"
            CFLAGS="$DEBUG_CFLAGS" \
            CPPFLAGS="$DEBUG_CPPFLAGS" \
            cmake .. -GNinja -DBUILD_SHARED_LIBS:BOOL=OFF -DBUILD_TESTING=ON \
                -DCMAKE_BUILD_TYPE="Debug" \
                -DCMAKE_C_FLAGS="$DEBUG_CFLAGS" \
                -DCMAKE_INSTALL_PREFIX="$stage/debug" \
                -DLIBXML2_WITH_ICONV=OFF \
                -DLIBXML2_WITH_LZMA=OFF \
                -DLIBXML2_WITH_PYTHON=OFF \
                -DLIBXML2_WITH_ZLIB=ON \
                -DZLIB_INCLUDE_DIRS="$stage/packages/include/zlib/" \
                -DZLIB_LIBRARIES="$stage/packages/lib/debug/libz.a" \
                -DZLIB_LIBRARY_DIRS="$stage/packages/lib"

            cmake --build . --config Debug
            cmake --install . --config Debug

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                ctest -C Debug
            fi
        popd

        mkdir -p "build_release"
        pushd "build_release"
            CFLAGS="$RELEASE_CFLAGS" \
            CPPFLAGS="$RELEASE_CPPFLAGS" \
            cmake .. -GNinja -DBUILD_SHARED_LIBS:BOOL=OFF -DBUILD_TESTING=ON \
                -DCMAKE_BUILD_TYPE="Release" \
                -DCMAKE_C_FLAGS="$RELEASE_CFLAGS" \
                -DCMAKE_INSTALL_PREFIX="$stage/release" \
                -DLIBXML2_WITH_ICONV=OFF \
                -DLIBXML2_WITH_LZMA=OFF \
                -DLIBXML2_WITH_PYTHON=OFF \
                -DLIBXML2_WITH_ZLIB=ON \
                -DZLIB_INCLUDE_DIRS="$stage/packages/include/zlib/" \
                -DZLIB_LIBRARIES="$stage/packages/lib/release/libz.a" \
                -DZLIB_LIBRARY_DIRS="$stage/packages/lib"

            cmake --build . --config Release
            cmake --install . --config Release

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                ctest -C Release
            fi
        popd

        # Copy libraries
        cp -a ${stage}/debug/lib/*.a ${stage}/lib/debug/
        cp -a ${stage}/release/lib/*.a ${stage}/lib/release/

        # copy headers
        cp -a ${stage}/release/include/* ${stage}/include/
    ;;
    
    darwin*)
        # Setup osx sdk platform
        SDKNAME="macosx"
        export SDKROOT=$(xcodebuild -version -sdk ${SDKNAME} Path)

        # Deploy Targets
        X86_DEPLOY=10.15
        ARM64_DEPLOY=11.0

        # Setup build flags
        ARCH_FLAGS_X86="-arch x86_64 -mmacosx-version-min=${X86_DEPLOY} -isysroot ${SDKROOT} -msse4.2"
        ARCH_FLAGS_ARM64="-arch arm64 -mmacosx-version-min=${ARM64_DEPLOY} -isysroot ${SDKROOT}"
        DEBUG_COMMON_FLAGS="-O0 -g -fPIC -DPIC"
        RELEASE_COMMON_FLAGS="-O3 -g -fPIC -DPIC -fstack-protector-strong"
        DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
        RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
        DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
        RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
        DEBUG_CPPFLAGS="-DPIC"
        RELEASE_CPPFLAGS="-DPIC"
        DEBUG_LDFLAGS="-Wl,-headerpad_max_install_names"
        RELEASE_LDFLAGS="-Wl,-headerpad_max_install_names"

        # force regenerate autoconf
        autoreconf -fvi

        # x86 Deploy Target
        export MACOSX_DEPLOYMENT_TARGET=${X86_DEPLOY}

        mkdir -p "build_debug_x86"
        pushd "build_debug_x86"
            CFLAGS="$ARCH_FLAGS_X86 $DEBUG_CFLAGS -I${stage}/packages/include/zlib -DALBUILD=1" \
            CPPFLAGS="$ARCH_FLAGS_X86 $DEBUG_CPPFLAGS -I${stage}/packages/include/zlib -DALBUILD=1" \
            CXXFLAGS="$ARCH_FLAGS_X86 $DEBUG_CXXFLAGS -I${stage}/packages/include/zlib -DALBUILD=1" \
            LDFLAGS="$ARCH_FLAGS_X86 $DEBUG_LDFLAGS -L${stage}/packages/lib/debug" \
            ../configure --host=x86_64-apple-darwin --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/debug" \
                --with-python=no --with-pic --with-zlib --without-lzma --disable-shared --enable-static

            make -j$AUTOBUILD_CPU_COUNT
            make install DESTDIR="$stage/debug_x86"

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make check || true
            fi
        popd

        mkdir -p "build_release_x86"
        pushd "build_release_x86"
            CFLAGS="$ARCH_FLAGS_X86 $RELEASE_CFLAGS  -I${stage}/packages/include/zlib -DALBUILD=1" \
            CPPFLAGS="$ARCH_FLAGS_X86 $RELEASE_CPPFLAGS -I${stage}/packages/include/zlib -DALBUILD=1" \
            CXXFLAGS="$ARCH_FLAGS_X86 $RELEASE_CXXFLAGS -I${stage}/packages/include/zlib -DALBUILD=1" \
            LDFLAGS="$ARCH_FLAGS_X86 $RELEASE_LDFLAGS -L${stage}/packages/lib/release" \
            ../configure --host=x86_64-apple-darwin --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/release" \
                --with-python=no --with-pic --with-zlib --without-lzma --disable-shared --enable-static

            make -j$AUTOBUILD_CPU_COUNT
            make install DESTDIR="$stage/release_x86"

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make check || true
            fi
        popd

        # ARM64 Deploy Target
        export MACOSX_DEPLOYMENT_TARGET=${ARM64_DEPLOY}

        mkdir -p "build_debug_arm64"
        pushd "build_debug_arm64"
            CFLAGS="$ARCH_FLAGS_ARM64 $DEBUG_CFLAGS -I${stage}/packages/include/zlib -DALBUILD=1" \
            CPPFLAGS="$ARCH_FLAGS_ARM64 $DEBUG_CPPFLAGS -I${stage}/packages/include/zlib -DALBUILD=1" \
            CXXFLAGS="$ARCH_FLAGS_ARM64 $DEBUG_CXXFLAGS -I${stage}/packages/include/zlib -DALBUILD=1" \
            LDFLAGS="$ARCH_FLAGS_ARM64 $DEBUG_LDFLAGS -L${stage}/packages/lib/debug" \
            ../configure --host=aarch64-apple-darwin --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/debug" \
                --with-python=no --with-pic --with-zlib --without-lzma --disable-shared --enable-static

            make -j$AUTOBUILD_CPU_COUNT
            make install DESTDIR="$stage/debug_arm64"

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make check || true
            fi
        popd

        mkdir -p "build_release_arm64"
        pushd "build_release_arm64"
            CFLAGS="$ARCH_FLAGS_ARM64 $RELEASE_CFLAGS  -I${stage}/packages/include/zlib -DALBUILD=1" \
            CPPFLAGS="$ARCH_FLAGS_ARM64 $RELEASE_CPPFLAGS -I${stage}/packages/include/zlib -DALBUILD=1" \
            CXXFLAGS="$ARCH_FLAGS_ARM64 $RELEASE_CXXFLAGS -I${stage}/packages/include/zlib -DALBUILD=1" \
            LDFLAGS="$ARCH_FLAGS_ARM64 $RELEASE_LDFLAGS -L${stage}/packages/lib/release" \
            ../configure --host=aarch64-apple-darwin --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/release" \
                --with-python=no --with-pic --with-zlib --without-lzma --disable-shared --enable-static

            make -j$AUTOBUILD_CPU_COUNT
            make install DESTDIR="$stage/release_arm64"

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make check || true
            fi
        popd

        # create fat libraries
        lipo -create ${stage}/debug_x86/lib/debug/libxml2.a ${stage}/debug_arm64/lib/debug/libxml2.a -output ${stage}/lib/debug/libxml2.a
        lipo -create ${stage}/release_x86/lib/release/libxml2.a ${stage}/release_arm64/lib/release/libxml2.a -output ${stage}/lib/release/libxml2.a

        # copy headers
        mv $stage/release_x86/include/* $stage/include
    ;;
    
    *)
        echo "platform not supported" 1>&2
        exit 1
    ;;
esac
popd

mkdir -p "$stage/LICENSES"
cp "$TOP/$SOURCE_DIR/$LICENSE" "$stage/LICENSES/$PROJECT.txt"
