```bash
#!/bin/bash
set -euo pipefail

###############################################################################
# Backslashxx KernelSU + SuSFS + Motorola kiev
#
# Device  : Motorola One 5G Ace / kiev
# Kernel  : Linux 4.19
# Kernel  : LineageOS lineage-23.2
#
# KernelSU:
#   https://github.com/backslashxx/KernelSU
#
# SuSFS:
#   https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd
#
# IMPORTANT
# -----------------------------------------------------------------------------
# 1. KernelSU est intégré avec le setup.sh de Backslashxx.
# 2. SuSFS utilise exclusivement la méthode JackA1ltman mainline.
# 3. Aucun ancien susfs_patch_to_4.19.patch n'est utilisé.
# 4. Aucun hook exec/open/stat manuel n'est ajouté ici.
# 5. Le patch tactile Motorola est conservé.
# 6. ksud est compilé depuis LE MÊME checkout Backslashxx que KernelSU.
# 7. Les assets ksud/bin/aarch64 restent présents afin que rust-embed
#    les embarque dans ksud.
###############################################################################

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

###############################################################################
# START
###############################################################################

echo
echo "============================================================"
echo " Backslashxx KernelSU + SuSFS + Tactile"
echo " Motorola kiev / Linux 4.19"
echo "============================================================"

echo
echo "Workspace : $WORKSPACE"
echo "Kernel    : $KERNEL_REPO"
echo "Branch    : $KERNEL_BRANCH"
echo "KernelSU  : $KSU_REPO"
echo "Jack      : $JACK_REPO"
echo "Defconfig : $DEFCONFIG"

###############################################################################
# CLEAN
###############################################################################

echo
echo "=== Nettoyage ==="

rm -rf "$KERNEL_DIR"
rm -rf "$KSU_DIR"
rm -rf "$JACK_DIR"
rm -rf "$OUTPUT_DIR"

rm -rf \
    "$WORKSPACE/repack" \
    "$WORKSPACE/verify_boot" \
    "$WORKSPACE/ksud-src" \
    "$WORKSPACE/android-ndk-r26d"

rm -f \
    "$WORKSPACE/ksud" \
    "$WORKSPACE/final_boot.img" \
    "$WORKSPACE/boot-stock.img" \
    "$WORKSPACE/dtbo-stock.img" \
    "$WORKSPACE/android-ndk-r26d-linux.zip"

mkdir -p "$OUTPUT_DIR"

###############################################################################
# DEPENDENCIES
###############################################################################

echo
echo "=== Installation des dépendances ==="

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

echo
echo "=== Toolchain ==="

clang --version | head -1
ld.lld --version | head -1
aarch64-linux-gnu-gcc --version | head -1

###############################################################################
# CLONE KERNEL
###############################################################################

echo
echo "============================================================"
echo "=== Clonage kernel LineageOS ==="
echo "============================================================"

git clone \
    --depth=1 \
    --branch "$KERNEL_BRANCH" \
    "$KERNEL_REPO" \
    "$KERNEL_DIR"

cd "$KERNEL_DIR"

###############################################################################
# VERIFY KERNEL VERSION
###############################################################################

echo
echo "=== Vérification kernel ==="

KERNEL_VERSION="$(
    awk '
        /^VERSION[[:space:]]*=/ {
            v=$3
        }
        /^PATCHLEVEL[[:space:]]*=/ {
            p=$3
        }
        END {
            print v "." p
        }
    ' Makefile
)"

echo "Version détectée : $KERNEL_VERSION"

if [ "$KERNEL_VERSION" != "4.19" ]; then
    echo "ERREUR : kernel 4.19 attendu."
    exit 1
fi

###############################################################################
# VERIFY DEFCONFIG
###############################################################################

echo
echo "=== Vérification defconfig ==="

if [ ! -f "arch/arm64/configs/vendor/lito-perf_defconfig" ]; then
    echo "ERREUR : vendor/lito-perf_defconfig absent."

    find arch/arm64/configs \
        -maxdepth 2 \
        \( \
            -iname "*lito*" \
            -o -iname "*kiev*" \
            -o -iname "*sm8250*" \
        \) \
        -print

    exit 1
fi

###############################################################################
# CLONE BACKSLASHXX KERNELSU
###############################################################################

echo
echo "============================================================"
echo "=== Clonage Backslashxx KernelSU ==="
echo "============================================================"

git clone \
    --depth=1 \
    --branch "$KSU_BRANCH" \
    "$KSU_REPO" \
    "$KSU_DIR"

cd "$KSU_DIR"

KSU_COMMIT="$(git rev-parse HEAD)"

echo "KernelSU commit : $KSU_COMMIT"

cd "$KERNEL_DIR"

###############################################################################
# KERNELSU SETUP
###############################################################################

echo
echo "============================================================"
echo "=== Intégration KernelSU ==="
echo "============================================================"

rm -rf KernelSU
rm -rf drivers/kernelsu

# Utilise le setup.sh provenant du checkout Backslashxx que nous venons
# précisément de cloner. Cela évite d'avoir deux versions différentes
# du code KernelSU entre le kernel et ksud.

if [ ! -f "$KSU_DIR/kernel/setup.sh" ]; then
    echo "ERREUR : KernelSU/kernel/setup.sh absent."
    exit 1
fi

bash "$KSU_DIR/kernel/setup.sh"

if [ ! -d "KernelSU/kernel" ]; then
    echo "ERREUR : KernelSU/kernel absent après setup."
    exit 1
fi

if [ ! -e "drivers/kernelsu" ]; then
    echo "ERREUR : drivers/kernelsu absent après setup."
    exit 1
fi

echo "KernelSU correctement intégré."

###############################################################################
# JACKA1LTMAN
###############################################################################

echo
echo "============================================================"
echo "=== Clonage JackA1ltman NonGKI_Kernel_Build_2nd ==="
echo "============================================================"

git clone \
    --depth=1 \
    --branch "$JACK_BRANCH" \
    "$JACK_REPO" \
    "$JACK_DIR"

JACK_HOOK="$JACK_DIR/Patches/susfs_inline_hook_patches.sh"

if [ ! -f "$JACK_HOOK" ]; then
    echo "ERREUR : $JACK_HOOK absent."

    find "$JACK_DIR/Patches" \
        -maxdepth 1 \
        -type f \
        -print

    exit 1
fi

chmod +x "$JACK_HOOK"

echo "Script SuSFS trouvé :"
echo "$JACK_HOOK"

###############################################################################
# INITIAL DEFCONFIG
###############################################################################

echo
echo "============================================================"
echo "=== Defconfig initial ==="
echo "============================================================"

make \
    O="$OUT_DIR" \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    "$DEFCONFIG"

###############################################################################
# KSU / SUSFS CONFIG
###############################################################################

echo
echo "============================================================"
echo "=== Configuration KernelSU / SuSFS ==="
echo "============================================================"

cat >> "$OUT_DIR/.config" <<'EOF'

# KernelSU
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y

# Kernel symbols
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y

# Compatibility
CONFIG_COMPAT=y
CONFIG_COMPAT_32BIT_TIME=y

# SuSFS
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
EOF

make \
    O="$OUT_DIR" \
    LLVM=1 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    olddefconfig

###############################################################################
# VERIFY CONFIG
###############################################################################

echo
echo "============================================================"
echo "=== Vérification configuration ==="
echo "============================================================"

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
    if ! grep -q "^${CONFIG_NAME}=y$" "$OUT_DIR/.config"; then
        echo "ERREUR : ${CONFIG_NAME} n'est pas activé."
        exit 1
    fi

    echo "OK : ${CONFIG_NAME}=y"
done

###############################################################################
# APPLY JACKA1LTMAN SUSFS HOOKS
###############################################################################

echo
echo "============================================================"
echo "=== Application des hooks SuSFS JackA1ltman ==="
echo "============================================================"

cp \
    "$JACK_HOOK" \
    "$KERNEL_DIR/susfs_inline_hook_patches.sh"

chmod +x "$KERNEL_DIR/susfs_inline_hook_patches.sh"

./susfs_inline_hook_patches.sh \
    2>&1 | tee "$OUTPUT_DIR/susfs_hooks.log"

###############################################################################
# NO REJECTS
###############################################################################

echo
echo "=== Vérification des .rej ==="

REJECTS="$(find "$KERNEL_DIR" -type f -name '*.rej' -print || true)"

if [ -n "$REJECTS" ]; then
    echo
    echo "ERREUR : fichiers .rej détectés :"
    echo "$REJECTS"
    exit 1
fi

echo "Aucun .rej."

###############################################################################
# VERIFY HOOKS
###############################################################################

echo
echo "============================================================"
echo "=== Vérification hooks ==="
echo "============================================================"

HOOK_ERROR=0

check_pattern()
{
    local FILE="$1"
    local PATTERN="$2"

    if grep -q "$PATTERN" "$FILE"; then
        echo "OK : $FILE -> $PATTERN"
    else
        echo "ERREUR : $FILE -> $PATTERN absent"
        HOOK_ERROR=1
    fi
}

check_pattern fs/exec.c "ksu_handle_execveat"
check_pattern fs/open.c "ksu_handle_faccessat"
check_pattern fs/stat.c "ksu_handle_stat"
check_pattern kernel/sys.c "ksu_handle_setresuid"

if [ "$HOOK_ERROR" -ne 0 ]; then
    echo
    echo "ERREUR : les hooks KernelSU/SuSFS attendus ne sont pas tous présents."
    exit 1
fi

###############################################################################
# PATCH TACTILE MOTOROLA
###############################################################################

echo
echo "============================================================"
echo "=== Patch tactile Motorola ==="
echo "============================================================"

TOUCH_FILE="techpack/display/msm/msm_drv.c"

if [ ! -f "$TOUCH_FILE" ]; then
    echo "ERREUR : $TOUCH_FILE introuvable."
    exit 1
fi

python3 - <<'PY'
from pathlib import Path

path = Path("techpack/display/msm/msm_drv.c")
text = path.read_text()

marker = "motorola_panel_notifier_list"

if marker in text:
    print("Patch tactile déjà présent.")
else:
    patch = r'''

/* --- Début Patch Tactile Motorola --- */
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

/* --- Fin Patch Tactile Motorola --- */
'''

    path.write_text(text + patch)

    print("Patch tactile Motorola ajouté.")
PY

###############################################################################
# VERIFY TOUCH
###############################################################################

echo
echo "=== Vérification patch tactile ==="

grep -q "motorola_panel_notifier_list" "$TOUCH_FILE"
grep -q "panel_register_notifier" "$TOUCH_FILE"
grep -q "panel_unregister_notifier" "$TOUCH_FILE"
grep -q "touch_set_state" "$TOUCH_FILE"

echo "Patch tactile présent."

###############################################################################
# BUILD KERNEL
###############################################################################

echo
echo "============================================================"
echo "=== Compilation kernel ==="
echo "============================================================"

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
    echo "ERREUR : Image kernel absente."
    exit 1
fi

echo
echo "Kernel compilé :"
ls -lh "$KERNEL_IMAGE"

###############################################################################
# ANDROID NDK
###############################################################################

echo
echo "============================================================"
echo "=== Android NDK ==="
echo "============================================================"

cd "$WORKSPACE"

wget -q \
    https://dl.google.com/android/repository/android-ndk-r26d-linux.zip \
    -O android-ndk-r26d-linux.zip

unzip -q \
    android-ndk-r26d-linux.zip

export ANDROID_NDK_ROOT="$WORKSPACE/android-ndk-r26d"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"

NDK_HOST="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64"

export AARCH64_CLANG_PATH="$NDK_HOST/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$NDK_HOST/bin/aarch64-linux-android26-clang++"
export AR_PATH="$NDK_HOST/bin/llvm-ar"

export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$NDK_HOST/sysroot -I$NDK_HOST/sysroot/usr/include/aarch64-linux-android"

if [ ! -x "$AARCH64_CLANG_PATH" ]; then
    echo "ERREUR : clang Android NDK absent."
    exit 1
fi

###############################################################################
# RUST
###############################################################################

echo
echo "============================================================"
echo "=== Rust ==="
echo "============================================================"

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

###############################################################################
# BUILD KSUD FROM SAME BACKSLASHXX CHECKOUT
###############################################################################

echo
echo "============================================================"
echo "=== Compilation ksud Backslashxx ==="
echo "============================================================"

cd "$KSU_DIR/userspace/ksud"

echo
echo "=== Vérification assets ksud ==="

if [ ! -d "bin/aarch64" ]; then
    echo "ERREUR : userspace/ksud/bin/aarch64 absent."
    exit 1
fi

echo "Assets présents :"
find bin/aarch64 -maxdepth 1 -type f -printf '%f\n' | sort

###############################################################################
# CLEAN KSUD BUILD
#
# Cargo.toml explicitly uses rust-embed with compression.
# A clean build is therefore required when embedded binaries change.
###############################################################################

cargo clean

###############################################################################
# CARGO CONFIG
###############################################################################

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

###############################################################################
# BUILD
###############################################################################

cargo build \
    --release \
    --target aarch64-linux-android \
    2>&1 | tee "$OUTPUT_DIR/ksud-build.log"

KSUD_BINARY="$KSU_DIR/userspace/ksud/target/aarch64-linux-android/release/ksud"

if [ ! -x "$KSUD_BINARY" ]; then
    echo "ERREUR : ksud absent après compilation."

    find "$KSU_DIR/userspace/ksud/target" \
        -type f \
        -name "ksud" \
        -print || true

    exit 1
fi

cp \
    "$KSUD_BINARY" \
    "$WORKSPACE/ksud"

chmod 755 \
    "$WORKSPACE/ksud"

echo
echo "ksud compilé :"
ls -lh "$WORKSPACE/ksud"

###############################################################################
# VERIFY KSUD ARCH
###############################################################################

echo
echo "=== Vérification architecture ksud ==="

file "$WORKSPACE/ksud"

if ! file "$WORKSPACE/ksud" | grep -qi "aarch64"; then
    echo "ERREUR : ksud n'est pas AArch64."
    exit 1
fi

###############################################################################
# DOWNLOAD STOCK BOOT
###############################################################################

echo
echo "============================================================"
echo "=== Boot stock ==="
echo "============================================================"

cd "$WORKSPACE"

curl -fL \
    "$BOOT_URL" \
    -o boot-stock.img

curl -fL \
    "$DTBO_URL" \
    -o dtbo-stock.img

if [ ! -s boot-stock.img ]; then
    echo "ERREUR : boot-stock.img absent."
    exit 1
fi

###############################################################################
# MAGISKBOOT
###############################################################################

echo
echo "=== Préparation magiskboot ==="

mkdir -p "$WORKSPACE/repack"

wget -q \
    https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk \
    -O "$WORKSPACE/Magisk-v27.0.apk"

unzip -q \
    "$WORKSPACE/Magisk-v27.0.apk" \
    'lib/x86_64/libmagiskboot.so' \
    -d "$WORKSPACE/magisk_extract"

cp \
    "$WORKSPACE/magisk_extract/lib/x86_64/libmagiskboot.so" \
    "$WORKSPACE/repack/magiskboot"

chmod 755 \
    "$WORKSPACE/repack/magiskboot"

###############################################################################
# UNPACK
###############################################################################

echo
echo "============================================================"
echo "=== Unpack boot.img ==="
echo "============================================================"

cp \
    "$WORKSPACE/boot-stock.img" \
    "$WORKSPACE/repack/boot.img"

cd "$WORKSPACE/repack"

./magiskboot unpack boot.img

if [ ! -f kernel ]; then
    echo "ERREUR : kernel absent après unpack."
    exit 1
fi

if [ ! -d ramdisk ]; then
    echo "ERREUR : ramdisk absent après unpack."
    exit 1
fi

###############################################################################
# INSTALL KERNEL
###############################################################################

echo
echo "=== Installation du kernel compilé ==="

cp \
    "$KERNEL_IMAGE" \
    kernel

###############################################################################
# INSTALL KSUD
###############################################################################

echo
echo "============================================================"
echo "=== Installation ksud ==="
echo "============================================================"

mkdir -p \
    ramdisk/data/adb

cp \
    "$WORKSPACE/ksud" \
    ramdisk/data/adb/ksud

chmod 755 \
    ramdisk/data/adb/ksud

if [ ! -x ramdisk/data/adb/ksud ]; then
    echo "ERREUR : ksud non exécutable."
    exit 1
fi

echo "OK : /data/adb/ksud"

###############################################################################
# NOTE
#
# ksud itself contains the Android aarch64 assets through rust-embed.
# assets.rs extracts them into /data/adb/ksu/bin/ when ksud performs its
# initialization. We therefore do NOT manually copy resetprop/busybox/etc.
# into the boot ramdisk here.
###############################################################################

###############################################################################
# REPACK
###############################################################################

echo
echo "============================================================"
echo "=== Repack boot.img ==="
echo "============================================================"

./magiskboot repack \
    boot.img \
    new-boot.img

if [ ! -s new-boot.img ]; then
    echo "ERREUR : nouveau boot.img absent."
    exit 1
fi

mv \
    new-boot.img \
    "$WORKSPACE/final_boot.img"

###############################################################################
# VERIFY FINAL BOOT
###############################################################################

echo
echo "============================================================"
echo "=== Vérification boot final ==="
echo "============================================================"

rm -rf "$WORKSPACE/verify_boot"

mkdir -p "$WORKSPACE/verify_boot"

cp \
    "$WORKSPACE/final_boot.img" \
    "$WORKSPACE/verify_boot/boot.img"

cd "$WORKSPACE/verify_boot"

"$WORKSPACE/repack/magiskboot" unpack boot.img >/dev/null

if [ ! -f kernel ]; then
    echo "ERREUR : kernel absent du boot final."
    exit 1
fi

if [ ! -d ramdisk ]; then
    echo "ERREUR : ramdisk absent du boot final."
    exit 1
fi

if [ ! -x ramdisk/data/adb/ksud ]; then
    echo "ERREUR : ksud absent/non exécutable dans le boot final."
    exit 1
fi

echo "OK : kernel présent."
echo "OK : ramdisk présent."
echo "OK : /data/adb/ksud présent."

###############################################################################
# OUTPUT
###############################################################################

echo
echo "============================================================"
echo "=== Artifacts ==="
echo "============================================================"

cd "$WORKSPACE"

cp \
    "$WORKSPACE/final_boot.img" \
    "$OUTPUT_DIR/Backslashxx-SuSFS-kiev-boot.img"

cp \
    "$WORKSPACE/dtbo-stock.img" \
    "$OUTPUT_DIR/dtbo.img"

cp \
    "$WORKSPACE/ksud" \
    "$OUTPUT_DIR/ksud"

cp \
    "$OUTPUT_DIR/build.log" \
    "$OUTPUT_DIR/build.log"

cp \
    "$OUTPUT_DIR/susfs_hooks.log" \
    "$OUTPUT_DIR/susfs_hooks.log"

cp \
    "$OUTPUT_DIR/ksud-build.log" \
    "$OUTPUT_DIR/ksud-build.log"

###############################################################################
# CONFIG ARTIFACT
###############################################################################

cp \
    "$OUT_DIR/.config" \
    "$OUTPUT_DIR/kernel.config"

###############################################################################
# FINAL
###############################################################################

echo
echo "============================================================"
echo " BUILD TERMINÉ"
echo "============================================================"

echo
echo "Artifacts :"
ls -lh "$OUTPUT_DIR"

echo
echo "Boot final :"
ls -lh "$OUTPUT_DIR/Backslashxx-SuSFS-kiev-boot.img"

echo
echo "ksud :"
ls -lh "$OUTPUT_DIR/ksud"

echo
echo "============================================================"
echo " Vérifications effectuées"
echo "============================================================"
echo " [OK] Linux 4.19"
echo " [OK] vendor/lito-perf_defconfig"
echo " [OK] Backslashxx KernelSU"
echo " [OK] CONFIG_KSU=y"
echo " [OK] CONFIG_KSU_MANUAL_HOOK=y"
echo " [OK] CONFIG_KALLSYMS"
echo " [OK] CONFIG_KALLSYMS_ALL"
echo " [OK] SuSFS"
echo " [OK] JackA1ltman inline hooks"
echo " [OK] Aucun .rej"
echo " [OK] Patch tactile Motorola"
echo " [OK] Kernel Image"
echo " [OK] ksud AArch64"
echo " [OK] ksud compilé avec assets rust-embed"
echo " [OK] /data/adb/ksud"
echo " [OK] boot.img repacké"
echo "============================================================"
```
