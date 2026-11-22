#!/usr/bin/env bash

KERNEL_BUILD_VERSION="1.0.0"

# The single shared overrides file is part of the builder installation.
# Resolve it relative to the common library so invocation directory and
# workspace paths do not affect configuration selection.
KB_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
KB_OVERRIDES_FILE="${KB_PROJECT_ROOT}/configs/kernel-overrides.txt"

# Python follows the same CPU affinity mask as this shell process. On Fedora,
# os.sched_getaffinity(0) counts all permitted logical CPUs, including SMT
# siblings. Use os.cpu_count() only if affinity information is unavailable.
# The nproc fallback keeps the builder usable if Python is not installed.
kb_detect_available_cpus()
{
    local count=""
    if command -v python3 >/dev/null 2>&1; then
        count="$(python3 - <<'PYTHON'
import os
try:
    count = len(os.sched_getaffinity(0))
except (AttributeError, OSError):
    count = os.cpu_count()
print(count or 1)
PYTHON
)" || count=""
    fi
    if [[ ! "$count" =~ ^[0-9]+$ ]] || (( count < 1 )); then
        count="$(nproc 2>/dev/null)" || count=""
    fi
    if [[ ! "$count" =~ ^[0-9]+$ ]] || (( count < 1 )); then
        count=1
    fi
    printf '%s\n' "$count"
}

# Default to all available logical CPUs (12 on unrestricted shire). Allow a
# caller to cap concurrent make jobs: KERNEL_BUILD_JOBS=8.
kb_resolve_build_jobs()
{
    local jobs="${KERNEL_BUILD_JOBS:-}"
    if [[ -z "$jobs" ]]; then
        jobs="$(kb_detect_available_cpus)"
    fi
    if [[ ! "$jobs" =~ ^[0-9]+$ ]] || (( 10#$jobs < 1 )); then
        kb_die "KERNEL_BUILD_JOBS must be a positive integer (got '${jobs}')." 2
    fi
    # Strip leading zeroes to avoid Bash interpreting numbers as octal.
    KERNEL_BUILD_JOBS="$((10#$jobs))"
}

# Lower *make* and all of its descendants to nice level +10. This applies
# equally to native and cross-compiled builds, without slowing clone-only Git
# operations or changing the parent interactive shell's scheduling priority.
# If nice is unavailable, preserve build behavior rather than refusing to run.
kb_make()
{
    if command -v nice >/dev/null 2>&1; then
        nice -n 10 make "$@"
    else
        make "$@"
    fi
}

kb_print_version()
{
    printf '%skernel-build %s%s\n' "${WHITE:-}" "$KERNEL_BUILD_VERSION" "${NORMAL:-}"
}

# Keep compiler setup messages accurate for native and cross-compiled builds.
# The cross-compiler prefix is established by kb_setup_cross_compile() during
# startup, before a build begins.
kb_compiler_setup_message()
{
    if [[ -n "${CROSS_COMPILE:-}" ]]; then
        printf '   - Preparing cross-compile environment\n'
    else
        printf '   - Preparing native compiler environment\n'
    fi
}

kb_init_colors()
{
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        BLACK=$(tput setaf 0)
        RED=$(tput setaf 1)
        GREEN=$(tput setaf 2)
        YELLOW=$(tput setaf 3)
        LIME_YELLOW=$(tput setaf 190 2>/dev/null || true)
        BLUE=$(tput setaf 4)
        BRIGHT_BLUE=$(tput setaf 12 2>/dev/null || true)
        POWDER_BLUE=$(tput setaf 153 2>/dev/null || true)
        MAGENTA=$(tput setaf 5)
        CYAN=$(tput setaf 6)
        WHITE=$(tput setaf 7)
        BRIGHT=$(tput bold)
        NORMAL=$(tput sgr0)
        BOLD=$(tput bold)
        BLINK=$(tput blink 2>/dev/null || true)
        REVERSE=$(tput smso)
        UNDERLINE=$(tput smul)
    else
        BLACK=""
        RED=""
        GREEN=""
        YELLOW=""
        LIME_YELLOW=""
        BLUE=""
        BRIGHT_BLUE=""
        POWDER_BLUE=""
        MAGENTA=""
        CYAN=""
        WHITE=""
        BRIGHT=""
        NORMAL=""
        BOLD=""
        BLINK=""
        REVERSE=""
        UNDERLINE=""
    fi
}

kb_status_begin()
{
    local msg="$1"
    printf "%s%s...%s" "${WHITE}" "$msg" "${NORMAL}"
}

kb_status_end_ok()
{
    local msg="$1"
    printf "\r\033[2K%s%s... %sDone%s\n" "${WHITE}" "$msg" "${BOLD}${GREEN}" "${NORMAL}"
}

kb_status_end_fail()
{
    local msg="$1" rc="${2:-1}"
    printf "\r\033[2K%s%s... %sFailed%s (rc=%s)\n" "${WHITE}" "$msg" "${BOLD}${RED}" "${NORMAL}" "$rc"
}

kb_die()
{
    local msg="$1"
    local rc="${2:-1}"
    printf "%s%s%s\n" "${BOLD}${RED}" "$msg" "${NORMAL}" >&2
    exit "$rc"
}

kb_done()
{
    echo "${GREEN}${BOLD}Done!"
    echo "${NORMAL}"
}

# Optional desktop notification when a requested build finishes. The sound theme
# files and audio players are not dependencies: missing/unavailable audio must
# never change a kernel build's exit status.
kb_play_build_sound()
{
    local outcome="$1"
    local sound_dir="${KB_BUILD_SOUND_DIR:-/usr/share/sounds/freedesktop/stereo}"
    local filename

    case "$outcome" in
        success) filename="complete.oga" ;;
        failure) filename="service-logout.oga" ;;
        *) return 0 ;;
    esac

    local file="${sound_dir}/${filename}"
    [[ -r "$file" ]] || return 0

    # Fedora supports these players; try the next if a backend is unavailable.
    if command -v canberra-gtk-play >/dev/null 2>&1; then
        canberra-gtk-play -f "$file" >/dev/null 2>&1 && return 0
    fi
    if command -v pw-play >/dev/null 2>&1; then
        pw-play "$file" >/dev/null 2>&1 && return 0
    fi
    if command -v paplay >/dev/null 2>&1; then
        paplay "$file" >/dev/null 2>&1 && return 0
    fi
    return 0
}

kb_notify_build_exit()
{
    local status="$1"
    if ((status == 0)); then
        kb_play_build_sound success
    else
        kb_play_build_sound failure
    fi
    return 0
}

kb_enable_build_notifications()
{
    # The caller enables this only for -b. One EXIT handler covers errors in
    # configuration, compilation, staging, and final copy operations.
    trap 'kb_notify_build_exit "$?"' EXIT
}

kb_normalize_localversion()
{
    local s="$1"
    if [[ -z "$s" || "$s" == "none" ]]; then
        printf '\n'
    elif [[ "$s" == -* ]]; then
        printf '%s\n' "$s"
    else
        printf -- '-%s\n' "$s"
    fi
}

kb_validate_localversion_tag()
{
    local tag="$1"

    if [[ -z "$tag" ]]; then
        kb_die "Option -l requires a non-empty localversion argument." 2
    fi

    if [[ "$tag" == -* ]]; then
        kb_die \
            "Invalid argument to -l: '${tag}'. Pass the localversion without a leading '-'; did a shell variable expand to an empty value?" \
            2
    fi
}

kb_require_env_vars()
{
    local missing=()
    local name

    for name in "$@"; do
        if [[ -z "${!name:-}" ]]; then
            missing+=( "$name" )
        fi
    done

    if ((${#missing[@]} > 0)); then
        printf '%sError:%s required environment variable(s) not set: %s\n' \
            "${BOLD}${RED}" "${NORMAL}" "${missing[*]}" >&2
        exit 1
    fi
}

kb_require_commands()
{
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || {
            printf 'Missing command: %s\n' "$cmd" >&2
            exit 127
        }
    done
}




kb_validate_architecture()
{
    case "$1" in
        x86_64|aarch64|riscv64) ;;
        *) kb_die "Unsupported arch: $1" 2 ;;
    esac
}

kb_normalize_platform()
{
    case "${1:-}" in
        opi5+|opi5plus)
            printf 'opi5plus\n'
            ;;
        rpi4|rpi4b|raspberrypi4)
            printf 'rpi4\n'
            ;;
        orin-nano|orinnano)
            printf 'orin-nano\n'
            ;;
        vf2|visionfive2|visionfive-2)
            printf 'vf2\n'
            ;;
        arm-server|armserver)
            printf 'arm-server\n'
            ;;
        *)
            return 1
            ;;
    esac
}

kb_platform_to_target_arch()
{
    case "$1" in
        opi5plus|rpi4|orin-nano|arm-server)
            printf 'aarch64\n'
            ;;
        vf2)
            printf 'riscv64\n'
            ;;
        *)
            return 1
            ;;
    esac
}

kb_platform_to_dtb_rel_path()
{
    case "$1" in
        opi5plus)
            printf 'rockchip/rk3588-orangepi-5-plus.dtb\n'
            ;;
        rpi4)
            printf 'broadcom/bcm2711-rpi-4-b.dtb\n'
            ;;
        orin-nano)
            printf 'nvidia/tegra234-p3768-0000+p3767-0005.dtb\n'
            ;;
        vf2)
            printf 'starfive/jh7110-starfive-visionfive-2-v1.3b.dtb\n'
            ;;
        arm-server)
            # UEFI/ACPI arm64 servers do not use a builder-supplied board DTB.
            printf '\n'
            ;;
        *)
            return 1
            ;;
    esac
}

# Platform presets select a DTB and an architecture. Without a preset, use
# the native architecture (or an explicit -a override) and no board DTB.
kb_resolve_platform()
{
    local requested_platform="${1:-}"
    local requested_arch="${2:-}"
    local normalized_platform=""
    local platform_arch=""

    if [[ -n "$requested_platform" ]]; then
        if ! normalized_platform="$(kb_normalize_platform "$requested_platform")"; then
            kb_die "Unknown platform preset: ${requested_platform}. Supported platforms: opi5plus, rpi4, orin-nano, vf2, arm-server" 2
        fi
        platform_arch="$(kb_platform_to_target_arch "$normalized_platform")"
        if [[ -n "$requested_arch" && "$requested_arch" != "$platform_arch" ]]; then
            kb_die "Architecture ${requested_arch} conflicts with platform ${normalized_platform} (${platform_arch})." 2
        fi
        PLATFORM="$normalized_platform"
        TARGET_ARCH="$platform_arch"
        DTB_REL_PATH="$(kb_platform_to_dtb_rel_path "$normalized_platform")"
    else
        PLATFORM="generic"
        TARGET_ARCH="${requested_arch:-$(uname -m)}"
        DTB_REL_PATH=""
    fi

    kb_validate_architecture "$TARGET_ARCH"
}

# Ensure an output directory configured for one architecture/platform cannot
# silently be reused for a different target. For an existing unstamped build,
# configure once with -c before building under this version.
kb_assert_build_target()
{
    local build_dir="$1"
    local expected_arch="$2"
    local expected_platform="$3"
    local stamp="${build_dir}/.kernel-build-target"
    local arch="" platform=""

    if [[ ! -f "$stamp" ]]; then
        [[ ! -f "${build_dir}/.config" ]] || kb_die             "Existing .config lacks a kernel-build target marker: ${build_dir}. Reconfigure with -c before building." 2
        return 0
    fi

    IFS=' ' read -r arch platform < "$stamp"
    if [[ "$arch" != "$expected_arch" || "$platform" != "$expected_platform" ]]; then
        kb_die "Build target mismatch at ${build_dir}: configured for ${arch}/${platform}, requested ${expected_arch}/${expected_platform}. Use a separate build directory." 2
    fi
}

kb_record_build_target()
{
    local build_dir="$1"
    local target_arch="$2"
    local platform="$3"
    mkdir -p "$build_dir"
    printf '%s %s\n' "$target_arch" "$platform" > "${build_dir}/.kernel-build-target"
}

kb_set_dtb_paths()
{
    [[ -n "${DTB_REL_PATH:-}" ]] || return 0
    [[ -n "${KERNEL_ARCH:-}" ]] || kb_die "KERNEL_ARCH must be set before DTB paths can be resolved" 2
    [[ -n "${KERNEL_BUILD_DIR:-}" ]] || kb_die "KERNEL_BUILD_DIR must be set before DTB paths can be resolved" 2

    DTB_NAME="$(basename "$DTB_REL_PATH")"
    DTB_BUILD_PATH="${KERNEL_BUILD_DIR}/arch/${KERNEL_ARCH}/boot/dts/${DTB_REL_PATH}"
}


kb_arch_to_kernel_arch()
{
    case "$1" in
        x86_64)  printf 'x86_64\n' ;;
        aarch64) printf 'arm64\n' ;;
        riscv64) printf 'riscv\n' ;;
        *)       return 1 ;;
    esac
}

kb_setup_cross_compile()
{
    local target_arch="$1"
    local host_arch

    host_arch=$(uname -m)
    if [[ "$host_arch" == "$target_arch" ]]; then
        unset CROSS_COMPILE
        return 0
    fi

    printf '%sCross-compiling %s on %s%s\n' "${WHITE}" "$target_arch" "$host_arch" "${NORMAL}"

    case "$target_arch" in
        aarch64) export CROSS_COMPILE=aarch64-linux-gnu- ;;
        riscv64) export CROSS_COMPILE=riscv64-linux-gnu- ;;
        x86_64)  export CROSS_COMPILE=x86_64-linux-gnu- ;;
        *)       return 1 ;;
    esac
}

kb_get_kbuild_image_rel_path()
{
    local kernel_src_dir="$1"
    local kernel_build_dir="$2"
    local kernel_arch="$3"
    local -a cmd=(
        kb_make -s --no-print-directory -C "$kernel_src_dir"
        O="$kernel_build_dir" ARCH="$kernel_arch"
    )

    if [[ -n "${CROSS_COMPILE:-}" ]]; then
        cmd+=("CROSS_COMPILE=${CROSS_COMPILE}")
    fi

    "${cmd[@]}" image_name
}

kb_kernel_image_deploy_basename()
{
    local image_path="$1"
    local image_name

    image_name="$(basename "$image_path")"

    case "$image_name" in
        vmlinuz.efi)
            printf 'vmlinuz\n'
            ;;
        *)
            printf '%s\n' "$image_name"
            ;;
    esac
}

kb_config_has_desired_localversion()
{
    local cfg="$1"
    local desired="$2"
    local current auto_disabled=1

    [[ -f "$cfg" ]] || return 1

    current="$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "$cfg" | tail -n1)"

    if grep -Eq '^# CONFIG_LOCALVERSION_AUTO is not set$' "$cfg" || \
       grep -Eq '^CONFIG_LOCALVERSION_AUTO=n$' "$cfg"; then
        auto_disabled=0
    fi

    [[ "$current" == "$desired" && "$auto_disabled" -eq 0 ]]
}

kb_apply_localversion_config()
{
    local kernel_src_dir="$1"
    local cfg="$2"
    local desired="$3"
    local kconf="${kernel_src_dir}/scripts/config"

    [[ -f "$cfg" ]] || { echo "ERROR: $cfg not found" >&2; return 2; }
    [[ -x "$kconf" ]] || { echo "ERROR: $kconf not found or not executable" >&2; return 2; }

    if kb_config_has_desired_localversion "$cfg" "$desired"; then
        return 0
    fi

    "$kconf" --file "$cfg" --set-str LOCALVERSION "$desired" --disable LOCALVERSION_AUTO
}

# Apply the bundled local overrides during configuration. Flat (legacy)
# directives and sectioned selectors are supported. Files may group
# directives by [all], [centos], [upstream],
# [platform:<name>], [arch:<name>], or [centos:<name>]/[upstream:<name>].
# Sections are opt-in: only a matching section's directives are applied.
kb_apply_configs()
{
    local kernel_src_dir="$1"
    local cfg="$2"
    local config_file="$3"
    local builder_kind="${4:-}"
    local platform="${5:-generic}"
    local target_arch="${6:-}"
    local kconf="${kernel_src_dir}/scripts/config"
    local active=true
    local section="all"
    local line action symbol value matches

    [[ -f "$cfg" ]] || { echo "Error: .config not found: ${cfg}" >&2; return 1; }
    [[ -x "$kconf" ]] || { echo "Error: scripts/config not found: ${kconf}" >&2; return 1; }
    [[ -f "$config_file" ]] || { echo "Error: config file not found: ${config_file}" >&2; return 1; }

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Section names must be on their own line, optionally indented.
        if [[ "$line" =~ ^[[:space:]]*\[([^][]+)\][[:space:]]*$ ]]; then
            section="${BASH_REMATCH[1]}"
            active=false
            case "$section" in
                all|common) active=true ;;
                centos|upstream) [[ "$section" == "$builder_kind" ]] && active=true ;;
                "${builder_kind}:${platform}"|"platform:${platform}"|"arch:${target_arch}") active=true ;;
                centos:*|upstream:*|platform:*|arch:*) ;;
                *) echo "Error: unknown override section: [$section]" >&2; return 1 ;;
            esac
            continue
        fi
        [[ "$active" == true ]] || continue

        action=""; symbol=""; value=""
        read -r action symbol value <<< "$line"
        if [[ -z "$action" || -z "$symbol" ]]; then
            echo "Error: malformed line: ${line}" >&2
            return 1
        fi

        case "$action" in
            enable|disable|module|set-str|set-val) ;;
            *) echo "Error: unsupported config action: ${action}" >&2; return 1 ;;
        esac

        matches="$(grep -Rwl --include='Kconfig*' \
            -e "^[[:space:]]*config[[:space:]]\+${symbol}$" \
            -e "^[[:space:]]*menuconfig[[:space:]]\+${symbol}$" \
            "${kernel_src_dir}" 2>/dev/null || true)"

        if [[ -z "$matches" ]]; then
            echo "Error: Unknown Kconfig symbol: ${symbol}" >&2
            return 1
        fi

        # The old text files used double quotes around set-str values.
        # Remove only the outer pair; arguments are never evaluated as code.
        if [[ "$action" == set-str && "$value" == \"*\" && "${#value}" -ge 2 ]]; then
            value="${value:1:${#value}-2}"
        fi

        local -a cmd=( "$kconf" --file "$cfg" "--${action}" "$symbol" )
        [[ -n "$value" ]] && cmd+=( "$value" )
        "${cmd[@]}" || {
            echo "Error: failed to apply: ${line}" >&2
            return 1
        }
    done < "$config_file"
}

kb_configure_kernel_for_debug()
{
    local kernel_src_dir="$1"
    local kernel_build_dir="$2"
    local kernel_arch="$3"
    local cfg="${kernel_build_dir}/.config"
    local kconf="${kernel_src_dir}/scripts/config"

    [[ -f "$cfg" ]] || { echo "ERROR: $cfg not found" >&2; return 2; }

    "$kconf" --file "$cfg" --enable DEBUG_KERNEL
    "$kconf" --file "$cfg" --enable DEBUG_INFO
    "$kconf" --file "$cfg" --enable DEBUG_INFO_DWARF5
    "$kconf" --file "$cfg" --disable DEBUG_INFO_DWARF4
    "$kconf" --file "$cfg" --enable GDB_SCRIPTS
    "$kconf" --file "$cfg" --enable FRAME_POINTER
    "$kconf" --file "$cfg" --enable STACKTRACE
    "$kconf" --file "$cfg" --enable DEBUG_FS
    "$kconf" --file "$cfg" --enable KALLSYMS --enable KALLSYMS_ALL
    "$kconf" --file "$cfg" --enable FTRACE --enable FUNCTION_TRACER --enable FUNCTION_GRAPH_TRACER
    "$kconf" --file "$cfg" --enable FTRACE_SYSCALLS --enable TRACING
    "$kconf" --file "$cfg" --enable PROVE_LOCKING --enable DEBUG_LOCK_ALLOC
    "$kconf" --file "$cfg" --enable DEBUG_SPINLOCK --enable DEBUG_MUTEXES
    "$kconf" --file "$cfg" --enable DEBUG_ATOMIC_SLEEP --enable SCHED_DEBUG
    "$kconf" --file "$cfg" --enable DYNAMIC_DEBUG
    "$kconf" --file "$cfg" --enable DEBUG_INFO_BTF --enable DEBUG_INFO_BTF_MODULES
    "$kconf" --file "$cfg" --disable MODULE_SIG_FORCE

    kb_make -C "$kernel_src_dir" O="$kernel_build_dir" ARCH="$kernel_arch" olddefconfig
}

kb_build_ctags()
{
    local kernel_src_dir="$1"
    local kernel_build_dir="$2"

    echo "${WHITE}"
    echo "Generating ctags..."
    echo "${NORMAL}"

    local tagfile="${kernel_build_dir}/tags"
    local ctags_bin
    local status=0
    local workers
    local ctags_help
    local ctags_langs
    local -a ctags_args
    local -a exclude_args

    rm -f "${tagfile}"

    if ! ctags_bin=$(command -v ctags 2>/dev/null); then
        echo "${YELLOW}Skipping ctags: ctags not installed.${NORMAL}"
        return 0
    fi

    mkdir -p "${kernel_build_dir}"

    ctags_help="$("${ctags_bin}" --help 2>&1 || true)"
    ctags_langs="$("${ctags_bin}" --list-languages 2>/dev/null || true)"

    kb_ctags_has()
    {
        grep -Fq -- "$1" <<< "${ctags_help}"
    }

    kb_ctags_lang_has()
    {
        grep -Eq "(^|[[:space:]])$1([[:space:]]|,|$)" <<< "${ctags_langs}"
    }

    ctags_args=(
        -R
        -f "${tagfile}"
        --tag-relative=yes
    )

    if kb_ctags_has "--sort"; then
        ctags_args+=( --sort=yes )
    fi

    local languages="C"
    if kb_ctags_lang_has "Asm"; then
        languages+=",Asm"
    elif kb_ctags_lang_has "Assembly"; then
        languages+=",Assembly"
    fi
    if kb_ctags_lang_has "Rust"; then
        languages+=",Rust"
    fi

    if kb_ctags_has "--languages="; then
        ctags_args+=( --languages="${languages}" )
    fi

    # Explicitly parse .h files as C.
    if kb_ctags_has "--langmap"; then
        ctags_args+=( --langmap=C:+.h )
    fi

    if kb_ctags_has "--fields="; then
        ctags_args+=( --fields=+iaS )
    fi
    if kb_ctags_has "--extras="; then
        ctags_args+=( --extras=+q )
    fi
    if kb_ctags_has "--c-kinds="; then
        ctags_args+=( --c-kinds=+p )
    fi
    if kb_ctags_has "--workers"; then
        workers="${KERNEL_BUILD_JOBS:-$(kb_detect_available_cpus)}"
        ctags_args+=( --workers="${workers}" )
    fi

    exclude_args=(
        --exclude=.git
        --exclude=tags
        --exclude=tags.*
        --exclude=cscope.*
        --exclude=GTAGS
        --exclude=GRTAGS
        --exclude=GPATH
        --exclude=Module.symvers
        --exclude=modules.order
        --exclude=vmlinux
        --exclude=vmlinux.*
        --exclude=System.map
        --exclude=System.map.*
        --exclude=compile_commands.json
        --exclude=Documentation
        --exclude=tools
        --exclude=samples
        --exclude='*.o'
        --exclude='*.a'
        --exclude='*.so'
        --exclude='*.ko'
        --exclude='*.mod'
        --exclude='*.mod.c'
        --exclude='*.cmd'
        --exclude='*.d'
        --exclude='*.dtb'
        --exclude='*.dtbo'
        --exclude='*.su'
        --exclude='*.symtypes'
        --exclude='*.order'
        --exclude='*.gcno'
        --exclude='*.gcda'
        --exclude='*.gcov'
    )

    if ! "${ctags_bin}" "${ctags_args[@]}" "${exclude_args[@]}" "${kernel_src_dir}"; then
        status=$?
        echo "${RED}${BOLD}Error:${NORMAL} Failed to generate tags"
        return "${status}"
    fi

    echo "${GREEN}Generated:${NORMAL} ${tagfile}"
}

kb_set_orin_nano_performance_mode()
{
    if [[ -r /sys/firmware/devicetree/base/model ]] && grep -q 'Orin Nano' /sys/firmware/devicetree/base/model; then
        sudo cpupower frequency-set -g performance >/dev/null 2>&1 || true
    fi
}
