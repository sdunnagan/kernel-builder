#!/usr/bin/env bash

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
            printf 'opi5plus
'
            ;;
        rpi4|rpi4b|raspberrypi4)
            printf 'rpi4
'
            ;;
        orin-nano|orinnano)
            printf 'orin-nano
'
            ;;
        *)
            return 1
            ;;
    esac
}

kb_require_platform()
{
    [[ -n "${1:-}" ]] || kb_die "-p <platform> is required. Supported platforms: opi5plus, rpi4, orin-nano" 2
}

kb_platform_to_target_arch()
{
    case "$1" in
        opi5plus|rpi4|orin-nano)
            printf 'aarch64
'
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
            printf 'rockchip/rk3588-orangepi-5-plus.dtb
'
            ;;
        rpi4)
            printf 'broadcom/bcm2711-rpi-4-b.dtb
'
            ;;
        orin-nano)
            printf 'nvidia/tegra234-p3768-0000+p3767-0005.dtb
'
            ;;
        *)
            return 1
            ;;
    esac
}

kb_resolve_platform()
{
    local requested_platform="$1"
    local normalized_platform

    kb_require_platform "$requested_platform"

    if ! normalized_platform="$(kb_normalize_platform "$requested_platform")"; then
        kb_die "Unknown platform preset: ${requested_platform}. Supported platforms: opi5plus, rpi4, orin-nano" 2
    fi

    PLATFORM="$normalized_platform"
    TARGET_ARCH="$(kb_platform_to_target_arch "$normalized_platform")"
    DTB_REL_PATH="$(kb_platform_to_dtb_rel_path "$normalized_platform")"
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

kb_apply_configs()
{
    local kernel_src_dir="$1"
    local cfg="$2"
    local config_file="$3"
    local kconf="${kernel_src_dir}/scripts/config"

    [[ -f "$cfg" ]] || { echo "Error: .config not found: ${cfg}" >&2; return 1; }
    [[ -x "$kconf" ]] || { echo "Error: scripts/config not found: ${kconf}" >&2; return 1; }
    [[ -f "$config_file" ]] || { echo "Error: config file not found: ${config_file}" >&2; return 1; }

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        local action=""
        local symbol=""
        local value=""
        read -r action symbol value <<< "$line"

        if [[ -z "$action" || -z "$symbol" ]]; then
            echo "Error: malformed line: ${line}" >&2
            return 1
        fi

        local matches
        matches="$(grep -Rwl --include='Kconfig*' \
            -e "^[[:space:]]*config[[:space:]]\+${symbol}$" \
            -e "^[[:space:]]*menuconfig[[:space:]]\+${symbol}$" \
            "${kernel_src_dir}" 2>/dev/null || true)"

        if [[ -z "$matches" ]]; then
            echo "Error: Unknown Kconfig symbol: ${symbol}" >&2
            return 1
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

    make -C "$kernel_src_dir" O="$kernel_build_dir" ARCH="$kernel_arch" olddefconfig
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
        workers="$(nproc 2>/dev/null || printf '1')"
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
