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
[ -f "$stage"/packages/include/zlib-ng/zlib.h ] || \
{ echo "You haven't installed packages yet." 1>&2; exit 1; }

# load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

# remove_cxxstd
source "$(dirname "$AUTOBUILD_VARIABLES_FILE")/functions"

pushd "$TOP/$SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in

        windows*)
            load_vsvars

            opts="$(replace_switch /Zi /Z7 $LL_BUILD_RELEASE)"
            plainopts="$(remove_switch /GR $(remove_cxxstd $opts))"

            # Setup staging dirs
            mkdir -p "$stage/include"
            mkdir -p "$stage/lib/release"

            mkdir -p "build"
            pushd "build"
                cmake -G Ninja .. -DCMAKE_BUILD_TYPE=Release \
                    -DCMAKE_C_FLAGS:STRING="$plainopts" \
                    -DCMAKE_CXX_FLAGS:STRING="$opts" \
                    -DCMAKE_INSTALL_PREFIX="$(cygpath -m $stage)" \
                    -DBUILD_SHARED_LIBS=OFF \
                    -DLIBXML2_WITH_ICONV=OFF \
                    -DLIBXML2_WITH_LZMA=OFF \
                    -DLIBXML2_WITH_PYTHON=OFF \
                    -DLIBXML2_WITH_ZLIB=ON \
                    -DZLIB_INCLUDE_DIR="$(cygpath -m "$stage/packages/include/zlib-ng/")" \
                    -DZLIB_LIBRARY="$(cygpath -m "$stage/packages/lib/release/zlib.lib")"

                cmake --build . --config Release --parallel $AUTOBUILD_CPU_COUNT

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release --parallel $AUTOBUILD_CPU_COUNT
                fi

                cmake --install . --config Release

                # Copy libraries
                mv ${stage}/lib/libxml2s.lib ${stage}/lib/release/libxml2.lib
            popd
        ;;

        linux*)
            # Default target per autobuild build --address-size
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE}"
            opts="$(remove_cxxstd $opts)"

            # Setup staging dirs
            mkdir -p "$stage/include"
            mkdir -p "$stage/lib"
            mkdir -p $stage/lib/release/

            mkdir -p "build_release"
            pushd "build_release"
                CFLAGS="$opts" \
                cmake .. -GNinja -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_BUILD_TYPE="Release" \
                    -DCMAKE_C_FLAGS="$opts" \
                    -DCMAKE_INSTALL_PREFIX="$stage" \
                    -DLIBXML2_WITH_ICONV=ON \
                    -DLIBXML2_WITH_LZMA=OFF \
                    -DLIBXML2_WITH_PYTHON=OFF \
                    -DLIBXML2_WITH_ZLIB=ON \
                    -DZLIB_INCLUDE_DIR="$stage/packages/include/zlib-ng/" \
                    -DZLIB_LIBRARY="$stage/packages/lib/release/libz.a"

                cmake --build . --config Release --parallel $AUTOBUILD_CPU_COUNT

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release --parallel $AUTOBUILD_CPU_COUNT
                fi

                cmake --install . --config Release

                mv $stage/lib/*.a $stage/lib/release/
            popd
        ;;

        darwin*)
            export MACOSX_DEPLOYMENT_TARGET="$LL_BUILD_DARWIN_DEPLOY_TARGET"

            for arch in x86_64 arm64 ; do
                ARCH_ARGS="-arch $arch"
                opts="${TARGET_OPTS:-$ARCH_ARGS $LL_BUILD_RELEASE}"
                cc_opts="$(remove_cxxstd $opts)"
                ld_opts="$ARCH_ARGS"

                mkdir -p "build_$arch"
                pushd "build_$arch"
                    CFLAGS="$cc_opts" \
                    CXXFLAGS="$opts" \
                    LDFLAGS="$ld_opts" \
                    cmake .. -GNinja -DBUILD_SHARED_LIBS:BOOL=OFF \
                        -DCMAKE_BUILD_TYPE="Release" \
                        -DCMAKE_C_FLAGS="$cc_opts" \
                        -DCMAKE_CXX_FLAGS="$opts" \
                        -DCMAKE_INSTALL_PREFIX="$stage" \
                        -DCMAKE_INSTALL_LIBDIR="$stage/lib/release/$arch" \
                        -DLIBXML2_WITH_ICONV=ON \
                        -DLIBXML2_WITH_LZMA=OFF \
                        -DLIBXML2_WITH_PYTHON=OFF \
                        -DLIBXML2_WITH_ZLIB=ON \
                        -DZLIB_INCLUDE_DIR="$stage/packages/include/zlib-ng/" \
                        -DZLIB_LIBRARY="$stage/packages/lib/release/libz.a" \
                        -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                        -DCMAKE_OSX_ARCHITECTURES="$arch"

                    cmake --build . --config Release --parallel $AUTOBUILD_CPU_COUNT

                    # conditionally run unit tests
                    if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                        ctest -C Release --parallel $AUTOBUILD_CPU_COUNT
                    fi

                    cmake --install . --config Release
                popd
            done

            lipo -create -output "$stage/lib/release/libxml2.a" "$stage/lib/release/x86_64/libxml2.a" "$stage/lib/release/arm64/libxml2.a"
        ;;

        *)
            echo "platform not supported" 1>&2
            exit 1
        ;;
    esac
popd

mkdir -p "$stage/LICENSES"
cp "$TOP/$SOURCE_DIR/$LICENSE" "$stage/LICENSES/$PROJECT.txt"
mkdir -p "$stage"/docs/libxml2/
cp -a "$TOP"/README.Linden "$stage"/docs/libxml2/
