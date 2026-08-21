#!/bin/bash
set -euo pipefail

echo "=== Début du build Backslashxx KernelSU + SUSFS ==="
df -h

# Nettoyage espace disque
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc || true
sudo apt-get clean || true
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

# Installation des dépendances
sudo apt-get update
sudo apt-get install -y \
  bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 mkbootimg patch wget

cd "$GITHUB_WORKSPACE"

echo "=== Clonage du kernel LineageOS ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources

echo "=== Intégration Backslashxx KernelSU (version pinée) ==="
rm -rf drivers/kernelsu

git clone --filter=blob:none --sparse https://github.com/backslashxx/KernelSU.git /tmp/backslashxx-src
cd /tmp/backslashxx-src

# Commit plus compatible avec les patches SUSFS 2.2.00
git checkout 67fa81b60c7efe2fc1a608fdd5965864706a4ede 2>/dev/null || \
git checkout HEAD~120 2>/dev/null || \
git checkout HEAD~80

git sparse-checkout set kernel
cd -

mkdir -p drivers/kernelsu
cp -a /tmp/backslashxx-src/kernel/. drivers/kernelsu/
rm -rf /tmp/backslashxx-src

# Correction pour noyau 4.19 : MODULE_IMPORT_NS n'existe pas
sed -i '/MODULE_IMPORT_NS/d' drivers/kernelsu/ksu.c 2>/dev/null || true

echo "=== Structure KernelSU ==="
ls -la drivers/kernelsu/

# Ajout dans Kconfig et Makefile
if ! grep -q "kernelsu" drivers/Kconfig; then
  echo 'source "drivers/kernelsu/Kconfig"' >> drivers/Kconfig
  echo "OK: Kconfig modifié"
fi

if ! grep -q "kernelsu" drivers/Makefile; then
  echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
  echo "OK: Makefile modifié"
fi

echo "=== Application des patches SUSFS ==="
# Ici tu dois avoir tes patches SUSFS déjà présents dans le workspace
# Exemple (adapte selon ton organisation) :
# - susfs_patch_to_4.19.patch
# - susfs_inline_hook_patches.sh

if [ -f "$GITHUB_WORKSPACE/susfs_patch_to_4.19.patch" ]; then
  patch -p1 < "$GITHUB_WORKSPACE/susfs_patch_to_4.19.patch" || true
fi

if [ -f "$GITHUB_WORKSPACE/susfs_inline_hook_patches.sh" ]; then
  bash "$GITHUB_WORKSPACE/susfs_inline_hook_patches.sh" || true
fi

echo "=== Configuration du kernel ==="
mkdir -p out
make O=out ARCH=arm64 vendor/lito-perf_defconfig

# Forcer les options KernelSU + SUSFS
cat << EOF >> out/.config
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
EOF

make O=out ARCH=arm64 olddefconfig

echo "=== Compilation ==="
export CCACHE_DIR=/tmp/ccache
export CCACHE_EXEC=$(which ccache)
export USE_CCACHE=1
ccache -M 10G || true

make -j$(nproc) O=out ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
  CC=clang \
  2>&1 | tee build.log

if [ -f out/arch/arm64/boot/Image ]; then
  echo "✅ BUILD SUCCESS"
  ls -lh out/arch/arm64/boot/
else
  echo "❌ BUILD FAILED"
  grep -i "error:" build.log | head -30
  exit 1
fi

echo "=== Téléchargement des images stock ==="
cd "$GITHUB_WORKSPACE"
curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260809/boot.img" 2>/dev/null || {
  echo "Impossible de télécharger boot.img stock, génération manuelle..."
  mkbootimg --kernel kernel_sources/out/arch/arm64/boot/Image \
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

curl -fLo dtbo-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260809/dtbo.img" 2>/dev/null || true

if [ -f "boot-stock.img" ]; then
  mkdir -p repack
  cp boot-stock.img repack/boot.img
  wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
  unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
  mv lib/x86_64/libmagiskboot.so repack/magiskboot
  chmod +x repack/magiskboot
  rm -rf Magisk-v27.0.apk lib/
  cd repack
  ./magiskboot unpack boot.img
  cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel
  ./magiskboot repack boot.img new-boot.img
  mv new-boot.img ../final_boot.img
  cd ..
fi

echo "=== Copie vers output ==="
mkdir -p output
cp final_boot.img output/Backslashxx-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/ 2>/dev/null || true

echo "=== BUILD TERMINÉ ==="
ls -lh output/
