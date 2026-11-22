# kernel-build

A small Bash-based kernel build toolkit for two workflows:

- **upstream Linux** builds
- **CentOS Stream** kernel builds

The project is intentionally focused on **building** kernels, not installing them.
Install and uninstall steps are left to **platform-specific notes or scripts**.

This keeps the build logic reusable while avoiding fragile assumptions about
boot firmware, DTB handling, initramfs generation, and bootloader behavior on
different targets.

---

## What this project does

`kernel-build` helps you:

- build **upstream Linux** kernels out of tree
- build **CentOS Stream** kernels out of tree
- use the native host architecture by default, with optional target architecture or board preset
- automatically apply the bundled `configs/kernel-overrides.txt` configuration tweaks when configuring
- set a custom `CONFIG_LOCALVERSION`
- generate clean, timestamped build logs
- stage build outputs into predictable locations:
  - `deploy/`
  - `modules_staging/`
- honor Kbuild's configured boot image instead of assuming `Image` or `bzImage`

For the CentOS Stream workflow, it can also:

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
- ARM and RISC-V board bring-up
- quick iteration on custom kernels

### CentOS Stream kernel builds

The downstream side supports:

- public CentOS Stream 9 / 10 (selected with `CS_VERSION`, default `10`)
- backport-oriented workspaces
- downstream config generation via `dist-configs`

Typical use cases:

- backport validation
- downstream patch testing
- stream-specific custom kernel builds

---

## Architecture and board presets

By default (no `-p` and no `-a`), the builder uses `uname -m` for its
**target architecture**, and does not build a board-specific DTB. This works
for native x86_64 builds on shire and generic ARM64 builds on an ARM host.

Pass `-a x86_64`, `-a aarch64`, or `-a riscv64` to choose a different
architecture explicitly. A non-native `-a` selects the cross-compiler.
Use `-p` only when a board-specific DTB should be built/staged.

The available board presets are:

- `rpi4`
- `opi5plus`
- `orin-nano`
- `vf2`
- `arm-server`

When `-p` is given, architecture is inferred from that board preset. Using
`-a` and `-p` together is allowed only if their architectures agree.

At the moment, these platform mappings resolve to:

- `rpi4` → `aarch64`
- `opi5plus` → `aarch64`
- `orin-nano` → `aarch64`
- `vf2` → `riscv64`
- `arm-server` → `aarch64`

DTB paths are also inferred from the platform where applicable. The `vf2` preset uses the VisionFive 2 v1.3B DTB. The `arm-server` preset represents an arm64 UEFI/ACPI server and therefore does not build or stage DTBs.

The kernel boot image is not hard-coded by architecture. After the kernel
configuration is finalized, kernel-build asks Kbuild's `image_name` target
for the configured `KBUILD_IMAGE` and builds that target. For example, a
RISC-V configuration with `CONFIG_EFI_ZBOOT=y` resolves to
`arch/riscv/boot/vmlinuz.efi` rather than the uncompressed `Image`.

---

## Project layout

```text
kernel-build/
├── upstream-kernel-build
├── centos-kernel-build
├── configs/
│   └── kernel-overrides.txt
└── lib/
    ├── kernel-build-common.sh
    ├── kernel-build-upstream.sh
    └── kernel-build-centos.sh
```

The two front-end scripts are intentionally thin.
Most shared behavior lives in the common library, while upstream-specific and
CentOS-specific behavior lives in separate libraries.

---

## Version

The current kernel-build version is `1.0.0`. Both front ends print the
version when they start. Version 0.1.1 fixes kernel-image selection by using
Kbuild's configured `KBUILD_IMAGE`; this is required for RISC-V EFI zboot
kernels such as the VisionFive 2 Fedora configuration.

To print only the version, use:

```bash
./upstream-kernel-build -V
./centos-kernel-build -V
```

---

## Environment variables

Both builders require just a workspace directory; the target architecture
is inferred from the host unless `-a` or `-p` specifies a different target:

```bash
export KERNEL_WORKSPACE_DIR="$HOME/projects/my-project"
# Only for CentOS Stream:
export CS_VERSION=10  # optional; 10 is the default, 9 is also supported
```

The builders derive source and architecture-specific build directories:

| Builder | Source directory | Build directory (x86_64 example) |
| --- | --- | --- |
| CentOS Stream 10 | `$KERNEL_WORKSPACE_DIR/centos-stream-10` | `$KERNEL_WORKSPACE_DIR/build-centos-stream-10-x86_64` |
| Upstream Linux | `$KERNEL_WORKSPACE_DIR/upstream_kernel` | `$KERNEL_WORKSPACE_DIR/build-upstream-x86_64` |

For an ARM64 target, the corresponding build directory ends in `-aarch64`.
Both architectures share the same source tree and use independent `.config`
files and build objects. Generic ARM64 and an ARM64 board preset share the
same build directory, so the target marker prevents incompatible reuse.

Do not export `KERNEL_SRC_DIR` or `KERNEL_BUILD_DIR` for either builder.
Matching old exports are tolerated, but conflicting values are rejected.
For upstream `-c`, the builder generates the architecture's Kbuild `defconfig`
when the derived build directory has no `.config`. If `.config` already exists,
`-c` preserves it as the starting point and normalizes it with `olddefconfig`.
Unlike CentOS Stream `-c`, upstream `-c` does not reset the build directory.

### Parallel compilation

The builder defaults to **all available logical CPUs** for `make -j<N>`.
On shire's unrestricted i7-8700, that means `make -j12` for both native
x86_64 builds and ARM64 cross-builds. CPU availability is detected with
Python's `os.sched_getaffinity(0)` (falling back to `os.cpu_count()`); if
Python is not available, it falls back to `nproc` and finally one job.
The affinity check respects taskset/cpuset restrictions.

Every Kbuild `make` invocation runs via `nice -n 10`, including configuration,
compilation, module installation, DTBs, and RPM build steps. Compiler and
linker subprocesses inherit the lower priority, leaving KDE and other
interactive tasks responsive without reducing build parallelism. Clone-only
Git operations aren't reniced. On systems lacking `nice`, builds proceed at
normal priority.

To override the default parallelism, set `KERNEL_BUILD_JOBS` for the command:

```bash
KERNEL_BUILD_JOBS=8 ./upstream-kernel-build -a aarch64 -c -b -l test
```

The chosen job count and nice level are recorded in the build log.

The older `build-centos-stream-10/` directory is **not deleted or moved** during
upgrades. Version 0.1.7 and later create a new directory per architecture. An old
`KERNEL_BUILD_DIR` export should be unset, otherwise the builder rejects it.

Logs are written under:

```bash
$HOME/logs
```

unless `LOG_DIR` is set explicitly.

---

## Command overview

### `upstream-kernel-build`

Builds an **upstream Linux** kernel from an existing source tree under
`$KERNEL_WORKSPACE_DIR/upstream_kernel`, using a build directory selected
by the target architecture. Configuration starts with an existing `.config`
when available, or generates the architecture's `defconfig` automatically.

#### Usage

```text
Usage: upstream-kernel-build [options]

Options:
  -b                            Build the kernel
  -c                            Configure kernel
  -C                            Clean build tree
  -d                            Configure kernel for debugging (requires -c)
  -h                            Show help
  -l <localversion>             Set CONFIG_LOCALVERSION
  -a <arch>                     Target architecture (default: host)
  -p <platform>                 Optional board preset (opi5plus|rpi4|orin-nano|vf2|arm-server)
  -V                            Show kernel-build version

Environment:
  KERNEL_WORKSPACE_DIR            Required parent of source/build directories
```

---

### `centos-kernel-build`

Builds a **CentOS Stream** kernel. Set `CS_VERSION=9` or `CS_VERSION=10` in the environment (default: 10). There is no `-s` or `-z` option.

#### Usage

```text
Usage: centos-kernel-build [options]

Options:
  -b                            Build the kernel
  -c                            Configure kernel
  -C                            Reset build directory (removes .config)
  -d                            Configure kernel for debugging (requires -c)
  -f <fork>                     CentOS Stream kernel fork
  -g                            Git clone
  -h                            Show help
  -l <localversion>             Set CONFIG_LOCALVERSION
  -a <arch>                     Target architecture (default: host)
  -p <platform>                 Optional board preset (opi5plus|rpi4|orin-nano|vf2|arm-server)
  -r                            Build RPM packages
  -U <upstream-kernel-repo>     Upstream kernel repository (next|stable)
  -V                            Show kernel-build version
  -x                            Prepare for backporting
```

---

## Quick start

## Upstream kernel

### 1. Set the workspace and clone upstream Linux

```bash
export KERNEL_WORKSPACE_DIR="$HOME/projects/opi5plus"
mkdir -p "$KERNEL_WORKSPACE_DIR"
git clone https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git \
    "$KERNEL_WORKSPACE_DIR/upstream_kernel"
```

No initial `.config` is required. When you first configure for ARM64, the
builder creates `build-upstream-aarch64/` and generates ARM64 `defconfig`.
It then applies the matching settings in `configs/kernel-overrides.txt` and
normalizes the result using `olddefconfig`.

To **optionally seed a known-working board config**, create the ARM64 build
directory and copy `/boot/config-*` into it *before* running `-c`:

```bash
mkdir -p "$KERNEL_WORKSPACE_DIR/build-upstream-aarch64"
scp user@board:/boot/config-6.17.6-200.fc42.aarch64 \
    "$KERNEL_WORKSPACE_DIR/build-upstream-aarch64/.config"
```

A working-board configuration may be preferable for boot testing, while
`defconfig` is sufficient as a starting point for general compile validation.
Neither automatically guarantees that every driver needed by a particular
board is enabled; check the resulting `.config` for your intended features.

### 2. Configure

```bash
./upstream-kernel-build \
    -p opi5plus \
    -c \
    -l florence
```

### 3. Build

```bash
./upstream-kernel-build \
    -p opi5plus \
    -b -l florence
```

### 4. Configure and build in one step

```bash
./upstream-kernel-build \
    -p opi5plus \
    -c -b \
    -l florence
```

---

## CentOS Stream kernel

### 1. Set the workspace

```bash
export CS_VERSION=10
export KERNEL_WORKSPACE_DIR="$HOME/projects/rhel-293896"
mkdir -p "$KERNEL_WORKSPACE_DIR"
```

The builder derives `centos-stream-10/` and an architecture-specific build directory
(e.g. `build-centos-stream-10-x86_64` or `build-centos-stream-10-aarch64`)
automatically. No source/build directory exports are required.

### 2. Clone your public CentOS Stream fork on main

```bash
./centos-kernel-build \
    -g -f sdunnaga-rhel-293896
```

To add public CentOS Stream and upstream stable remotes for larger backports,
add `-x -U stable` to the clone command. `-x` fetches full histories and can
take considerable time.

### 3. Configure and build after applying your patches

For a native build, the architecture is inferred from the host. The bundled
`configs/kernel-overrides.txt` is applied automatically when configuring:

```bash
./centos-kernel-build -c -b -l madrid
```

For an Orin Nano build, supply `-p orin-nano` to also select its DTB.
Subsequent incremental builds use:

```bash
./centos-kernel-build -b -l madrid
```


---

## Automatic kernel configuration overrides

Both builders **always load** `configs/kernel-overrides.txt` when `-c` is used.
No `-k` option, separate configuration filename, or environment variable is
needed. The file is located relative to the installed builder, not the
current working directory. Edit that single file to adjust your local build
preferences for any target; empty/comment-only sections make no changes.

CentOS Stream builds start from the architecture-specific configuration
created with `dist-configs`, then apply the matching overrides. Upstream
builds preserve an existing `.config` or generate the architecture's
`defconfig` when one is absent, then apply the matching overrides. Both
builders normalize the result with `olddefconfig`.

The sections in the file determine which overrides apply:

```ini
[all]
# Both builders and all targets

[centos]
# Any CentOS Stream kernel

[arch:aarch64]
# Any ARM64 target

[platform:orin-nano]
# Only when -p orin-nano is selected

[centos:opi5plus]
# Only CentOS + Orange Pi 5 Plus

[upstream:opi5plus]
# Only upstream + Orange Pi 5 Plus
```

Directives include `enable`, `disable`, `module`, `set-val`, and `set-str`.
A section applies to the directives that follow it until another section.
Unknown section names or unknown Kconfig symbols in applicable sections
cause configuration to fail rather than silently skipping them.

**Local versus distribution validation:** The bundled `[centos]` section preserves
legacy local development choices, including disabling SELinux, BTF, and
module-signing features. Those options apply automatically to a local build.
If you want an unmodified distribution configuration, comment those directives
out in `configs/kernel-overrides.txt`, then re-run `-c`. A downstream CI
or production build pipeline may use separate configurations; a passing local
build is not a substitute for that validation.

Overrides are applied **during configuration**, not every build. After editing
the file, run `-c` again to refresh `.config`; an incremental `-b` alone uses
the already-generated `.config`.

For native CS10 on x86_64:

```bash
export CS_VERSION=10
export KERNEL_WORKSPACE_DIR="$HOME/projects/rhel-293896"
./centos-kernel-build -c -b -l madrid
```

### Build directory target safety

After configuration, the builder records the architecture and preset in
`$KERNEL_BUILD_DIR/.kernel-build-target`. Building with a different target
using the same output directory is rejected. Existing build directories with a
`.config` but without this marker must be reconfigured once with `-c`.
Different architectures now get separate output directories automatically.
Different board presets of the same architecture still share a directory, and
the target marker prevents accidentally building with the wrong preset.

The CentOS `-C -c -b` flow now cleans before configuring, so its new `.config`
is not deleted by the cleanup step. `-C` by itself resets the CentOS build
directory; follow it with `-c` before `-b`.

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

Pass the localversion without a leading `-`; the scripts add it automatically.
When supplying it through a shell variable, make an unset or empty value fail
before invoking the builder:

```bash
-l "${KERNEL_ID:?KERNEL_ID is not set}"
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

## Audible build completion (optional)

When running either builder with `-b`, kernel-build plays one sound when the
**entire build** finishes, including module staging and artifact copying:

- **Success:** `/usr/share/sounds/freedesktop/stereo/complete.oga`
- **Failure:** `/usr/share/sounds/freedesktop/stereo/service-logout.oga`

Audio is best-effort and intended for a Fedora desktop session. The builder
tries `canberra-gtk-play`, then `pw-play`, then `paplay` if available. Missing
sound files, missing players, and audio server failures are ignored. They do
not affect the build's exit status. Clone-only, configuration-only, help, and
version commands do not play sounds. Both builders are silent on headless
systems without usable desktop audio.

To enable a player if none is installed on Fedora, you can install
`libcanberra-gtk3` (which provides `canberra-gtk-play`), or `pipewire-utils`
(which provides `pw-play`). You can change the sound directory with the
optional `KB_BUILD_SOUND_DIR` environment variable; the filenames above
remain fixed.

## Build outputs

The build outputs are staged into predictable locations under
`KERNEL_BUILD_DIR`.

### Common output directories

```text
$KERNEL_BUILD_DIR/deploy/
$KERNEL_BUILD_DIR/modules_staging/
```

### Upstream output examples

The deployed kernel filename follows the image selected by Kbuild. Typical
examples are:

```text
$KERNEL_BUILD_DIR/deploy/Image-upstream-<kernel-release>      # arm64 Image
$KERNEL_BUILD_DIR/deploy/vmlinuz-upstream-<kernel-release>    # EFI zboot
$KERNEL_BUILD_DIR/deploy/dtbs/
$KERNEL_BUILD_DIR/modules_staging/lib/modules/<kernel-release>/
```

For the VisionFive 2 Fedora configuration with `CONFIG_EFI_ZBOOT=y`, the
expected kernel artifact is `vmlinuz-upstream-<kernel-release>`.

### CentOS Stream output examples

Likewise, the deployed downstream kernel filename follows Kbuild's selected
image:

```text
$KERNEL_BUILD_DIR/deploy/Image-cs10-<kernel-release>
$KERNEL_BUILD_DIR/deploy/vmlinuz-cs10-<kernel-release>        # EFI zboot
$KERNEL_BUILD_DIR/deploy/dtbs/
$KERNEL_BUILD_DIR/modules_staging/lib/modules/<kernel-release>/
$KERNEL_BUILD_DIR/deploy/rpms/     # when -r is used
```

The scripts also print a short artifact summary at the end of a successful build.

---

## Notes on the CentOS Stream configure flow

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
9. builds ctags if installed
10. records the build target architecture/platform

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
- `dtc` (board builds that need DTBs)
- `ctags` (optional; tag generation is skipped if unavailable)

Additional tooling may be needed depending on workflow.

---

## Status

This project has been exercised successfully in the following scenarios:

- custom **CentOS Stream 10** kernel build on **RPi 4**
- custom **CentOS Stream 10** kernel build on **Orin Nano**
- custom **upstream Linux** kernel build on **Orange Pi 5+**
- manual installation workflows validated separately per target

---

## Running tests

From the repository root, run the shell smoke tests without compiling a full kernel:

```bash
for test in tests/*.sh; do bash "$test"; done
```

## License

MIT. See [LICENSE](LICENSE).
