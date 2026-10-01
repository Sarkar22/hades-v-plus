#!/bin/sh
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------------------------------
# update.sh -- re-vendor the FreeRTOS sources in third_party/freertos/ from upstream.
#
#   sh third_party/freertos/update.sh                                 (the pinned commits)
#   sh third_party/freertos/update.sh <KERNEL_COMMIT> <FREERTOS_COMMIT>
#
# Fetches FreeRTOS-Kernel at KERNEL_COMMIT and FreeRTOS/FreeRTOS at FREERTOS_COMMIT (full
# 40-digit commit ids) into a temporary directory, replaces the vendored trees FreeRTOS-Kernel/
# and FreeRTOS/ next to this script with exactly the files listed below, unmodified, rewrites
# MANIFEST (the SHA-256 of every vendored file) and prints it. With the pinned commits the
# result is byte-identical to the committed tree, so `git status` stays clean.
#
# This is a maintainer tool: building HaDes-V+ never runs it. It needs git 2.25 or newer,
# sha256sum (or shasum) and network access to github.com. Invoked with `sh`, so it needs no
# execute permission. See README.md in this directory, section "Updating".
# ---------------------------------------------------------------------------------------------
set -eu
set -f   # no pathname expansion: the file lists below are split on white space only

KERNEL_URL=https://github.com/FreeRTOS/FreeRTOS-Kernel.git
FREERTOS_URL=https://github.com/FreeRTOS/FreeRTOS.git
KERNEL_PINNED=8be86d4a24fd4091f8f4192018423ab590f408db     # FreeRTOS-Kernel, main (V11.1.0+)
FREERTOS_PINNED=f4fcc3b228643144727e9257ba12db1cb632b6e6   # FreeRTOS/FreeRTOS, main

# Paths in the FreeRTOS-Kernel repository; vendored as FreeRTOS-Kernel/<path>.
KERNEL_FILES='
LICENSE.md
tasks.c
queue.c
list.c
timers.c
event_groups.c
stream_buffer.c
include/FreeRTOS.h
include/StackMacros.h
include/atomic.h
include/croutine.h
include/deprecated_definitions.h
include/event_groups.h
include/list.h
include/message_buffer.h
include/mpu_prototypes.h
include/mpu_syscall_numbers.h
include/mpu_wrappers.h
include/newlib-freertos.h
include/picolibc-freertos.h
include/portable.h
include/projdefs.h
include/queue.h
include/semphr.h
include/stack_macros.h
include/stream_buffer.h
include/task.h
include/timers.h
portable/GCC/RISC-V/port.c
portable/GCC/RISC-V/portASM.S
portable/GCC/RISC-V/portContext.h
portable/GCC/RISC-V/portmacro.h
portable/GCC/RISC-V/chip_specific_extensions/RISCV_MTIME_CLINT_no_extensions/freertos_risc_v_chip_specific_extensions.h
portable/MemMang/heap_1.c
portable/MemMang/heap_4.c
'

# Paths in the FreeRTOS/FreeRTOS repository; vendored as FreeRTOS/<path>.
FREERTOS_FILES='
LICENSE.md
FreeRTOS/Demo/Common/Minimal/AbortDelay.c
FreeRTOS/Demo/Common/Minimal/BlockQ.c
FreeRTOS/Demo/Common/Minimal/EventGroupsDemo.c
FreeRTOS/Demo/Common/Minimal/GenQTest.c
FreeRTOS/Demo/Common/Minimal/IntSemTest.c
FreeRTOS/Demo/Common/Minimal/MessageBufferDemo.c
FreeRTOS/Demo/Common/Minimal/PollQ.c
FreeRTOS/Demo/Common/Minimal/QueueOverwrite.c
FreeRTOS/Demo/Common/Minimal/QueueSet.c
FreeRTOS/Demo/Common/Minimal/StreamBufferDemo.c
FreeRTOS/Demo/Common/Minimal/StreamBufferInterrupt.c
FreeRTOS/Demo/Common/Minimal/TaskNotify.c
FreeRTOS/Demo/Common/Minimal/TimerDemo.c
FreeRTOS/Demo/Common/Minimal/blocktim.c
FreeRTOS/Demo/Common/Minimal/countsem.c
FreeRTOS/Demo/Common/Minimal/dynamic.c
FreeRTOS/Demo/Common/Minimal/recmutex.c
FreeRTOS/Demo/Common/Minimal/semtest.c
FreeRTOS/Demo/Common/include/AbortDelay.h
FreeRTOS/Demo/Common/include/BlockQ.h
FreeRTOS/Demo/Common/include/EventGroupsDemo.h
FreeRTOS/Demo/Common/include/GenQTest.h
FreeRTOS/Demo/Common/include/IntSemTest.h
FreeRTOS/Demo/Common/include/MessageBufferDemo.h
FreeRTOS/Demo/Common/include/PollQ.h
FreeRTOS/Demo/Common/include/QueueOverwrite.h
FreeRTOS/Demo/Common/include/QueueSet.h
FreeRTOS/Demo/Common/include/StreamBufferDemo.h
FreeRTOS/Demo/Common/include/StreamBufferInterrupt.h
FreeRTOS/Demo/Common/include/TaskNotify.h
FreeRTOS/Demo/Common/include/TimerDemo.h
FreeRTOS/Demo/Common/include/blocktim.h
FreeRTOS/Demo/Common/include/countsem.h
FreeRTOS/Demo/Common/include/dynamic.h
FreeRTOS/Demo/Common/include/recmutex.h
FreeRTOS/Demo/Common/include/semtest.h
FreeRTOS/Demo/RISC-V_RV32_QEMU_VIRT_GCC/build/gcc/RegTest.S
FreeRTOS-Plus/Source/FreeRTOS-Plus-CLI/FreeRTOS_CLI.c
FreeRTOS-Plus/Source/FreeRTOS-Plus-CLI/FreeRTOS_CLI.h
FreeRTOS-Plus/Source/FreeRTOS-Plus-CLI/LICENSE_INFORMATION.txt
'

die() { echo "update.sh: $*" >&2; exit 1; }

case $# in
    0) KERNEL_REV=$KERNEL_PINNED; FREERTOS_REV=$FREERTOS_PINNED ;;
    2) KERNEL_REV=$1; FREERTOS_REV=$2 ;;
    *) die "usage: sh $0 [<FreeRTOS-Kernel commit> <FreeRTOS commit>]" ;;
esac
for rev in "$KERNEL_REV" "$FREERTOS_REV"; do
    case $rev in
        *[!0-9a-f]*) die "'$rev' is not a full 40-digit lower-case commit id" ;;
    esac
    [ ${#rev} -eq 40 ] || die "'$rev' is not a full 40-digit lower-case commit id"
done

if command -v sha256sum > /dev/null 2>&1; then SHA256='sha256sum'; else SHA256='shasum -a 256'; fi
command -v git > /dev/null 2>&1 || die "git not found"

HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/freertos-vendor.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' INT TERM

# fetch <url> <commit> <dir> <files>: check out only <files> of <url> at <commit> into <dir>
# (a shallow, blob-less fetch of that one commit and a sparse checkout of the listed paths).
fetch() {
    echo "fetching $1 at $2"
    git init -q "$3"
    git -C "$3" remote add origin "$1"
    git -C "$3" config core.sparseCheckout true
    for f in $4; do printf '/%s\n' "$f"; done > "$3/.git/info/sparse-checkout"
    git -C "$3" fetch -q --depth 1 --filter=blob:none origin "$2"
    git -C "$3" -c advice.detachedHead=false checkout -q FETCH_HEAD
    got=$(git -C "$3" rev-parse HEAD)
    [ "$got" = "$2" ] || die "$1: checked out $got, expected $2"
    for f in $4; do
        [ -f "$3/$f" ] || die "$1 at $2 has no file $f"
    done
}

# stage <checkout> <destination> <files>: copy the listed files, keeping their paths
stage() {
    for f in $3; do
        mkdir -p "$2/$(dirname "$f")"
        cp "$1/$f" "$2/$f"
    done
}

fetch "$KERNEL_URL"   "$KERNEL_REV"   "$TMP/kernel"   "$KERNEL_FILES"
fetch "$FREERTOS_URL" "$FREERTOS_REV" "$TMP/freertos" "$FREERTOS_FILES"
stage "$TMP/kernel"   "$TMP/out/FreeRTOS-Kernel" "$KERNEL_FILES"
stage "$TMP/freertos" "$TMP/out/FreeRTOS"        "$FREERTOS_FILES"

# Replace the vendored trees only now that both checkouts are complete.
[ -f "$HERE/MANIFEST" ] && cp "$HERE/MANIFEST" "$TMP/MANIFEST.old"
rm -rf "$HERE/FreeRTOS-Kernel" "$HERE/FreeRTOS"
cp -R "$TMP/out/FreeRTOS-Kernel" "$TMP/out/FreeRTOS" "$HERE/"

cd "$HERE"
find FreeRTOS-Kernel FreeRTOS -type f | LC_ALL=C sort | while read -r f; do
    $SHA256 "$f"
done > MANIFEST

cat MANIFEST
n=$(wc -l < MANIFEST | tr -d ' ')
echo
echo "Vendored $n files into $HERE:"
echo "  FreeRTOS-Kernel    $KERNEL_REV"
echo "  FreeRTOS/FreeRTOS  $FREERTOS_REV"
if [ -f "$TMP/MANIFEST.old" ]; then
    if cmp -s "$TMP/MANIFEST.old" MANIFEST; then
        echo "MANIFEST is unchanged: the vendored files are byte-identical to the previous ones."
    else
        echo "MANIFEST changed (- previous, + new):"
        diff "$TMP/MANIFEST.old" MANIFEST | sed -n -e 's/^< /- /p' -e 's/^> /+ /p' || true
    fi
fi
if [ "$KERNEL_REV" != "$KERNEL_PINNED" ] || [ "$FREERTOS_REV" != "$FREERTOS_PINNED" ]; then
    echo "These are not the pinned commits: record them in this script (KERNEL_PINNED,"
    echo "FREERTOS_PINNED) and in README.md once the new sources have been tested."
fi
