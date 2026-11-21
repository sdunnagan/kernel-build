#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# The code being tested intentionally uses globals to set selected target.
# shellcheck source=../lib/kernel-build-common.sh
source "$root/lib/kernel-build-common.sh"

assert_eq() {
    [[ "$1" == "$2" ]] || { printf 'Expected %s, got %s\n' "$2" "$1" >&2; exit 1; }
}

kb_resolve_platform '' ''
assert_eq "$PLATFORM" generic
assert_eq "$TARGET_ARCH" "$(uname -m)"
assert_eq "$DTB_REL_PATH" ''
kb_resolve_platform '' aarch64
assert_eq "$TARGET_ARCH" aarch64
kb_resolve_platform orin-nano ''
assert_eq "$PLATFORM" orin-nano
assert_eq "$TARGET_ARCH" aarch64
[[ -n "$DTB_REL_PATH" ]]
kb_resolve_platform opi5+ aarch64
assert_eq "$PLATFORM" opi5plus
if ( kb_resolve_platform orin-nano x86_64 ) >/dev/null 2>&1; then
    echo 'Expected mismatching -p and -a to fail' >&2; exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/kernel/scripts" "$work/build"
printf 'CONFIG_FAKE=y\n' > "$work/build/.config"
# Dummy Kconfig must declare every symbol found in the consolidated file.
awk '$1=="enable" || $1=="disable" || $1=="module" || $1=="set-str" || $1=="set-val" { print "config " $2 }' \
    "$root/configs/kernel-overrides.txt" | sort -u > "$work/kernel/Kconfig"
cat > "$work/kernel/scripts/config" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_OVERRIDE_LOG"
FAKE
chmod +x "$work/kernel/scripts/config"
export TEST_OVERRIDE_LOG="$work/applied.log"

check_count() {
    : > "$TEST_OVERRIDE_LOG"
    kb_apply_configs "$work/kernel" "$work/build/.config" "$root/configs/kernel-overrides.txt" "$1" "$2" "$3"
    assert_eq "$(wc -l < "$TEST_OVERRIDE_LOG")" "$4"
}
check_count centos generic x86_64 7
check_count centos orin-nano aarch64 7
check_count centos opi5plus aarch64 41
check_count upstream opi5plus aarch64 16
# No common upstream defaults in legacy file.
check_count upstream generic x86_64 0
# No quote characters should be passed to set-str after parsing.
grep -q -- 'CMDLINE console=ttyS2,1500000n8' <(
    : > "$TEST_OVERRIDE_LOG"
    kb_apply_configs "$work/kernel" "$work/build/.config" "$root/configs/kernel-overrides.txt" upstream opi5plus aarch64
    cat "$TEST_OVERRIDE_LOG"
)

kb_record_build_target "$work/build" x86_64 generic
[[ -f "$work/build/.kernel-build-target" ]] || {
    echo 'Expected new kernel-build target stamp' >&2; exit 1;
}
kb_assert_build_target "$work/build" x86_64 generic
if ( kb_assert_build_target "$work/build" aarch64 generic ) >/dev/null 2>&1; then
    echo 'Expected conflicting build target to fail' >&2; exit 1
fi

# Existing configurations without a target marker must be reconfigured.
rm -f -- "$work/build/.kernel-build-target"
if ( kb_assert_build_target "$work/build" x86_64 generic ) >/dev/null 2>&1; then
    echo 'Expected missing target marker to be rejected for existing config' >&2; exit 1
fi

# Reconfiguration restores the marker and permits the correct target only.
kb_record_build_target "$work/build" aarch64 generic
kb_assert_build_target "$work/build" aarch64 generic
if ( kb_assert_build_target "$work/build" x86_64 generic ) >/dev/null 2>&1; then
    echo 'Expected reconfigured target mismatch to fail' >&2; exit 1
fi

# A brand new empty build directory can be configured without a marker.
mkdir -p "$work/fresh-build"
kb_assert_build_target "$work/fresh-build" x86_64 generic
kb_record_build_target "$work/fresh-build" x86_64 generic
kb_assert_build_target "$work/fresh-build" x86_64 generic

echo 'All architecture, target-stamp and consolidated-config smoke tests passed.'
