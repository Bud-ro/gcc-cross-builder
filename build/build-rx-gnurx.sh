#!/bin/bash

# Build a Renesas RX (rx-elf) bare-metal toolchain from the Renesas GNU-RX
# *patched* GCC sources.
#
# Unlike the crosstool-NG driven build.sh, this uses the source tarballs that
# Renesas/CyberThor publish for the GNU-RX product. Those tarballs already carry
# the RX-specific patches on top of mainline GCC/binutils/newlib (improved RX
# codegen, the -misa=v1/v2/v3 + DFPU support, the optimised RX libraries, the
# .fvectors/.rvectors / interrupt-handler fixes, the bsr/bit-manipulation
# improvements, etc.), so building straight from them is what gives the
# "improved over plain GCC" behaviour the site wants.
#
# Output contract matches build.sh / build-vax-netbsd.sh:
#   - produces  rx-gcc-${VERSION}.tar.xz  whose top dir is  gcc-${VERSION}/
#     containing bin/rx-elf-* (matches infra cpp.yaml: subdir rx, arch_prefix
#     rx-elf, check_exe "bin/{{arch_prefix}}-g++ --version")
#   - optionally uploads to an s3:// destination
#   - prints ce-build-output: / ce-build-status: lines
#
# Usage:
#   build-rx-gnurx.sh <VERSION> [ s3://bucket/path/ | /local/output/dir ]
#
# VERSION is a GNU-RX product release (e.g. 14.2.0.202511, 8.3.0.202004).

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

# ----------------------------------------------------------------------------
# Per-release source coordinates.
#
# Renesas publishes the GNU-RX *patched* sources on the source-code pages at
# https://llvm-gcc-renesas.com/rx/rx-latest-source-code/ , served via the CDN
# download endpoint:
#
#   https://llvm-gcc-renesas.com/downloads/d.php?s=cdn&f=rx/<component>/<release>-gnurx/<file>
#
# The filenames are the upstream component version (e.g. gcc-14.2.tar.gz) but the
# tarball contents already carry the RX patches (improved RX codegen, the
# -misa=v1/v2/v3 + DFPU support, the optimised RX libraries, interrupt-handler
# fixes, etc.). To add a release, copy its exact filenames from that page.
# ----------------------------------------------------------------------------
base="https://llvm-gcc-renesas.com/downloads/d.php?s=cdn&f=rx"
case "${VERSION}" in
    14.2.0.202511)
        BINUTILS_URL="${base}/binutils/14.2.0.202511-gnurx/binutils-2.44.tar.gz"
        GCC_URL="${base}/gcc/14.2.0.202511-gnurx/gcc-14.2.tar.gz"
        NEWLIB_URL="${base}/newlib/14.2.0.202511-gnurx/newlib-4.4.0.tar.gz"
        ;;
    14.2.0.202505)
        BINUTILS_URL="${base}/binutils/14.2.0.202505-gnurx/binutils-2.44.tar.gz"
        GCC_URL="${base}/gcc/14.2.0.202505-gnurx/gcc-14.2.tar.gz"
        NEWLIB_URL="${base}/newlib/14.2.0.202505-gnurx/newlib-4.4.0.tar.gz"
        ;;
    *)
        echo "Unknown GNU-RX release '${VERSION}'. Copy its source filenames from" >&2
        echo "https://llvm-gcc-renesas.com/rx/rx-latest-source-code/ into the case table." >&2
        exit 1
        ;;
esac

NPROC=$(nproc)
mkdir -p "${STAGING_DIR}"
export PATH="${STAGING_DIR}/bin:${PATH}"

fetch_and_unpack() {
    local url=$1 out=$2
    curl -fsSL "${url}" -o "${WORKDIR}/${out}.tar.gz"
    mkdir -p "${WORKDIR}/${out}"
    # The GNU-RX tarballs are flat (sources at the archive root, no top-level
    # versioned directory), so extract straight into ${out} without stripping.
    tar xf "${WORKDIR}/${out}.tar.gz" -C "${WORKDIR}/${out}"
}

fetch_and_unpack "${BINUTILS_URL}" binutils
fetch_and_unpack "${GCC_URL}"      gcc
fetch_and_unpack "${NEWLIB_URL}"   newlib

# GCC needs gmp/mpfr/mpc/isl; let GCC fetch matching versions itself.
( cd "${WORKDIR}/gcc" && ./contrib/download_prerequisites )

COMMON_CFG=(--target="${TARGET}" --prefix="${STAGING_DIR}" --disable-nls --disable-werror)

# 1) binutils. Disable gdb/sim/gprofng: they are not needed for a compile
# toolchain and the GNU-RX sim sources fail to build standalone (rx.c /
# gdb-if.c reference an older rx_decode_opcode signature + sim_rx_acc_regnum).
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
