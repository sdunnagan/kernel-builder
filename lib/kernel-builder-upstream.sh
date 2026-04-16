#!/usr/bin/env bash

DEBUG_CONFIG=false
DO_BUILD=false
DO_CLEAN=false
DO_CONFIG=false
DTB_BUILD_PATH=""
DTB_NAME=""
DTB_REL_PATH=""
KERNEL_ARCH=""
KERNEL_CONFIG_FILE=""
KERNEL_IMAGE_PATH=""
KERNEL_IMAGE_TARGET=""
KERNEL_RELEASE=""
LOCALVERSION=""
LOCALVERSION_TAG=""
LOG_DIR="${LOG_DIR:-$HOME/logs}"
LOG_FILE=""
PLATFORM=""
TARGET_ARCH=""

upstream_usage()
{
    cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  -b                            Build the kernel (image, modules, and DTBs when applicable)
  -c                            Configure kernel
  -C                            Clean build tree (make clean)
  -d                            Configure kernel for debugging (requires -c)
  -h                            Show help
  -k <config-file>              Apply Kconfig from file
  -l <localversion>             Set CONFIG_LOCALVERSION
  -p <platform>                 Target platform (required: opi5plus|rpi4|orin-nano)

Environment:
  KERNEL_SRC_DIR=${KERNEL_SRC_DIR:-<unset>}
  KERNEL_BUILD_DIR=${KERNEL_BUILD_DIR:-<unset>}
USAGE
    exit 1
}

upstream_parse_args()
{
    while getopts ":bcCdhk:l:p:" opt; do
        case "$opt" in
            b) DO_BUILD=true ;;
            c) DO_CONFIG=true ;;
            C) DO_CLEAN=true ;;
            d) DEBUG_CONFIG=true ;;
            h) upstream_usage ;;
            k) KERNEL_CONFIG_FILE="$OPTARG" ;;
            l) LOCALVERSION_TAG="$OPTARG" ;;
            p) PLATFORM="$OPTARG" ;;
            :) kb_die "Option -$OPTARG requires an argument" 2 ;;
            *) upstream_usage ;;
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

upstream_resolve_build_targets()
{
    KERNEL_ARCH="$(kb_arch_to_kernel_arch "$TARGET_ARCH")" || kb_die "Unsupported arch: ${TARGET_ARCH}" 2

    case "$TARGET_ARCH" in
        aarch64)
            KERNEL_IMAGE_TARGET="Image"
            KERNEL_IMAGE_PATH="${KERNEL_BUILD_DIR}/arch/arm64/boot/Image"
            ;;
        riscv64)
            KERNEL_IMAGE_TARGET="Image"
            KERNEL_IMAGE_PATH="${KERNEL_BUILD_DIR}/arch/riscv/boot/Image"
            ;;
        x86_64)
            KERNEL_IMAGE_TARGET="bzImage"
            KERNEL_IMAGE_PATH="${KERNEL_BUILD_DIR}/arch/x86/boot/bzImage"
            ;;
    esac
}

upstream_resolve_platform()
{
    kb_resolve_platform "$PLATFORM"
}

upstream_require_local_commands()
{
    kb_require_commands make awk sed find tar grep cp rm mkdir

    if [[ "$DO_BUILD" == true || "$DO_CONFIG" == true ]]; then
        kb_require_commands gcc
    fi

    if [[ "$DO_BUILD" == true && -n "$DTB_REL_PATH" ]]; then
        kb_require_commands dtc
    fi

    if [[ "$DEBUG_CONFIG" == true ]]; then
        kb_require_commands ctags
    fi
}



upstream_create_log_file()
{
    local ts gccv host

    ts="$(date +"%Y_%m_%d_%H%M")"
    gccv="$(gcc --version | head -n 1 || true)"
    host="$(hostname -s 2>/dev/null || echo unknown)"

    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/upstream_kernel_build_${ts}.log"

    {
        echo "//---------------------------------------------------------------"
        echo "// Upstream Kernel Build"
        echo "// Date: $(date)"
        echo "// Host: ${host}"
        echo "// PLATFORM: ${PLATFORM}"
        echo "// ARCH: ${TARGET_ARCH}"
        echo "// KERNEL_ARCH: ${KERNEL_ARCH}"
        echo "// KERNEL_SRC_DIR =   ${KERNEL_SRC_DIR}"
        echo "// KERNEL_BUILD_DIR = ${KERNEL_BUILD_DIR}"
        echo "// GCC: ${gccv}"
        echo "// LOCALVERSION: ${LOCALVERSION:-<none>}"
        echo "// KCONFIG FILE: ${KERNEL_CONFIG_FILE:-<none>}"
        echo "//---------------------------------------------------------------"
        echo
    } > "$LOG_FILE"
}

upstream_configure_kernel()
{
    local rc

    echo "${WHITE}Configuring kernel:${NORMAL}"
    echo "${WHITE}   - Log file: ${CYAN}${LOG_FILE}${NORMAL}"

    kb_status_begin "   - Verifying ${KERNEL_BUILD_DIR}/.config"
    if [[ -f "${KERNEL_BUILD_DIR}/.config" ]]; then
        kb_status_end_ok "   - Verifying ${KERNEL_BUILD_DIR}/.config"
    else
        kb_status_end_fail "   - Verifying ${KERNEL_BUILD_DIR}/.config" 2
        kb_die "No .config in ${KERNEL_BUILD_DIR}" 2
    fi

    kb_status_begin "   - Normalizing config"
    if make -C "$KERNEL_SRC_DIR" O="$KERNEL_BUILD_DIR" ARCH="$KERNEL_ARCH" olddefconfig >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Normalizing config"
    else
        rc=$?
        kb_status_end_fail "   - Normalizing config" "$rc"
        return "$rc"
    fi

    if [[ -n "$LOCALVERSION_TAG" ]]; then
        kb_status_begin "   - Applying localversion config"
        if kb_apply_localversion_config "$KERNEL_SRC_DIR" "${KERNEL_BUILD_DIR}/.config" "$LOCALVERSION" >>"$LOG_FILE" 2>&1; then
            kb_status_end_ok "   - Applying localversion config"
        else
            rc=$?
            kb_status_end_fail "   - Applying localversion config" "$rc"
            return "$rc"
        fi
    fi

    if [[ -n "$KERNEL_CONFIG_FILE" ]]; then
        kb_status_begin "   - Applying config file"
        if kb_apply_configs "$KERNEL_SRC_DIR" "${KERNEL_BUILD_DIR}/.config" "$KERNEL_CONFIG_FILE" >>"$LOG_FILE" 2>&1; then
            kb_status_end_ok "   - Applying config file"
        else
            rc=$?
            kb_status_end_fail "   - Applying config file" "$rc"
            return "$rc"
        fi
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

        kb_status_begin "   - Building ctags"
        if kb_build_ctags "$KERNEL_SRC_DIR" "$KERNEL_BUILD_DIR" >>"$LOG_FILE" 2>&1; then
            kb_status_end_ok "   - Building ctags"
        else
            rc=$?
            kb_status_end_fail "   - Building ctags" "$rc"
            return "$rc"
        fi
    fi

    kb_status_begin "   - Normalizing config again"
    if make -C "$KERNEL_SRC_DIR" O="$KERNEL_BUILD_DIR" ARCH="$KERNEL_ARCH" olddefconfig >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Normalizing config again"
    else
        rc=$?
        kb_status_end_fail "   - Normalizing config again" "$rc"
        return "$rc"
    fi

    echo
}

upstream_clean_kernel()
{
    local rc

    echo "${WHITE}Cleaning kernel build:${NORMAL}"
    kb_status_begin "   - Cleaning build tree"
    if make -C "$KERNEL_SRC_DIR" O="$KERNEL_BUILD_DIR" ARCH="$KERNEL_ARCH" clean >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Cleaning build tree"
    else
        rc=$?
        kb_status_end_fail "   - Cleaning build tree" "$rc"
        return "$rc"
    fi

    echo
}

upstream_get_kernel_release()
{
    make -s -C "$KERNEL_SRC_DIR" O="$KERNEL_BUILD_DIR" ARCH="$KERNEL_ARCH" kernelrelease
}

upstream_ensure_localversion_matches_for_build()
{
    if [[ -z "$LOCALVERSION_TAG" ]]; then
        return 0
    fi

    if kb_config_has_desired_localversion "${KERNEL_BUILD_DIR}/.config" "$LOCALVERSION"; then
        return 0
    fi

    local cfg="${KERNEL_BUILD_DIR}/.config"
    local current

    current="$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "$cfg" | tail -n1)"

    echo "Error: .config LOCALVERSION state does not match requested value." >&2
    echo "  requested: ${LOCALVERSION}" >&2
    echo "  current:   ${current:-<unset>}" >&2
    echo "  note:      CONFIG_LOCALVERSION_AUTO may still be enabled" >&2
    echo "Run with -c first to update the config." >&2
    return 2
}

upstream_build_symbol_dtb()
{
    local rc
    local label

    [[ -n "$DTB_BUILD_PATH" ]] || return 0

    label="   - Building DTB with symbols (-@): ${DTB_NAME}"
    rm -f "$DTB_BUILD_PATH"

    kb_status_begin "$label"
    if make -C "$KERNEL_SRC_DIR" -j"$(nproc)" O="$KERNEL_BUILD_DIR" ARCH="$KERNEL_ARCH" \
        V=1 "${DTB_REL_PATH}" DTC_FLAGS="-@" >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "$label"
    else
        rc=$?
        kb_status_end_fail "$label" "$rc"
        return "$rc"
    fi

    kb_status_begin "   - Verifying built DTB contains /__symbols__"
    if command -v fdtget >/dev/null 2>&1; then
        if fdtget -l "$DTB_BUILD_PATH" /__symbols__ >/dev/null 2>&1; then
            kb_status_end_ok "   - Verifying built DTB contains /__symbols__"
        else
            rc=$?
            kb_status_end_fail "   - Verifying built DTB contains /__symbols__" "$rc"
            echo "ERROR: Built DTB is missing /__symbols__: $DTB_BUILD_PATH" >&2
            return 1
        fi
    else
        if "$KERNEL_SRC_DIR/scripts/dtc/dtc" -@ -I dtb -O dts -o - "$DTB_BUILD_PATH" | grep -q '^/__symbols__'; then
            kb_status_end_ok "   - Verifying built DTB contains /__symbols__"
        else
            rc=$?
            kb_status_end_fail "   - Verifying built DTB contains /__symbols__" "$rc"
            echo "ERROR: Built DTB is missing /__symbols__: $DTB_BUILD_PATH" >&2
            return 1
        fi
    fi
}

upstream_stage_modules()
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
    if make -C "$KERNEL_SRC_DIR" -j"$(nproc)" O="$KERNEL_BUILD_DIR" ARCH="$KERNEL_ARCH" \
        INSTALL_MOD_PATH="$stage_dir" modules_install >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Staging modules"
    else
        rc=$?
        kb_status_end_fail "   - Staging modules" "$rc"
        return "$rc"
    fi
}

upstream_install_dtbs_to_deploy()
{
    local rc
    local deploy_dtbs_dir="${KERNEL_BUILD_DIR}/deploy/dtbs"

    [[ "$TARGET_ARCH" == "x86_64" ]] && return 0

    kb_status_begin "   - Installing DTBs into deploy/dtbs"
    if mkdir -p "$deploy_dtbs_dir" && \
       make -C "$KERNEL_SRC_DIR" O="$KERNEL_BUILD_DIR" ARCH="$KERNEL_ARCH" DTC_FLAGS="-@" \
            INSTALL_DTBS_PATH="$deploy_dtbs_dir" dtbs_install >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Installing DTBs into deploy/dtbs"
    else
        rc=$?
        kb_status_end_fail "   - Installing DTBs into deploy/dtbs" "$rc"
        return "$rc"
    fi
}

upstream_copy_build_artifacts()
{
    local deploy_dir="${KERNEL_BUILD_DIR}/deploy"
    local kernel_image_name
    local kernel_image_dst
    local modules_root="${KERNEL_BUILD_DIR}/modules_staging/lib/modules"
    local modules_dir="${modules_root}/${KERNEL_RELEASE}"

    kernel_image_name="$(basename "$KERNEL_IMAGE_PATH")"
    kernel_image_dst="${deploy_dir}/${kernel_image_name}-upstream-${KERNEL_RELEASE}"

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
        if [[ -d "$modules_dir" ]]; then
            echo "  ${modules_dir}/"
        fi
        if [[ -d "${deploy_dir}/dtbs" ]]; then
            echo "  ${deploy_dir}/dtbs/"
        fi
        echo
    } >>"$LOG_FILE"

    echo
    echo "${WHITE}Build artifacts copied to:${CYAN}"
    echo "  ${kernel_image_dst}"
    if [[ -d "$modules_dir" ]]; then
        echo "  ${modules_dir}/"
    fi
    if [[ -d "${deploy_dir}/dtbs" ]]; then
        echo "  ${deploy_dir}/dtbs/"
    fi
    echo "${NORMAL}"
}


upstream_build_kernel()
{
    local rc
    local start end dur

    echo "${WHITE}Building kernel:${NORMAL}"
    echo "${WHITE}   - Log file: ${CYAN}${LOG_FILE}${NORMAL}"

    kb_status_begin "   - Preparing cross-compile environment"
    if kb_setup_cross_compile "$TARGET_ARCH" >/dev/null 2>&1; then
        kb_status_end_ok "   - Preparing cross-compile environment"
    else
        rc=$?
        kb_status_end_fail "   - Preparing cross-compile environment" "$rc"
        return "$rc"
    fi

    kb_status_begin "   - Verifying localversion config"
    if upstream_ensure_localversion_matches_for_build >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Verifying localversion config"
    else
        rc=$?
        kb_status_end_fail "   - Verifying localversion config" "$rc"
        return "$rc"
    fi

    local -a make_base_cmd=(
        make -C "$KERNEL_SRC_DIR" -j"$(nproc)"
        O="$KERNEL_BUILD_DIR" ARCH="$KERNEL_ARCH"
    )

    {
        echo
        echo "== Build begin"
        echo "   When:   $(date '+%F %T')"
        echo "   Log:    $LOG_FILE"
    } >>"$LOG_FILE"

    kb_status_begin "   - Building kernel ${KERNEL_IMAGE_TARGET}"
    start="$(date +%s)"
    if "${make_base_cmd[@]}" "$KERNEL_IMAGE_TARGET" >>"$LOG_FILE" 2>&1; then
        end="$(date +%s)"
        dur=$((end - start))
        {
            echo "== Build ${KERNEL_IMAGE_TARGET} end"
            echo "   When:   $(date '+%F %T')"
            echo "   Elapsed: $((dur/60))m $((dur%60))s"
        } >>"$LOG_FILE"
        kb_status_end_ok "   - Building kernel ${KERNEL_IMAGE_TARGET}"
    else
        rc=$?
        end="$(date +%s)"
        dur=$((end - start))
        {
            echo "== Build ${KERNEL_IMAGE_TARGET} end [FAILED rc=${rc}]"
            echo "   When:   $(date '+%F %T')"
            echo "   Elapsed: $((dur/60))m $((dur%60))s"
        } >>"$LOG_FILE"
        kb_status_end_fail "   - Building kernel ${KERNEL_IMAGE_TARGET}" "$rc"
        return "$rc"
    fi

    kb_status_begin "   - Building modules"
    start="$(date +%s)"
    if "${make_base_cmd[@]}" modules >>"$LOG_FILE" 2>&1; then
        end="$(date +%s)"
        dur=$((end - start))
        {
            echo "== Build modules end"
            echo "   When:   $(date '+%F %T')"
            echo "   Elapsed: $((dur/60))m $((dur%60))s"
        } >>"$LOG_FILE"
        kb_status_end_ok "   - Building modules"
    else
        rc=$?
        end="$(date +%s)"
        dur=$((end - start))
        {
            echo "== Build modules end [FAILED rc=${rc}]"
            echo "   When:   $(date '+%F %T')"
            echo "   Elapsed: $((dur/60))m $((dur%60))s"
        } >>"$LOG_FILE"
        kb_status_end_fail "   - Building modules" "$rc"
        return "$rc"
    fi

    if [[ "$TARGET_ARCH" != "x86_64" ]]; then
        kb_status_begin "   - Building DTBs"
        start="$(date +%s)"
        if "${make_base_cmd[@]}" dtbs >>"$LOG_FILE" 2>&1; then
            end="$(date +%s)"
            dur=$((end - start))
            {
                echo "== Build DTBs end"
                echo "   When:   $(date '+%F %T')"
                echo "   Elapsed: $((dur/60))m $((dur%60))s"
            } >>"$LOG_FILE"
            kb_status_end_ok "   - Building DTBs"
        else
            rc=$?
            end="$(date +%s)"
            dur=$((end - start))
            {
                echo "== Build DTBs end [FAILED rc=${rc}]"
                echo "   When:   $(date '+%F %T')"
                echo "   Elapsed: $((dur/60))m $((dur%60))s"
            } >>"$LOG_FILE"
            kb_status_end_fail "   - Building DTBs" "$rc"
            return "$rc"
        fi

        upstream_build_symbol_dtb || return $?
    fi

    kb_status_begin "   - Determining kernel release"
    KERNEL_RELEASE="$(upstream_get_kernel_release)"
    if [[ -n "$KERNEL_RELEASE" ]]; then
        {
            echo
            echo "// KERNEL_RELEASE: ${KERNEL_RELEASE}"
        } >>"$LOG_FILE"
        kb_status_end_ok "   - Determining kernel release"
    else
        kb_status_end_fail "   - Determining kernel release" 1
        return 1
    fi

    upstream_stage_modules || return $?
    upstream_install_dtbs_to_deploy || return $?
    upstream_copy_build_artifacts || return $?

    echo
}

upstream_main()
{
    upstream_parse_args "$@"
    kb_init_colors

    kb_require_env_vars KERNEL_SRC_DIR KERNEL_BUILD_DIR

    upstream_resolve_platform
    kb_validate_architecture "$TARGET_ARCH"
    upstream_resolve_build_targets
    kb_set_dtb_paths
    upstream_require_local_commands

    if [[ "$DEBUG_CONFIG" == true || -n "$KERNEL_CONFIG_FILE" ]]; then
        [[ "$DO_CONFIG" == true ]] || kb_die "-d and -k require -c" 2
    fi

    echo
    echo "${WHITE}KERNEL_SRC_DIR:   ${CYAN}${KERNEL_SRC_DIR}${NORMAL}"
    echo "${WHITE}KERNEL_BUILD_DIR: ${CYAN}${KERNEL_BUILD_DIR}${NORMAL}"
    echo

    upstream_create_log_file

    if [[ "$DO_CONFIG" == true ]]; then
        upstream_configure_kernel
    fi

    if [[ "$DO_CLEAN" == true ]]; then
        upstream_clean_kernel
    fi

    if [[ "$DO_BUILD" == true ]]; then
        kb_set_orin_nano_performance_mode
        upstream_build_kernel
    fi

    kb_done

    echo
}
