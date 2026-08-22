#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
KERNEL_DIR="$WORKSPACE/kernel_sources"
OUT_DIR="$KERNEL_DIR/out"
OUTPUT_DIR="$WORKSPACE/output"
JACK_DIR="$WORKSPACE/NonGKI_Kernel_Build_2nd"

KERNEL_REPO="https://github.com/LineageOS/android_kernel_motorola_sm8250.git"
KERNEL_BRANCH="lineage-23.2"

JACK_REPO="https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git"
JACK_BRANCH="mainline"

DEFCONFIG="vendor/lito-perf_defconfig"

BOOT_URL="https://mirrorbits.lineageos.org/full/kiev/20260809/boot.img"
DTBO_URL="https://mirrorbits.lineageos.org/full/kiev/20260809/dtbo.img"

rm -rf "$KERNEL_DIR" "$JACK_DIR" "$OUTPUT_DIR"
rm -rf "$WORKSPACE/repack" "$WORKSPACE/verify_boot"
rm -rf "$WORKSPACE/android-ndk-r26d" "$WORKSPACE/magisk_extract"
rm -f "$WORKSPACE/ksud" "$WORKSPACE/final_boot.img"
rm -f "$WORKSPACE/boot-stock.img" "$WORKSPACE/dtbo-stock.img"
rm -f "$WORKSPACE/android-ndk-r26d-linux.zip"
rm -f "$WORKSPACE/Magisk-v27.0.apk"

mkdir -p "$OUTPUT_DIR"

echo "Installation des dépendances"

sudo apt-get update
sudo apt-get install -y \
    bc bison build-essential ccache clang curl \
    device-tree-compiler flex gcc-aarch64-linux-gnu \
    gcc-arm-linux-gnueabi git libelf-dev libncurses-dev \
    libssl-dev lld llvm mkbootimg perl python3 unzip wget zip

echo "Clonage kernel"

git clone \
    --depth=1 \
    --branch "$KERNEL_BRANCH" \
    "$KERNEL_REPO" \
    "$KERNEL_DIR"

cd "$KERNEL_DIR"

KVER="$(awk '
/^VERSION[[:space:]]*=/ {v=$3}
/^PATCHLEVEL[[:space:]]*=/ {p=$3}
END {print v "." p}
' Makefile)"

if [ "$KVER" != "4.19" ]; then
    echo "ERREUR: kernel $KVER"
    exit 1
fi

echo "Kernel Linux $KVER"

if [ ! -f "arch/arm64/configs/vendor/lito-perf_defconfig" ]; then
    echo "ERREUR: $DEFCONFIG absent"
    exit 1
fi

echo "Clonage JackA1ltman"

git clone \
    --depth=1 \
    --branch "$JACK_BRANCH" \
    "$JACK_REPO" \
    "$JACK_DIR"

echo "Intégration Backslashxx KernelSU"

rm -rf "$KERNEL_DIR/KernelSU"

git clone \
    https://github.com/backslashxx/KernelSU.git \
    "$KERNEL_DIR/KernelSU"

cd "$KERNEL_DIR/KernelSU"

git fetch --tags --force

LATEST_TAG="$(git describe --abbrev=0 --tags)"

echo "KernelSU tag: $LATEST_TAG"

git checkout "$LATEST_TAG"

cd "$KERNEL_DIR"

bash "$KERNEL_DIR/KernelSU/kernel/setup.sh"

if [ ! -L "$KERNEL_DIR/drivers/kernelsu" ]; then
    echo "ERREUR: drivers/kernelsu absent"
    exit 1
fi

if ! grep -q 'obj-\$(CONFIG_KSU) += kernelsu/' \
    "$KERNEL_DIR/drivers/Makefile"; then
    echo "ERREUR: KernelSU absent de drivers/Makefile"
    exit 1
fi

if ! grep -q 'drivers/kernelsu/Kconfig' \
    "$KERNEL_DIR/drivers/Kconfig"; then
    echo "ERREUR: KernelSU absent de drivers/Kconfig"
    exit 1
fi

echo "KernelSU intégré"

echo "Configuration kernel"

make \
    O="$OUT_DIR" \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    "$DEFCONFIG"

echo "Activation KSU"

scripts/config --file "$OUT_DIR/.config" \
    --enable KPROBES \
    --enable KSU \
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

grep -q '^CONFIG_KPROBES=y$' "$OUT_DIR/.config" || {
    echo "ERREUR: CONFIG_KPROBES absent"
    exit 1
}

grep -q '^CONFIG_KSU=y$' "$OUT_DIR/.config" || {
    echo "ERREUR: CONFIG_KSU absent"
    exit 1
}

grep -q '^CONFIG_EXT4_FS=y$' "$OUT_DIR/.config" || {
    echo "ERREUR: CONFIG_EXT4_FS absent"
    exit 1
}

echo "KPROBES=OK"
echo "KSU=OK"
echo "EXT4_FS=OK"

echo "Application SuSFS JackA1ltman"

PATCH_419="$(
    find "$JACK_DIR/Patches" \
        -type f \
        -iname '*4.19*.patch' \
        | sort \
        | head -1
)"

if [ -z "$PATCH_419" ]; then
    echo "ERREUR: patch SuSFS 4.19 introuvable"
    find "$JACK_DIR/Patches" -type f -name '*.patch' | sort
    exit 1
fi

echo "Patch: $PATCH_419"

patch \
    -p1 \
    --forward \
    < "$PATCH_419" \
    2>&1 | tee "$OUTPUT_DIR/susfs-patch.log" || PATCH_STATUS=$?

PATCH_STATUS="${PATCH_STATUS:-0}"

if find "$KERNEL_DIR" \
    -type f \
    -name '*.rej' \
    | grep -q .; then

    echo "ERREUR: .rej détecté"

    find "$KERNEL_DIR" \
        -type f \
        -name '*.rej' \
        -print

    exit 1
fi

if [ "$PATCH_STATUS" -ne 0 ]; then
    echo "ERREUR: patch SuSFS non appliqué"
    exit 1
fi

echo "SuSFS patch appliqué"

echo "Configuration SuSFS"

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

for CONFIG_NAME in \
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
    grep -q "^${CONFIG_NAME}=y$" "$OUT_DIR/.config" || {
        echo "ERREUR: $CONFIG_NAME absent après olddefconfig"
        exit 1
    }
done

echo "Configuration SuSFS OK"

echo "Patch tactile Motorola"

TOUCH_FILE="$KERNEL_DIR/techpack/display/msm/msm_drv.c"

if [ ! -f "$TOUCH_FILE" ]; then
    echo "ERREUR: $TOUCH_FILE absent"
    exit 1
fi

python3 - "$TOUCH_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "motorola_panel_notifier_list" not in text:
    text += r'''

/* Motorola touchscreen compatibility */
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

    path.write_text(text)

grep_text="motorola_panel_notifier_list"

grep -q "$grep_text" "$TOUCH_FILE"
grep -q "panel_register_notifier" "$TOUCH_FILE"
grep -q "panel_unregister_notifier" "$TOUCH_FILE"
grep -q "touch_set_state" "$TOUCH_FILE"

echo "Patch tactile OK"

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
    echo "ERREUR: Image absente"
    exit 1
fi

echo "Kernel compilé"

echo "Installation Rust"

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

echo "Téléchargement NDK"

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

echo "Compilation ksud"

cd "$KERNEL_DIR/KernelSU/userspace/ksud"

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

KSUD="$KERNEL_DIR/KernelSU/userspace/ksud/target/aarch64-linux-android/release/ksud"

if [ ! -f "$KSUD" ]; then
    echo "ERREUR: ksud absent"
    exit 1
fi

cp "$KSUD" "$WORKSPACE/ksud"
chmod 755 "$WORKSPACE/ksud"

echo "Téléchargement boot"

cd "$WORKSPACE"

curl -fL "$BOOT_URL" -o boot-stock.img
curl -fL "$DTBO_URL" -o dtbo-stock.img

echo "Téléchargement Magiskboot"

wget -q \
    https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk \
    -O Magisk-v27.0.apk

mkdir -p magisk_extract repack

unzip -q \
    Magisk-v27.0.apk \
    'lib/x86_64/libmagiskboot.so' \
    -d magisk_extract

cp \
    magisk_extract/lib/x86_64/libmagiskboot.so \
    repack/magiskboot

chmod 755 repack/magiskboot

echo "Unpack boot"

cp boot-stock.img repack/boot.img

cd repack

./magiskboot unpack boot.img

if [ ! -f kernel ]; then
    echo "ERREUR: kernel stock non extrait"
    exit 1
fi

if [ ! -d ramdisk ]; then
    echo "ERREUR: ramdisk absent"
    exit 1
fi

cp "$KERNEL_IMAGE" kernel

mkdir -p ramdisk/data/adb

cp "$WORKSPACE/ksud" ramdisk/data/adb/ksud
chmod 755 ramdisk/data/adb/ksud

echo "Repack boot"

./magiskboot repack boot.img new-boot.img

if [ ! -s new-boot.img ]; then
    echo "ERREUR: repack boot échoué"
    exit 1
fi

mv new-boot.img "$WORKSPACE/final_boot.img"

echo "Vérification finale"

mkdir -p "$WORKSPACE/verify_boot"

cp "$WORKSPACE/final_boot.img" \
    "$WORKSPACE/verify_boot/boot.img"

cd "$WORKSPACE/verify_boot"

"$WORKSPACE/repack/magiskboot" unpack boot.img >/dev/null

[ -f kernel ] || {
    echo "ERREUR: kernel absent du boot final"
    exit 1
}

[ -x ramdisk/data/adb/ksud ] || {
    echo "ERREUR: ksud absent du boot final"
    exit 1
}

echo "Création artifacts"

cd "$WORKSPACE"

cp final_boot.img \
    "$OUTPUT_DIR/Backslashxx-SuSFS-kiev-boot.img"

cp dtbo-stock.img \
    "$OUTPUT_DIR/dtbo.img"

cp ksud \
    "$OUTPUT_DIR/ksud"

cp "$OUT_DIR/.config" \
    "$OUTPUT_DIR/kernel.config"

echo "BUILD OK"

ls -lh "$OUTPUT_DIR"
