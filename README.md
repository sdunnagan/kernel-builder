# kernel-builder

A small Bash-based kernel build toolkit for two workflows:

- **upstream Linux** builds
- **CentOS Stream / RHEL downstream** kernel builds

The project is intentionally focused on **building** kernels, not installing them.  
Install and uninstall steps are left to **platform-specific notes or scripts**.

This keeps the build logic reusable while avoiding fragile assumptions about
boot firmware, DTB handling, initramfs generation, and bootloader behavior on
different targets.

---

## What this project does

`kernel-builder` helps you:

- build **upstream Linux** kernels out of tree
- build **CentOS Stream / RHEL** kernels out of tree
- infer architecture and DTB handling from the target **platform**
- apply local configuration tweaks from a config input file
- set a custom `CONFIG_LOCALVERSION`
- generate clean, timestamped build logs
- stage build outputs into predictable locations:
  - `deploy/`
  - `modules_staging/`

For the CentOS Stream / RHEL workflow, it can also:

- clone a downstream kernel tree
- prepare a workspace for backporting by adding useful git remotes

---

## What this project does not do

This project does **not** attempt to automate installation or removal of kernels
on target systems.

That work is deliberately left outside the project because real-world boot
chains vary a lot between boards and systems. In practice, installation details
can differ based on:

- UEFI vs non-UEFI boot
- ACPI vs DT/OF
- BLS/grubby vs custom bootloader flow
- `/boot` layout
- initramfs generation on the target
- DTB usage and DTB location

In short: **this project builds kernels**.  
You can then install them using separate platform-specific notes or scripts.

---

## Supported workflows

### Upstream kernel builds

The upstream side assumes you already have a kernel source tree checked out.

Typical use cases:

- mainline kernel testing
- local feature work
- ARM board bring-up
- quick iteration on custom kernels

### CentOS Stream / RHEL kernel builds

The downstream side supports:

- CentOS Stream 9 / 10
- RHEL 9 / 10
- backport-oriented workspaces
- downstream config generation via `dist-configs`

Typical use cases:

- backport validation
- downstream patch testing
- stream-specific custom kernel builds

---

## Supported platforms

The current platform list is intentionally small and explicit:

- `rpi4`
- `opi5plus`
- `orin-nano`

Architecture is inferred from the selected platform.

At the moment, these platform mappings resolve to:

- `rpi4` → `aarch64`
- `opi5plus` → `aarch64`
- `orin-nano` → `aarch64`

DTB paths are also inferred from the platform where applicable.

---

## Project layout

```text
kernel-builder/
├── upstream-kernel-builder
├── centos-kernel-builder
└── lib/
    ├── kernel-builder-common.sh
    ├── kernel-builder-upstream.sh
    └── kernel-builder-centos.sh
```

The two front-end scripts are intentionally thin.  
Most shared behavior lives in the common library, while upstream-specific and
CentOS-specific behavior lives in separate libraries.

---

## Environment variables

Both workflows use these environment variables:

```bash
export KERNEL_SRC_DIR="/path/to/kernel/source/tree"
export KERNEL_BUILD_DIR="/path/to/out-of-tree/build"
```

`KERNEL_SRC_DIR` points at the source tree.  
`KERNEL_BUILD_DIR` points at the out-of-tree build directory.

Logs are written under:

```bash
$HOME/logs
```

unless `LOG_DIR` is set explicitly.

---

## Command overview

### `upstream-kernel-builder`

Builds an **upstream Linux** kernel from an existing source tree.

#### Usage

```text
Usage: upstream-kernel-builder [options]

Options:
  -b                            Build the kernel
  -c                            Configure kernel
  -C                            Clean build tree
  -d                            Configure kernel for debugging (requires -c)
  -h                            Show help
  -k <config-file>              Apply Kconfig from file
  -l <localversion>             Set CONFIG_LOCALVERSION
  -p <platform>                 Target platform (required: opi5plus|rpi4|orin-nano)
```

---

### `centos-kernel-builder`

Builds a **CentOS Stream / RHEL downstream** kernel.

#### Usage

```text
Usage: centos-kernel-builder [options]

Options:
  -b                            Build the kernel
  -c                            Configure kernel
  -C                            Clean build tree
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
```

---

## Quick start

## Upstream kernel

### 1. Set the workspace

```bash
export KERNEL_SRC_DIR="/home/user/projects/opi5plus/upstream_kernel"
export KERNEL_BUILD_DIR="/home/user/projects/opi5plus/build_upstream_kernel"
```

### 2. Configure

```bash
./upstream-kernel-builder \
    -p opi5plus \
    -c -k /home/user/projects/opi5plus/upstream_kernel_config_opi5plus.txt \
    -l florence
```

### 3. Build

```bash
./upstream-kernel-builder \
    -p opi5plus \
    -b -l florence
```

### 4. Configure and build in one step

```bash
./upstream-kernel-builder \
    -p opi5plus \
    -c -b -k /home/user/projects/opi5plus/upstream_kernel_config_opi5plus.txt \
    -l florence
```

---

## CentOS Stream / RHEL kernel

### 1. Set the workspace

```bash
export KERNEL_SRC_DIR="/home/user/projects/rhel-158921/centos-stream-10"
export KERNEL_BUILD_DIR="/home/user/projects/rhel-158921/build-centos-stream-10"
```

### 2. Clone and prepare a backport workspace

```bash
./centos-kernel-builder \
    -p rpi4 -s y10 \
    -g -x -f my-fork-name -U stable
```

### 3. Configure

```bash
./centos-kernel-builder \
    -p rpi4 -s y10 \
    -c -k /home/user/projects/rhel-158921/cs10_kernel_config_rpi4.txt \
    -l madrid
```

### 4. Build

```bash
./centos-kernel-builder \
    -p rpi4 -s y10 \
    -b -l madrid
```

### 5. Configure and build in one step

```bash
./centos-kernel-builder \
    -p rpi4 -s y10 \
    -c -b -k /home/user/projects/rhel-158921/cs10_kernel_config_rpi4.txt \
    -l madrid
```

---

## Configuration input files

Both workflows support:

```bash
-k <config-file>
```

The config input file is a simple line-oriented list of `scripts/config` style
operations, for example:

```text
disable WERROR
disable SECURITY_SELINUX
disable DEBUG_INFO_BTF
disable DEBUG_INFO_BTF_MODULES
disable MODULE_SIG_ALL
disable MODULE_SIG_FORCE
```

These input files are useful for keeping board-specific or task-specific config
changes small and reviewable.

---

## Localversion handling

Both workflows support:

```bash
-l <localversion>
```

This is used to set `CONFIG_LOCALVERSION`, which gives the built kernel an
identifiable release string such as:

```text
6.12.0-madrid+
7.0.0-florence+
```

For rebuilds, use the same `-l` value you used during configuration.

---

## Logs

Each script invocation creates a fresh timestamped log file.

Examples:

```text
/home/user/logs/upstream_kernel_build_2026_04_16_1135.log
/home/user/logs/cs10_kernel_build_2026_04_15_1721.log
```

If you run configure and build in a single invocation, both phases write to the
same log file.

The scripts print the log path at the start of the operation.

---

## Build outputs

The build outputs are staged into predictable locations under
`KERNEL_BUILD_DIR`.

### Common output directories

```text
$KERNEL_BUILD_DIR/deploy/
$KERNEL_BUILD_DIR/modules_staging/
```

### Upstream output example

```text
$KERNEL_BUILD_DIR/deploy/Image-upstream-<kernel-release>
$KERNEL_BUILD_DIR/deploy/dtbs/
$KERNEL_BUILD_DIR/modules_staging/lib/modules/<kernel-release>/
```

### CentOS Stream / RHEL output example

```text
$KERNEL_BUILD_DIR/deploy/Image-cs10-<kernel-release>
$KERNEL_BUILD_DIR/deploy/dtbs/
$KERNEL_BUILD_DIR/modules_staging/lib/modules/<kernel-release>/
$KERNEL_BUILD_DIR/deploy/rpms/     # when -r is used
```

The scripts also print a short artifact summary at the end of a successful build.

---

## Notes on the CentOS Stream / RHEL configure flow

The downstream configure path is intentionally different from upstream.

It does the following:

1. resets the build directory
2. runs `dist-configs` in the source tree
3. selects the matching base config from `redhat/configs`
4. seeds the out-of-tree build directory
5. applies config-file changes
6. cleans the source tree with `mrproper`
7. runs `olddefconfig`
8. reapplies the requested localversion
9. builds ctags

This matches the downstream workflow more closely than treating it like a normal
mainline build tree.

---

## Notes on installation

Installation is intentionally out of scope for this project.

However, the staged outputs are designed to make manual installation easy:

- kernel image in `deploy/`
- modules in `modules_staging/`
- DTBs in `deploy/dtbs/`

In practice, you can maintain separate installation notes per target.

Examples of targets where different install details may matter:

- Fedora on Orange Pi 5+
- CentOS Stream on Raspberry Pi 4
- CentOS Stream on Orin Nano

---

## Philosophy

This project is intentionally conservative about automation.

Kernel build logic is shareable.  
Kernel install logic is often target-specific.

So the design goal is:

- make **builds** repeatable
- keep **installation** explicit
- avoid pretending that every boot chain works the same way

---

## Requirements

This project is plain Bash and standard build tooling. Exact package names vary
by distribution, but common requirements include:

- `bash`
- `make`
- `gcc`
- `ld`
- `bc`
- `perl`
- `python3`
- `flex`
- `bison`
- `patch`
- `xz`
- `git`
- `ctags`
- `dtc`

Additional tooling may be needed depending on workflow.

---

## Status

This project has been exercised successfully in the following scenarios:

- custom **CentOS Stream 10** kernel build on **RPi 4**
- custom **CentOS Stream 10** kernel build on **Orin Nano**
- custom **upstream Linux** kernel build on **Orange Pi 5+**
- manual installation workflows validated separately per target

---

## License

Add your preferred license here.
