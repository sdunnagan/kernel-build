#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/lib/kernel-build-common.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The default is CPU-affinity aware; Python subprocess inherits this shell's affinity.
unset KERNEL_BUILD_JOBS
expected="$(python3 - <<'PY'
import os
print(len(os.sched_getaffinity(0)))
PY
)"
kb_resolve_build_jobs
[[ "$KERNEL_BUILD_JOBS" == "$expected" ]] || fail "affinity: got $KERNEL_BUILD_JOBS; expected $expected"

# Restrict to one permitted CPU and confirm the count is not the host total.
if command -v taskset >/dev/null 2>&1; then
    cpu="$(python3 - <<'PY'
import os
print(min(os.sched_getaffinity(0)))
PY
)"
    got="$(taskset -c "$cpu" bash -c '
        source "$1"
        unset KERNEL_BUILD_JOBS
        kb_resolve_build_jobs
        printf "%s\n" "$KERNEL_BUILD_JOBS"
    ' bash "$root/lib/kernel-build-common.sh")"
    [[ "$got" == 1 ]] || fail "taskset affinity returned $got instead of 1"
fi

# If the OS cannot report affinity, use os.cpu_count() as requested.
(
    system_python="$(command -v python3)"
    python3() {
        "$system_python" -c 'import os,sys; os.sched_getaffinity=lambda _: (_ for _ in ()).throw(OSError("unsupported")); os.cpu_count=lambda:5; exec(sys.stdin.read())'
    }
    unset KERNEL_BUILD_JOBS
    kb_resolve_build_jobs
    [[ "$KERNEL_BUILD_JOBS" == 5 ]] || fail 'os.cpu_count fallback'
)

# An explicit override takes precedence over CPU discovery.
KERNEL_BUILD_JOBS=10
kb_resolve_build_jobs
[[ "$KERNEL_BUILD_JOBS" == 10 ]] || fail 'KERNEL_BUILD_JOBS=10 override'

# If Python is unavailable/broken, fall back to nproc.
(
    python3() { return 1; }
    nproc() { echo 7; }
    unset KERNEL_BUILD_JOBS
    kb_resolve_build_jobs
    [[ "$KERNEL_BUILD_JOBS" == 7 ]] || fail 'nproc fallback'
)

# Verify actual *make* descendants receive reduced priority and the requested
# target architecture / parallelism. Use a fake make so no kernel sources are needed.
mkdir -p "$work/bin"
cat > "$work/bin/make" <<'MAKE'
#!/usr/bin/env bash
python3 - "$@" <<'PY'
import os, sys
with open(os.environ['MAKE_RECORD'], 'a') as f:
    f.write(f"nice={os.getpriority(os.PRIO_PROCESS, 0)} args={' '.join(sys.argv[1:])}\n")
PY
exit "${MAKE_EXIT:-0}"
MAKE
chmod +x "$work/bin/make"
export MAKE_RECORD="$work/make.log"
export PATH="$work/bin:$PATH"
for arch in x86 arm64; do
    kb_make -j12 "ARCH=$arch" test-target || fail 'make invocation failed'
done
[[ $(wc -l < "$MAKE_RECORD") -eq 2 ]] || fail 'expected two invocations'
grep -Eq 'nice=1[0-9] args=-j12 ARCH=x86 test-target' "$MAKE_RECORD" || fail 'x86 priority/args'
grep -Eq 'nice=1[0-9] args=-j12 ARCH=arm64 test-target' "$MAKE_RECORD" || fail 'arm64 priority/args'

# Wrapping make must preserve failure exit codes.
if MAKE_EXIT=31 kb_make -j12 ARCH=arm64 failing-target; then
    fail 'failed make reported success'
else
    [[ $? == 31 ]] || fail 'make error status not preserved'
fi

# Both builder implementations should use the shared niceness wrapper,
# including the primary image/module compilation and staging make steps.
for kind in centos upstream; do
    grep -Fq 'kb_make' "$root/lib/kernel-build-$kind.sh" || fail "missing kb_make calls in $kind"
    if grep -Eq '^[[:space:]]*(if[[:space:]]+)?make[[:space:]]' "$root/lib/kernel-build-$kind.sh"; then
        fail "unwrapped make invocation in $kind"
    fi
done

echo 'CPU affinity, overrides, make niceness, native/cross selection and exit-code tests passed.'
