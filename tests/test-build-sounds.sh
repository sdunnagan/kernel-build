#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/sounds" "$work/logs"
: > "$work/sounds/complete.oga"
: > "$work/sounds/service-logout.oga"
cat > "$work/bin/canberra-gtk-play" <<'PLAYER'
#!/usr/bin/env bash
printf 'canberra %s\n' "$*" >> "$TEST_SOUND_LOG"
exit "${TEST_CANBERRA_RC:-0}"
PLAYER
cat > "$work/bin/pw-play" <<'PLAYER'
#!/usr/bin/env bash
printf 'pipewire %s\n' "$*" >> "$TEST_SOUND_LOG"
exit "${TEST_PIPEWIRE_RC:-0}"
PLAYER
cat > "$work/bin/paplay" <<'PLAYER'
#!/usr/bin/env bash
printf 'pulse %s\n' "$*" >> "$TEST_SOUND_LOG"
exit "${TEST_PULSE_RC:-0}"
PLAYER
chmod +x "$work/bin/"*
export KB_BUILD_SOUND_DIR="$work/sounds"
export TEST_SOUND_LOG="$work/sound.log"
export PATH="$work/bin:$PATH"

# Simulated build completion, exit status preserved on success and failure.
: > "$TEST_SOUND_LOG"
bash -c 'set -euo pipefail; source "$1"; kb_enable_build_notifications; exit 0' \
    _ "$root/lib/kernel-build-common.sh"
[[ "$(wc -l < "$TEST_SOUND_LOG")" -eq 1 ]]
grep -Fq "canberra -f $work/sounds/complete.oga" "$TEST_SOUND_LOG"

: > "$TEST_SOUND_LOG"
rc=0
bash -c 'set -euo pipefail; source "$1"; kb_enable_build_notifications; exit 37' \
    _ "$root/lib/kernel-build-common.sh" || rc=$?
[[ "$rc" -eq 37 ]]
[[ "$(wc -l < "$TEST_SOUND_LOG")" -eq 1 ]]
grep -Fq "canberra -f $work/sounds/service-logout.oga" "$TEST_SOUND_LOG"

# Player fallback: libcanberra unavailable, PipeWire succeeds.
: > "$TEST_SOUND_LOG"
TEST_CANBERRA_RC=1 bash -c 'set -euo pipefail; source "$1"; kb_enable_build_notifications; exit 0' \
    _ "$root/lib/kernel-build-common.sh"
[[ "$(wc -l < "$TEST_SOUND_LOG")" -eq 2 ]]
grep -Fq "pipewire $work/sounds/complete.oga" "$TEST_SOUND_LOG"

# Even if all players fail, the build's status must remain unchanged.
: > "$TEST_SOUND_LOG"
rc=0
TEST_CANBERRA_RC=1 TEST_PIPEWIRE_RC=1 TEST_PULSE_RC=1 \
    bash -c 'set -euo pipefail; source "$1"; kb_enable_build_notifications; exit 23' \
    _ "$root/lib/kernel-build-common.sh" || rc=$?
[[ "$rc" -eq 23 ]]
[[ "$(wc -l < "$TEST_SOUND_LOG")" -eq 3 ]]

# Missing sound files mean silence, even if players are available.
: > "$TEST_SOUND_LOG"
KB_BUILD_SOUND_DIR="$work/absent" bash -c \
    'set -euo pipefail; source "$1"; kb_enable_build_notifications; exit 0' \
    _ "$root/lib/kernel-build-common.sh"
[[ ! -s "$TEST_SOUND_LOG" ]]

# Real CLI early failure with -b produces failure notification on both builders.
for builder in centos-kernel-build upstream-kernel-build; do
    : > "$TEST_SOUND_LOG"
    rc=0
    env -u KERNEL_WORKSPACE_DIR -u KERNEL_SRC_DIR -u KERNEL_BUILD_DIR \
        "$root/$builder" -b >"$work/$builder.log" 2>&1 || rc=$?
    [[ "$rc" -ne 0 ]]
    grep -Fq "canberra -f $work/sounds/service-logout.oga" "$TEST_SOUND_LOG"
    [[ "$(wc -l < "$TEST_SOUND_LOG")" -eq 1 ]]
done

# Non-build commands have no audible completion.
for builder in centos-kernel-build upstream-kernel-build; do
    : > "$TEST_SOUND_LOG"
    "$root/$builder" -V >/dev/null
    [[ ! -s "$TEST_SOUND_LOG" ]]
done
: > "$TEST_SOUND_LOG"
rc=0
env -u KERNEL_WORKSPACE_DIR -u KERNEL_SRC_DIR -u KERNEL_BUILD_DIR \
    "$root/centos-kernel-build" -c >"$work/config.log" 2>&1 || rc=$?
[[ "$rc" -ne 0 ]]
[[ ! -s "$TEST_SOUND_LOG" ]]

echo 'Build completion sounds, fallbacks, exit status, and both builder CLI paths passed.'
