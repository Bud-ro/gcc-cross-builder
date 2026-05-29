#!/bin/bash

# Build a Renesas RX (rx-elf) bare-metal toolchain from the Renesas GNU-RX
# *patched* sources. Unlike crosstool-NG driven build.sh, this builds straight
# from the tarballs Renesas/CyberThor publish for the GNU-RX product, which
# already carry the RX patches (improved codegen, -misa=v1/v2/v3 + DFPU, the
# optimised RX libraries, interrupt-handler fixes, etc.).
#
# Output contract matches build.sh / build-vax-netbsd.sh: produces
# rx-gcc-${VERSION}.tar.xz with top dir gcc-${VERSION}/ (containing bin/rx-elf-*),
# optionally uploads to an s3:// destination, and prints ce-build-* lines.
#
# Usage:
#   build-rx-gnurx.sh <VERSION> [ s3://bucket/path/ | /local/output/dir ]
#
# VERSION is a GNU-RX product release (e.g. 14.2.0.202511).

set -exuo pipefail

VERSION=$1
ARG2=${2:-}

ARCHITECTURE=rx
FULLNAME=${ARCHITECTURE}-gcc-${VERSION}
TARGET=rx-elf

STAGING_DIR=/opt/compiler-explorer/${ARCHITECTURE}/gcc-${VERSION}
WORKDIR=$(mktemp -d /tmp/build-rx.XXXXXX)

# Resolve output destination (mirrors build.sh's ARG handling).
S3OUTPUT=""
if [[ ${ARG2} =~ s3:// ]]; then
    OUTPUT=${WORKDIR}/${FULLNAME}.tar.xz
    S3OUTPUT=${ARG2}
elif [[ -d ${ARG2} ]]; then
    OUTPUT=${ARG2}/${FULLNAME}.tar.xz
else
    OUTPUT=${ARG2:-${WORKDIR}/${FULLNAME}.tar.xz}
fi

# Per-release source coordinates. Renesas serves the GNU-RX *patched* sources
# (filenames are the upstream component version, contents carry the RX patches)
# from the CDN endpoint below. To add a release, list it here; the filenames are
# on https://llvm-gcc-renesas.com/rx/rx-latest-source-code/ .
base="https://llvm-gcc-renesas.com/downloads/d.php?s=cdn&f=rx"
case "${VERSION}" in
    14.2.0.202511 | 14.2.0.202505)
        BINUTILS_URL="${base}/binutils/${VERSION}-gnurx/binutils-2.44.tar.gz"
        GCC_URL="${base}/gcc/${VERSION}-gnurx/gcc-14.2.tar.gz"
        NEWLIB_URL="${base}/newlib/${VERSION}-gnurx/newlib-4.4.0.tar.gz"
        ;;
    *)
        echo "Unknown GNU-RX release '${VERSION}'. Add it from" >&2
        echo "https://llvm-gcc-renesas.com/rx/rx-latest-source-code/ to the case table." >&2
        exit 1
        ;;
esac

NPROC=$(nproc)
mkdir -p "${STAGING_DIR}"
export PATH="${STAGING_DIR}/bin:${PATH}"

# The GNU-RX tarballs are flat (sources at the archive root, no top-level
# versioned dir), so extract straight into ${out} without --strip-components.
fetch_and_unpack() {
    local url=$1 out=$2
    curl -fsSL "${url}" -o "${WORKDIR}/${out}.tar.gz"
    mkdir -p "${WORKDIR}/${out}"
    tar xf "${WORKDIR}/${out}.tar.gz" -C "${WORKDIR}/${out}"
}

fetch_and_unpack "${BINUTILS_URL}" binutils
fetch_and_unpack "${GCC_URL}"      gcc
fetch_and_unpack "${NEWLIB_URL}"   newlib

# GCC needs gmp/mpfr/mpc/isl; let GCC fetch matching versions itself.
( cd "${WORKDIR}/gcc" && ./contrib/download_prerequisites )

COMMON_CFG=(--target="${TARGET}" --prefix="${STAGING_DIR}" --disable-nls --disable-werror)

# 1) binutils. Disable gdb/sim/gprofng: not needed for a compile toolchain, and
# the GNU-RX sim sources fail to build standalone.
mkdir -p "${WORKDIR}/b-binutils"
( cd "${WORKDIR}/b-binutils" \
    && "${WORKDIR}/binutils/configure" "${COMMON_CFG[@]}" \
        --disable-gdb --disable-gdbserver --disable-sim --disable-gprofng \
    && make -j"${NPROC}" MAKEINFO=true && make install MAKEINFO=true )

# 2) gcc stage 1 (C only -- needed to build newlib)
mkdir -p "${WORKDIR}/b-gcc1"
( cd "${WORKDIR}/b-gcc1" \
    && "${WORKDIR}/gcc/configure" "${COMMON_CFG[@]}" \
        --enable-languages=c --without-headers --with-newlib \
        --disable-shared --disable-threads --disable-libssp \
    && make -j"${NPROC}" all-gcc && make install-gcc )

# 3) newlib (C runtime / libc for the bare-metal target)
mkdir -p "${WORKDIR}/b-newlib"
( cd "${WORKDIR}/b-newlib" \
    && "${WORKDIR}/newlib/configure" --target="${TARGET}" --prefix="${STAGING_DIR}" \
    && make -j"${NPROC}" && make install )

# 4) gcc final (C + C++ against newlib)
mkdir -p "${WORKDIR}/b-gcc2"
( cd "${WORKDIR}/b-gcc2" \
    && "${WORKDIR}/gcc/configure" "${COMMON_CFG[@]}" \
        --enable-languages=c,c++ --with-newlib \
        --disable-shared --disable-threads --disable-libssp \
    && make -j"${NPROC}" && make install )

# Sanity check the freshly built compiler (same spirit as build-vax-netbsd.sh).
printf 'int sq(int x){return x*x;}\n' > "${WORKDIR}/t.c"
"${STAGING_DIR}/bin/${TARGET}-gcc" -O2 -S "${WORKDIR}/t.c" -o "${WORKDIR}/t.s"
"${STAGING_DIR}/bin/${TARGET}-g++" --version
test -x "${STAGING_DIR}/bin/${TARGET}-objdump"
test -x "${STAGING_DIR}/bin/${TARGET}-c++filt"

# Package: top dir must be gcc-${VERSION}/ (the install dir basename).
export XZ_DEFAULTS="-T 0"
tar Jcf "${OUTPUT}" -C "${STAGING_DIR}/.." "gcc-${VERSION}"

echo "ce-build-output:${OUTPUT}"

if [[ -n "${S3OUTPUT}" ]]; then
    aws s3 cp --storage-class REDUCED_REDUNDANCY "${OUTPUT}" "${S3OUTPUT}"
fi

echo "ce-build-status:OK"
