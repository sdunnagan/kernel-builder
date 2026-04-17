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
KERNEL_CONFIG_FILE=""
KERNEL_DESCRIPTION=""
KERNEL_GROUP=""
KERNEL_IMAGE_PATH=""
KERNEL_IMAGE_TARGET=""
KERNEL_PREFIX=""
KERNEL_RELEASE=""
LOCALVERSION=""
LOCALVERSION_TAG=""
LOG_DIR="${LOG_DIR:-$HOME/logs}"
LOG_FILE=""
PLATFORM=""
PREP_FOR_BACKPORTING=false
REPO_NAME=""
STREAM=""
TARGET_ARCH=""
UPSTREAM_REPO_NAME="stable"

centos_usage()
{
    cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  -b                            Build the kernel (image, modules, and DTBs when applicable)
  -c                            Configure kernel
  -C                            Clean build tree (make clean)
  -d                            Configure kernel for debugging (requires -c)
  -f <fork>                     CentOS Stream kernel fork
  -g                            Git clone
  -h                            Show help
  -k <config-file>              Apply Kconfig from file
  -l <localversion>             Set CONFIG_LOCALVERSION
  -p <platform>                 Target platform (required: opi5plus|rpi4|orin-nano)
  -r                            Build RPM packages
  -s <stream>                   CentOS/RHEL kernel stream (y9|y10|z9|z10)
  -U <upstream-kernel-repo>     Upstream kernel repository (next|stable)
  -x                            Prepare for backporting

Environment:
  KERNEL_SRC_DIR=${KERNEL_SRC_DIR:-<unset>}
  KERNEL_BUILD_DIR=${KERNEL_BUILD_DIR:-<unset>}
USAGE
    exit 1
}

centos_resolve_stream_spec()
{
    case "$1" in
        y9)
            KERNEL_GROUP="centos-stream"
            REPO_NAME="centos-stream-9"
            KERNEL_DESCRIPTION="CentOS Stream 9 (Y-stream)"
            KERNEL_PREFIX="cs9"
            ;;
        y10)
            KERNEL_GROUP="centos-stream"
            REPO_NAME="centos-stream-10"
            KERNEL_DESCRIPTION="CentOS Stream 10 (Y-stream)"
            KERNEL_PREFIX="cs10"
            ;;
        z9)
            KERNEL_GROUP="rhel"
            REPO_NAME="rhel-9"
            KERNEL_DESCRIPTION="RHEL 9 (Z-stream)"
            KERNEL_PREFIX="rhel9"
            ;;
        z10)
            KERNEL_GROUP="rhel"
            REPO_NAME="rhel-10"
            KERNEL_DESCRIPTION="RHEL 10 (Z-stream)"
            KERNEL_PREFIX="rhel10"
            ;;
        *)
            kb_die "Invalid stream '${1}'. Must be one of: y9, y10, z9, z10." 2
            ;;
    esac
}

centos_parse_args()
{
    while getopts ":bcCdf:ghk:l:p:rs:U:x" opt; do
        case "$opt" in
            b) DO_BUILD=true ;;
            c) DO_CONFIG=true ;;
            C) DO_CLEAN=true ;;
            d) DEBUG_CONFIG=true ;;
            f) FORK_NAME="${OPTARG%%:*}" ;;
            g) DO_CLONE=true ;;
            h) centos_usage ;;
            k) KERNEL_CONFIG_FILE="$OPTARG" ;;
            l) LOCALVERSION_TAG="$OPTARG" ;;
            p) PLATFORM="$OPTARG" ;;
            r) DO_BUILD_RPM=true ;;
            s) STREAM="$OPTARG"; centos_resolve_stream_spec "$STREAM" ;;
            U)
                case "$OPTARG" in
                    stable|next) UPSTREAM_REPO_NAME="$OPTARG" ;;
                    *) kb_die "-U must be either 'stable' or 'next'" 2 ;;
                esac
                ;;
            x) PREP_FOR_BACKPORTING=true ;;
            :) kb_die "Option -$OPTARG requires an argument" 2 ;;
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

centos_require_stream()
{
    [[ -n "$STREAM" ]] || kb_die "-s <stream> is required" 2
}

centos_resolve_platform()
{
    kb_resolve_platform "$PLATFORM"
}

centos_require_local_commands()
{
    local -a cmds=(make awk sed find tar grep cp rm mkdir)

    if [[ "$DO_BUILD" == true || "$DO_CONFIG" == true || "$DO_BUILD_RPM" == true ]]; then
        cmds+=(gcc ld bc perl python3 flex bison patch xz)
    fi

    if [[ "$DO_CLONE" == true || "$PREP_FOR_BACKPORTING" == true ]]; then
        cmds+=(git)
    fi

    if [[ "$DO_BUILD" == true && -n "$DTB_REL_PATH" ]]; then
        cmds+=(dtc)
    fi

    if [[ "$DO_CONFIG" == true ]]; then
        cmds+=(ctags)
    fi

    kb_require_commands "${cmds[@]}"
}


centos_create_log_file()
{
    local ts gccv host

    ts="$(date +"%Y_%m_%d_%H%M")"
    gccv="$(gcc --version | head -n 1 || true)"
    host="$(hostname -s 2>/dev/null || echo unknown)"

    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/${KERNEL_PREFIX}_kernel_build_${ts}.log"

    {
        echo "//---------------------------------------------------------------"
        echo "// ${KERNEL_DESCRIPTION} Build"
        echo "// Date: $(date)"
        echo "// Host: ${host}"
        echo "// PLATFORM: ${PLATFORM}"
        echo "// ARCH: ${TARGET_ARCH}"
        echo "// KERNEL_ARCH: ${KERNEL_ARCH}"
        echo "// KERNEL_SRC_DIR =   ${KERNEL_SRC_DIR}"
        echo "// KERNEL_BUILD_DIR = ${KERNEL_BUILD_DIR}"
        echo "// GCC: ${gccv}"
        echo "// FORK: ${FORK_NAME}"
        echo "// STREAM: ${STREAM}"
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

    case "$STREAM" in
        y9)
            centos_git_remote_ensure cs9 "https://gitlab.com/redhat/centos-stream/src/kernel/centos-stream-9.git"
            ;;
        y10)
            centos_git_remote_ensure cs10 "https://gitlab.com/redhat/centos-stream/src/kernel/centos-stream-10.git"
            ;;
        z9)
            centos_git_remote_ensure rhel9 "https://gitlab.com/redhat/rhel/src/kernel/rhel-9.git"
            ;;
        z10)
            centos_git_remote_ensure rhel10 "https://gitlab.com/redhat/rhel/src/kernel/rhel-10.git"
            ;;
        *)
            kb_die "Invalid stream '${STREAM}'" 2
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

    case "$STREAM" in
        y9|z9)
            if [[ "$DEBUG_CONFIG" == true ]]; then
                pattern="kernel-5.*-${TARGET_ARCH}-debug.config"
            else
                pattern="kernel-5.*-${TARGET_ARCH}.config"
            fi
            ;;
        y10|z10)
            if [[ "$DEBUG_CONFIG" == true ]]; then
                pattern="kernel-6.*-${TARGET_ARCH}-debug.config"
            else
                pattern="kernel-6.*-${TARGET_ARCH}.config"
            fi
            ;;
        *)
            kb_die "Invalid stream '${STREAM}'" 2
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
    if make -C "$KERNEL_SRC_DIR" -j"$(nproc)" dist-configs >>"$LOG_FILE" 2>&1; then
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
        make
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
    if rm -rf "$KERNEL_BUILD_DIR" "$HOME/rpmbuild" && mkdir -p "$KERNEL_BUILD_DIR"; then
        kb_status_end_ok "   - Resetting build directory"
    else
        rc=$?
        kb_status_end_fail "   - Resetting build directory" "$rc"
        return "$rc"
    fi

    centos_generate_config || return $?

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

    rm -rf "$HOME/rpmbuild"
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
    if make -C "$KERNEL_SRC_DIR" ARCH="$KERNEL_ARCH" mrproper >>"$LOG_FILE" 2>&1; then
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
    if make -C "$KERNEL_SRC_DIR" -j"$(nproc)" O="$KERNEL_BUILD_DIR" ARCH="$KERNEL_ARCH" \
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

    [[ "$TARGET_ARCH" == "x86_64" ]] && return 0

    kb_status_begin "   - Building DTBs"
    if make -C "$KERNEL_SRC_DIR" -j"$(nproc)" O="$KERNEL_BUILD_DIR" ARCH="$KERNEL_ARCH" DTC_FLAGS="-@" dtbs >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Building DTBs"
    else
        rc=$?
        kb_status_end_fail "   - Building DTBs" "$rc"
        return "$rc"
    fi

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

centos_collect_rpms()
{
    local rc
    local rpm_dir="${KERNEL_BUILD_DIR}/deploy/rpms"

    [[ "$DO_BUILD_RPM" == true ]] || return 0

    kb_status_begin "   - Building RPM packages"
    if make -C "$KERNEL_SRC_DIR" -j"$(nproc)" O="$KERNEL_BUILD_DIR" ARCH="$KERNEL_ARCH" binrpm-pkg >>"$LOG_FILE" 2>&1; then
        kb_status_end_ok "   - Building RPM packages"
    else
        rc=$?
        kb_status_end_fail "   - Building RPM packages" "$rc"
        return "$rc"
    fi

    kb_status_begin "   - Collecting RPM packages"
    if mkdir -p "$rpm_dir" && compgen -G "$HOME/rpmbuild/RPMS/${TARGET_ARCH}/*.rpm" >/dev/null; then
        cp "$HOME"/rpmbuild/RPMS/"${TARGET_ARCH}"/*.rpm "$rpm_dir"/
        kb_status_end_ok "   - Collecting RPM packages"
    else
        rc=$?
        kb_status_end_fail "   - Collecting RPM packages" "$rc"
        return 1
    fi
}

centos_copy_build_artifacts()
{
    local deploy_dir="${KERNEL_BUILD_DIR}/deploy"
    local kernel_image_name
    local kernel_image_dst

    kernel_image_name="$(basename "$KERNEL_IMAGE_PATH")"
    kernel_image_dst="${deploy_dir}/${kernel_image_name}-${KERNEL_PREFIX}-${KERNEL_RELEASE}"

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
        make -C "$KERNEL_SRC_DIR" -j"$(nproc)"
        O="$KERNEL_BUILD_DIR" ARCH="$KERNEL_ARCH" ENABLE_WERROR=
    )

    echo "${WHITE}Building ${KERNEL_DESCRIPTION} kernel:${NORMAL}"
    echo "${WHITE}   - Log file: ${CYAN}${LOG_FILE}${NORMAL}"

    kb_status_begin "   - Preparing cross-compile environment"
    if kb_setup_cross_compile "$TARGET_ARCH" >/dev/null 2>&1; then
        kb_status_end_ok "   - Preparing cross-compile environment"
    else
        rc=$?
        kb_status_end_fail "   - Preparing cross-compile environment" "$rc"
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
    centos_parse_args "$@"
    kb_init_colors

    kb_require_env_vars KERNEL_SRC_DIR KERNEL_BUILD_DIR

    centos_require_stream
    centos_resolve_platform
    kb_validate_architecture "$TARGET_ARCH"
    centos_resolve_build_targets
    kb_set_dtb_paths
    centos_require_local_commands

    if [[ "$DEBUG_CONFIG" == true || -n "$KERNEL_CONFIG_FILE" ]]; then
        [[ "$DO_CONFIG" == true ]] || kb_die "-d and -k require -c" 2
    fi

    echo
    echo "${WHITE}KERNEL_SRC_DIR:   ${CYAN}${KERNEL_SRC_DIR}${NORMAL}"
    echo "${WHITE}KERNEL_BUILD_DIR: ${CYAN}${KERNEL_BUILD_DIR}${NORMAL}"
    echo

    centos_create_log_file

    if [[ "$DO_CLONE" == true ]]; then
        centos_clone_kernel_repos
    fi

    if [[ "$PREP_FOR_BACKPORTING" == true ]]; then
        centos_prepare_for_backporting
    fi

    [[ -d "$KERNEL_SRC_DIR" ]] || kb_die "KERNEL_SRC_DIR does not exist: ${KERNEL_SRC_DIR}" 1

    if [[ "$DO_CONFIG" == true ]]; then
        centos_configure_kernel
    fi

    if [[ "$DO_CLEAN" == true ]]; then
        centos_clean_kernel
    fi

    if [[ "$DO_BUILD" == true ]]; then
        [[ -f "${KERNEL_BUILD_DIR}/.config" ]] || kb_die "No existing .config found in ${KERNEL_BUILD_DIR}. Run with -c first." 1
        kb_set_orin_nano_performance_mode
        centos_build_kernel
        echo
    fi

    kb_done
}
