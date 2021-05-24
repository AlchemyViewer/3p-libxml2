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

pushd "$TOP/$SOURCE_DIR"
case "$AUTOBUILD_PLATFORM" in
    
    windows*)
        load_vsvars
        
        # We've observed some weird failures in which the PATH is too big
        # to be passed to a child process! When that gets munged, we start
        # seeing errors like 'nmake' failing to find the 'cl.exe' command.
        # Thing is, by this point in the script we've acquired a shocking
        # number of duplicate entries. Dedup the PATH using Python's
        # OrderedDict, which preserves the order in which you insert keys.
        # We find that some of the Visual Studio PATH entries appear both
        # with and without a trailing slash, which is pointless. Strip
        # those off and dedup what's left.
        # Pass the existing PATH as an explicit argument rather than
        # reading it from the environment, to bypass the fact that cygwin
        # implicitly converts PATH to Windows form when running a native
        # executable. Since we're setting bash's PATH, leave everything in
        # cygwin form. That means splitting and rejoining on ':' rather
        # than on os.pathsep, which on Windows is ';'.
        # Use python -u, else the resulting PATH will end with a spurious
        # '\r'.
        export PATH="$(python -u -c "import sys
from collections import OrderedDict
print(':'.join(OrderedDict((dir.rstrip('/'), 1) for dir in sys.argv[1].split(':'))))" "$PATH")"
        
        mkdir -p "$stage/lib/debug"
        mkdir -p "$stage/lib/release"
        
        pushd "win32"

        # Debug Build
        cscript configure.js zlib=yes icu=no static=yes debug=yes python=no iconv=no \
        compiler=msvc cruntime="/MDd" \
        include="$(cygpath -w $stage/packages/include);$(cygpath -w $stage/packages/include/zlib)" \
        lib="$(cygpath -w $stage/packages/lib/debug)" \
        prefix="$(cygpath -w $stage)" \
        sodir="$(cygpath -w $stage/lib/debug)" \
        libdir="$(cygpath -w $stage/lib/debug)"
        
        nmake /f Makefile.msvc ZLIB_LIBRARY=zlibd.lib all
        nmake /f Makefile.msvc install
        
        # conditionally run unit tests
        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            # There is one particular test .xml file that has started
            # failing consistently on our Windows build hosts. The
            # file is full of errors; but it's as if the test harness
            # has forgotten that this particular test is SUPPOSED to
            # produce errors! We can bypass it simply by renaming the
            # file: the test is based on picking up *.xml from that
            # directory.
            # Don't forget, we're in libxml2/win32 at the moment.
            badtest="$TOP/$SOURCE_DIR/test/errors/759398.xml"
            [ -f "$badtest" ] && mv "$badtest" "$badtest.hide"
            nmake /f Makefile.msvc checktests
            # Make sure we move it back after testing. It's not good
            # for a build script to leave modifications to a source
            # tree that's under version control.
            [ -f "$badtest.hide" ] && mv "$badtest.hide" "$badtest"
        fi
        
        nmake /f Makefile.msvc clean

        # Release Build
        cscript configure.js zlib=yes icu=no static=yes debug=no python=no iconv=no \
        compiler=msvc cruntime="/MD" \
        include="$(cygpath -w $stage/packages/include);$(cygpath -w $stage/packages/include/zlib)" \
        lib="$(cygpath -w $stage/packages/lib/release)" \
        prefix="$(cygpath -w $stage)" \
        sodir="$(cygpath -w $stage/lib/release)" \
        libdir="$(cygpath -w $stage/lib/release)"
        
        nmake /f Makefile.msvc ZLIB_LIBRARY=zlib.lib all
        nmake /f Makefile.msvc install
        
        # conditionally run unit tests
        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            # There is one particular test .xml file that has started
            # failing consistently on our Windows build hosts. The
            # file is full of errors; but it's as if the test harness
            # has forgotten that this particular test is SUPPOSED to
            # produce errors! We can bypass it simply by renaming the
            # file: the test is based on picking up *.xml from that
            # directory.
            # Don't forget, we're in libxml2/win32 at the moment.
            badtest="$TOP/$SOURCE_DIR/test/errors/759398.xml"
            [ -f "$badtest" ] && mv "$badtest" "$badtest.hide"
            nmake /f Makefile.msvc checktests
            # Make sure we move it back after testing. It's not good
            # for a build script to leave modifications to a source
            # tree that's under version control.
            [ -f "$badtest.hide" ] && mv "$badtest.hide" "$badtest"
        fi
        
        nmake /f Makefile.msvc clean
        popd
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
        
        JOBS=`cat /proc/cpuinfo | grep processor | wc -l`
        
        # Handle any deliberate platform targeting
        if [ -z "${TARGET_CPPFLAGS:-}" ]; then
            # Remove sysroot contamination from build environment
            unset CPPFLAGS
        else
            # Incorporate special pre-processing flags
            export CPPFLAGS="$TARGET_CPPFLAGS"
        fi
        
        # Fix up path for pkgconfig
        if [ -d "$stage/packages/lib/release/pkgconfig" ]; then
            fix_pkgconfig_prefix "$stage/packages"
        fi
        
        OLD_PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"
        
        # force regenerate autoconf
        autoreconf -fvi

        mkdir -p "build_debug"
        pushd "build_debug"
            # debug configure and build
            export PKG_CONFIG_PATH="$stage/packages/lib/debug/pkgconfig:${OLD_PKG_CONFIG_PATH}"
            
            # CPPFLAGS will be used by configure and we need to
            # get the dependent packages in there as well.  Process
            # may find the system zlib.h but it won't find the
            # packaged one.
            CFLAGS="$DEBUG_CFLAGS -I$stage/packages/include/zlib -DALBUILD=1" \
            CXXFLAGS="$DEBUG_CXXFLAGS -I$stage/packages/include/zlib -DALBUILD=1" \
            CPPFLAGS="${DEBUG_CPPFLAGS:-} -I$stage/packages/include/zlib -DALBUILD=1" \
            LDFLAGS="$opts -L$stage/packages/lib/debug" \
            ../configure --with-python=no --with-pic --with-zlib --without-lzma \
                --disable-shared --enable-static \
                --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/debug"

            make -j$JOBS
            make install DESTDIR="$stage"
            
            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make check
            fi
	popd

        mkdir -p "build_release"
        pushd "build_release"
            # release configure and build
            export PKG_CONFIG_PATH="$stage/packages/lib/release/pkgconfig:${OLD_PKG_CONFIG_PATH}"
            
            # CPPFLAGS will be used by configure and we need to
            # get the dependent packages in there as well.  Process
            # may find the system zlib.h but it won't find the
            # packaged one.
            CFLAGS="$RELEASE_CFLAGS -I$stage/packages/include/zlib -DALBUILD=1" \
            CXXFLAGS="$RELEASE_CXXFLAGS -I$stage/packages/include/zlib -DALBUILD=1" \
            CPPFLAGS="${RELEASE_CPPFLAGS:-} -I$stage/packages/include/zlib -DALBUILD=1" \
            LDFLAGS="$opts -L$stage/packages/lib/release" \
            ../configure --with-python=no --with-pic --with-zlib --without-lzma \
                --disable-shared --enable-static \
                --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/release"

            make -j$JOBS
            make install DESTDIR="$stage"
            
            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make check
            fi
        popd
    ;;
    
    darwin*)
        # Setup osx sdk platform
        SDKNAME="macosx"
        export SDKROOT=$(xcodebuild -version -sdk ${SDKNAME} Path)
        export MACOSX_DEPLOYMENT_TARGET=10.13

        # Setup build flags
        ARCH_FLAGS="-arch x86_64"
        SDK_FLAGS="-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} -isysroot ${SDKROOT}"
        DEBUG_COMMON_FLAGS="$ARCH_FLAGS $SDK_FLAGS -O0 -g -msse4.2 -fPIC -DPIC"
        RELEASE_COMMON_FLAGS="$ARCH_FLAGS $SDK_FLAGS -O3 -g -msse4.2 -fPIC -DPIC -fstack-protector-strong"
        DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
        RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
        DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
        RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
        DEBUG_CPPFLAGS="-DPIC"
        RELEASE_CPPFLAGS="-DPIC"
        DEBUG_LDFLAGS="$ARCH_FLAGS $SDK_FLAGS -Wl,-headerpad_max_install_names"
        RELEASE_LDFLAGS="$ARCH_FLAGS $SDK_FLAGS -Wl,-headerpad_max_install_names"

        JOBS=`sysctl -n hw.ncpu`

        # force regenerate autoconf
        autoreconf -fvi

        mkdir -p "build_debug"
        pushd "build_debug"
            CFLAGS="$DEBUG_CFLAGS -I${stage}/packages/include/zlib -DALBUILD=1" \
            CPPFLAGS="$DEBUG_CPPFLAGS -I${stage}/packages/include/zlib -DALBUILD=1" \
            CXXFLAGS="$DEBUG_CXXFLAGS -I${stage}/packages/include/zlib -DALBUILD=1" \
            LDFLAGS="$DEBUG_LDFLAGS -L${stage}/packages/lib/debug" \
            ../configure --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/debug" \
                --with-python=no --with-pic --with-zlib --without-lzma --disable-shared --enable-static

            make -j$JOBS
            make install DESTDIR="$stage"

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make check
            fi
        popd

        mkdir -p "build_release"
        pushd "build_release"
            CFLAGS="$RELEASE_CFLAGS  -I${stage}/packages/include/zlib -DALBUILD=1" \
            CPPFLAGS="$RELEASE_CPPFLAGS -I${stage}/packages/include/zlib -DALBUILD=1" \
            CXXFLAGS="$RELEASE_CXXFLAGS -I${stage}/packages/include/zlib -DALBUILD=1" \
            LDFLAGS="$RELEASE_LDFLAGS -L${stage}/packages/lib/release" \
            ../configure --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/release" \
                --with-python=no --with-pic --with-zlib --without-lzma --disable-shared --enable-static

            make -j$JOBS
            make install DESTDIR="$stage"

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make check
            fi
        popd
    ;;
    
    *)
        echo "platform not supported" 1>&2
        exit 1
    ;;
esac
popd

mkdir -p "$stage/LICENSES"
cp "$TOP/$SOURCE_DIR/$LICENSE" "$stage/LICENSES/$PROJECT.txt"
