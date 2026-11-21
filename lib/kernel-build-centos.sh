#!/usr/bin/env bash

BRANCH_NAME="main"
DEBUG_CONFIG=false
DO_BUILD=false
DO_BUILD_RPM=false
DO_CLEAN=false
DO_CLONE=false
DO_CONFIG=false
FORK_NAME="redhat"
KERNEL_ARCH=""
KERNEL_CONFIG_FILE="$KB_OVERRIDES_FILE"
KERNEL_DESCRIPTION=""
KERNEL_GROUP=""
KERNEL_IMAGE_DEPLOY_NAME=""
KERNEL_IMAGE_PATH=""
KERNEL_IMAGE_REL_PATH=""
KERNEL_IMAGE_TARGET=""
KERNEL_PREFIX=""
KERNEL_RELEASE=""
LOCALVERSION=""
LOCALVERSION_TAG=""
LOG_DIR="${LOG_DIR:-$HOME/logs}"
LOG_FILE=""
PLATFORM=""
TARGET_ARCH_OVERRIDE=""
PREP_FOR_BACKPORTING=false
REPO_NAME=""
TARGET_ARCH=""
UPSTREAM_REPO_NAME="stable"

centos_usage()
{
    cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  -b                            Build the kernel (image, modules, and DTBs when applicable)
  -c                            Configure kernel
  -C                            Reset build directory (removes .config)
  -d                            Configure kernel for debugging (requires -c)
  -f <fork>                     CentOS Stream kernel fork
  -g                            Git clone
  -h                            Show help
  -l <localversion>             Set CONFIG_LOCALVERSION (without a leading '-')
  -a <arch>                     Target architecture (x86_64|aarch64|riscv64; default: host)
  -p <platform>                 Optional board preset (opi5plus|rpi4|orin-nano|vf2|arm-server)
  -r                            Build RPM packages
  -U <upstream-kernel-repo>     Upstream kernel repository (next|stable)
  -V                            Show kernel-build version
  -x                            Prepare for backporting

Environment:
  CS_VERSION=${CS_VERSION:-10} (supported: 9 or 10; defaults to 10)
  KERNEL_WORKSPACE_DIR=${KERNEL_WORKSPACE_DIR:-<required>} (parent of source and build directories)
  Source and build directories are derived from CS_VERSION and target arch.
  KERNEL_BUILD_JOBS=${KERNEL_BUILD_JOBS:-auto} (default: affinity-aware logical CPU count)
USAGE
    exit 0
}

# Select the public CentOS Stream source tree for the requested version.
centos_resolve_cs_version()
{
    CS_VERSION="${CS_VERSION:-10}"
    case "$CS_VERSION" in
        9|10)
            KERNEL_GROUP="centos-stream"
            REPO_NAME="centos-stream-${CS_VERSION}"
            KERNEL_DESCRIPTION="CentOS Stream ${CS_VERSION}"
            KERNEL_PREFIX="cs${CS_VERSION}"
            ;;
        *)
            kb_die "Unsupported CS_VERSION '${CS_VERSION}'. Use 9 or 10." 2
            ;;
    esac
}

# Source and build paths follow a single convention under the workspace.
# Refuse conflicting legacy variables instead of silently using a different
# source tree or overwriting an unexpected build directory.
centos_resolve_workspace_paths()
{
    [[ -n "${KERNEL_WORKSPACE_DIR:-}" ]] || \
        kb_die "Set KERNEL_WORKSPACE_DIR to the parent directory for this project." 2
    [[ -n "${TARGET_ARCH:-}" ]] || \
        kb_die "Resolve the target architecture before deriving workspace paths." 2

    local source_path="${KERNEL_WORKSPACE_DIR%/}/${REPO_NAME}"
    local build_path="${KERNEL_WORKSPACE_DIR%/}/build-${REPO_NAME}-${TARGET_ARCH}"

    if [[ -n "${KERNEL_SRC_DIR:-}" && "${KERNEL_SRC_DIR%/}" != "$source_path" ]]; then
        kb_die "KERNEL_SRC_DIR conflicts with derived path (${source_path}). Remove the old KERNEL_SRC_DIR export." 2
    fi
    if [[ -n "${KERNEL_BUILD_DIR:-}" && "${KERNEL_BUILD_DIR%/}" != "$build_path" ]]; then
        kb_die "KERNEL_BUILD_DIR conflicts with derived path (${build_path}). Remove the old KERNEL_BUILD_DIR export." 2
    fi

    KERNEL_SRC_DIR="$source_path"
    KERNEL_BUILD_DIR="$build_path"
    export KERNEL_SRC_DIR KERNEL_BUILD_DIR
}

centos_parse_args()
{
    while getopts ":a:bcCdf:ghl:p:rU:Vx" opt; do
        case "$opt" in
            a) TARGET_ARCH_OVERRIDE="$OPTARG" ;;
            b) DO_BUILD=true ;;
            c) DO_CONFIG=true ;;
            C) DO_CLEAN=true ;;
            d) DEBUG_CONFIG=true ;;
            f) FORK_NAME="${OPTARG%%:*}" ;;
            g) DO_CLONE=true ;;
            h) centos_usage ;;
            l)
                kb_validate_localversion_tag "$OPTARG"
                LOCALVERSION_TAG="$OPTARG"
                ;;
            p) PLATFORM="$OPTARG" ;;
            r) DO_BUILD_RPM=true ;;
            U)
                case "$OPTARG" in
                    stable|next) UPSTREAM_REPO_NAME="$OPTARG" ;;
                    *) kb_die "-U must be either 'stable' or 'next'" 2 ;;
                esac
                ;;
            V) kb_print_version; exit 0 ;;
            x) PREP_FOR_BACKPORTING=true ;;
            :) kb_die "Option -$OPTARG requires an argument" 2 ;;
            \?) kb_die "Unknown option -$OPTARG. Use -h for help." 2 ;;
            *) centos_usage ;;
        esac
    done

    shift $((OPTIND - 1))
    if (($# > 0)); then
        kb_die "Unexpected positional arguments: $*" 2
    fi

    if [[ -n "$LOCALVERSION_TAG" ]]; then
        LOCALVERSION="$(kb_normalize_localversion "$LOCALVERSION_TAG")"
    fi
}

centos_resolve_build_targets()
{
    KERNEL_ARCH="$(kb_arch_to_kernel_arch "$TARGET_ARCH")" || kb_die "Unsupported arch: ${TARGET_ARCH}" 2
}

centos_resolve_kernel_image()
{
    local image_rel_path

    if image_rel_path="$(kb_get_kbuild_image_rel_path "$KERNEL_SRC_DIR" "$KERNEL_BUILD_DIR" "$KERNEL_ARCH")"; then
        :
    else
        local rc=$?
        return "$rc"
    fi

    [[ -n "$image_rel_path" ]] || {
        echo "Error: Kbuild returned an empty kernel image path" >&2
        return 1
    }

    [[ "$image_rel_path" != /* ]] || {
        echo "Error: Kbuild returned an absolute kernel image path: ${image_rel_path}" >&2
        return 1
    }

    KERNEL_IMAGE_REL_PATH="$image_rel_path"
    KERNEL_IMAGE_PATH="${KERNEL_BUILD_DIR}/${KERNEL_IMAGE_REL_PATH}"
    KERNEL_IMAGE_TARGET="$(basename "$KERNEL_IMAGE_REL_PATH")"
    KERNEL_IMAGE_DEPLOY_NAME="$(kb_kernel_image_deploy_basename "$KERNEL_IMAGE_REL_PATH")"

    {
        echo "// KBUILD_IMAGE: ${KERNEL_IMAGE_REL_PATH}"
        echo "// KERNEL_IMAGE_TARGET: ${KERNEL_IMAGE_TARGET}"
    } >>"$LOG_FILE"
}

centos_resolve_platform()
{
    kb_resolve_platform "$PLATFORM" "$TARGET_ARCH_OVERRIDE"
}

centos_require_local_commands()
{
    local -a cmds=(make awk sed find tar grep cp rm mkdir)

    if [[ "$DO_BUILD" == true || "$DO_CONFIG" == true || "$DO_BUILD_RPM" == true ]]; then
        cmds+=(gcc ld bc perl python3 flex bison patch xz)
        if [[ -n "${CROSS_COMPILE:-}" ]]; then
            cmds+=("${CROSS_COMPILE}gcc" "${CROSS_COMPILE}ld")
        fi
    fi

    if [[ "$DO_BUILD_RPM" == true ]]; then
        cmds+=(rpmbuild)
    fi

    if [[ "$DO_CLONE" == true || "$PREP_FOR_BACKPORTING" == true ]]; then
        cmds+=(git)
    fi

    if [[ "$DO_BUILD" == true && -n "$DTB_REL_PATH" ]]; then
        cmds+=(dtc)
    fi

    kb_require_commands "${cmds[@]}"
}


centos_create_log_file()
{
    local ts gccv host

    ts="$(date +"%Y_%m_%d_%H%M%S")"
    if command -v "${CROSS_COMPILE:-}gcc" >/dev/null 2>&1; then
        gccv="$("${CROSS_COMPILE:-}gcc" --version | head -n 1 || true)"
    else
        gccv="<compiler not installed>"
    fi
    host="$(hostname -s 2>/dev/null || echo unknown)"

    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/${KERNEL_PREFIX}_kernel_build_${ts}.log"

    {
        echo "//---------------------------------------------------------------"
        echo "// ${KERNEL_DESCRIPTION} Build"
        echo "// kernel-build: ${KERNEL_BUILD_VERSION}"
        echo "// Date: $(date)"
        echo "// Host: ${host}"
        echo "// PLATFORM: ${PLATFORM}"
        echo "// HOST_ARCH: $(uname -m)"
        echo "// ARCH: ${TARGET_ARCH}"
        echo "// KERNEL_ARCH: ${KERNEL_ARCH}"
        echo "// BUILD_JOBS: ${KERNEL_BUILD_JOBS}"
        echo "// MAKE_NICE: 10"
        echo "// KERNEL_SRC_DIR =   ${KERNEL_SRC_DIR}"
        echo "// KERNEL_BUILD_DIR = ${KERNEL_BUILD_DIR}"
        echo "// CROSS_COMPILE: ${CROSS_COMPILE:-<none>}"
        echo "// GCC: ${gccv}"
        echo "// FORK: ${FORK_NAME}"
        echo "// CS_VERSION: ${CS_VERSION}"
        echo "// LOCALVERSION: ${LOCALVERSION:-<empty>}"
        echo "// KCONFIG FILE: ${KERNEL_CONFIG_FILE:-<none>}"
        echo "//---------------------------------------------------------------"
        echo
    } > "$LOG_FILE"
}

centos_git_remote_ensure()
{
    local name="$1"
    local url="$2"
    local fetch_refspec="${3:-}"

    if git -C "$KERNEL_SRC_DIR" remote get-url "$name" >/dev/null 2>&1; then
        git -C "$KERNEL_SRC_DIR" remote set-url "$name" "$url"
    else
        git -C "$KERNEL_SRC_DIR" remote add "$name" "$url"
    fi

    if [[ -n "$fetch_refspec" ]]; then
        # shellcheck disable=SC2206
        local refspecs=( $fetch_refspec )
        git -C "$KERNEL_SRC_DIR" fetch --quiet "$name" "${refspecs[@]}"
    else
        git -C "$KERNEL_SRC_DIR" fetch --quiet "$name"
    fi
}

centos_prepare_for_backporting()
{
    kb_status_begin "Preparing for backporting"

    [[ -d "$KERNEL_SRC_DIR" ]] || kb_die "Kernel source directory does not exist: ${KERNEL_SRC_DIR}" 1

    case "$CS_VERSION" in
        9)
            centos_git_remote_ensure cs9 "https://gitlab.com/redhat/centos-stream/src/kernel/centos-stream-9.git"
            ;;
        10)
            centos_git_remote_ensure cs10 "https://gitlab.com/redhat/centos-stream/src/kernel/centos-stream-10.git"
            ;;
    esac

    case "$UPSTREAM_REPO_NAME" in
        stable)
            centos_git_remote_ensure linux-stable "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git"
            ;;
        next)
            centos_git_remote_ensure linux-next "https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git" \
                "+refs/heads/*:refs/remotes/linux-next/* +refs/tags/*:refs/tags/*"
            ;;
        *)
            kb_die "Invalid upstream kernel repository '${UPSTREAM_REPO_NAME}'" 2
            ;;
    esac

    kb_status_end_ok "Preparing for backporting"

    echo
}

centos_clone_kernel_repos()
{
    local kernel_url
    local status_msg

    if [[ -d "$KERNEL_SRC_DIR" ]]; then
        echo "${YELLOW}${BOLD}WARNING:${NORMAL} ${KERNEL_SRC_DIR} already exists."
        read -r -p "Remove the existing workspace? Type 'yes' to confirm: " confirmation
        confirmation="${confirmation:-no}"
        if [[ "$confirmation" == "yes" ]]; then
            echo "${WHITE}Removing ${BRIGHT_BLUE}${BOLD}${KERNEL_SRC_DIR}${NORMAL}"
            echo "${WHITE}Removing ${BRIGHT_BLUE}${BOLD}${KERNEL_BUILD_DIR}${NORMAL}"
            rm -rf "$KERNEL_SRC_DIR" "$KERNEL_BUILD_DIR"
        else
            kb_die "Workspace was not removed." 1
        fi
    fi

    if [[ "$FORK_NAME" == "redhat" ]]; then
        kernel_url="https://gitlab.com/${FORK_NAME}/${KERNEL_GROUP}/src/kernel/${REPO_NAME}.git"
    else
        kernel_url="https://gitlab.com/${FORK_NAME}/${REPO_NAME}.git"
    fi

    status_msg="Cloning ${KERNEL_DESCRIPTION} kernel source tree"
    kb_status_begin "$status_msg"

    git clone --quiet "$kernel_url" "$KERNEL_SRC_DIR" \
        || kb_die "Cloning '${REPO_NAME}' failed. Check URL or permissions." 1

    git -C "$KERNEL_SRC_DIR" fetch --quiet origin "$BRANCH_NAME" \
        || kb_die "Remote branch '${BRANCH_NAME}' does not exist." 1

    git -C "$KERNEL_SRC_DIR" switch --quiet -C "$BRANCH_NAME" "origin/${BRANCH_NAME}" \
        || kb_die "Failed to switch to branch '${BRANCH_NAME}'." 1

    kb_status_end_ok "$status_msg"
    echo
}

centos_select_base_config()
{
    local pattern=""

    case "$CS_VERSION" in
        9)
            if [[ "$DEBUG_CONFIG" == true ]]; then
                pattern="kernel-5.*-${TARGET_ARCH}-debug.config"
            else
                pattern="kernel-5.*-${TARGET_ARCH}.config"
            fi
            ;;
        10)
            if [[ "$DEBUG_CONFIG" == true ]]; then
                pattern="kernel-6.*-${TARGET_ARCH}-debug.config"
            else
                pattern="kernel-6.*-${TARGET_ARCH}.config"
            fi
            ;;
    esac

    local config_file
    config_file="$(find "${KERNEL_SRC_DIR}/redhat/configs" -maxdepth 1 -name "$pattern" | sort | head -n1 || true)"
    [[ -n "$config_file" ]] || kb_die "No base config found matching redhat/configs/${pattern}" 1

    printf '%s
' "$config_file"
}

centos_generate_config()
{
    local rc
    local base_config_file
    local base_config_name

    kb_status_begin "   - Running dist-configs"
    if kb_make -C "$KERNEL_SRC_DIR" -j"$KERNEL_BUILD_JOBS" dist-configs >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Running dist-configs"
    else
        rc=$?
        kb_status_end_fail "   - Running dist-configs" "$rc"
        return "$rc"
    fi

    base_config_file="$(centos_select_base_config)"
    base_config_name="$(basename "$base_config_file")"
    echo "Base kernel config file: ${base_config_file}" >>"$LOG_FILE"
    echo
    echo "${WHITE}Base kernel config file: ${CYAN}${base_config_file}${NORMAL}"

    kb_status_begin "   - Seeding build config from ${base_config_name}"
    if cp "$base_config_file" "${KERNEL_BUILD_DIR}/" && cp "$base_config_file" "${KERNEL_BUILD_DIR}/.config"; then
        kb_status_end_ok "   - Seeding build config from ${base_config_name}"
    else
        rc=$?
        kb_status_end_fail "   - Seeding build config from ${base_config_name}" "$rc"
        return "$rc"
    fi
}

centos_run_olddefconfig()
{
    local rc
    local msg="   - Running olddefconfig"
    local -a olddefconfig_cmd=(
        kb_make
        -C "$KERNEL_SRC_DIR"
        O="$KERNEL_BUILD_DIR"
        ARCH="$KERNEL_ARCH"
    )

    if ! "${KERNEL_SRC_DIR}/scripts/config" \
        --file "${KERNEL_BUILD_DIR}/.config" \
        --set-str LOCALVERSION "" \
        --disable LOCALVERSION_AUTO >>"$LOG_FILE" 2>&1; then
        kb_die "Failed to sanitize LOCALVERSION before olddefconfig." 1
    fi

    if [[ -n "${CROSS_COMPILE:-}" ]]; then
        olddefconfig_cmd+=( CROSS_COMPILE="${CROSS_COMPILE}" )
    fi

    olddefconfig_cmd+=( olddefconfig )

    echo "olddefconfig command: KCONFIG_NONINTERACTIVE=1 ${olddefconfig_cmd[*]}" >>"$LOG_FILE"

    kb_status_begin "$msg"
    if KCONFIG_NONINTERACTIVE=1 "${olddefconfig_cmd[@]}" >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "$msg"
    else
        rc=$?
        kb_status_end_fail "$msg" "$rc"
        return "$rc"
    fi
}

centos_configure_kernel()
{
    local rc

    echo "${WHITE}Configuring kernel:${NORMAL}"
    echo "${WHITE}   - Log file: ${CYAN}${LOG_FILE}${NORMAL}"

    kb_status_begin "   - Resetting build directory"
    if rm -rf "$KERNEL_BUILD_DIR" && mkdir -p "$KERNEL_BUILD_DIR"; then
        kb_status_end_ok "   - Resetting build directory"
    else
        rc=$?
        kb_status_end_fail "   - Resetting build directory" "$rc"
        return "$rc"
    fi

    centos_generate_config || return $?

    kb_status_begin "   - Applying bundled kernel overrides"
    if kb_apply_configs "$KERNEL_SRC_DIR" "${KERNEL_BUILD_DIR}/.config" "$KERNEL_CONFIG_FILE" "centos" "$PLATFORM" "$TARGET_ARCH" >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Applying bundled kernel overrides"
    else
        rc=$?
        kb_status_end_fail "   - Applying bundled kernel overrides" "$rc"
        return "$rc"
    fi

    if [[ "$DEBUG_CONFIG" == true ]]; then
        kb_status_begin "   - Applying debug config"
        if kb_configure_kernel_for_debug "$KERNEL_SRC_DIR" "$KERNEL_BUILD_DIR" "$KERNEL_ARCH" >>"$LOG_FILE" 2>&1; then
            kb_status_end_ok "   - Applying debug config"
        else
            rc=$?
            kb_status_end_fail "   - Applying debug config" "$rc"
            return "$rc"
        fi
    fi

    centos_clean_source_tree || return $?
    centos_run_olddefconfig || return $?

    kb_status_begin "   - Applying localversion config"
    if kb_apply_localversion_config "$KERNEL_SRC_DIR" "${KERNEL_BUILD_DIR}/.config" "$LOCALVERSION" >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Applying localversion config"
    else
        rc=$?
        kb_status_end_fail "   - Applying localversion config" "$rc"
        return "$rc"
    fi

    kb_status_begin "   - Building ctags"
    if kb_build_ctags "$KERNEL_SRC_DIR" "$KERNEL_BUILD_DIR" >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Building ctags"
    else
        rc=$?
        kb_status_end_fail "   - Building ctags" "$rc"
        return "$rc"
    fi

    echo
}

centos_clean_kernel()
{
    local rc

    echo "${WHITE}Cleaning kernel build:${NORMAL}"
    echo "${WHITE}   - Log file: ${CYAN}${LOG_FILE}${NORMAL}"

    kb_status_begin "   - Resetting build directory"

    rm -rf "$KERNEL_BUILD_DIR"
    mkdir -p "$KERNEL_BUILD_DIR"

    if [[ $? -eq 0 ]]; then
        kb_status_end_ok "   - Resetting build directory"
    else
        rc=$?
        kb_status_end_fail "   - Resetting build directory" "$rc"
        return "$rc"
    fi

    echo
}

centos_clean_source_tree()
{
    local rc
    local msg="   - Cleaning source tree"

    kb_status_begin "$msg"
    if kb_make -C "$KERNEL_SRC_DIR" ARCH="$KERNEL_ARCH" mrproper >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "$msg"
    else
        rc=$?
        kb_status_end_fail "$msg" "$rc"
        return "$rc"
    fi
}

centos_ensure_localversion_matches_for_build()
{
    if kb_config_has_desired_localversion "${KERNEL_BUILD_DIR}/.config" "$LOCALVERSION"; then
        return 0
    fi

    local cfg="${KERNEL_BUILD_DIR}/.config"
    local current

    current="$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "$cfg" | tail -n1)"

    echo "Error: .config LOCALVERSION state does not match requested value." >&2
    echo "  requested: ${LOCALVERSION:-<empty>}" >&2
    echo "  current:   ${current:-<unset>}" >&2
    echo "  note:      CONFIG_LOCALVERSION_AUTO may still be enabled" >&2
    echo "Run with -c first to update the config." >&2
    return 2
}

centos_stage_modules()
{
    local rc
    local stage_dir="${KERNEL_BUILD_DIR}/modules_staging"

    kb_status_begin "   - Resetting modules staging"
    if rm -rf "$stage_dir" && mkdir -p "$stage_dir"; then
        kb_status_end_ok "   - Resetting modules staging"
    else
        rc=$?
        kb_status_end_fail "   - Resetting modules staging" "$rc"
        return "$rc"
    fi

    kb_status_begin "   - Staging modules"
    if kb_make -C "$KERNEL_SRC_DIR" -j"$KERNEL_BUILD_JOBS" O="$KERNEL_BUILD_DIR" ARCH="$KERNEL_ARCH" \
        INSTALL_MOD_PATH="$stage_dir" modules_install >>"$LOG_FILE" 2>&1; then
        sudo chown -R "$(id -u):$(id -g)" "$stage_dir" >/dev/null 2>&1 || true
        kb_status_end_ok "   - Staging modules"
    else
        rc=$?
        kb_status_end_fail "   - Staging modules" "$rc"
        return "$rc"
    fi
}

centos_set_kernel_release_from_staged_modules()
{
    local modules_root="${KERNEL_BUILD_DIR}/modules_staging/lib/modules"

    [[ -d "$modules_root" ]] || kb_die "kernel modules not staged (${modules_root})" 1

    local -a module_dirs=("$modules_root"/*)
    [[ ${#module_dirs[@]} -eq 1 ]] || kb_die "expected exactly 1 modules dir, found ${#module_dirs[@]}" 1

    KERNEL_RELEASE="$(basename "${module_dirs[0]}")"
}

centos_build_dtbs()
{
    local rc
    local deploy_dtbs_dir="${KERNEL_BUILD_DIR}/deploy/dtbs"

    if [[ -z "${DTB_REL_PATH:-}" ]]; then
        # Avoid exposing stale DTBs when a build directory is reused for an
        # ACPI/UEFI platform that does not use a board DTB.
        rm -rf "$deploy_dtbs_dir"
        return 0
    fi

    kb_status_begin "   - Building DTBs"
    if kb_make -C "$KERNEL_SRC_DIR" -j"$KERNEL_BUILD_JOBS" \
        O="$KERNEL_BUILD_DIR" ARCH="$KERNEL_ARCH" DTC_FLAGS="-@" \
        dtbs >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Building DTBs"
    else
        rc=$?
        kb_status_end_fail "   - Building DTBs" "$rc"
        return "$rc"
    fi

    kb_status_begin "   - Installing DTBs into deploy/dtbs"
    if mkdir -p "$deploy_dtbs_dir" &&
        kb_make -C "$KERNEL_SRC_DIR" \
            O="$KERNEL_BUILD_DIR" ARCH="$KERNEL_ARCH" DTC_FLAGS="-@" \
            INSTALL_DTBS_PATH="$deploy_dtbs_dir" \
            dtbs_install >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Installing DTBs into deploy/dtbs"
    else
        rc=$?
        kb_status_end_fail "   - Installing DTBs into deploy/dtbs" "$rc"
        return "$rc"
    fi
}

centos_collect_rpms()
{
    local rc
    local rpm_dir="${KERNEL_BUILD_DIR}/deploy/rpms"
    local rpm_src_dir="${KERNEL_BUILD_DIR}/rpmbuild/RPMS/${TARGET_ARCH}"
    local -a rpm_files=()

    [[ "$DO_BUILD_RPM" == true ]] || return 0

    kb_status_begin "   - Building RPM packages"
    if kb_make -C "$KERNEL_SRC_DIR" -j"$KERNEL_BUILD_JOBS" O="$KERNEL_BUILD_DIR" ARCH="$KERNEL_ARCH" binrpm-pkg >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Building RPM packages"
    else
        rc=$?
        kb_status_end_fail "   - Building RPM packages" "$rc"
        return "$rc"
    fi

    kb_status_begin "   - Collecting RPM packages"
    if ! mkdir -p "$rpm_dir"; then
        rc=$?
        kb_status_end_fail "   - Collecting RPM packages" "$rc"
        return "$rc"
    fi

    mapfile -t rpm_files < <(find "$rpm_src_dir" -maxdepth 1 -type f -name '*.rpm' -print 2>/dev/null)
    if ((${#rpm_files[@]} == 0)); then
        {
            echo "No RPM files found under: ${rpm_src_dir}"
            echo "Expected binrpm-pkg output under: ${KERNEL_BUILD_DIR}/rpmbuild/RPMS/${TARGET_ARCH}"
        } >>"$LOG_FILE"
        kb_status_end_fail "   - Collecting RPM packages" 1
        return 1
    fi

    if cp -v "${rpm_files[@]}" "$rpm_dir"/ >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Collecting RPM packages"
    else
        rc=$?
        kb_status_end_fail "   - Collecting RPM packages" "$rc"
        return "$rc"
    fi
}

centos_copy_build_artifacts()
{
    local deploy_dir="${KERNEL_BUILD_DIR}/deploy"
    local kernel_image_dst

    kernel_image_dst="${deploy_dir}/${KERNEL_IMAGE_DEPLOY_NAME}-${KERNEL_PREFIX}-${KERNEL_RELEASE}"

    mkdir -p "$deploy_dir"

    [[ -f "$KERNEL_IMAGE_PATH" ]] || kb_die "kernel image not found at ${KERNEL_IMAGE_PATH}" 1

    kb_status_begin "   - Copying build artifacts into deploy/"
    if cp "$KERNEL_IMAGE_PATH" "$kernel_image_dst"; then
        kb_status_end_ok "   - Copying build artifacts into deploy/"
    else
        local rc=$?
        kb_status_end_fail "   - Copying build artifacts into deploy/" "$rc"
        return "$rc"
    fi

    {
        echo
        echo "Build artifacts copied to:"
        echo "  ${kernel_image_dst}"
        if [[ -d "${deploy_dir}/dtbs" ]]; then
            echo "  ${deploy_dir}/dtbs/"
        fi
        if [[ -d "${deploy_dir}/rpms" ]]; then
            echo "  ${deploy_dir}/rpms/"
        fi
        echo
    } >>"$LOG_FILE"

    echo
    echo "${WHITE}Build artifacts copied to:${CYAN}"
    echo "  ${kernel_image_dst}"
    if [[ -d "${deploy_dir}/dtbs" ]]; then
        echo "  ${deploy_dir}/dtbs/"
    fi
    if [[ -d "${deploy_dir}/rpms" ]]; then
        echo "  ${deploy_dir}/rpms/"
    fi
    echo "${NORMAL}"
}

centos_build_kernel()
{
    local rc
    local start end duration
    local -a make_base_cmd=(
        kb_make -C "$KERNEL_SRC_DIR" -j"$KERNEL_BUILD_JOBS"
        O="$KERNEL_BUILD_DIR" ARCH="$KERNEL_ARCH" ENABLE_WERROR=
    )

    echo "${WHITE}Building ${KERNEL_DESCRIPTION} kernel:${NORMAL}"
    echo "${WHITE}   - Log file: ${CYAN}${LOG_FILE}${NORMAL}"

    local compiler_setup_msg
    compiler_setup_msg="$(kb_compiler_setup_message)"
    kb_status_begin "$compiler_setup_msg"
    if kb_setup_cross_compile "$TARGET_ARCH" >/dev/null 2>&1; then
        kb_status_end_ok "$compiler_setup_msg"
    else
        rc=$?
        kb_status_end_fail "$compiler_setup_msg" "$rc"
        return "$rc"
    fi

    kb_status_begin "   - Ensuring localversion config"
    if kb_apply_localversion_config "$KERNEL_SRC_DIR" "${KERNEL_BUILD_DIR}/.config" "$LOCALVERSION" >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Ensuring localversion config"
    else
        rc=$?
        kb_status_end_fail "   - Ensuring localversion config" "$rc"
        return "$rc"
    fi

    kb_status_begin "   - Resolving Kbuild kernel image"
    if centos_resolve_kernel_image; then
        kb_status_end_ok "   - Resolving Kbuild kernel image"
    else
        rc=$?
        kb_status_end_fail "   - Resolving Kbuild kernel image" "$rc"
        return "$rc"
    fi

    kb_status_begin "   - Building kernel ${KERNEL_IMAGE_TARGET}"
    start="$(date +%s)"
    if KCONFIG_NONINTERACTIVE=1 "${make_base_cmd[@]}" "$KERNEL_IMAGE_TARGET" >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Building kernel ${KERNEL_IMAGE_TARGET}"
    else
        rc=$?
        kb_status_end_fail "   - Building kernel ${KERNEL_IMAGE_TARGET}" "$rc"
        return "$rc"
    fi

    kb_status_begin "   - Building modules"
    if KCONFIG_NONINTERACTIVE=1 "${make_base_cmd[@]}" modules >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Building modules"
    else
        rc=$?
        kb_status_end_fail "   - Building modules" "$rc"
        return "$rc"
    fi

    centos_stage_modules || return $?
    centos_set_kernel_release_from_staged_modules
    centos_build_dtbs || return $?
    centos_collect_rpms || return $?
    centos_copy_build_artifacts || return $?

    end="$(date +%s)"
    duration=$((end - start))

    {
        echo
        echo "// KERNEL_RELEASE: ${KERNEL_RELEASE}"
        echo "// Build time: $((duration/60)) min, $((duration%60)) sec"
        echo
    } >>"$LOG_FILE"

    echo "${WHITE}Build time: ${CYAN}$((duration/60)) min, $((duration%60)) sec${NORMAL}"
    echo
}

centos_main()
{
    kb_init_colors
    centos_parse_args "$@"
    kb_print_version

    if [[ "$DO_BUILD" == true ]]; then
        kb_enable_build_notifications
    fi

    centos_resolve_cs_version
    centos_resolve_platform
    centos_resolve_workspace_paths
    kb_resolve_build_jobs

    kb_validate_architecture "$TARGET_ARCH"
    kb_setup_cross_compile "$TARGET_ARCH" >/dev/null 2>&1 || kb_die "Unable to configure compiler for target architecture: ${TARGET_ARCH}" 2
    centos_resolve_build_targets
    kb_set_dtb_paths
    centos_require_local_commands

    if [[ "$DEBUG_CONFIG" == true ]]; then
        [[ "$DO_CONFIG" == true ]] || kb_die "-d requires -c" 2
    fi

    # Fail before touching the build tree if the bundled config is missing.
    if [[ "$DO_CONFIG" == true && ! -f "$KERNEL_CONFIG_FILE" ]]; then
        kb_die "Missing kernel overrides file: ${KERNEL_CONFIG_FILE}" 2
    fi

    echo
    echo "${WHITE}KERNEL_SRC_DIR:   ${CYAN}${KERNEL_SRC_DIR}${NORMAL}"
    echo "${WHITE}KERNEL_BUILD_DIR: ${CYAN}${KERNEL_BUILD_DIR}${NORMAL}"
    if [[ "$DO_CONFIG" == true || "$DO_BUILD" == true || "$DO_BUILD_RPM" == true ]]; then
        echo "${WHITE}BUILD_JOBS:       ${CYAN}${KERNEL_BUILD_JOBS}${NORMAL}"
        echo "${WHITE}MAKE_NICE:        ${CYAN}10${NORMAL}"
    fi
    echo

    centos_create_log_file

    if [[ "$DO_CLONE" == true ]]; then
        centos_clone_kernel_repos
    fi

    if [[ "$PREP_FOR_BACKPORTING" == true ]]; then
        centos_prepare_for_backporting
    fi

    [[ -d "$KERNEL_SRC_DIR" ]] || kb_die "KERNEL_SRC_DIR does not exist: ${KERNEL_SRC_DIR}" 1

    if [[ "$DO_CLEAN" == true ]]; then
        centos_clean_kernel
    fi

    if [[ "$DO_CONFIG" == true ]]; then
        centos_configure_kernel
        kb_record_build_target "$KERNEL_BUILD_DIR" "$TARGET_ARCH" "$PLATFORM"
    fi

    if [[ "$DO_BUILD" == true ]]; then
        kb_assert_build_target "$KERNEL_BUILD_DIR" "$TARGET_ARCH" "$PLATFORM"
        [[ -f "${KERNEL_BUILD_DIR}/.config" ]] || kb_die "No existing .config found in ${KERNEL_BUILD_DIR}. Run with -c first." 1
        kb_set_orin_nano_performance_mode
        centos_build_kernel
        echo
    fi

    kb_done
}
