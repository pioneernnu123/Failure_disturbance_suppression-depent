#!/bin/sh
# Build against the running kernel and load only when the prior module can unload.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
KERNEL_RELEASE=$(uname -r)
KDIR="/lib/modules/$KERNEL_RELEASE/build"

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

if [ ! -d "$KDIR" ] || [ ! -f "$KDIR/Module.symvers" ]; then
    echo "Missing matching kernel build tree or Module.symvers: $KDIR" >&2
    exit 1
fi
cd "$SCRIPT_DIR"
make -C "$KDIR" M="$SCRIPT_DIR" clean
if ! make -C "$KDIR" M="$SCRIPT_DIR" modules > ./build.log 2>&1; then
    cat ./build.log >&2
    exit 1
fi
cat ./build.log
VERMAGIC=$(modinfo -F vermagic ./phys_mem.ko)
case "$VERMAGIC" in
    "$KERNEL_RELEASE "*) ;;
    *) echo "vermagic mismatch: $VERMAGIC" >&2; exit 1 ;;
esac
UNDEFINED_SYMBOLS=$(nm -u ./phys_mem.ko)
if printf '%s\n' "$UNDEFINED_SYMBOLS" | grep -E 'mm_page_order|mm_buddy_expand|memory_failure|SetPageHWPoison'; then
    echo "Legacy or memory-failure symbol dependency remains" >&2
    exit 1
fi
echo "Built phys_mem.ko for $KERNEL_RELEASE: $VERMAGIC"
{
    date -Is
    uname -a
    printf 'vermagic=%s\n' "$VERMAGIC"
    modinfo -F version ./phys_mem.ko
    sha256sum ./phys_mem.ko "$KDIR/Module.symvers"
    CONFIG_FILE="$KDIR/include/config/auto.conf"
    if [ -f "$CONFIG_FILE" ]; then
        grep '^CONFIG_MEMORY_FAILURE=' "$CONFIG_FILE" || echo 'CONFIG_MEMORY_FAILURE is not set'
    fi
    cc --version | sed -n '1p'
} > ./build-info.txt

if grep -q '^phys_mem ' /proc/modules; then
    echo "Unloading current phys_mem; this fails while isolated pages are held."
    run_as_root rmmod phys_mem
fi
run_as_root insmod ./phys_mem.ko
echo "Loaded phys_mem on the existing kernel."
