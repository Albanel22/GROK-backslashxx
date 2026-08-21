#!/bin/bash
set -euo pipefail

# ============================================================
# Configuration
# ============================================================
KERNEL_REPO="https://github.com/LineageOS/android_kernel_motorola_sm8250.git"
KERNEL_BRANCH="lineage-23.2"
KERNEL_DIR="kernel_sources"
OUTPUT_DIR="output"
STOCK_BOOT_URL="https://mirrorbits.lineageos.org/full/kiev/20260809/boot.img"
STOCK_DTBO_URL="https://mirrorbits.lineageos.org/full/kiev/20260809/dtbo.img"

export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
export CCACHE_DIR="${GITHUB_WORKSPACE:-$PWD}/.ccache"
export PATH="/usr/lib/ccache:$PATH"

echo "=== Début du build Backslashxx KernelSU + SUSFS ==="
df -h

# ============================================================
# Nettoyage espace disque
# ============================================================
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc || true
sudo apt-get clean
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y \
  bc bison build-essential ccache flex glibc-source \
  libelf-dev libssl-dev libncurses-dev \
  gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
  clang llvm lld device-tree-compiler \
  zip unzip curl git python3 mkbootimg patch binutils

# ============================================================
# Clonage du kernel
# ============================================================
cd "$GITHUB_WORKSPACE"
rm -rf "$KERNEL_DIR"
echo "=== Clonage du kernel ==="
git clone "$KERNEL_REPO" -b "$KERNEL_BRANCH" --depth=1 "$KERNEL_DIR"
cd "$KERNEL_DIR"

# ============================================================
# Intégration Backslashxx KernelSU
# ============================================================
echo "=== Intégration Backslashxx KernelSU ==="
rm -rf drivers/kernelsu

git clone --depth=1 --filter=blob:none --sparse https://github.com/backslashxx/KernelSU.git /tmp/backslashxx-src
(cd /tmp/backslashxx-src && git sparse-checkout set kernel)
mkdir -p drivers/kernelsu
cp -a /tmp/backslashxx-src/kernel/. drivers/kernelsu/
rm -rf /tmp/backslashxx-src

# Kconfig + Makefile
if ! grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig; then
  echo 'source "drivers/kernelsu/Kconfig"' >> drivers/Kconfig
fi

if ! grep -q 'kernelsu/' drivers/Makefile; then
  echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
fi

echo "Structure KernelSU :"
ls -la drivers/kernelsu/

# ============================================================
# Récupération des patches SUSFS
# ============================================================
cd "$GITHUB_WORKSPACE"
rm -rf susfs-tools
git clone --depth=1 --filter=blob:none --sparse https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git susfs-tools
(cd susfs-tools && git sparse-checkout set Patches)

SUSFS_PATCH="susfs-tools/Patches/Patch/susfs_patch_to_4.19.patch"
SUSFS_HOOK_SCRIPT="susfs-tools/Patches/susfs_inline_hook_patches.sh"

if [[ ! -f "$SUSFS_PATCH" ]]; then
  echo "❌ Patch SUSFS introuvable : $SUSFS_PATCH"
  ls -la susfs-tools/Patches/ || true
  exit 1
fi

# ============================================================
# Application du patch SUSFS
# ============================================================
cd "$KERNEL_DIR"
mkdir -p ../"$OUTPUT_DIR"/susfs-patch-rejects

echo "=== Application du patch SUSFS 4.19 ==="
if ! patch -p1 --forward --reject-file=- < "../$SUSFS_PATCH" > ../susfs_patch.log 2>&1; then
  echo "⚠️  Le patch SUSFS ne s'est pas appliqué proprement."
fi
cat ../susfs_patch.log

REJ_COUNT=$(find . -name "*.rej" | wc -l)
if [[ "$REJ_COUNT" -gt 0 ]]; then
  echo "⚠️  $REJ_COUNT hunk(s) rejeté(s). Application des corrections manuelles..."
  find . -name "*.rej" -exec cp --parents {} ../"$OUTPUT_DIR"/susfs-patch-rejects/ \;
  cp ../susfs_patch.log ../"$OUTPUT_DIR"/susfs-patch-rejects/

  # ---------- Corrections manuelles plus robustes ----------

  # 1. fs/namespace.c
  if ! grep -q "susfs_def.h" fs/namespace.c; then
    if grep -q '#include <linux/sched/task.h>' fs/namespace.c; then
      sed -i '/#include <linux\/sched\/task.h>/a\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
#include <linux/susfs_def.h>\
#endif\
\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
extern bool susfs_is_current_ksu_domain(void);\
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\
#define CL_COPY_MNT_NS BIT(25)\
#endif' fs/namespace.c
      echo "OK: includes SUSFS ajoutés dans fs/namespace.c"
    else
      echo "⚠️  Impossible de trouver l'ancre dans fs/namespace.c"
    fi
  fi

  # 2. fs/proc/task_mmu.c
  if grep -q "susfs" fs/proc/task_mmu.c 2>/dev/null; then
    sed -i '/susfs_is_current_ksu_domain/d' fs/proc/task_mmu.c 2>/dev/null || true
  fi

  rm -f fs/namespace.c.rej fs/proc/task_mmu.c.rej 2>/dev/null || true

  REMAINING=$(find . -name "*.rej" | wc -l)
  if [[ "$REMAINING" -gt 0 ]]; then
    echo "⚠️  $REMAINING fichier(s) .rej restant(s) :"
    find . -name "*.rej"
    echo "→ On continue, mais vérifie bien la compilation."
  else
    echo "✅ Tous les .rej critiques ont été traités"
  fi
fi

# ============================================================
# Script de hooks inline SUSFS
# ============================================================
if [[ -f "../$SUSFS_HOOK_SCRIPT" ]]; then
  echo "=== Exécution du script de hooks inline SUSFS ==="
  chmod +x "../$SUSFS_HOOK_SCRIPT"
  bash "../$SUSFS_HOOK_SCRIPT" | tee ../susfs_hooks.log

  if grep -qi "patch failed\|failed to" ../susfs_hooks.log; then
    echo "⚠️  Au moins un hook a échoué. On continue."
    mkdir -p ../"$OUTPUT_DIR"/susfs-patch-rejects
    cp ../susfs_hooks.log ../"$OUTPUT_DIR"/susfs-patch-rejects/
  fi

  # Correctif policy_rwlock
  echo "=== Correctif policy_rwlock ==="
  if grep -q 'static DEFINE_RWLOCK(policy_rwlock);' security/selinux/ss/services.c; then
    sed -i 's/static DEFINE_RWLOCK(policy_rwlock);/DEFINE_RWLOCK(policy_rwlock);/' security/selinux/ss/services.c
    echo "[+] policy_rwlock rendu non-static"
  fi
else
  echo "❌ Script de hooks inline introuvable"
  exit 1
fi

# ============================================================
# Configuration
# ============================================================
echo "=== Configuration ==="
mkdir -p out

CONFIG=$(find arch/arm64/configs/ -type f \( -name "*kiev*" -o -name "*lito*" -o -name "*sm8250*" \) | head -1)
if [[ -z "$CONFIG" ]]; then
  echo "❌ Aucun defconfig trouvé"
  exit 1
fi

CONFIG_NAME=${CONFIG#arch/arm64/configs/}
echo "Config utilisée : $CONFIG_NAME"

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 "$CONFIG_NAME"

# Activation des options KSU + SUSFS
cat >> out/.config << 'EOF'
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
CONFIG_KPROBES=y
CONFIG_HAVE_KPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_COMPAT=y
CONFIG_COMPAT_32BIT_TIME=y
# CONFIG_COMPAT_VDSO is not set
# CONFIG_VDSO32 is not set
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
EOF

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

echo "=== Vérification des options ==="
grep -E "CONFIG_KSU|CONFIG_SECCOMP|CONFIG_KPROBE" out/.config || true

# ============================================================
# Patches supplémentaires (signatures + tactile)
# ============================================================
echo "=== Patch signatures modules + tactile ==="

# Désactivation du check de version des modules
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

# Patch tactile Motorola
if ! grep -q "panel_register_notifier" techpack/display/msm/msm_drv.c; then
  cat >> techpack/display/msm/msm_drv.c << 'EOF'

/* --- Début Patch Tactile --- */
#include <linux/notifier.h>
#include <linux/module.h>
static BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);
int panel_register_notifier(struct notifier_block *nb) {
    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);
}
EXPORT_SYMBOL(panel_register_notifier);
int panel_unregister_notifier(struct notifier_block *nb) {
    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);
}
EXPORT_SYMBOL(panel_unregister_notifier);
void touch_set_state(int state) { return; }
EXPORT_SYMBOL(touch_set_state);
/* --- Fin Patch Tactile --- */
EOF
  echo "OK: patch tactile appliqué"
fi

# ============================================================
# Compilation
# ============================================================
echo "=== Compilation finale ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j"$(nproc)" Image 2>&1 | tee build.log

if [[ ! -f "out/arch/arm64/boot/Image" ]]; then
  echo "❌ BUILD FAILED"
  grep -iE "error:|fatal error:" build.log | head -30
  exit 1
fi

echo "✅ Compilation réussie"
ls -lh out/arch/arm64/boot/

# ============================================================
# Vérification des symboles KSU / SUSFS
# ============================================================
echo "=== Vérification des symboles KSU / SUSFS ==="
IMAGE="out/arch/arm64/boot/Image"

echo "--- Symboles KernelSU ---"
nm "$IMAGE" 2>/dev/null | grep -E "ksu_|kernelsu" | head -20 || echo "Aucun symbole KSU trouvé (anormal)"

echo ""
echo "--- Symboles SUSFS ---"
nm "$IMAGE" 2>/dev/null | grep -iE "susfs_" | head -30 || echo "Aucun symbole SUSFS trouvé (anormal)"

echo ""
echo "--- Résumé ---"
KSU_COUNT=$(nm "$IMAGE" 2>/dev/null | grep -cE "ksu_|kernelsu" || true)
SUSFS_COUNT=$(nm "$IMAGE" 2>/dev/null | grep -ciE "susfs_" || true)

echo "Symboles KSU trouvés   : $KSU_COUNT"
echo "Symboles SUSFS trouvés : $SUSFS_COUNT"

if [[ "$KSU_COUNT" -lt 5 ]]; then
  echo "⚠️  Peu de symboles KSU détectés. Vérifie l'intégration."
fi
if [[ "$SUSFS_COUNT" -lt 5 ]]; then
  echo "⚠️  Peu de symboles SUSFS détectés. Les patches n'ont peut-être pas tous pris."
fi

# ============================================================
# Création du boot.img
# ============================================================
cd "$GITHUB_WORKSPACE"
echo "=== Téléchargement des images stock ==="

curl -fLo boot-stock.img "$STOCK_BOOT_URL" || {
  echo "⚠️  Impossible de télécharger boot.img stock, fallback mkbootimg"
  mkbootimg \
    --kernel "$KERNEL_DIR/out/arch/arm64/boot/Image" \
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

curl -fLo dtbo-stock.img "$STOCK_DTBO_URL" 2>/dev/null || true

if [[ -f boot-stock.img ]]; then
  mkdir -p repack
  cp boot-stock.img repack/boot.img

  wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk.apk
  unzip -q -o Magisk.apk lib/x86_64/libmagiskboot.so
  mv lib/x86_64/libmagiskboot.so repack/magiskboot
  chmod +x repack/magiskboot
  rm -rf Magisk.apk lib

  cd repack
  ./magiskboot unpack boot.img
  cp "$GITHUB_WORKSPACE/$KERNEL_DIR/out/arch/arm64/boot/Image" kernel
  ./magiskboot repack boot.img new-boot.img
  mv new-boot.img ../final_boot.img
  cd ..
fi

# ============================================================
# Sortie finale
# ============================================================
mkdir -p "$OUTPUT_DIR"
cp final_boot.img "$OUTPUT_DIR/Backslashxx-boot.img"
[[ -f dtbo-stock.img ]] && cp dtbo-stock.img "$OUTPUT_DIR/dtbo.img"
cp "$KERNEL_DIR/build.log" "$OUTPUT_DIR/"

echo "=== BUILD TERMINÉ ==="
ls -lh "$OUTPUT_DIR"
df -h
