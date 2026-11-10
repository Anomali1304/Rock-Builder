# Rock-Builder

Automated kernel builder for Xiaomi Rock (MT6789), powered by GitHub Actions.

[![Build](https://github.com/Anomali1304/Rock-Builder/actions/workflows/build.yml/badge.svg)](https://github.com/Anomali1304/Rock-Builder/actions/workflows/build.yml)
[![Platform](https://img.shields.io/badge/Platform-Xiaomi%20Rock-blue)](https://github.com/Anomali1304/Rock-Builder)

## Development Progress

| Component | Status |
|---|---|
| GKI Build System | Complete |
| Kernel Source Selection | Complete |
| Clang Toolchain Selection | Complete |
| Thin / Full LTO | Complete |
| Vanilla / KSU Next / BakaSU | Complete |
| External Kernel Modules | Complete |
| AnyKernel3 Packaging | Complete |
| Separate Kernel / Modules ZIP | Complete |
| Replaceable MT6789 GPU OPP Header | Complete |
| Automatic GPU OPP Overclock | Complete |

## Features

- Build from supported Xiaomi Rock kernel sources.
- Choose GKI, ZyC, or a custom Clang toolchain.
- Select Thin or Full LTO.
- Choose Vanilla, KernelSU Next, or BakaSU.
- Build all external modules or select specific modules.
- Generate separate flashable kernel and modules ZIP files.
- Configure kernel name, local version, and ZIP prefix.
- Override the MT6789 GPU frequency and voltage table from `gpu/gpufreq_mt6789.h`.
- Select a GPU maximum frequency from 1100 to 1500 MHz in 25 MHz steps.

## Build

1. Open the **Actions** tab.
2. Select **Rock Kernel Builder**.
3. Choose **Run workflow**.
4. Configure the build options.
5. Start the workflow and wait for completion.
6. Download the artifacts from the completed run.

## Build Options

| Option | Choices |
|---|---|
| Kernel Source | Anomali1304, Asmodeus7999 |
| Clang | GKI, ZyC, Custom |
| LTO | Thin, Full |
| Root Variant | Vanilla, KSU Next, BakaSU |
| External Modules | Enabled or Disabled |
| GPU OC Target | 1100 to 1500 MHz, 25 MHz steps |
| Module Selection | Required list by default, or comma-separated names |

Leave the module selection empty to build all configured modules.

## GPU Overclock

The builder copies `gpu/gpufreq_mt6789.h` over the kernel source header before compilation. Set the GPU OC target in the workflow. The generator adds OPPs above 1100 MHz in 25 MHz steps. It extrapolates voltage from the first five stock OPPs, rounds up to the 625-unit PMIC step, validates hardware limits, and updates AVS, aging, segment, and MCL50 indices. AVS remains enabled. Calculated voltage is a starting point and does not guarantee silicon stability.

## Output

The workflow uploads two separate artifacts:

- **Kernel ZIP:** Minimal AnyKernel3-based flashable package containing `Image.gz`.
- **Modules ZIP:** Selected modules under `modules/system/lib/modules/`.

## Sources & Credits

- [Anomali1304 Kernel Source](https://github.com/Anomali1304/android_kernel_xiaomi_rock)
- [Asmodeus7999 Kernel Source](https://github.com/Asmodeus7999/android_kernel_xiaomi_rock)
- [Android Common Kernel](https://android.googlesource.com/kernel/common/)
- [KernelSU Next](https://github.com/KernelSU-Next/KernelSU-Next)
- [SUSFS](https://github.com/simonpunk/susfs4ksu)
- [ZyC Clang](https://github.com/ZyCromerZ/Clang)
- [AnyKernel3](https://github.com/Anomali1304/AnyKernel3)

## Disclaimer

For development and testing. Flash at your own risk and keep a backup of your current boot image.
