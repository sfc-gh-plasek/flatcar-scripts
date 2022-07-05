#!/bin/bash
# Copyright (c) 2021 The Flatcar Maintainers.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

set -euo pipefail

# Test execution script for the qemu vendor image.
# This script is supposed to run in the mantle container.

source ci-automation/vendor_test.sh

# ARM64 qemu tests only supported on UEFI
if [ "${CIA_ARCH}" = "arm64" ] && [ "${CIA_TESTSCRIPT}" != "qemu_uefi.sh" ] ; then
    echo "1..1" > "${CIA_TAPFILE}"
    echo "not ok - all qemu tests" >> "${CIA_TAPFILE}"
    echo "  ---" >> "${CIA_TAPFILE}"
    echo "  ERROR: ARM64 tests only supported on qemu_uefi." | tee -a "${CIA_TAPFILE}"
    echo "  ..." >> "${CIA_TAPFILE}"
    exit 1
fi

# Fetch image and BIOS if not present
if [ -f "${QEMU_IMAGE_NAME}" ] ; then
    echo "++++ ${CIA_TESTSCRIPT}: Using existing ./${QEMU_IMAGE_NAME} for testing ${CIA_VERNUM} (${CIA_ARCH}) ++++"
else
    echo "++++ ${CIA_TESTSCRIPT}: downloading ${QEMU_IMAGE_NAME} for ${CIA_VERNUM} (${CIA_ARCH}) ++++"
    rm -f "${QEMU_IMAGE_NAME}.bz2"
    copy_from_buildcache "images/${CIA_ARCH}/${CIA_VERNUM}/${QEMU_IMAGE_NAME}.bz2" .
    lbunzip2 "${QEMU_IMAGE_NAME}.bz2"
fi

bios="${QEMU_BIOS}"
if [ "${CIA_TESTSCRIPT}" = "qemu_uefi.sh" ] ; then
    bios="${QEMU_UEFI_BIOS}"
    if [ -f "${bios}" ] ; then
        echo "++++ ${CIA_TESTSCRIPT}: Using existing ./${bios} ++++"
    else
        echo "++++ ${CIA_TESTSCRIPT}: downloading ${bios} for ${CIA_VERNUM} (${CIA_ARCH}) ++++"
        copy_from_buildcache "images/${CIA_ARCH}/${CIA_VERNUM}/${bios}" .
    fi
fi

set -x

kola run \
    --board="${CIA_ARCH}-usr" \
    --parallel="${QEMU_PARALLEL}" \
    --platform=qemu \
    --qemu-bios="${bios}" \
    --qemu-image="${QEMU_IMAGE_NAME}" \
    --tapfile="${CIA_TAPFILE}" \
    --torcx-manifest="${CIA_TORCX_MANIFEST}" \
    "${@}"

set +x
