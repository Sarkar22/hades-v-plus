#!/bin/sh
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------------------------------
# fetch_freertos.sh -- clone the external FreeRTOS sources used by test/freertos at the exact,
# tested commits. Nothing from FreeRTOS is vendored in this repository.
#
#   sh test/freertos/fetch_freertos.sh [DEST]      (default: the repository's parent directory)
#   make freertos-fetch                            (DEST = FREERTOS_HOME, see docs/FREERTOS.md)
#
# Creates DEST/FreeRTOS-Kernel (full kernel, partial clone) and DEST/FreeRTOS (sparse: only
# FreeRTOS/Demo/Common and the RISC-V QEMU demo's RegTest.S). Safe to re-run: existing
# clones are reused and checked out at the pinned commits again. Needs git >= 2.25 and
# network access to github.com. Invoked with `sh`, so it needs no execute permission.
# ---------------------------------------------------------------------------------------------
set -e
DEST=${1:-$(cd "$(dirname "$0")/../../.." && pwd)}
KERNEL_REV=8be86d4a24fd4091f8f4192018423ab590f408db   # FreeRTOS-Kernel V11.1.0+ (main, 2025)
DEMO_REV=f4fcc3b228643144727e9257ba12db1cb632b6e6     # FreeRTOS/FreeRTOS (Demo/Common, RegTest.S)

mkdir -p "$DEST"
cd "$DEST"
DEST=$(pwd)

if [ ! -d FreeRTOS-Kernel/.git ]; then
    git clone --filter=blob:none --no-checkout https://github.com/FreeRTOS/FreeRTOS-Kernel.git
fi
git -C FreeRTOS-Kernel -c advice.detachedHead=false checkout -q "$KERNEL_REV"

if [ ! -d FreeRTOS/.git ]; then
    git clone --filter=blob:none --no-checkout https://github.com/FreeRTOS/FreeRTOS.git
    git -C FreeRTOS sparse-checkout set --no-cone \
        '/FreeRTOS/Demo/Common/Minimal/*' '/FreeRTOS/Demo/Common/include/*' \
        '/FreeRTOS/Demo/RISC-V_RV32_QEMU_VIRT_GCC/build/gcc/RegTest.S'
fi
git -C FreeRTOS -c advice.detachedHead=false checkout -q "$DEMO_REV"

# Verify: the exact commits, and the files the build needs.
k=$(git -C FreeRTOS-Kernel rev-parse HEAD)
d=$(git -C FreeRTOS rev-parse HEAD)
[ "$k" = "$KERNEL_REV" ] || { echo "FreeRTOS-Kernel is at $k, expected $KERNEL_REV" >&2; exit 1; }
[ "$d" = "$DEMO_REV" ]   || { echo "FreeRTOS is at $d, expected $DEMO_REV" >&2; exit 1; }
for f in FreeRTOS-Kernel/tasks.c FreeRTOS-Kernel/portable/GCC/RISC-V/portASM.S \
         FreeRTOS-Kernel/portable/MemMang/heap_4.c FreeRTOS/FreeRTOS/Demo/Common/Minimal/semtest.c \
         FreeRTOS/FreeRTOS/Demo/RISC-V_RV32_QEMU_VIRT_GCC/build/gcc/RegTest.S; do
    [ -f "$f" ] || { echo "missing $DEST/$f after checkout" >&2; exit 1; }
done

echo "FreeRTOS sources ready in $DEST:"
echo "  FreeRTOS-Kernel  $k"
echo "  FreeRTOS (demo)  $d"
echo "The Makefile finds them through FREERTOS_HOME=$DEST (default: the repository's parent"
echo "directory). Other scripts can be pointed at them directly with"
echo "  export FREERTOS_KERNEL=$DEST/FreeRTOS-Kernel"
echo "  export FREERTOS_DEMO=$DEST/FreeRTOS/FreeRTOS/Demo"
