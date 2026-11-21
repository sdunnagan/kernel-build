#!/usr/bin/env bash
set -euo pipefail
trap 'echo "TEST FAILED line $LINENO: $BASH_COMMAND" >&2' ERR
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/lib/kernel-build-common.sh"
source "$root/lib/kernel-build-upstream.sh"
kb_init_colors
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

eq() { [[ "$1" == "$2" ]] || { printf 'Expected <%s>; got <%s>\n' "$2" "$1" >&2; exit 1; }; }

# Source is architecture independent; build trees are not.
for arch in x86_64 aarch64 riscv64; do
    (
        unset KERNEL_SRC_DIR KERNEL_BUILD_DIR
        KERNEL_WORKSPACE_DIR="$work/with spaces"
        kb_resolve_platform '' "$arch"
        upstream_resolve_workspace_paths
        eq "$KERNEL_SRC_DIR" "$work/with spaces/upstream_kernel"
        eq "$KERNEL_BUILD_DIR" "$work/with spaces/build-upstream-$arch"
    )
done
(
    unset KERNEL_SRC_DIR KERNEL_BUILD_DIR
    KERNEL_WORKSPACE_DIR="$work/with spaces/"
    kb_resolve_platform 'opi5plus' ''
    upstream_resolve_workspace_paths
    eq "$TARGET_ARCH" aarch64
    eq "$KERNEL_BUILD_DIR" "$work/with spaces/build-upstream-aarch64"
)

# Existing explicit variables remain compatible only when matching.
(
    KERNEL_WORKSPACE_DIR="$work/legacy"
    KERNEL_SRC_DIR="$work/legacy/upstream_kernel"
    KERNEL_BUILD_DIR="$work/legacy/build-upstream-aarch64"
    kb_resolve_platform '' aarch64
    upstream_resolve_workspace_paths
    eq "$KERNEL_SRC_DIR" "$work/legacy/upstream_kernel"
    eq "$KERNEL_BUILD_DIR" "$work/legacy/build-upstream-aarch64"
)
for conflict in source build; do
    if (
        KERNEL_WORKSPACE_DIR="$work/legacy"
        unset KERNEL_SRC_DIR KERNEL_BUILD_DIR
        if [[ "$conflict" == source ]]; then
            KERNEL_SRC_DIR="$work/another-source"
        else
            KERNEL_BUILD_DIR="$work/legacy/build_upstream_kernel"
        fi
        kb_resolve_platform '' aarch64
        upstream_resolve_workspace_paths
    ) >"$work/conflict.log" 2>&1; then
        echo "Expected $conflict path conflict" >&2; exit 1
    fi
    if [[ "$conflict" == source ]]; then
        grep -Fq "KERNEL_SRC_DIR conflicts" "$work/conflict.log"
    else
        grep -Fq "KERNEL_BUILD_DIR conflicts" "$work/conflict.log"
    fi
done
if (
    unset KERNEL_WORKSPACE_DIR KERNEL_SRC_DIR KERNEL_BUILD_DIR
    kb_resolve_platform '' aarch64
    upstream_resolve_workspace_paths
) >"$work/noworkspace.log" 2>&1; then
    echo 'Expected missing workspace to fail' >&2; exit 1
fi
grep -Fq 'Set KERNEL_WORKSPACE_DIR' "$work/noworkspace.log"

# Native and cross-compile labels depend on CROSS_COMPILE, not on builder type.
(
    unset CROSS_COMPILE
    eq "$(kb_compiler_setup_message)" '   - Preparing native compiler environment'
)
(
    CROSS_COMPILE=aarch64-linux-gnu-
    eq "$(kb_compiler_setup_message)" '   - Preparing cross-compile environment'
)
for kind in centos upstream; do
    grep -Fq 'compiler_setup_msg="$(kb_compiler_setup_message)"' "$root/lib/kernel-build-$kind.sh"
done

# -V works without a workspace and remains plain when not attached to a tty.
for builder in centos-kernel-build upstream-kernel-build; do
    output="$(env -u KERNEL_WORKSPACE_DIR -u KERNEL_SRC_DIR -u KERNEL_BUILD_DIR "$root/$builder" -V)"
    eq "$output" 'kernel-build 0.1.10'
done

# Config-only upstream invocation derives paths and attempts defconfig when
# the build directory lacks .config. An absent source tree fails at Kbuild.
if env -u KERNEL_SRC_DIR -u KERNEL_BUILD_DIR \
    KERNEL_WORKSPACE_DIR="$work/smoke" LOG_DIR="$work/logs" \
    "$root/upstream-kernel-build" -c >"$work/cli.log" 2>&1; then
    echo 'Expected missing upstream source tree to fail' >&2; exit 1
fi
grep -Fq "$work/smoke/upstream_kernel" "$work/cli.log"
grep -Fq "$work/smoke/build-upstream-$(uname -m)" "$work/cli.log"
grep -Fq 'Generating ' "$work/cli.log"
grep -Fq 'defconfig' "$work/cli.log"

# If the terminal utility is present, check that the banner forces white.
if command -v script >/dev/null 2>&1 && command -v tput >/dev/null 2>&1; then
    TERM=xterm script -q -c "$root/upstream-kernel-build -V" /dev/null > "$work/tty.log"
    white="$(TERM=xterm tput setaf 7)"
    [[ $(cat "$work/tty.log") == *"${white}kernel-build 0.1.10"* ]] || {
        echo 'Expected white banner in TTY mode' >&2; exit 1;
    }
fi

echo 'Upstream path derivation, legacy protection, native/cross labels, CLI and banner tests passed.'
