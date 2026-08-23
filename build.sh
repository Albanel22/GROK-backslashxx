#!/bin/bash
set -e

echo "=== Début du build Backslashxx KernelSU + SusFS (Manual Hook) ==="
df -h

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg perl

cd "$GITHUB_WORKSPACE"

echo "=== Clonage du kernel depuis le fork Albanel22 ==="
git clone https://github.com/Albanel22/android_kernel_motorola_sm8250.git \
  -b lineage-23.2 --depth=1 kernel_sources

cd kernel_sources

echo "=== Intégration Backslashxx KernelSU ==="
rm -rf drivers/kernelsu kernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/backslashxx/KernelSU/master/kernel/setup.sh" | bash

echo "=== Les hooks manuels sont déjà intégrés dans le fork ==="
echo "=== Les modifications SusFS manuelles sont déjà intégrées dans le fork ==="

echo "=== Configuration ==="

export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out

CONFIG=$(find arch/arm64/configs/ \
  \( -name "*kiev*" -o -name "*lito*" -o -name "*sm8250*" \) \
  | head -1)

CONFIG_NAME=${CONFIG#arch/arm64/configs/}

echo "Config utilisée: $CONFIG_NAME"

make O=out LLVM=1 \
  CROSS_COMPILE="$CROSS_COMPILE" \
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
  "$CONFIG_NAME"

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  echo "# CONFIG_KPROBES is not set"
  echo "# CONFIG_HAVE_KPROBES is not set"
  echo "# CONFIG_KPROBE_EVENTS is not set"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
  echo "# CONFIG_COMPAT_VDSO is not set"
  echo "# CONFIG_VDSO32 is not set"
  echo "CONFIG_KSU_SUSFS=y"
  echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
  echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
  echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
  echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
  echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
  echo "CONFIG_KSU_SUSFS_SUS_MAP=y"
} >> out/.config

make O=out LLVM=1 \
  CROSS_COMPILE="$CROSS_COMPILE" \
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
  olddefconfig

echo "=== Vérification ==="

grep -E \
  "CONFIG_KSU=|CONFIG_KSU_MANUAL_HOOK|CONFIG_KPROBES" \
  out/.config

echo "=== Patch signatures + tactile ==="

sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c

echo "=== Compilation finale ==="

make O=out LLVM=1 \
  CROSS_COMPILE="$CROSS_COMPILE" \
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
  -j"$(nproc)" Image 2>&1 | tee build.log

if [ -f "out/arch/arm64/boot/Image" ]; then
  echo "✅ Compilation réussie"
else
  echo "❌ BUILD FAILED"
  grep -i "error:" build.log | head -20
  exit 1
fi

echo "=== Vérification KernelSU ==="

grep -E \
  "CONFIG_KSU=|CONFIG_KSU_MANUAL_HOOK|CONFIG_KSU_SUSFS" \
  out/.config || true

strings out/arch/arm64/boot/Image | grep -i "ksu_" | head -50 || true

echo "=== Compilation de ksud ==="

cd "$GITHUB_WORKSPACE"

curl --proto '=https' --tlsv1.2 -sSf \
  https://sh.rustup.rs | sh -s -- -y

source "$HOME/.cargo/env"

rustup target add aarch64-linux-android

wget -q \
  https://dl.google.com/android/repository/android-ndk-r26d-linux.zip

unzip -q android-ndk-r26d-linux.zip

export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"

export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"

export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

rm -rf "$GITHUB_WORKSPACE/ksud-src"

git clone --depth=1 \
  https://github.com/backslashxx/KernelSU.git \
  "$GITHUB_WORKSPACE/ksud-src"

cd "$GITHUB_WORKSPACE/ksud-src/userspace/ksud"

echo "=== Vérification SU Backslashxx ==="

test -f src/su.rs
test -f src/cli.rs

grep -n "pub fn root_shell" src/su.rs
grep -n 'arg0 == "su"' src/cli.rs

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

cargo build --release --target aarch64-linux-android

KSUD_BINARY="$GITHUB_WORKSPACE/ksud-src/target/aarch64-linux-android/release/ksud"

if [ ! -f "$KSUD_BINARY" ]; then
  echo "❌ ksud introuvable"
  exit 1
fi

cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"
chmod 755 "$GITHUB_WORKSPACE/ksud"

echo "✅ ksud compilé"

cd "$GITHUB_WORKSPACE"

echo "=== Téléchargement des images stock ==="

curl -fLo boot-stock.img \
  "https://mirrorbits.lineageos.org/full/kiev/20260809/boot.img" \
  2>/dev/null || {
    mkbootimg \
      --kernel kernel_sources/out/arch/arm64/boot/Image \
      --ramdisk /dev/null \
      --output final_boot.img \
      --header_version 2 \
      --pagesize 4096 \
      --base 0x00000000 \
      --kernel_offset 0x00008000 \
      --ramdisk_offset 0x01000000 \
      --tags_offset 0x00000100 \
      --cmdline "androidboot.hardware=kiev androidboot.selinux=permissive"
  }

curl -fLo dtbo-stock.img \
  "https://mirrorbits.lineageos.org/full/kiev/20260809/dtbo.img" \
  2>/dev/null || true

if [ -f "boot-stock.img" ]; then

  mkdir -p repack
  cp boot-stock.img repack/boot.img

  wget -q \
    https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk \
    -O Magisk-v27.0.apk

  unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so

  mv lib/x86_64/libmagiskboot.so repack/magiskboot
  chmod +x repack/magiskboot

  rm -rf Magisk-v27.0.apk lib/

  cd repack

  set +e
  ./magiskboot unpack boot.img
  UNPACK_EXIT=$?
  set -e

  if [ ! -f "kernel" ] || [ ! -f "ramdisk.cpio" ]; then
    echo "❌ Échec réel du unpack"
    exit 1
  fi

  cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

  echo "=== Installation de ksud ==="

  ./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" \
    "mkdir 0755 data/adb" \
    "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"

  echo "=== Installation de SU ==="

  cp "$GITHUB_WORKSPACE/ksud" local_su_binary
  chmod 755 local_su_binary

  ./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" \
    "mkdir 0755 system/bin" \
    "add 06755 system/bin/su ./local_su_binary"

  rm -f local_su_binary

  echo "=== Vérification SU/ksud dans ramdisk ==="

  ./magiskboot cpio ramdisk.cpio list | \
    grep -E '(^|/)(su|ksud)$' || true

  ./magiskboot repack boot.img new-boot.img || {
    echo "❌ Échec du repack"
    exit 1
  }

  mv new-boot.img ../final_boot.img

  cd ..
fi

echo "=== Copie vers output ==="

mkdir -p output

cp final_boot.img \
  output/Backslashxx-SusFS-boot.img

cp dtbo-stock.img \
  output/dtbo.img 2>/dev/null || true

cp kernel_sources/build.log \
  output/

cp "$GITHUB_WORKSPACE/ksud" \
  output/ksud 2>/dev/null || true

echo "=== BUILD TERMINÉ ==="

ls -lh output/

