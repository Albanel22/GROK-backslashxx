#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
KERNEL_DIR="$WORKSPACE/kernel_sources"
OUT_DIR="$KERNEL_DIR/out"
OUTPUT_DIR="$WORKSPACE/output"
JACK_DIR="$WORKSPACE/NonGKI_Kernel_Build_2nd"
KSUD_DIR="$KERNEL_DIR/KernelSU"

KERNEL_REPO="https://github.com/LineageOS/android_kernel_motorola_sm8250.git"
KERNEL_BRANCH="lineage-23.2"
JACK_REPO="https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git"
JACK_BRANCH="mainline"

DEFCONFIG="vendor/lito-perf_defconfig"

BOOT_URL="https://mirrorbits.lineageos.org/full/kiev/20260809/boot.img"
DTBO_URL="https://mirrorbits.lineageos.org/full/kiev/20260809/dtbo.img"

export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

rm -rf "$KERNEL_DIR"
rm -rf "$JACK_DIR"
rm -rf "$OUTPUT_DIR"
rm -rf "$WORKSPACE/repack"
rm -rf "$WORKSPACE/magisk_extract"
rm -rf "$WORKSPACE/android-ndk-r26d"

rm -f "$WORKSPACE/boot-stock.img"
rm -f "$WORKSPACE/dtbo-stock.img"
rm -f "$WORKSPACE/final_boot.img"
rm -f "$WORKSPACE/ksud"
rm -f "$WORKSPACE/Magisk-v27.0.apk"
rm -f "$WORKSPACE/android-ndk-r26d-linux.zip"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/rejects"

sudo apt-get update

sudo apt-get install -y \
    bc \
    bison \
    build-essential \
    ccache \
    clang \
    curl \
    device-tree-compiler \
    flex \
    gcc-aarch64-linux-gnu \
    gcc-arm-linux-gnueabi \
    git \
    libelf-dev \
    libncurses-dev \
    libssl-dev \
    lld \
    llvm \
    mkbootimg \
    perl \
    python3 \
    unzip \
    wget \
    zip

echo "Clonage kernel"

git clone \
    --depth=1 \
    --branch "$KERNEL_BRANCH" \
    "$KERNEL_REPO" \
    "$KERNEL_DIR"

echo "Clonage NonGKI"

git clone \
    --depth=1 \
    --branch "$JACK_BRANCH" \
    "$JACK_REPO" \
    "$JACK_DIR"

cd "$KERNEL_DIR"

KERNEL_VERSION="$(
    awk '
        /^VERSION[[:space:]]*=/ { v=$3 }
        /^PATCHLEVEL[[:space:]]*=/ { p=$3 }
        END { print v "." p }
    ' Makefile
)"

if [ "$KERNEL_VERSION" != "4.19" ]; then
    echo "ERREUR: kernel détecté: $KERNEL_VERSION"
    exit 1
fi

if [ ! -f "arch/arm64/configs/$DEFCONFIG" ]; then
    echo "ERREUR: $DEFCONFIG absent"
    exit 1
fi

echo "Kernel 4.19 OK"

echo "Clonage Backslashxx KernelSU"

git clone \
    https://github.com/backslashxx/KernelSU.git \
    "$KSUD_DIR"

cd "$KSUD_DIR"

git fetch --tags --force

if git rev-parse --verify v3.2.5-67 >/dev/null 2>&1; then
    git checkout v3.2.5-67
fi

echo "KernelSU commit:"
git rev-parse --short HEAD

cd "$KERNEL_DIR"

echo "Intégration KernelSU"

bash "$KSUD_DIR/kernel/setup.sh"

if [ ! -d "$KERNEL_DIR/drivers/kernelsu" ]; then
    echo "ERREUR: drivers/kernelsu absent après setup.sh"
    exit 1
fi

echo "KernelSU intégré"

echo "Configuration initiale"

make \
    O="$OUT_DIR" \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    "$DEFCONFIG"

scripts/config --file "$OUT_DIR/.config" \
    --enable KSU \
    --enable KPROBES \
    --enable KALLSYMS \
    --enable KALLSYMS_ALL \
    --enable EXT4_FS \
    --enable COMPAT \
    --enable COMPAT_32BIT_TIME

make \
    O="$OUT_DIR" \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    olddefconfig

echo "Vérification KSU"

grep -q '^CONFIG_KPROBES=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_KSU=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_EXT4_FS=y$' "$OUT_DIR/.config"

echo "KPROBES=OK"
echo "KSU=OK"
echo "EXT4_FS=OK"

echo "Application SuSFS JackA1ltman"

PATCH_419="$(
    find "$JACK_DIR/Patches" \
        -type f \
        -name 'susfs_patch_to_4.19.patch' \
        | head -1
)"

if [ -z "$PATCH_419" ]; then
    echo "ERREUR: susfs_patch_to_4.19.patch introuvable"
    find "$JACK_DIR/Patches" -type f -name '*.patch' | head -30
    exit 1
fi

echo "Patch: $PATCH_419"

PATCH_LOG="$OUTPUT_DIR/susfs-patch.log"

set +e

patch \
    -p1 \
    --forward \
    < "$PATCH_419" \
    2>&1 | tee "$PATCH_LOG"

PATCH_RESULT=${PIPESTATUS[0]}

set -e

echo "Sauvegarde des rejets initiaux"

find "$KERNEL_DIR" \
    -type f \
    -name '*.rej' \
    -print0 |
while IFS= read -r -d '' rej
do
    rel="${rej#$KERNEL_DIR/}"
    dest="$OUTPUT_DIR/rejects/$rel"

    mkdir -p "$(dirname "$dest")"
    cp "$rej" "$dest"
done

echo "Correction namespace.c"

python3 <<'PY'
from pathlib import Path
import re

p = Path("fs/namespace.c")
s = p.read_text()

include_anchor = "#include <linux/sched/task.h>"

if "susfs_is_current_ksu_domain" not in s:
    if include_anchor not in s:
        raise SystemExit("namespace.c: include anchor absent")

    block = r'''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
#include <linux/susfs_def.h>
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;

#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */

#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
'''

    s = s.replace(
        include_anchor,
        include_anchor + "\n" + block,
        1
    )

if "susfs_alloc_non_unshare_ksu_vfsmnt" not in s:

    fn = re.search(
        r'vfs_kern_mount\s*\([^)]*\)\s*\{',
        s
    )

    if not fn:
        raise SystemExit(
            "namespace.c: vfs_kern_mount introuvable"
        )

    start = fn.end()

    type_check = re.search(
        r'\n\s*if\s*\(\s*!type\s*\)\s*'
        r'return\s+ERR_PTR\s*\(\s*-ENODEV\s*\)\s*;',
        s[start:],
        re.S
    )

    if not type_check:
        raise SystemExit(
            "namespace.c: test !type introuvable"
        )

    pos = start + type_check.end()

    block = r'''

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	/* SusFS mount bypass for KSU domain. */
	if (static_branch_unlikely(
			&susfs_is_sdcard_android_data_not_decrypted)) {
		if (susfs_is_current_ksu_domain()) {
			mnt = susfs_alloc_non_unshare_ksu_vfsmnt(
				name ? : "none");
			goto bypass_orig_flow;
		}
	}
#endif
'''

    s = s[:pos] + block + s[pos:]

if "bypass_orig_flow:" not in s:

    mnt = re.search(
        r'\n\s*mnt\s*=\s*alloc_vfsmnt\s*\(\s*name\s*\)\s*;',
        s
    )

    if not mnt:
        raise SystemExit(
            "namespace.c: alloc_vfsmnt introuvable"
        )

    pos = mnt.end()

    label = r'''

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bypass_orig_flow:
#endif
'''

    s = s[:pos] + label + s[pos:]

p.write_text(s)

print("namespace.c corrigé")
PY

echo "Correction task_mmu.c"

python3 <<'PY'
from pathlib import Path
import re

p = Path("fs/proc/task_mmu.c")
s = p.read_text()

if "SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file))" not in s:

    fn = re.search(
        r'static\s+ssize_t\s+pagemap_read\s*\(',
        s
    )

    if not fn:
        raise SystemExit(
            "task_mmu.c: pagemap_read introuvable"
        )

    start = fn.start()

    end = s.find("\n}", start)

    if end < 0:
        raise SystemExit(
            "task_mmu.c: fin pagemap_read introuvable"
        )

    body = s[start:end]

    anchor = re.search(
        r'\n\s*ret\s*=\s*down_read_killable\s*\(&mm->mmap_sem\)\s*;'
        r'\s*if\s*\(\s*ret\s*\)'
        r'\s*goto\s+out_free\s*;',
        body,
        re.S
    )

    if not anchor:
        raise SystemExit(
            "task_mmu.c: anchor down_read_killable introuvable"
        )

    pos = start + anchor.end()

    block = r'''
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		vma = find_vma(mm, start_vaddr);
		if (vma && vma->vm_file &&
		    SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))
			goto bypass_orig_flow;
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP
'''

    s = s[:pos] + block + s[pos:]

if "bypass_orig_flow:" not in s:

    fn = re.search(
        r'static\s+ssize_t\s+pagemap_read\s*\(',
        s
    )

    start = fn.start()
    end = s.find("\n}", start)

    body = s[start:end]

    walk = re.search(
        r'\n\s*ret\s*=\s*walk_page_range\s*\('
        r'.*?'
        r'\)\s*;',
        body,
        re.S
    )

    if not walk:
        raise SystemExit(
            "task_mmu.c: walk_page_range introuvable"
        )

    pos = start + walk.end()

    label = r'''
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
bypass_orig_flow:
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP
'''

    s = s[:pos] + label + s[pos:]

p.write_text(s)

print("task_mmu.c corrigé")
PY

echo "Suppression des rejets consommés"

find "$KERNEL_DIR" \
    -type f \
    -name '*.rej' \
    -delete

if find "$KERNEL_DIR" -type f -name '*.rej' | grep -q .; then
    echo "ERREUR: .rej encore présent"
    exit 1
fi

echo "SuSFS corrections OK"

echo "Activation SuSFS"

scripts/config --file "$OUT_DIR/.config" \
    --enable KSU_SUSFS \
    --enable KSU_SUSFS_SUS_PATH \
    --enable KSU_SUSFS_SUS_MOUNT \
    --enable KSU_SUSFS_SUS_KSTAT \
    --enable KSU_SUSFS_SPOOF_UNAME \
    --enable KSU_SUSFS_ENABLE_LOG \
    --enable KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    --enable KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    --enable KSU_SUSFS_OPEN_REDIRECT \
    --enable KSU_SUSFS_SUS_MAP

make \
    O="$OUT_DIR" \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    olddefconfig

echo "Vérification SuSFS"

for c in \
    CONFIG_KSU \
    CONFIG_KPROBES \
    CONFIG_KALLSYMS \
    CONFIG_KALLSYMS_ALL \
    CONFIG_KSU_SUSFS \
    CONFIG_KSU_SUSFS_SUS_PATH \
    CONFIG_KSU_SUSFS_SUS_MOUNT \
    CONFIG_KSU_SUSFS_SUS_KSTAT \
    CONFIG_KSU_SUSFS_SPOOF_UNAME \
    CONFIG_KSU_SUSFS_ENABLE_LOG \
    CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    CONFIG_KSU_SUSFS_OPEN_REDIRECT \
    CONFIG_KSU_SUSFS_SUS_MAP
do
    if ! grep -q "^${c}=y$" "$OUT_DIR/.config"; then
        echo "ERREUR: $c absent"
        exit 1
    fi
done

echo "SuSFS configuration OK"

echo "Patch tactile Motorola"

TOUCH_FILE="$KERNEL_DIR/techpack/display/msm/msm_drv.c"

if [ ! -f "$TOUCH_FILE" ]; then
    echo "ERREUR: $TOUCH_FILE absent"
    exit 1
fi

python3 <<'PY'
from pathlib import Path

p = Path("techpack/display/msm/msm_drv.c")
s = p.read_text()

if "motorola_panel_notifier_list" not in s:

    s += r'''

#include <linux/notifier.h>
#include <linux/module.h>

static BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);

int panel_register_notifier(struct notifier_block *nb)
{
	return blocking_notifier_chain_register(
		&motorola_panel_notifier_list, nb);
}
EXPORT_SYMBOL(panel_register_notifier);

int panel_unregister_notifier(struct notifier_block *nb)
{
	return blocking_notifier_chain_unregister(
		&motorola_panel_notifier_list, nb);
}
EXPORT_SYMBOL(panel_unregister_notifier);

void touch_set_state(int state)
{
	return;
}
EXPORT_SYMBOL(touch_set_state);
'''

p.write_text(s)
PY

echo "Compilation kernel"

make \
    O="$OUT_DIR" \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    -j"$(nproc)" \
    Image \
    2>&1 | tee "$OUTPUT_DIR/build.log"

KERNEL_IMAGE="$OUT_DIR/arch/arm64/boot/Image"

if [ ! -s "$KERNEL_IMAGE" ]; then
    echo "ERREUR: Image kernel absente"
    exit 1
fi

cp "$KERNEL_IMAGE" "$OUTPUT_DIR/Image"

echo "Compilation ksud"

if ! command -v rustup >/dev/null 2>&1; then
    curl \
        --proto '=https' \
        --tlsv1.2 \
        -sSf \
        https://sh.rustup.rs \
        | sh -s -- -y
fi

source "$HOME/.cargo/env"

rustup target add aarch64-linux-android

cd "$WORKSPACE"

wget -q \
    https://dl.google.com/android/repository/android-ndk-r26d-linux.zip \
    -O android-ndk-r26d-linux.zip

unzip -q android-ndk-r26d-linux.zip

export ANDROID_NDK_ROOT="$WORKSPACE/android-ndk-r26d"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"

NDK_HOST="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64"

export AARCH64_CLANG_PATH="$NDK_HOST/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$NDK_HOST/bin/aarch64-linux-android26-clang++"
export AR_PATH="$NDK_HOST/bin/llvm-ar"

export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$NDK_HOST/sysroot -I$NDK_HOST/sysroot/usr/include/aarch64-linux-android"

cd "$KSUD_DIR/userspace/ksud"

mkdir -p .cargo

cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$AARCH64_CLANG_PATH"

[env]
CC_aarch64_linux_android = "$AARCH64_CLANG_PATH"
CXX_aarch64_linux_android = "$AARCH64_CLANGXX_PATH"
AR_aarch64_linux_android = "$AR_PATH"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "$BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android"
EOF

cargo build \
    --release \
    --target aarch64-linux-android \
    --manifest-path Cargo.toml \
    2>&1 | tee "$OUTPUT_DIR/ksud-build.log"

KSUD="$KSUD_DIR/userspace/ksud/target/aarch64-linux-android/release/ksud"

if [ ! -s "$KSUD" ]; then
    echo "ERREUR: ksud absent"
    exit 1
fi

cp "$KSUD" "$WORKSPACE/ksud"
chmod 755 "$WORKSPACE/ksud"

cp "$WORKSPACE/ksud" "$OUTPUT_DIR/ksud"

echo "Téléchargement boot stock"

cd "$WORKSPACE"

curl -fL \
    "$BOOT_URL" \
    -o boot-stock.img

curl -fL \
    "$DTBO_URL" \
    -o dtbo-stock.img

mkdir -p repack
mkdir -p magisk_extract

wget -q \
    https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk \
    -O Magisk-v27.0.apk

unzip -q \
    Magisk-v27.0.apk \
    'lib/x86_64/libmagiskboot.so' \
    -d magisk_extract

cp \
    magisk_extract/lib/x86_64/libmagiskboot.so \
    repack/magiskboot

chmod 755 repack/magiskboot

cp boot-stock.img repack/boot.img

cd repack

./magiskboot unpack boot.img

if [ ! -f kernel ]; then
    echo "ERREUR: kernel absent après unpack"
    exit 1
fi

cp "$KERNEL_IMAGE" kernel

mkdir -p ramdisk/data/adb

cp "$WORKSPACE/ksud" ramdisk/data/adb/ksud
chmod 755 ramdisk/data/adb/ksud

./magiskboot repack boot.img new-boot.img

if [ ! -s new-boot.img ]; then
    echo "ERREUR: repack boot échoué"
    exit 1
fi

mv new-boot.img "$WORKSPACE/final_boot.img"

cd "$WORKSPACE"

cp final_boot.img \
    "$OUTPUT_DIR/Backslashxx-SuSFS-kiev-boot.img"

cp dtbo-stock.img \
    "$OUTPUT_DIR/dtbo.img"

cp "$OUT_DIR/.config" \
    "$OUTPUT_DIR/kernel.config"

echo "Build terminé"

find "$OUTPUT_DIR" \
    -type f \
    -print \
    | sort
