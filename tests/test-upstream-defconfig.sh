#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/lib/kernel-build-common.sh"
source "$root/lib/kernel-build-upstream.sh"
kb_init_colors

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/source tree"
export TEST_MAKE_LOG="$work/make.log"
: > "$TEST_MAKE_LOG"

# Simulate only the Kbuild configuration operations, including creation of
# the .config in the O= directory. No kernel sources/toolchain are needed.
cat > "$work/bin/make" <<'MAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_MAKE_LOG"
for arg in "$@"; do
    case "$arg" in
        O=*) out="${arg#O=}" ;;
    esac
done
case " ${*} " in
    *' defconfig '*)
        [[ -n "${out:-}" ]] || exit 37
        [[ "${TEST_FAIL_DEFCONFIG:-0}" == 0 ]] || exit 23
        mkdir -p "$out"
        printf 'CONFIG_BASE_DEFAULT=y\n' > "$out/.config"
        ;;
    *' olddefconfig '*)
        [[ -f "${out}/.config" ]] || exit 38
        ;;
esac
MAKE
chmod +x "$work/bin/make"
export PATH="$work/bin:$PATH"

KERNEL_SRC_DIR="$work/source tree"
KERNEL_BUILD_DIR="$work/build aarch64"
TARGET_ARCH=aarch64
KERNEL_ARCH=arm64
PLATFORM=opi5plus
KERNEL_CONFIG_FILE="$root/configs/kernel-overrides.txt"
LOCALVERSION_TAG=''
LOG_FILE="$work/build.log"
: > "$LOG_FILE"

# Stub operations unrelated to selecting a Kbuild initial configuration.
kb_apply_configs()
{
    printf 'CONFIG_TEST_OVERRIDE=y\n' >> "$2"
}
kb_build_ctags() { return 0; }

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# A fresh workspace needs neither an existing build directory nor .config.
upstream_configure_kernel >/dev/null
[[ -f "$KERNEL_BUILD_DIR/.config" ]] || fail 'defconfig did not create config'
grep -qx 'CONFIG_BASE_DEFAULT=y' "$KERNEL_BUILD_DIR/.config" || fail 'wrong defconfig'
grep -qx 'CONFIG_TEST_OVERRIDE=y' "$KERNEL_BUILD_DIR/.config" || fail 'overrides not applied'
[[ "$(grep -c ' defconfig$' "$TEST_MAKE_LOG")" == 1 ]] || fail 'expected one defconfig'
[[ "$(grep -c ' olddefconfig$' "$TEST_MAKE_LOG")" == 2 ]] || fail 'expected two normalizations'
grep -q 'ARCH=arm64 defconfig$' "$TEST_MAKE_LOG" || fail 'wrong target Kbuild arch'

# An existing configuration is retained even when running -c again.
printf 'CONFIG_SEEDED_BOARD=y\n' > "$KERNEL_BUILD_DIR/.config"
: > "$TEST_MAKE_LOG"
upstream_configure_kernel >/dev/null
[[ "$(grep -c ' defconfig$' "$TEST_MAKE_LOG" || true)" == 0 ]] || fail 'overwrote supplied .config'
grep -qx 'CONFIG_SEEDED_BOARD=y' "$KERNEL_BUILD_DIR/.config" || fail 'lost supplied config'
grep -qx 'CONFIG_TEST_OVERRIDE=y' "$KERNEL_BUILD_DIR/.config" || fail 'lost override'

# Another target architecture selects its own Kbuild default and directory.
KERNEL_BUILD_DIR="$work/build x86_64"
TARGET_ARCH=x86_64
KERNEL_ARCH=x86_64
PLATFORM=generic
: > "$TEST_MAKE_LOG"
upstream_configure_kernel >/dev/null
grep -q 'ARCH=x86_64 defconfig$' "$TEST_MAKE_LOG" || fail 'wrong x86 default'

# If Kbuild defconfig fails, configuration fails, and does not proceed to
# overrides/normalization or masquerade as a successful build.
KERNEL_BUILD_DIR="$work/build failing"
TARGET_ARCH=aarch64
KERNEL_ARCH=arm64
export TEST_FAIL_DEFCONFIG=1
: > "$TEST_MAKE_LOG"
if (upstream_configure_kernel >/dev/null) 2>/dev/null; then
    fail 'Kbuild defconfig failure was ignored'
else
    rc=$?
    [[ "$rc" == 23 ]] || fail "unexpected failure code: $rc"
fi
[[ ! -f "$KERNEL_BUILD_DIR/.config" ]] || fail 'unexpected configuration on failure'
[[ "$(wc -l < "$TEST_MAKE_LOG")" == 1 ]] || fail 'continued configuring after failed defconfig'
unset TEST_FAIL_DEFCONFIG

echo 'PASS: upstream defconfig generation and existing-config preservation'
