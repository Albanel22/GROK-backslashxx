#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
KERNEL_DIR="$WORKSPACE/kernel_sources"
OUT_DIR="$KERNEL_DIR/out"
OUTPUT_DIR="$WORKSPACE/output"
JACK_DIR="$WORKSPACE/NonGKI_Kernel_Build_2nd"
KSU_DIR="$WORKSPACE/KernelSU"

KERNEL_REPO="https://github.com/LineageOS/android_kernel_motorola_sm8250.git"
KERNEL_BRANCH="lineage-23.2"

JACK_REPO="https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git"
JACK_BRANCH="mainline"

KSU_REPO="https://github.com/backslashxx/KernelSU.git"
KSU_REF="v3.2.5-67"

DEFCONFIG="vendor/lito-perf_defconfig"

BOOT_URL="https://mirrorbits.lineageos.org/full/kiev/20260809/boot.img"
DTBO_URL="https://mirrorbits.lineageos.org/full/kiev/20260809/dtbo.img"

export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

rm -rf "$KERNEL_DIR"
rm -rf "$JACK_DIR"
rm -rf "$KSU_DIR"
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

echo "Clonage Backslashxx KernelSU"

git clone \
    "$KSU_REPO" \
    "$KSU_DIR"

cd "$KSU_DIR"

git fetch --tags --force

git checkout "$KSU_REF"

echo "KernelSU: $(git describe --tags --always)"

cd "$KERNEL_DIR"

if [ ! -f "arch/arm64/configs/$DEFCONFIG" ]; then
    echo "ERREUR: $DEFCONFIG introuvable"
    exit 1
fi

KERNEL_VERSION="$(
    awk '
        /^VERSION[[:space:]]*=/ { v=$3 }
        /^PATCHLEVEL[[:space:]]*=/ { p=$3 }
        END { print v "." p }
    ' Makefile
)"

if [ "$KERNEL_VERSION" != "4.19" ]; then
    echo "ERREUR: kernel $KERNEL_VERSION"
    exit 1
fi

echo "Kernel 4.19 OK"

echo "Integration KernelSU"

bash "$KSU_DIR/kernel/setup.sh" "$KSU_REF"

if [ ! -L "$KERNEL_DIR/drivers/kernelsu" ] &&
   [ ! -d "$KERNEL_DIR/drivers/kernelsu" ]; then
    echo "ERREUR: drivers/kernelsu absent"
    exit 1
fi

if [ ! -f "$KERNEL_DIR/drivers/kernelsu/Kconfig" ]; then
    echo "ERREUR: drivers/kernelsu/Kconfig absent"
    exit 1
fi

echo "KernelSU integre"

echo "Configuration kernel"

make \
    O="$OUT_DIR" \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    "$DEFCONFIG"

scripts/config --file "$OUT_DIR/.config" \
    --enable KPROBES \
    --enable KALLSYMS \
    --enable KALLSYMS_ALL \
    --enable EXT4_FS \
    --enable COMPAT \
    --enable COMPAT_32BIT_TIME \
    --enable KSU

make \
    O="$OUT_DIR" \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    olddefconfig

grep -q '^CONFIG_KPROBES=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_KSU=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_EXT4_FS=y$' "$OUT_DIR/.config"

echo "KPROBES=OK"
echo "KSU=OK"
echo "EXT4_FS=OK"

echo "Application SuSFS"

PATCH_FILE="$JACK_DIR/Patches/Patch/susfs_patch_to_4.19.patch"

if [ ! -f "$PATCH_FILE" ]; then
    echo "ERREUR: patch SuSFS absent"
    exit 1
fi

PATCH_LOG="$OUTPUT_DIR/susfs-patch.log"

set +e

patch \
    -p1 \
    --forward \
    --reject-file="$KERNEL_DIR/susfs-current.rej" \
    < "$PATCH_FILE" \
    2>&1 | tee "$PATCH_LOG"

PATCH_STATUS=${PIPESTATUS[0]}

set -e

find "$KERNEL_DIR" \
    -type f \
    -name '*.rej' \
    -print0 |
while IFS= read -r -d '' f
do
    rel="${f#$KERNEL_DIR/}"
    mkdir -p "$OUTPUT_DIR/rejects/$(dirname "$rel")"
    cp "$f" "$OUTPUT_DIR/rejects/$rel"
done

if [ "$PATCH_STATUS" -ne 0 ]; then
    echo "Le patch contient des rejets connus; correction des deux incompatibilites 4.19"
fi

echo "Correction namespace.c"

python3 <<'PY'
from pathlib import Path

p = Path("fs/namespace.c")
s = p.read_text()

include = "#include <linux/sched/task.h>"

susfs_declarations = r'''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
#include <linux/susfs_def.h>
#endif

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;

#define CL_COPY_MNT_NS BIT(25)
#endif
'''

if "susfs_is_current_ksu_domain" not in s:
    if include not in s:
        raise SystemExit("namespace.c: include anchor introuvable")

    s = s.replace(
        include,
        include + "\n" + susfs_declarations,
        1
    )

mount_block = r'''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
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

if "susfs_alloc_non_unshare_ksu_vfsmnt(name" not in s:
    anchor = "\n\tmnt = alloc_vfsmnt(name);"

    if anchor not in s:
        raise SystemExit(
            "namespace.c: alloc_vfsmnt(name) introuvable"
        )

    s = s.replace(
        anchor,
        "\n" + mount_block + "\tmnt = alloc_vfsmnt(name);",
        1
    )

if "bypass_orig_flow:" not in s:
    anchor = "\n\tmnt = alloc_vfsmnt(name);"

    pos = s.find(anchor)

    if pos < 0:
        raise SystemExit(
            "namespace.c: point bypass introuvable"
        )

    end = pos + len(anchor)

    label = r'''

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bypass_orig_flow:
#endif
'''

    s = s[:end] + label + s[end:]

p.write_text(s)
PY

echo "Correction task_mmu.c"

python3 <<'PY'
from pathlib import Path

p = Path("fs/proc/task_mmu.c")
s = p.read_text()

susfs_block = r'''
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		vma = find_vma(mm, start_vaddr);
		if (vma && vma->vm_file &&
		    SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))
			goto bypass_orig_flow;
#endif
'''

if "SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file))" not in s:

    anchor = """\t\tret = down_read_killable(&mm->mmap_sem);
\t\tif (ret)
\t\t\tgoto out_free;"""

    if anchor not in s:
        raise SystemExit(
            "task_mmu.c: anchor down_read_killable introuvable"
        )

    s = s.replace(
        anchor,
        anchor + susfs_block,
        1
    )

if "bypass_orig_flow:" not in s:

    anchor = "\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);"

    if anchor not in s:
        raise SystemExit(
            "task_mmu.c: walk_page_range introuvable"
        )

    s = s.replace(
        anchor,
        anchor + r'''
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
bypass_orig_flow:
#endif
''',
        1
    )

p.write_text(s)
PY

echo "Suppression uniquement des rejets resolus"

rm -f "$KERNEL_DIR/fs/namespace.c.rej"
rm -f "$KERNEL_DIR/fs/proc/task_mmu.c.rej"
rm -f "$KERNEL_DIR/susfs-current.rej"

REMAINING_REJ=0

while IFS= read -r -d '' rej
do
    rel="${rej#$KERNEL_DIR/}"
    mkdir -p "$OUTPUT_DIR/rejects/$(dirname "$rel")"
    cp "$rej" "$OUTPUT_DIR/rejects/$rel"
    echo "ERREUR: rejet non resolu: $rel"
    REMAINING_REJ=1
done < <(find "$KERNEL_DIR" -type f -name '*.rej' -print0)

if [ "$REMAINING_REJ" -ne 0 ]; then
    exit 1
fi

echo "Tous les rejets sont resolus"

echo "Ajout Kconfig SuSFS"

KSU_KCONFIG="$KERNEL_DIR/drivers/kernelsu/Kconfig"

python3 <<'PY'
from pathlib import Path

p = Path("drivers/kernelsu/Kconfig")
s = p.read_text()

if "config KSU_SUSFS" not in s:

    marker = "\nendmenu"

    if marker not in s:
        raise SystemExit(
            "Kconfig KernelSU: endmenu introuvable"
        )

    susfs = r'''
menu "KernelSU - SUSFS"

config KSU_SUSFS
	bool "KernelSU addon - SUSFS"
	depends on KSU
	depends on THREAD_INFO_IN_TASK
	default y
	help
	  Patch and enable SUSFS with KernelSU.

config KSU_SUSFS_SUS_PATH
	bool "Enable to hide suspicious path"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_MOUNT
	bool "Enable to hide suspicious mounts"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_KSTAT
	bool "Enable to spoof suspicious kstat"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SPOOF_UNAME
	bool "Enable to spoof uname"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_ENABLE_LOG
	bool "Enable SUSFS logging"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
	bool "Hide KernelSU and SUSFS symbols"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	bool "Spoof cmdline or bootconfig"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_OPEN_REDIRECT
	bool "Enable open redirect"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_MAP
	bool "Enable SUS map hiding"
	depends on KSU_SUSFS
	default y

endmenu
'''

    pos = s.rfind(marker)

    s = s[:pos] + "\n" + susfs + s[pos:]

    p.write_text(s)

    print("Kconfig SuSFS ajoute")
else:
    print("Kconfig SuSFS deja present")
PY

echo "Activation SuSFS"

make \
    O="$OUT_DIR" \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    olddefconfig

scripts/config --file "$OUT_DIR/.config" \
    --enable KSU \
    --enable KPROBES \
    --enable KALLSYMS \
    --enable KALLSYMS_ALL \
    --enable EXT4_FS \
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

echo "Verification configuration"

for cfg in \
    CONFIG_KPROBES \
    CONFIG_KSU \
    CONFIG_KALLSYMS \
    CONFIG_KALLSYMS_ALL \
    CONFIG_EXT4_FS \
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
    if ! grep -q "^${cfg}=y$" "$OUT_DIR/.config"; then
        echo "ERREUR: $cfg absent"
        cp "$OUT_DIR/.config" "$OUTPUT_DIR/kernel.config"
        exit 1
    fi
done

cp "$OUT_DIR/.config" "$OUTPUT_DIR/kernel.config"

echo "Configuration SuSFS OK"

echo "Patch tactile Motorola"

TOUCH_FILE="$KERNEL_DIR/techpack/display/msm/msm_drv.c"

if [ ! -f "$TOUCH_FILE" ]; then
    echo "ERREUR: msm_drv.c absent"
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

cd "$KSU_DIR/userspace/ksud"

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

KSUD="$KSU_DIR/userspace/ksud/target/aarch64-linux-android/release/ksud"

if [ ! -s "$KSUD" ]; then
    echo "ERREUR: ksud absent"
    exit 1
fi

cp "$KSUD" "$WORKSPACE/ksud"
chmod 755 "$WORKSPACE/ksud"
cp "$WORKSPACE/ksud" "$OUTPUT_DIR/ksud"

echo "Repack boot"

cd "$WORKSPACE"

curl -fL "$BOOT_URL" -o boot-stock.img
curl -fL "$DTBO_URL" -o dtbo-stock.img

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

mkdir -p ramdisk/data/adb/ksud

cp "$WORKSPACE/ksud" \
    ramdisk/data/adb/ksud/ksud

chmod 755 \
    ramdisk/data/adb/ksud/ksud

./magiskboot repack boot.img new-boot.img

if [ ! -s new-boot.img ]; then
    echo "ERREUR: nouveau boot absent"
    exit 1
fi

mv new-boot.img "$WORKSPACE/final_boot.img"

cd "$WORKSPACE"

cp final_boot.img \
    "$OUTPUT_DIR/Backslashxx-SuSFS-kiev-boot.img"

cp dtbo-stock.img \
    "$OUTPUT_DIR/dtbo.img"

echo "Diagnostics"

find "$KERNEL_DIR" \
    -type f \
    -name '*.rej' \
    -print0 |
while IFS= read -r -d '' rej
do
    rel="${rej#$KERNEL_DIR/}"
    mkdir -p "$OUTPUT_DIR/rejects/$(dirname "$rel")"
    cp "$rej" "$OUTPUT_DIR/rejects/$rel"
done

echo "Build termine"

find "$OUTPUT_DIR" \
    -type f \
    -print \
    | sort
