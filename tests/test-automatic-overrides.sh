#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Verify that the default is the packaged configuration, regardless of cwd.
(
    cd /tmp
    source "$root/lib/kernel-build-common.sh"
    [[ "$KB_OVERRIDES_FILE" == "$root/configs/kernel-overrides.txt" ]]
    [[ -f "$KB_OVERRIDES_FILE" ]]
)

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/src" "$work/build"
touch "$work/log"

for builder in centos upstream; do
    (
        source "$root/lib/kernel-build-common.sh"
        source "$root/lib/kernel-build-${builder}.sh"
        [[ "$KERNEL_CONFIG_FILE" == "$root/configs/kernel-overrides.txt" ]]
        [[ -f "$KERNEL_CONFIG_FILE" ]]
        # -k was removed, not repurposed to a possibly ambiguous new meaning.
        if ( "${builder}_parse_args" -k "$work/old-config" ) >/dev/null 2>&1; then
            echo "Unexpected -k support for ${builder}" >&2
            exit 1
        fi
    )
done

# Exercise each builder's configure flow with operations unrelated to
# overrides stubbed out. Assert the consolidated file is always passed,
# using the correct builder kind, platform, and target architecture.
(
    source "$root/lib/kernel-build-common.sh"
    source "$root/lib/kernel-build-centos.sh"
    kb_init_colors
    LOG_FILE="$work/log"
    KERNEL_SRC_DIR="$work/src"
    KERNEL_BUILD_DIR="$work/build"
    PLATFORM=generic
    TARGET_ARCH=x86_64
    KERNEL_ARCH=x86
    centos_generate_config() { printf 'CONFIG_FAKE=y\n' > "$KERNEL_BUILD_DIR/.config"; }
    centos_clean_source_tree() { :; }
    centos_run_olddefconfig() { :; }
    kb_apply_localversion_config() { :; }
    kb_build_ctags() { :; }
    kb_apply_configs() {
        [[ "$3" == "$root/configs/kernel-overrides.txt" ]]
        [[ "$4" == centos && "$5" == generic && "$6" == x86_64 ]]
        printf 'centos\n' >> "$work/overrides-called"
    }
    centos_configure_kernel >/dev/null
)
(
    source "$root/lib/kernel-build-common.sh"
    source "$root/lib/kernel-build-upstream.sh"
    kb_init_colors
    LOG_FILE="$work/log"
    KERNEL_SRC_DIR="$work/src"
    KERNEL_BUILD_DIR="$work/build"
    PLATFORM=orin-nano
    TARGET_ARCH=aarch64
    KERNEL_ARCH=arm64
    kb_make() { :; }
    kb_build_ctags() { :; }
    kb_apply_configs() {
        [[ "$3" == "$root/configs/kernel-overrides.txt" ]]
        [[ "$4" == upstream && "$5" == orin-nano && "$6" == aarch64 ]]
        printf 'upstream\n' >> "$work/overrides-called"
    }
    upstream_configure_kernel >/dev/null
)
[[ "$(wc -l < "$work/overrides-called")" == 2 ]]
grep -qx centos "$work/overrides-called"
grep -qx upstream "$work/overrides-called"
echo 'Both builders automatically apply packaged overrides during configuration.'
