#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export ARCH=arm64
export SUBARCH=arm64
export LLVM=1
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"

KERNEL_DIR="$WORKSPACE/kernel_sources"
OUT_DIR="$KERNEL_DIR/out"
OUTPUT_DIR="$WORKSPACE/output"
KSU_DIR="$WORKSPACE/KernelSU"
JACK_DIR="$WORKSPACE/NonGKI_Kernel_Build_2nd"

KERNEL_REPO="https://github.com/LineageOS/android_kernel_motorola_sm8250.git"
KERNEL_BRANCH="lineage-23.2"

KSU_REPO="https://github.com/backslashxx/KernelSU.git"
KSU_BRANCH="master"

JACK_REPO="https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git"
JACK_BRANCH="mainline"

DEFCONFIG="vendor/lito-perf_defconfig"

BOOT_URL="https://mirrorbits.lineageos.org/full/kiev/20260809/boot.img"
DTBO_URL="https://mirrorbits.lineageos.org/full/kiev/20260809/dtbo.img"

echo "Début du build Backslashxx KernelSU + SuSFS + tactile"

rm -rf "$KERNEL_DIR" "$KSU_DIR" "$JACK_DIR" "$OUTPUT_DIR"
rm -rf "$WORKSPACE/repack" "$WORKSPACE/verify_boot"
rm -rf "$WORKSPACE/android-ndk-r26d"
rm -f "$WORKSPACE/ksud" "$WORKSPACE/final_boot.img"
rm -f "$WORKSPACE/boot-stock.img" "$WORKSPACE/dtbo-stock.img"
rm -f "$WORKSPACE/android-ndk-r26d-linux.zip"

mkdir -p "$OUTPUT_DIR"

echo "Installation des dépendances"

sudo apt-get update
sudo apt-get install -y \
    bc bison build-essential ccache clang curl \
    device-tree-compiler flex gcc-aarch64-linux-gnu \
    gcc-arm-linux-gnueabi git libelf-dev libncurses-dev \
    libssl-dev lld llvm mkbootimg perl python3 unzip wget zip

echo "Clonage du kernel"

git clone --depth=1 \
    --branch "$KERNEL_BRANCH" \
    "$KERNEL_REPO" \
    "$KERNEL_DIR"

cd "$KERNEL_DIR"

KERNEL_VERSION="$(
    awk '
        /^VERSION[[:space:]]*=/ { v=$3 }
        /^PATCHLEVEL[[:space:]]*=/ { p=$3 }
        END { print v "." p }
    ' Makefile
)"

if [ "$KERNEL_VERSION" != "4.19" ]; then
    echo "ERREUR: kernel $KERNEL_VERSION détecté, 4.19 attendu"
    exit 1
fi

if [ ! -f "arch/arm64/configs/vendor/lito-perf_defconfig" ]; then
    echo "ERREUR: vendor/lito-perf_defconfig absent"
    exit 1
fi

echo "Clonage Backslashxx KernelSU"

git clone --depth=1 \
    --branch "$KSU_BRANCH" \
    "$KSU_REPO" \
    "$KSU_DIR"

KSU_COMMIT="$(git -C "$KSU_DIR" rev-parse HEAD)"
echo "KernelSU: $KSU_COMMIT"

echo "Intégration KernelSU"

if [ ! -f "$KSU_DIR/kernel/setup.sh" ]; then
    echo "ERREUR: setup.sh Backslashxx absent"
    exit 1
fi

rm -rf KernelSU drivers/kernelsu

bash "$KSU_DIR/kernel/setup.sh"

if [ ! -d "KernelSU/kernel" ] || [ ! -e "drivers/kernelsu" ]; then
    echo "ERREUR: intégration KernelSU incomplète"
    exit 1
fi

echo "Clonage JackA1ltman"

git clone --depth=1 \
    --branch "$JACK_BRANCH" \
    "$JACK_REPO" \
    "$JACK_DIR"

echo "Recherche du script SuSFS"

JACK_SCRIPT="$(
    find "$JACK_DIR" -type f \
    \( \
        -name "susfs_inline_hook_patches.sh" \
        -o -name "susfs*.sh" \
    \) \
    -print | head -1
)"

if [ -z "$JACK_SCRIPT" ]; then
    echo "ERREUR: script SuSFS JackA1ltman introuvable"
    find "$JACK_DIR" -maxdepth 3 -type f | sort | head -100
    exit 1
fi

chmod +x "$JACK_SCRIPT"

echo "Script SuSFS: $JACK_SCRIPT"

echo "Configuration initiale"

make \
    O="$OUT_DIR" \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    "$DEFCONFIG"

echo "Activation KernelSU et SuSFS"

if [ ! -x "scripts/config" ]; then
    echo "ERREUR: scripts/config absent"
    exit 1
fi

scripts/config --file "$OUT_DIR/.config" \
    --enable KSU \
    --enable KSU_MANUAL_HOOK \
    --enable KALLSYMS \
    --enable KALLSYMS_ALL \
    --enable COMPAT \
    --enable COMPAT_32BIT_TIME \
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

scripts/config --file "$OUT_DIR/.config" \
    --disable KPROBES \
    --disable HAVE_KPROBES \
    --disable KPROBE_EVENTS

make \
    O="$OUT_DIR" \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    olddefconfig

echo "Vérification configuration"

REQUIRED_CONFIGS=(
    CONFIG_KSU
    CONFIG_KSU_MANUAL_HOOK
    CONFIG_KALLSYMS
    CONFIG_KALLSYMS_ALL
    CONFIG_KSU_SUSFS
    CONFIG_KSU_SUSFS_SUS_PATH
    CONFIG_KSU_SUSFS_SUS_MOUNT
    CONFIG_KSU_SUSFS_SUS_KSTAT
    CONFIG_KSU_SUSFS_SPOOF_UNAME
    CONFIG_KSU_SUSFS_ENABLE_LOG
    CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
    CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
    CONFIG_KSU_SUSFS_OPEN_REDIRECT
    CONFIG_KSU_SUSFS_SUS_MAP
)

for CONFIG_NAME in "${REQUIRED_CONFIGS[@]}"; do
    grep -q "^${CONFIG_NAME}=y$" "$OUT_DIR/.config" || {
        echo "ERREUR: $CONFIG_NAME absent"
        exit 1
    }
done

echo "Configuration OK"

echo "Application des hooks SuSFS JackA1ltman"

cp "$JACK_SCRIPT" "$KERNEL_DIR/susfs_inline_hook_patches.sh"
chmod +x "$KERNEL_DIR/susfs_inline_hook_patches.sh"

./susfs_inline_hook_patches.sh \
    2>&1 | tee "$OUTPUT_DIR/susfs_hooks.log"

if find "$KERNEL_DIR" -type f -name "*.rej" -print | grep -q .; then
    echo "ERREUR: fichiers .rej détectés"
    find "$KERNEL_DIR" -type f -name "*.rej" -print
    exit 1
fi

echo "Vérification hooks KernelSU"

for CHECK in \
    "fs/exec.c:ksu_handle_execveat" \
    "fs/open.c:ksu_handle_faccessat" \
    "fs/stat.c:ksu_handle_stat" \
    "kernel/sys.c:ksu_handle_setresuid"
do
    FILE="${CHECK%%:*}"
    SYMBOL="${CHECK#*:}"

    grep -q "$SYMBOL" "$FILE" || {
        echo "ERREUR: $SYMBOL absent de $FILE"
        exit 1
    }
done

echo "Hooks KernelSU présents"

echo "Application du patch tactile Motorola"

TOUCH_FILE="techpack/display/msm/msm_drv.c"

if [ ! -f "$TOUCH_FILE" ]; then
    echo "ERREUR: $TOUCH_FILE absent"
    exit 1
fi

python3 - <<'PY'
from pathlib import Path

path = Path("techpack/display/msm/msm_drv.c")
text = path.read_text()

if "motorola_panel_notifier_list" not in text:
    text += r'''

/* Motorola tactile compatibility */
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
PY

grep -q "motorola_panel_notifier_list" "$TOUCH_FILE"
grep -q "panel_register_notifier" "$TOUCH_FILE"
grep -q "panel_unregister_notifier" "$TOUCH_FILE"
grep -q "touch_set_state" "$TOUCH_FILE"

echo "Patch tactile présent"

echo "Compilation du kernel"

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

echo "Kernel compilé"

cd "$WORKSPACE"

echo "Installation Android NDK"

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

if ! command -v rustup >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf \
        https://sh.rustup.rs | sh -s -- -y
fi

source "$HOME/.cargo/env"

rustup target add aarch64-linux-android

echo "Préparation ksud Backslashxx"

cd "$KSU_DIR/userspace/ksud"

if [ ! -d "bin/aarch64" ]; then
    echo "ERREUR: userspace/ksud/bin/aarch64 absent"
    exit 1
fi

find bin/aarch64 -maxdepth 1 -type f -print | sort

cargo clean

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

echo "Compilation ksud"

cargo build \
    --release \
    --target aarch64-linux-android \
    --manifest-path "$KSU_DIR/userspace/ksud/Cargo.toml" \
    2>&1 | tee "$OUTPUT_DIR/ksud-build.log"

KSUD_BINARY="$KSU_DIR/userspace/ksud/target/aarch64-linux-android/release/ksud"

if [ ! -x "$KSUD_BINARY" ]; then
    echo "ERREUR: ksud absent"
    exit 1
fi

cp "$KSUD_BINARY" "$WORKSPACE/ksud"
chmod 755 "$WORKSPACE/ksud"

file "$WORKSPACE/ksud" | grep -qi aarch64 || {
    echo "ERREUR: ksud n'est pas AArch64"
    exit 1
}

echo "Téléchargement boot stock"

cd "$WORKSPACE"

curl -fL "$BOOT_URL" -o boot-stock.img
curl -fL "$DTBO_URL" -o dtbo-stock.img

if [ ! -s boot-stock.img ]; then
    echo "ERREUR: boot-stock.img absent"
    exit 1
fi

echo "Installation magiskboot"

mkdir -p "$WORKSPACE/repack"

wget -q \
    https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk \
    -O Magisk-v27.0.apk

mkdir -p "$WORKSPACE/magisk_extract"

unzip -q \
    Magisk-v27.0.apk \
    'lib/x86_64/libmagiskboot.so' \
    -d "$WORKSPACE/magisk_extract"

cp \
    "$WORKSPACE/magisk_extract/lib/x86_64/libmagiskboot.so" \
    "$WORKSPACE/repack/magiskboot"

chmod 755 "$WORKSPACE/repack/magiskboot"

echo "Décompression boot"

cp "$WORKSPACE/boot-stock.img" "$WORKSPACE/repack/boot.img"

cd "$WORKSPACE/repack"

./magiskboot unpack boot.img

if [ ! -f kernel ] || [ ! -d ramdisk ]; then
    echo "ERREUR: unpack boot incomplet"
    exit 1
fi

echo "Remplacement kernel"

cp "$KERNEL_IMAGE" kernel

echo "Installation ksud"

mkdir -p ramdisk/data/adb

cp "$WORKSPACE/ksud" ramdisk/data/adb/ksud
chmod 755 ramdisk/data/adb/ksud

if [ ! -x ramdisk/data/adb/ksud ]; then
    echo "ERREUR: /data/adb/ksud non exécutable"
    exit 1
fi

echo "Repack boot"

./magiskboot repack boot.img new-boot.img

if [ ! -s new-boot.img ]; then
    echo "ERREUR: nouveau boot absent"
    exit 1
fi

mv new-boot.img "$WORKSPACE/final_boot.img"

echo "Vérification boot final"

rm -rf "$WORKSPACE/verify_boot"
mkdir -p "$WORKSPACE/verify_boot"

cp "$WORKSPACE/final_boot.img" \
   "$WORKSPACE/verify_boot/boot.img"

cd "$WORKSPACE/verify_boot"

"$WORKSPACE/repack/magiskboot" unpack boot.img >/dev/null

[ -f kernel ] || {
    echo "ERREUR: kernel absent du boot final"
    exit 1
}

[ -d ramdisk ] || {
    echo "ERREUR: ramdisk absent du boot final"
    exit 1
}

[ -x ramdisk/data/adb/ksud ] || {
    echo "ERREUR: ksud absent du boot final"
    exit 1
}

echo "Copie des résultats"

cd "$WORKSPACE"

cp "$WORKSPACE/final_boot.img" \
   "$OUTPUT_DIR/Backslashxx-SuSFS-kiev-boot.img"

cp "$WORKSPACE/dtbo-stock.img" \
   "$OUTPUT_DIR/dtbo.img"

cp "$WORKSPACE/ksud" \
   "$OUTPUT_DIR/ksud"

cp "$OUT_DIR/.config" \
   "$OUTPUT_DIR/kernel.config"

echo "BUILD TERMINÉ"

ls -lh "$OUTPUT_DIR"
