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

if [[ "$OSTYPE" == "cygwin" || "$OSTYPE" == "msys" ]] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

stage="$(pwd)"

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

pushd "$TOP/$SOURCE_DIR"
case "$AUTOBUILD_PLATFORM" in
    
    windows*)
        load_vsvars

        # Setup staging dirs
        mkdir -p "$stage/include"
        mkdir -p "$stage/lib/debug"
        mkdir -p "$stage/lib/release"

        mkdir -p "build_debug"
        pushd "build_debug"
            cmake -G Ninja .. -DCMAKE_BUILD_TYPE=Debug \
                -DCMAKE_INSTALL_PREFIX="$(cygpath -m $stage)/debug" \
                -DBUILD_SHARED_LIBS=OFF \
                -DLIBXML2_WITH_ICONV=OFF \
                -DLIBXML2_WITH_LZMA=OFF \
                -DLIBXML2_WITH_PYTHON=OFF \
                -DLIBXML2_WITH_ZLIB=ON \
                -DZLIB_INCLUDE_DIRS="$(cygpath -m $stage)/packages/include/zlib/" \
                -DZLIB_LIBRARIES="$(cygpath -m $stage)/packages/lib/debug/zlibd.lib" \
                -DZLIB_LIBRARY_DIRS="$(cygpath -m $stage)/packages/lib"

            cmake --build . --config Debug
            cmake --install . --config Debug

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                ctest -C Debug
            fi
        popd

        mkdir -p "build_release"
        pushd "build_release"
            cmake -G Ninja .. -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX="$(cygpath -m $stage)/release" \
                -DBUILD_SHARED_LIBS=OFF \
                -DLIBXML2_WITH_ICONV=OFF \
                -DLIBXML2_WITH_LZMA=OFF \
                -DLIBXML2_WITH_PYTHON=OFF \
                -DLIBXML2_WITH_ZLIB=ON \
                -DZLIB_INCLUDE_DIRS="$(cygpath -m $stage)/packages/include/zlib/" \
                -DZLIB_LIBRARIES="$(cygpath -m $stage)/packages/lib/release/zlib.lib" \
                -DZLIB_LIBRARY_DIRS="$(cygpath -m $stage)/packages/lib"

            cmake --build . --config Release
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
        unset DISTCC_HOSTS CFLAGS CPPFLAGS CXXFLAGS

        # Default target per --address-size
        opts_c="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE_CFLAGS}"
        opts_cxx="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE_CXXFLAGS}"
        
        # Handle any deliberate platform targeting
        if [ -z "${TARGET_CPPFLAGS:-}" ]; then
            # Remove sysroot contamination from build environment
            unset CPPFLAGS
        else
            # Incorporate special pre-processing flags
            export CPPFLAGS="$TARGET_CPPFLAGS"
        fi
        
        # Setup staging dirs
        mkdir -p "$stage/include"
        mkdir -p "$stage/lib"

        mkdir -p "build_release"
        pushd "build_release"
            CFLAGS="$opts_c" \
            cmake .. -GNinja -DBUILD_SHARED_LIBS:BOOL=OFF -DBUILD_TESTING=ON \
                -DCMAKE_BUILD_TYPE="Release" \
                -DCMAKE_C_FLAGS="$opts_c" \
                -DCMAKE_INSTALL_PREFIX="$stage" \
                -DLIBXML2_WITH_ICONV=OFF \
                -DLIBXML2_WITH_LZMA=OFF \
                -DLIBXML2_WITH_PYTHON=OFF \
                -DLIBXML2_WITH_ZLIB=ON \
                -DZLIB_INCLUDE_DIRS="$stage/packages/include/" \
                -DZLIB_LIBRARIES="$stage/packages/lib/libz.a" \
                -DZLIB_LIBRARY_DIRS="$stage/packages/lib"

            cmake --build . --config Release
            cmake --install . --config Release

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                ctest -C Release
            fi
        popd
    ;;
    
    darwin*)
        # Setup build flags
        C_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_CFLAGS"
        C_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_CFLAGS"
        CXX_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_CXXFLAGS"
        CXX_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_CXXFLAGS"
        LINK_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_LINKER"
        LINK_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_LINKER"

        # deploy target
        export MACOSX_DEPLOYMENT_TARGET=${LL_BUILD_DARWIN_BASE_DEPLOY_TARGET}

        # Setup staging dirs
        mkdir -p "$stage/include"
        mkdir -p "$stage/lib/release"

        # force regenerate autoconf
        autoreconf -fvi

        mkdir -p "build_release_x86"
        pushd "build_release_x86"
            CFLAGS="$C_OPTS_X86 -I${stage}/packages/include/zlib -DALBUILD=1" \
            CXXFLAGS="$CXX_OPTS_X86 -I${stage}/packages/include/zlib -DALBUILD=1" \
            LDFLAGS="$LINK_OPTS_X86 -L${stage}/packages/lib/release" \
            ../configure --host=x86_64-apple-darwin --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/release" \
                --with-python=no --with-pic --with-zlib --without-lzma --disable-shared --enable-static

            make -j$AUTOBUILD_CPU_COUNT
            make install DESTDIR="$stage/release_x86"

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make check || true
            fi
        popd

        mkdir -p "build_release_arm64"
        pushd "build_release_arm64"
            CFLAGS="$C_OPTS_ARM64 -I${stage}/packages/include/zlib -DALBUILD=1" \
            CXXFLAGS="$CXX_OPTS_ARM64 -I${stage}/packages/include/zlib -DALBUILD=1" \
            LDFLAGS="$LINK_OPTS_ARM64 -L${stage}/packages/lib/release" \
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
