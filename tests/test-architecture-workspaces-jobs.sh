#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/lib/kernel-build-common.sh"
source "$root/lib/kernel-build-centos.sh"
kb_init_colors
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

eq() { [[ "$1" == "$2" ]] || { printf 'Expected <%s> but got <%s>\n' "$2" "$1" >&2; exit 1; }; }

# The same CS10 source tree has distinct out-of-tree build directories.
(
    unset KERNEL_SRC_DIR KERNEL_BUILD_DIR
    KERNEL_WORKSPACE_DIR="$work/with spaces"
    CS_VERSION=10
    centos_resolve_cs_version
    kb_resolve_platform '' x86_64
    centos_resolve_workspace_paths
    eq "$KERNEL_SRC_DIR" "$work/with spaces/centos-stream-10"
    eq "$KERNEL_BUILD_DIR" "$work/with spaces/build-centos-stream-10-x86_64"
)
(
    unset KERNEL_SRC_DIR KERNEL_BUILD_DIR
    KERNEL_WORKSPACE_DIR="$work/with spaces"
    CS_VERSION=10
    centos_resolve_cs_version
    kb_resolve_platform '' aarch64
    centos_resolve_workspace_paths
    eq "$KERNEL_SRC_DIR" "$work/with spaces/centos-stream-10"
    eq "$KERNEL_BUILD_DIR" "$work/with spaces/build-centos-stream-10-aarch64"
)
(
    unset KERNEL_SRC_DIR KERNEL_BUILD_DIR
    KERNEL_WORKSPACE_DIR="$work/with spaces"
    CS_VERSION=10
    centos_resolve_cs_version
    kb_resolve_platform orin-nano ''
    centos_resolve_workspace_paths
    eq "$KERNEL_BUILD_DIR" "$work/with spaces/build-centos-stream-10-aarch64"
)
# The old unsuffixed build-dir export must never be used accidentally.
if (
    KERNEL_WORKSPACE_DIR="$work/with spaces"
    KERNEL_BUILD_DIR="$work/with spaces/build-centos-stream-10"
    unset KERNEL_SRC_DIR
    centos_resolve_cs_version
    kb_resolve_platform '' aarch64
    centos_resolve_workspace_paths
) >"$work/legacy.log" 2>&1; then
    echo 'Expected unsuffixed legacy path to be refused' >&2; exit 1
fi
grep -q 'KERNEL_BUILD_DIR conflicts' "$work/legacy.log"

# The default follows the detected logical CPU affinity count.
(
    unset KERNEL_BUILD_JOBS
    kb_detect_available_cpus() { printf '12\n'; }
    kb_resolve_build_jobs
    eq "$KERNEL_BUILD_JOBS" 12
)
(
    KERNEL_BUILD_JOBS=8
    kb_detect_available_cpus() { printf '12\n'; }
    kb_resolve_build_jobs
    eq "$KERNEL_BUILD_JOBS" 8
)
(
    KERNEL_BUILD_JOBS=008
    kb_resolve_build_jobs
    eq "$KERNEL_BUILD_JOBS" 8
)
for invalid in 0 -1 abc 1.5; do
    if ( KERNEL_BUILD_JOBS="$invalid"; kb_resolve_build_jobs ) >"$work/jobs.log" 2>&1; then
        echo "Expected invalid KERNEL_BUILD_JOBS '$invalid' to fail" >&2; exit 1
    fi
done

# Every parallel make invocation uses the centralized count.
if rg -n -- '-j"\$\(nproc\)"' "$root/lib" >/dev/null 2>&1; then
    echo 'Old -j$(nproc) call remains' >&2; exit 1
fi

# Clone-only CLI smoke test: architecture change alters output dir, not source.
mkdir -p "$work/bin"
cat > "$work/bin/git" <<'GIT'
#!/usr/bin/env bash
if [[ "$1" == clone ]]; then mkdir -p "$4"; fi
GIT
chmod +x "$work/bin/git"
env -u KERNEL_SRC_DIR -u KERNEL_BUILD_DIR \
    CS_VERSION=10 KERNEL_WORKSPACE_DIR="$work/cross" LOG_DIR="$work/logs" \
    PATH="$work/bin:$PATH" "$root/centos-kernel-build" -a aarch64 -g -f demo \
    >"$work/cross.log"
grep -Fq "$work/cross/centos-stream-10" "$work/cross.log"
grep -Fq "$work/cross/build-centos-stream-10-aarch64" "$work/cross.log"
[[ -d "$work/cross/centos-stream-10" ]]

echo 'Architecture-specific workspaces, legacy rejection, job selection and cross-target CLI tests passed.'
