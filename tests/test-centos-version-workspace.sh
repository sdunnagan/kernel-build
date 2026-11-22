#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/lib/kernel-build-common.sh"
source "$root/lib/kernel-build-centos.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

assert_eq() {
    [[ "$1" == "$2" ]] || { printf 'Expected <%s>, got <%s>\n' "$2" "$1" >&2; exit 1; }
}

# Only a workspace is needed for CS10 (the default) or explicit CS9.
(
    unset CS_VERSION KERNEL_SRC_DIR KERNEL_BUILD_DIR
    KERNEL_WORKSPACE_DIR="$work/default"
    centos_resolve_cs_version
    kb_resolve_platform "" ""
    centos_resolve_workspace_paths
    assert_eq "$CS_VERSION" 10
    assert_eq "$REPO_NAME" centos-stream-10
    assert_eq "$KERNEL_PREFIX" cs10
    assert_eq "$KERNEL_SRC_DIR" "$work/default/centos-stream-10"
    assert_eq "$KERNEL_BUILD_DIR" "$work/default/build-centos-stream-10-$(uname -m)"
)
(
    CS_VERSION=9
    unset KERNEL_SRC_DIR KERNEL_BUILD_DIR
    KERNEL_WORKSPACE_DIR="$work/cs9/"
    centos_resolve_cs_version
    kb_resolve_platform "" ""
    centos_resolve_workspace_paths
    assert_eq "$REPO_NAME" centos-stream-9
    assert_eq "$KERNEL_PREFIX" cs9
    assert_eq "$KERNEL_SRC_DIR" "$work/cs9/centos-stream-9"
    assert_eq "$KERNEL_BUILD_DIR" "$work/cs9/build-centos-stream-9-$(uname -m)"
)

# Matching legacy exports remain harmless during migration; conflicting
# values must never override the derived paths.
(
    CS_VERSION=10
    KERNEL_WORKSPACE_DIR="$work/legacy"
    KERNEL_SRC_DIR="$work/legacy/centos-stream-10"
    KERNEL_BUILD_DIR="$work/legacy/build-centos-stream-10-$(uname -m)"
    centos_resolve_cs_version
    kb_resolve_platform "" ""
    centos_resolve_workspace_paths
    assert_eq "$KERNEL_SRC_DIR" "$work/legacy/centos-stream-10"
    assert_eq "$KERNEL_BUILD_DIR" "$work/legacy/build-centos-stream-10-$(uname -m)"
)
if ( CS_VERSION=8; centos_resolve_cs_version ) >/dev/null 2>&1; then
    echo 'Expected unsupported version to fail' >&2; exit 1
fi
if (
    unset KERNEL_WORKSPACE_DIR KERNEL_SRC_DIR KERNEL_BUILD_DIR
    CS_VERSION=10
    centos_resolve_cs_version
    kb_resolve_platform "" ""
    centos_resolve_workspace_paths
) >/dev/null 2>&1; then
    echo 'Expected missing workspace to fail' >&2; exit 1
fi
for conflict in source build; do
    if (
        CS_VERSION=10
        KERNEL_WORKSPACE_DIR="$work/conflict"
        unset KERNEL_SRC_DIR KERNEL_BUILD_DIR
        case "$conflict" in
            source) KERNEL_SRC_DIR="$work/wrong/centos-stream-10" ;;
            build) KERNEL_BUILD_DIR="$work/wrong/build-centos-stream-10-$(uname -m)" ;;
        esac
        centos_resolve_cs_version
        centos_resolve_workspace_paths
    ) >/dev/null 2>&1; then
        echo "Expected conflicting $conflict directory to fail" >&2; exit 1
    fi
done

# Simulate clone and backport remote setup without network operations.
(
    CS_VERSION=10
    unset KERNEL_SRC_DIR KERNEL_BUILD_DIR
    KERNEL_WORKSPACE_DIR="$work/clone"
    mkdir -p "$KERNEL_WORKSPACE_DIR"
    FORK_NAME='sdunnaga-rhel-293896'
    UPSTREAM_REPO_NAME=stable
    centos_resolve_cs_version
    kb_resolve_platform "" ""
    centos_resolve_workspace_paths
    git() {
        printf '%s\n' "$*" >> "$work/git-operations"
        if [[ "$1" == clone ]]; then
            mkdir -p "$4"
        elif [[ "$1" == -C && "$3" == remote && "$4" == get-url ]]; then
            return 1
        fi
    }
    kb_init_colors
    centos_clone_kernel_repos >/dev/null
    centos_prepare_for_backporting >/dev/null
)
grep -Fq 'https://gitlab.com/sdunnaga-rhel-293896/centos-stream-10.git' "$work/git-operations"
grep -Fq 'switch --quiet -C main origin/main' "$work/git-operations"
grep -Fq 'https://gitlab.com/redhat/centos-stream/src/kernel/centos-stream-10.git' "$work/git-operations"
grep -Fq 'https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git' "$work/git-operations"
[[ "$(grep -cF 'https://' "$work/git-operations")" == 3 ]]

# CLI compatibility: -s and -z are no longer supported, while -V works.
assert_eq "$("$root/centos-kernel-build" -V)" 'kernel-build 1.0.0'
for option in -s -z; do
    if "$root/centos-kernel-build" "$option" >"$work/cli.log" 2>&1; then
        echo "Expected removed option $option to fail" >&2; exit 1
    fi
    grep -Fq "Unknown option $option" "$work/cli.log"
done
printf 'CentOS Stream version, workspace paths, public remotes and CLI tests passed.\n'

# End-to-end clone-only CLI tests with fake Git. Check CS10 default, CS9
# selection, paths with spaces, and behavior of conflicting legacy exports.
mkdir -p "$work/bin" "$work/cli workspace" "$work/cli-cs9"
cat > "$work/bin/git" <<'GIT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_GIT_LOG"
if [[ "$1" == clone ]]; then mkdir -p "$4"; fi
GIT
chmod +x "$work/bin/git"
export TEST_GIT_LOG="$work/cli-git.log"
env -u CS_VERSION -u KERNEL_SRC_DIR -u KERNEL_BUILD_DIR \
    KERNEL_WORKSPACE_DIR="$work/cli workspace" LOG_DIR="$work/logs" \
    PATH="$work/bin:$PATH" "$root/centos-kernel-build" \
    -g -f sdunnaga-rhel-293896 >"$work/cli-clone.log"
[[ -d "$work/cli workspace/centos-stream-10" ]]
grep -Fq 'clone --quiet https://gitlab.com/sdunnaga-rhel-293896/centos-stream-10.git' "$TEST_GIT_LOG"
[[ -f "$(find "$work/logs" -maxdepth 1 -name 'cs10_kernel_build_*.log' -print -quit)" ]]

env -u KERNEL_SRC_DIR -u KERNEL_BUILD_DIR \
    CS_VERSION=9 KERNEL_WORKSPACE_DIR="$work/cli-cs9" LOG_DIR="$work/logs" \
    PATH="$work/bin:$PATH" "$root/centos-kernel-build" \
    -g -f sdunnaga-rhel-293896 >"$work/cli-cs9.log"
[[ -d "$work/cli-cs9/centos-stream-9" ]]
grep -Fq 'clone --quiet https://gitlab.com/sdunnaga-rhel-293896/centos-stream-9.git' "$TEST_GIT_LOG"

if env CS_VERSION=10 KERNEL_WORKSPACE_DIR="$work/wrong" \
    KERNEL_SRC_DIR="$work/incorrect/centos-stream-10" \
    KERNEL_BUILD_DIR="$work/wrong/build-centos-stream-10-$(uname -m)" \
    PATH="$work/bin:$PATH" "$root/centos-kernel-build" -g \
    >"$work/conflicting-cli.log" 2>&1; then
    echo 'Expected contradictory legacy source directory to be rejected' >&2; exit 1
fi
grep -q 'KERNEL_SRC_DIR conflicts' "$work/conflicting-cli.log"

printf 'End-to-end CS9/CS10 clone command and stale environment tests passed (mock Git).\n'
