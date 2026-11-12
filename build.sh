#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${RUNNER_TEMP:-/tmp}/rock-kernel-build"
WORKSPACE="$WORK_DIR/workspace"
KERNEL_DIR="$WORKSPACE/common"
OUT_DIR="$WORKSPACE/out"
MODULES_DIR="$WORKSPACE/vendor/mediatek/kernel_modules"
RELEASE_DIR="$ROOT_DIR/dist"

GKI_MANIFEST_BRANCH="common-android12-5.10-lts"
EXTERNAL_MODULES_REPO="https://github.com/Asmodeus7999/MTK_kernel_modules.git"
EXTERNAL_MODULES_BRANCH="rock-u-oss"
ANYKERNEL_REPO="https://github.com/Anomali1304/AnyKernel3.git"
ANYKERNEL_BRANCH="rock"

log() { printf '[ROCK] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
trap 'status=$?; printf "[ERROR] Failed at line %s (exit %s)\n" "$LINENO" "$status" >&2; exit "$status"' ERR

install_susfs() {
    SUSFS_READY=false
    log "Attempting SUSFS integration"
    local sus_tmp="$WORK_DIR/susfs-source"
    rm -rf "$sus_tmp"
    if ! git clone --depth=1 --single-branch --branch gki-android12-5.10 \
        https://gitlab.com/simonpunk/susfs4ksu.git "$sus_tmp"; then
        log "SUSFS source unavailable. Continuing without SUSFS."
        return 0
    fi
    cp "$sus_tmp"/kernel_patches/fs/* "$KERNEL_DIR/fs/" 2>/dev/null || true
    cp "$sus_tmp"/kernel_patches/include/linux/* "$KERNEL_DIR/include/linux/" 2>/dev/null || true
    if ! patch -d "$KERNEL_DIR" -p1 --forward --no-backup-if-mismatch \
        < "$sus_tmp/kernel_patches/50_add_susfs_in_gki-android12-5.10.patch"; then
        log "SUSFS patch did not apply cleanly. Checking required files."
    fi
    if grep -q 'set_nameidata(nd, old_dfd, fake_filename, NULL)' "$KERNEL_DIR/fs/namei.c" 2>/dev/null; then
        sed -i 's/set_nameidata(nd, old_dfd, fake_filename, NULL)/set_nameidata(nd, old_dfd, fake_filename)/g' "$KERNEL_DIR/fs/namei.c"
    fi
    if [[ -s "$KERNEL_DIR/fs/susfs.c" && -s "$KERNEL_DIR/include/linux/susfs.h" ]]; then
        # These helpers are conditionally unused in some BakaSU/SUSFS feature combinations.
        # Mark only these helpers as optional instead of weakening -Werror globally.
        sed -i \
            -e 's/^static struct cred \*susfs_switch_to_ksu_domain(/static __maybe_unused struct cred *susfs_switch_to_ksu_domain(/' \
            -e 's/^static void susfs_restore_creds(/static __maybe_unused void susfs_restore_creds(/' \
            "$KERNEL_DIR/fs/susfs.c"
        grep -q 'susfs.o' "$KERNEL_DIR/fs/Makefile" || \
            printf '\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n' >> "$KERNEL_DIR/fs/Makefile"
        SUSFS_READY=true
        log "SUSFS source and build entry are ready"
    else
        log "SUSFS files are incomplete. Continuing without SUSFS."
    fi
    rm -rf "$sus_tmp"
}

setup_root_variant() {
    local fragment="$KERNEL_DIR/arch/arm64/configs/rock.fragment"
    [[ -s "$fragment" ]] || die "rock.fragment missing"
    case "$ROOT_VARIANT" in
        VANILLA)
            log "Root variant: VANILLA"
            return 0
            ;;
        KSUN)
            log "Installing KernelSU-Next dev-susfs"
            git clone --depth=1 --single-branch --branch dev-susfs \
                https://github.com/pershoot/KernelSU-Next.git "$KERNEL_DIR/KernelSU-Next"
            if [[ -s "$KERNEL_DIR/KernelSU-Next/kernel/setup.sh" ]]; then
                (cd "$KERNEL_DIR" && bash KernelSU-Next/kernel/setup.sh dev-susfs)
            else
                ln -sfn ../KernelSU-Next/kernel "$KERNEL_DIR/drivers/kernelsu"
                grep -q 'obj-y += kernelsu/' "$KERNEL_DIR/drivers/Makefile" || \
                    printf '\nobj-y += kernelsu/\n' >> "$KERNEL_DIR/drivers/Makefile"
                grep -q 'source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig" || \
                    printf '\nsource "drivers/kernelsu/Kconfig"\n' >> "$KERNEL_DIR/drivers/Kconfig"
            fi
            install_susfs
            {
                printf '\nCONFIG_KSU=y\n# CONFIG_KSU_MANUAL_HOOK is not set\n'
                printf 'CONFIG_KPROBES=y\nCONFIG_KPROBE_EVENTS=y\n'
                if [[ "$SUSFS_READY" == true ]]; then
                    printf 'CONFIG_KSU_SUSFS=y\n'
                else
                    printf '# CONFIG_KSU_SUSFS is not set\n'
                fi
            } >> "$fragment"
            ;;
        BAKASU)
            log "Installing BakaSU"
            git clone --depth=1 --single-branch --branch main \
                https://github.com/Baka-SU/BakaSU.git "$KERNEL_DIR/KernelSU"
            [[ -s "$KERNEL_DIR/KernelSU/kernel/setup.sh" ]] || die "BakaSU kernel/setup.sh missing"
            (cd "$KERNEL_DIR" && bash KernelSU/kernel/setup.sh main)
            install_susfs
            {
                printf '\nCONFIG_KSU=y\n'
                if [[ "$SUSFS_READY" == true ]]; then
                    printf 'CONFIG_KSU_SUSFS=y\n'
                elif grep -q 'ksu_handle_newfstat_ret' "$KERNEL_DIR/fs/stat.c" 2>/dev/null; then
                    printf 'CONFIG_KSU_MANUAL_HOOK=y\n'
                else
                    printf '# CONFIG_KSU_MANUAL_HOOK is not set\n'
                    printf 'CONFIG_KPROBES=y\nCONFIG_KPROBE_EVENTS=y\n'
                fi
            } >> "$fragment"
            ;;
        *)
            die "Unknown ROOT_VARIANT: $ROOT_VARIANT"
            ;;
    esac
    log "Root integration completed: $ROOT_VARIANT"
}

extract_clang_archive() {
    local archive="$1" destination="$2"
    case "$archive" in
        *.tar.zst|*.zst) tar --zstd -xf "$archive" -C "$destination" ;;
        *.tar.xz|*.xz) tar -xJf "$archive" -C "$destination" ;;
        *) tar -xf "$archive" -C "$destination" ;;
    esac
}

setup_clang_vendor() {
    local clang_dir="" asset_url="" release_json="" tmp_dir="" archive_name="" clang_bin_dir="" clang_lib_dir="" configured_bin=""
    case "$CLANG_VENDOR" in
        GKI)
            log "Using the compiler supplied by Android GKI."
            configured_bin="$(sed -n 's/^CLANG_PREBUILT_BIN=//p' "$KERNEL_DIR/build.config.common" | head -1 | tr -d '"')"
            [[ -n "$configured_bin" ]] || die "CLANG_PREBUILT_BIN missing from build.config.common"
            if [[ "$configured_bin" = /* ]]; then
                clang_bin_dir="$configured_bin"
            else
                clang_bin_dir="$WORKSPACE/$configured_bin"
            fi
            ;;
        ZyC)
            log "Resolving latest ZyCromerZ/Clang release"
            if release_json="$(curl -fsSL --retry 3 --retry-delay 2 -H 'Accept: application/vnd.github+json' -H 'User-Agent: Rock-Builder' https://api.github.com/repos/ZyCromerZ/Clang/releases/latest)"; then
                asset_url="$(printf '%s' "$release_json" | jq -r '(.assets // [])[]?.browser_download_url // empty' | grep -E 'Clang-.*\.(tar\.gz|tar\.zst|tar\.xz)' | sort -V | tail -1 || true)"
            fi
            if [[ -z "$asset_url" ]]; then
                asset_url="$(curl -fsSL --retry 3 --retry-delay 2 -H 'User-Agent: Rock-Builder' https://github.com/ZyCromerZ/Clang/releases/latest | grep -oE 'https://github\.com/ZyCromerZ/Clang/releases/download/[^"< ]+/Clang-[^"< ]+\.(tar\.gz|tar\.zst|tar\.xz)' | head -1 || true)"
            fi
            if [[ -z "$asset_url" ]]; then
                asset_url="https://github.com/ZyCromerZ/Clang/releases/download/23.0.0git-20260130-release/Clang-23.0.0git-20260130.tar.gz"
                log "Using pinned ZyC Clang fallback"
            fi
            clang_dir="$WORKSPACE/clang-zyc"
            ;;
        Custom)
            [[ -n "$CLANG_CUSTOM_URL" ]] || die "CLANG_CUSTOM_URL is required when CLANG_VENDOR=Custom"
            asset_url="$CLANG_CUSTOM_URL"
            clang_dir="$WORKSPACE/clang-custom"
            ;;
        *)
            die "Unknown CLANG_VENDOR: $CLANG_VENDOR"
            ;;
    esac

    if [[ "$CLANG_VENDOR" != "GKI" ]]; then
        tmp_dir="$(mktemp -d)"
        archive_name="$(basename "$asset_url" | sed 's/[?].*$//')"
        [[ -n "$archive_name" ]] || archive_name="clang.tar"
        rm -rf "$clang_dir"
        mkdir -p "$clang_dir"
        log "Downloading Clang archive: $asset_url"
        wget -q --show-progress "$asset_url" -O "$tmp_dir/$archive_name" || die "Clang download failed"
        case "$archive_name" in
            *.tar.zst|*.zst) tar --zstd -xf "$tmp_dir/$archive_name" -C "$clang_dir" ;;
            *.tar.xz|*.xz) tar -xJf "$tmp_dir/$archive_name" -C "$clang_dir" ;;
            *) tar -xf "$tmp_dir/$archive_name" -C "$clang_dir" ;;
        esac
        rm -rf "$tmp_dir"
        [[ -x "$clang_dir/bin/clang" ]] || die "Clang archive must contain bin/clang at its root"
        python3 - "$KERNEL_DIR/build.config.common" "$clang_dir" "$WORKSPACE" <<'PY'
import pathlib
import sys

config = pathlib.Path(sys.argv[1])
clang = pathlib.Path(sys.argv[2])
workspace = pathlib.Path(sys.argv[3])
relative = clang.relative_to(workspace)
lines = config.read_text().splitlines()
matches = [i for i, line in enumerate(lines) if line.startswith("CLANG_PREBUILT_BIN=")]
if len(matches) != 1:
    raise SystemExit(f"Expected one CLANG_PREBUILT_BIN entry, found {len(matches)}")
lines[matches[0]] = f"CLANG_PREBUILT_BIN={relative}/bin"
config.write_text("\n".join(lines) + "\n")
PY
        clang_bin_dir="$clang_dir/bin"
    fi

    [[ -x "$clang_bin_dir/clang" ]] || die "Selected Clang not found: $clang_bin_dir/clang"
    clang_lib_dir="$(dirname "$clang_bin_dir")/lib"
    export PATH="$clang_bin_dir:$PATH"
    if [[ -d "$clang_lib_dir" ]]; then
        export LD_LIBRARY_PATH="$clang_lib_dir:$LD_LIBRARY_PATH"
    fi
    export CLANG_BIN="$clang_bin_dir/clang"
    export KBUILD_COMPILER_STRING="$("$CLANG_BIN" --version | sed -n '1p')"
    log "Compiler: $KBUILD_COMPILER_STRING"
    log "Compiler path: $CLANG_BIN"
}


case "${KERNEL_SOURCE:-Anomali1304}" in
    Anomali1304)
        KERNEL_REPO="https://github.com/Anomali1304/android_kernel_xiaomi_rock.git"
        KERNEL_BRANCH="android12-5.10"
        ;;
    Asmodeus7999)
        KERNEL_REPO="https://github.com/Asmodeus7999/android_kernel_xiaomi_rock.git"
        KERNEL_BRANCH="main"
        ;;
    *) die "Unknown kernel source: ${KERNEL_SOURCE}" ;;
esac

MODULE_SELECTION="${MODULES:-}"
ROOT_VARIANT="${ROOT_VARIANT:-VANILLA}"
ZIP_PREFIX="${ZIP_PREFIX:-Rock}"
KERNEL_NAME="${KERNEL_NAME:-AlterEgo}"
KERNEL_LOCALVERSION="${KERNEL_LOCALVERSION:--AlterEgo}"
# Remove a trailing plus marker from the displayed release.
KERNEL_LOCALVERSION="${KERNEL_LOCALVERSION%+}"
CLONE_EXTERNAL="${CLONE_EXTERNAL_MODULES:-false}"
CLANG_VENDOR="${CLANG_VENDOR:-GKI}"
CLANG_CUSTOM_URL="${CLANG_CUSTOM_URL:-}"
LTO_MODE="${LTO_MODE:-thin}"
case "${LTO_MODE,,}" in
    thin|full) LTO_MODE="${LTO_MODE,,}" ;;
    *) die "Unknown LTO_MODE: $LTO_MODE (expected thin or full)" ;;
esac

command -v git >/dev/null || die "git is required"
command -v curl >/dev/null || die "curl is required"
command -v python3 >/dev/null || die "python3 is required"
command -v zip >/dev/null || die "zip is required"
command -v unzip >/dev/null || die "unzip is required"
command -v wget >/dev/null || die "wget is required"
command -v jq >/dev/null || die "jq is required"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"

log "Kernel source: $KERNEL_REPO ($KERNEL_BRANCH)"
log "Root variant: $ROOT_VARIANT"
log "External modules clone: $CLONE_EXTERNAL"
log "LTO mode: $LTO_MODE"
log "Module selection: ${MODULE_SELECTION:-ALL}"

rm -rf "$WORKSPACE" "$RELEASE_DIR"
mkdir -p "$WORKSPACE" "$RELEASE_DIR"
cd "$WORKSPACE"

if ! command -v repo >/dev/null 2>&1; then
    mkdir -p "$HOME/bin"
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/bin/repo"
    chmod a+x "$HOME/bin/repo"
    export PATH="$HOME/bin:$PATH"
fi

log "Initializing Android GKI manifest"
repo init --no-repo-verify \
    -u https://android.googlesource.com/kernel/manifest \
    -b "$GKI_MANIFEST_BRANCH" \
    --repo-rev=main \
    --depth=1
repo sync -c -j"$(nproc)" --no-tags --no-clone-bundle --force-sync

for file in build.config.common build.config.aarch64; do
    [[ -s "$KERNEL_DIR/$file" ]] || die "GKI file missing: $KERNEL_DIR/$file"
    cp "$KERNEL_DIR/$file" "$WORKSPACE/$file"
done

log "Replacing GKI common source with selected Rock kernel"
rm -rf "$KERNEL_DIR"
git clone --depth=1 --single-branch --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"

GPU_HEADER_SOURCE="$ROOT_DIR/gpu/gpufreq_mt6789.h"
GPU_HEADER_TARGET="$KERNEL_DIR/drivers/gpu/mediatek/gpufreq/v2/include/gpufreq_mt6789.h"
[[ -s "$GPU_HEADER_SOURCE" ]] || die "Custom GPU header missing: $GPU_HEADER_SOURCE"
[[ -d "$(dirname "$GPU_HEADER_TARGET")" ]] || die "MT6789 GPU header directory missing in selected kernel source"
cp -f "$GPU_HEADER_SOURCE" "$GPU_HEADER_TARGET"
log "Applied custom MT6789 GPU frequency table: gpu/gpufreq_mt6789.h"

GPU_OC_TARGET="${GPU_OC_TARGET:-1100}"
[[ "$GPU_OC_TARGET" =~ ^(1100|1125|1150|1175|1200|1225|1250|1275|1300|1325|1350|1375|1400|1425|1450|1475|1500)$ ]] || die "Invalid GPU_OC_TARGET: $GPU_OC_TARGET"
python3 "$ROOT_DIR/gpu/generate_gpu_opp.py" "$GPU_HEADER_TARGET" "$GPU_OC_TARGET"
log "GPU maximum frequency: ${GPU_OC_TARGET} MHz"

GPU_BATTERY_EFFICIENCY="${GPU_BATTERY_EFFICIENCY:-false}"
GPU_MIN_FREQ="${GPU_MIN_FREQ:-365}"
GPU_UNDERVOLT_STEP="${GPU_UNDERVOLT_STEP:-0}"
if [[ "$GPU_BATTERY_EFFICIENCY" == "true" ]]; then
    log "Applying experimental GPU battery-efficiency tuning"
    python3 "$ROOT_DIR/gpu/apply_gpu_efficiency.py" \
        "$GPU_HEADER_TARGET" "$GPU_MIN_FREQ" "$GPU_UNDERVOLT_STEP"
else
    log "GPU battery-efficiency tuning disabled. Keeping the standard GPU table."
fi

if (( GPU_OC_TARGET > 1100 )); then
    GPU_PPM_SOURCE="$KERNEL_DIR/drivers/gpu/mediatek/gpufreq/v2/gpuppm.c"
    [[ -s "$GPU_PPM_SOURCE" ]] || die "GPU PPM source missing: $GPU_PPM_SOURCE"
    python3 - "$GPU_PPM_SOURCE" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text()
pattern = r"(?ms)(\t\tcase LIMIT_THERMAL_AP:\n)(.*?)(?=\n\t\tcase LIMIT_THERMAL_EB:)"
replacement = (
    "\\1"
    "\t\t\t/* Allow generated GPU OPPs above the stock thermal-AP ceiling. */\n"
    "\t\t\t*ceiling_idx = 0;\n"
    "\t\t\t*floor_idx = GPUPPM_KEEP_IDX;\n"
    "\t\t\tbreak;\n"
)
updated, count = re.subn(pattern, replacement, source)
if count != 1:
    raise SystemExit(f"Expected one LIMIT_THERMAL_AP case in gpuppm.c, found {count}")
if updated == source:
    raise SystemExit("LIMIT_THERMAL_AP patch made no changes")
path.write_text(updated)
print("LIMIT_THERMAL_AP patched: ceiling forced to OPP 0.")
PY
    log "Applied GPU thermal-AP override for GPU overclock"
else
    log "GPU OC disabled. Keeping stock thermal-AP behavior."
fi

[[ -s "$KERNEL_DIR/build.config.rock" ]] || die "build.config.rock not found in kernel source"
[[ -s "$WORKSPACE/build/build.sh" ]] || die "GKI build/build.sh not found in workspace"

for file in build.config.common build.config.aarch64; do
    [[ -s "$WORKSPACE/$file" ]] || die "Saved GKI config missing: $file"
    cp -f "$WORKSPACE/$file" "$KERNEL_DIR/$file"
done

setup_clang_vendor
setup_root_variant

log "Applying kernel identity and localversion"
python3 - "$KERNEL_DIR/arch/arm64/configs/rock.fragment" "$KERNEL_DIR/init/version.c" "$KERNEL_LOCALVERSION" "$KBUILD_COMPILER_STRING" "$KERNEL_NAME" <<'PY'
import json
import pathlib
import re
import sys

fragment = pathlib.Path(sys.argv[1])
version_file = pathlib.Path(sys.argv[2])
localversion, compiler, display_name = sys.argv[3:6]

config = fragment.read_text()
config = re.sub(r"(?m)^CONFIG_LOCALVERSION=.*\n?", "", config)
config = re.sub(r"(?m)^# CONFIG_LOCALVERSION_AUTO is not set\n?", "", config)
config = re.sub(r"(?m)^CONFIG_LOCALVERSION_AUTO=.*\n?", "", config)
config += f"\nCONFIG_LOCALVERSION={json.dumps(localversion)}\nCONFIG_LOCALVERSION_AUTO=n\n"
fragment.write_text(config)

source = version_file.read_text()
compiler_c = json.dumps(compiler)
name_c = json.dumps(display_name)

start = source.index("const char linux_proc_banner[] =")
end = source.index("\n\nBUILD_SALT;", start)
source = source[:start] + (
    "const char linux_proc_banner[] =\n"
    '\t"%s version %s"\n'
    f'\t" (" {compiler_c} ") %s\\n";'
) + source[end:]

start = source.index("const char linux_banner[] =")
end = source.index(";", start) + 1
source = source[:start] + (
    "const char linux_banner[] =\n"
    '\t"Linux version " UTS_RELEASE\n'
    f'\t" (" {compiler_c} ") " UTS_VERSION "\\n";'
) + source[end:]
version_file.write_text(source)
PY
if [[ "$CLONE_EXTERNAL" == "true" ]]; then
    log "Cloning fixed external modules"
    mkdir -p "$(dirname "$MODULES_DIR")"
    git clone --depth=1 --single-branch --branch "$EXTERNAL_MODULES_BRANCH" \
        "$EXTERNAL_MODULES_REPO" "$MODULES_DIR"
else
    SOURCE_MODULES_DIR="$KERNEL_DIR/vendor/mediatek/kernel_modules"
    if [[ -d "$SOURCE_MODULES_DIR" ]]; then
        log "Using modules included in the selected kernel source"
        mkdir -p "$(dirname "$MODULES_DIR")"
        ln -sfn "$SOURCE_MODULES_DIR" "$MODULES_DIR"
    else
        log "No in-tree vendor modules found. Disabling EXT_MODULES."
    fi
fi

# Match the GKI build.config preparation used by 3-Cluster-CPU.
sed -i '/build.config.common/d; /build.config.aarch64/d' "$KERNEL_DIR/build.config.rock"
sed -i '1i . ./build.config.common' "$KERNEL_DIR/build.config.rock"
sed -i '2i . ./build.config.aarch64' "$KERNEL_DIR/build.config.rock"
sed -i 's|${ROOT_DIR}/${KERNEL_DIR}/|${KERNEL_DIR}/|g' "$KERNEL_DIR/build.config.rock"

if [[ ! -d "$MODULES_DIR" ]]; then
    log "No vendor module source available. Disabling EXT_MODULES in build.config.rock"
    python3 - "$KERNEL_DIR/build.config.rock" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
text, count = re.subn(r'(?ms)^EXT_MODULES=".*?^"', 'EXT_MODULES=""', text)
if count != 1:
    raise SystemExit(f"Expected one EXT_MODULES block, found {count}")
path.write_text(text)
PY
fi

# Keep build identity deterministic after GKI build.config files are sourced.
cat >> "$KERNEL_DIR/build.config.rock" <<EOF

KBUILD_BUILD_USER="$KERNEL_NAME"
KBUILD_BUILD_HOST="$ZIP_PREFIX"
export KBUILD_BUILD_USER KBUILD_BUILD_HOST
EOF

# Keep the selected compiler identity intact and omit linker metadata.
python3 - "$KERNEL_DIR/scripts/mkcompile_h" <<'PY'
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = 'CC_VERSION="$6"'
new = '''CC_VERSION="$6"
if [ -n "$KBUILD_COMPILER_STRING" ]; then
	CC_VERSION="$KBUILD_COMPILER_STRING"
fi'''
if old not in s:
    raise SystemExit("Cannot locate CC_VERSION assignment in scripts/mkcompile_h")
s = s.replace(old, new, 1)
old = '''LD_VERSION=$($LD -v | head -n1 | sed 's/(compatible with [^)]*)//' \\
		      | sed 's/[[:space:]]*$//')'''
if old not in s:
    raise SystemExit("Cannot locate linker version block in scripts/mkcompile_h")
s = s.replace(old, 'LD_VERSION=""', 1)
old = '''printf '#define LINUX_COMPILER "%s"\\n' "$CC_VERSION, $LD_VERSION"'''
new = '''printf '#define LINUX_COMPILER "%s"\\n' "$CC_VERSION"'''
if old not in s:
    raise SystemExit("Cannot locate LINUX_COMPILER output in scripts/mkcompile_h")
s = s.replace(old, new, 1)
p.write_text(s)
PY

# The kernel tree's build script expects the Rock build config at common/build.config.rock.
cd "$WORKSPACE"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

export KBUILD_BUILD_USER="$KERNEL_NAME"
export KBUILD_BUILD_HOST="$ZIP_PREFIX"
export KBUILD_BUILD_VERSION="1"

export KCFLAGS="${KCFLAGS:+$KCFLAGS }-Wno-unused-command-line-argument"

log "Compiling kernel and configured modules with $CLANG_VENDOR Clang (LTO=$LTO_MODE)"
LTO="$LTO_MODE" BUILD_CONFIG=common/build.config.rock OUT_DIR="$OUT_DIR" bash build/build.sh 2>&1 | tee "$WORKSPACE/build.log"

IMAGE="$(find "$OUT_DIR" "$KERNEL_DIR" -type f -name Image.gz -not -path '*/obj/*' -print -quit)"
[[ -n "$IMAGE" && -s "$IMAGE" ]] || die "Image.gz was not produced. Refusing to package an uncompressed Image."

log "Collecting module files"
mapfile -t ALL_MODULES < <(find "$OUT_DIR" -type f -name '*.ko' -print | sort -u)
(("${#ALL_MODULES[@]}" > 0)) || die "No .ko modules were produced"

SELECTED_MODULES=()
if [[ -z "${MODULE_SELECTION//[[:space:]]/}" ]]; then
    REQUIRED_MODULES_FILE="$ROOT_DIR/modules/required_modules.txt"
    [[ -s "$REQUIRED_MODULES_FILE" ]] || die "Required module list missing: $REQUIRED_MODULES_FILE"
    declare -A BUILT_MODULE_MAP=()
    for module in "${ALL_MODULES[@]}"; do
        BUILT_MODULE_MAP["$(basename "$module")"]="$module"
    done
    MISSING_MODULES=()
    while IFS= read -r required || [[ -n "$required" ]]; do
        required="${required%%#*}"
        required="$(printf '%s' "$required" | xargs)"
        [[ -n "$required" ]] || continue
        [[ "$required" == *.ko ]] || required="$required.ko"
        if [[ -n "${BUILT_MODULE_MAP[$required]:-}" ]]; then
            SELECTED_MODULES+=("${BUILT_MODULE_MAP[$required]}")
        else
            MISSING_MODULES+=("$required")
        fi
    done < "$REQUIRED_MODULES_FILE"
    (("${#MISSING_MODULES[@]}" == 0)) || {
        printf '[ERROR] Required modules were not built:\n' >&2
        printf '  %s\n' "${MISSING_MODULES[@]}" >&2
        exit 1
    }
    (("${#SELECTED_MODULES[@]}" > 0)) || die "Required module list is empty"
    log "Using required module allowlist: ${#SELECTED_MODULES[@]} modules"
else
    IFS=',' read -ra REQUESTED <<< "$MODULE_SELECTION"
    for requested in "${REQUESTED[@]}"; do
        requested="$(printf '%s' "$requested" | xargs)"
        requested="${requested%.ko}"
        [[ -n "$requested" ]] || continue
        found=""
        for module in "${ALL_MODULES[@]}"; do
            base="$(basename "$module" .ko)"
            if [[ "$base" == "$requested" ]]; then
                found="$module"
                break
            fi
        done
        [[ -n "$found" ]] || die "Requested module not built or not found: $requested"
        SELECTED_MODULES+=("$found")
    done
    (("${#SELECTED_MODULES[@]}" > 0)) || die "No valid module names were provided"
fi

AK_DIR="$WORK_DIR/AnyKernel3"
STAGE_DIR="$WORK_DIR/package"
log "Cloning AnyKernel3"
git clone --depth=1 --single-branch --branch "$ANYKERNEL_BRANCH" "$ANYKERNEL_REPO" "$AK_DIR"
[[ -s "$AK_DIR/anykernel.sh" ]] || die "AnyKernel3 anykernel.sh missing"

python3 - "$AK_DIR/anykernel.sh" "$KERNEL_NAME" <<'PY'
import pathlib
import re
import sys

p = pathlib.Path(sys.argv[1])
s = p.read_text()
s, n = re.subn(r"(?m)^kernel\.string=.*$", "kernel.string=" + sys.argv[2], s)
if n != 1:
    raise SystemExit(f"Expected one kernel.string entry, found {n}")
p.write_text(s)
PY

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
for item in LICENSE anykernel.sh META-INF patch ramdisk; do
    [[ -e "$AK_DIR/$item" ]] || die "Required AnyKernel3 item missing: $item"
    cp -a "$AK_DIR/$item" "$STAGE_DIR/"
done
mkdir -p "$STAGE_DIR/tools"
for item in ak3-core.sh busybox magiskboot; do
    [[ -s "$AK_DIR/tools/$item" ]] || die "Required AnyKernel3 tool missing: $item"
    cp -a "$AK_DIR/tools/$item" "$STAGE_DIR/tools/$item"
done
for item in META-INF/com/google/android/update-binary META-INF/com/google/android/updater-script tools/ak3-core.sh tools/busybox tools/magiskboot; do
    [[ -s "$STAGE_DIR/$item" ]] || die "Required AnyKernel3 file missing: $item"
done

IMAGE_NAME="Image.gz"
cp "$IMAGE" "$STAGE_DIR/$IMAGE_NAME"
SAFE_PREFIX="${ZIP_PREFIX//[^A-Za-z0-9._-]/-}"
BUILD_STAMP="$(date -u '+%Y%m%d-%H%M')"
ROOT_VARIANT_LABEL="$ROOT_VARIANT"
if [[ "$ROOT_VARIANT" == "BAKASU" ]]; then
    ROOT_VARIANT_LABEL="BakaSU"
fi
KERNEL_ZIP="$SAFE_PREFIX-Kernel-${ROOT_VARIANT_LABEL}-$BUILD_STAMP.zip"
MODULES_ZIP="$SAFE_PREFIX-Modules-${ROOT_VARIANT_LABEL}-$BUILD_STAMP.zip"

(
    cd "$STAGE_DIR"
    zip -qr9 "$RELEASE_DIR/$KERNEL_ZIP" "$IMAGE_NAME" LICENSE META-INF anykernel.sh patch ramdisk tools
)
unzip -tq "$RELEASE_DIR/$KERNEL_ZIP" >/dev/null

# Remove DWARF/debug sections from selected modules before packaging.
# Keep normal ELF symbols so the kernel can still resolve module symbols.
LLVM_STRIP="$(dirname "$CLANG_BIN")/llvm-strip"
[[ -x "$LLVM_STRIP" ]] || die "llvm-strip not found in selected Clang toolchain: $LLVM_STRIP"

log "Stripping debug information from selected modules"
for module in "${SELECTED_MODULES[@]}"; do
    before_size="$(stat -c '%s' "$module")"
    "$LLVM_STRIP" --strip-debug "$module"
    after_size="$(stat -c '%s' "$module")"
    log "$(basename "$module"): $before_size -> $after_size bytes"
done

MODULE_STAGE="$WORK_DIR/modules-package"
rm -rf "$MODULE_STAGE"
mkdir -p "$MODULE_STAGE/lib/modules"
for module in "${SELECTED_MODULES[@]}"; do
    cp "$module" "$MODULE_STAGE/lib/modules/"
done
(
    cd "$MODULE_STAGE"
    zip -qr9 "$RELEASE_DIR/$MODULES_ZIP" lib
)
unzip -tq "$RELEASE_DIR/$MODULES_ZIP" >/dev/null

log "Built modules: ${#SELECTED_MODULES[@]}"
log "Flashable kernel ZIP: dist/$KERNEL_ZIP"
log "Modules ZIP: dist/$MODULES_ZIP"
log "Kernel ZIP size: $(du -h "$RELEASE_DIR/$KERNEL_ZIP" | cut -f1)"
log "Modules ZIP size: $(du -h "$RELEASE_DIR/$MODULES_ZIP" | cut -f1)"
