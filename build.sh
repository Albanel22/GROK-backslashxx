#!/bin/bash
set -euo pipefail

echo "=== Début du build Backslashxx KernelSU + SusFS (Manual Hook) ==="
df -h

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev \
  libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
  clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg \
  perl patch

cd "$GITHUB_WORKSPACE"

echo "=== Clonage du kernel ==="
rm -rf kernel_sources
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
  -b lineage-23.2 --depth=1 kernel_sources

cd kernel_sources

echo "=== Intégration Backslashxx KernelSU ==="
rm -rf drivers/kernelsu kernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/backslashxx/KernelSU/master/kernel/setup.sh" | bash

echo "=== Téléchargement patches SusFS officiels 4.19 ==="

wget -q \
  "https://gitlab.com/simonpunk/susfs4ksu/-/raw/kernel-4.19/kernel_patches/50_add_susfs_in_kernel-4.19.patch" \
  -O /tmp/susfs_kernel.patch || {
    echo "❌ Échec téléchargement patch SusFS kernel"
    exit 1
  }

wget -q \
  "https://gitlab.com/simonpunk/susfs4ksu/-/raw/kernel-4.19/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" \
  -O /tmp/susfs_ksu.patch || {
    echo "❌ Échec téléchargement patch SusFS KernelSU"
    exit 1
  }

echo "=== Hooks manuels sucompat (fs/exec.c, fs/open.c, fs/stat.c) ==="

mkdir -p ../output/manual-hooks-diag

hook_insert() {
  local file="$1" sig_re="$2" extern_block="$3" call_line="$4"

  if [ ! -f "$file" ]; then
    echo "❌ $file introuvable."
    return 1
  fi

  if ! grep -Pzo "$sig_re" "$file" > /dev/null 2>&1; then
    echo "❌ Signature attendue introuvable dans $file — hook NON inséré."
    return 1
  fi

  perl -0777 -i -pe "s/($sig_re)/${extern_block}\$1\n#ifdef CONFIG_KSU\n#pragma GCC diagnostic ignored \x22-Wdeclaration-after-statement\x22\n${call_line}\n#endif\n/s" "$file"

  echo "[+] Hook inséré dans $file"
  return 0
}

HOOKS_FAILED=0

hook_insert "fs/exec.c" \
  '(?s)static int do_execveat_common\(.*?int flags\)\s*\n\{' \
  '#ifdef CONFIG_KSU\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n\t\t\t\t\t void *envp, int *flags);\n#endif\n' \
  'ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);' \
  || HOOKS_FAILED=1

if grep -Pzo 'long do_faccessat\(int dfd, const char __user \*filename, int mode\)\s*\n\{' fs/open.c > /dev/null 2>&1; then

  hook_insert "fs/open.c" \
    'long do_faccessat\(int dfd, const char __user \*filename, int mode\)\s*\n\{' \
    '#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t\t int *flags);\n#endif\n' \
    'ksu_handle_faccessat(&dfd, &filename, &mode, NULL);' \
    || HOOKS_FAILED=1

elif grep -Pzo 'SYSCALL_DEFINE3\(faccessat, int, dfd, const char __user \*, filename, int, mode\)\s*\n\{' fs/open.c > /dev/null 2>&1; then

  hook_insert "fs/open.c" \
    'SYSCALL_DEFINE3\(faccessat, int, dfd, const char __user \*, filename, int, mode\)\s*\n\{' \
    '#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t\t int *flags);\n#endif\n' \
    'ksu_handle_faccessat(&dfd, &filename, &mode, NULL);' \
    || HOOKS_FAILED=1

else
  echo "❌ Ni do_faccessat ni SYSCALL_DEFINE3(faccessat...) trouvé dans fs/open.c"
  HOOKS_FAILED=1
fi

if grep -Pzo 'int vfs_statx\(int dfd, const char __user \*filename, int flags,' fs/stat.c > /dev/null 2>&1; then

  hook_insert "fs/stat.c" \
    'int vfs_statx\(int dfd, const char __user \*filename, int flags,[^{]*\{' \
    '#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' \
    'ksu_handle_stat(&dfd, &filename, &flags);' \
    || HOOKS_FAILED=1

elif grep -Pzo 'int vfs_fstatat\(int dfd, const char __user \*filename, struct kstat \*stat,\s*\n\s*int flag\)\s*\n\{' fs/stat.c > /dev/null 2>&1; then

  hook_insert "fs/stat.c" \
    'int vfs_fstatat\(int dfd, const char __user \*filename, struct kstat \*stat,\s*\n\s*int flag\)\s*\n\{' \
    '#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' \
    'ksu_handle_stat(&dfd, &filename, &flag);' \
    || HOOKS_FAILED=1

else
  echo "❌ Ni vfs_statx ni vfs_fstatat trouvé dans fs/stat.c"
  HOOKS_FAILED=1
fi

if [ "$HOOKS_FAILED" -eq 1 ]; then
  echo "❌ Au moins un hook sucompat n'a pas pu être inséré automatiquement."
  for f in fs/exec.c fs/open.c fs/stat.c; do
    cp --parents "$f" ../output/manual-hooks-diag/ 2>/dev/null || true
  done
  exit 1
fi

echo "✅ Les 3 hooks sucompat sont en place."

echo "=== Hooks additionnels KernelSU (setresuid, input, devpts) ==="

# --- setresuid (CORRIGÉ: CONFIG_KSU au lieu de CONFIG_KSU_SUSFS) ---
if ! grep -q "ksu_handle_setresuid" kernel/sys.c; then
  if grep -q "__sys_setresuid" kernel/sys.c 2>/dev/null; then
    sed -i '/long __sys_setresuid(uid_t ruid, uid_t euid, uid_t suid)/i\
#ifdef CONFIG_KSU\
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);\
#endif' kernel/sys.c
    if grep -q "bool ruid_new, euid_new, suid_new;" kernel/sys.c; then
      sed -i '/bool ruid_new, euid_new, suid_new;/a\
#ifdef CONFIG_KSU\
\t(void)ksu_handle_setresuid(ruid, euid, suid);\
#endif' kernel/sys.c
    else
      sed -i '/kuid_t kruid, keuid, ksuid;/a\
#ifdef CONFIG_KSU\
\t(void)ksu_handle_setresuid(ruid, euid, suid);\
#endif' kernel/sys.c
    fi
  else
    sed -i '/^SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)/i\
#ifdef CONFIG_KSU\
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);\
#endif' kernel/sys.c
    sed -i '/kuid_t kruid, keuid, ksuid;/a\
#ifdef CONFIG_KSU\
\t(void)ksu_handle_setresuid(ruid, euid, suid);\
#endif' kernel/sys.c
  fi
  echo "[+] kernel/sys.c (setresuid) patché"
else
  echo "[~] kernel/sys.c (setresuid) déjà patché"
fi

# --- drivers/input/input.c (keycombo Vol+Vol-) ---
if [ -f "drivers/input/input.c" ] && ! grep -q "ksu_handle_input_handle_event" drivers/input/input.c; then
  perl -0777 -i -pe 's/(^void input_event\(struct input_dev \*dev,\s*unsigned int type, unsigned int code, int value\)\s*\{)/#ifdef CONFIG_KSU\nextern bool ksu_input_hook __read_mostly;\nextern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\n#endif\n$1/' drivers/input/input.c

  perl -0777 -i -pe 's/(\tif \(is_event_supported\(type, dev->evbit, EV_MAX\)\) \{)/#ifdef CONFIG_KSU\n\tif (unlikely(ksu_input_hook))\n\t\tksu_handle_input_handle_event(\&type, \&code, \&value);\n#endif\n$1/' drivers/input/input.c
  echo "[+] drivers/input/input.c patché"
elif grep -q "ksu_handle_input_handle_event" drivers/input/input.c; then
  echo "[~] drivers/input/input.c déjà patché"
else
  echo "⚠️ drivers/input/input.c introuvable"
fi

# --- drivers/tty/pty.c (devpts namespace) ---
if [ -f "drivers/tty/pty.c" ] && ! grep -q "ksu_handle_devpts" drivers/tty/pty.c; then
  perl -0777 -i -pe 's/(static struct tty_struct \*pts_unix98_lookup\(struct tty_driver \*driver,\s*struct inode \*inode, int idx\)\s*\{\s*struct tty_struct \*tty;\s*struct dentry \*dentry;\s*)/#ifdef CONFIG_KSU\nextern int ksu_handle_devpts(struct inode*);\n#endif\n$1#ifdef CONFIG_KSU\n\tksu_handle_devpts(inode);\n#endif\n/' drivers/tty/pty.c
  echo "[+] drivers/tty/pty.c patché"
elif grep -q "ksu_handle_devpts" drivers/tty/pty.c; then
  echo "[~] drivers/tty/pty.c déjà patché"
else
  echo "⚠️ drivers/tty/pty.c introuvable"
fi

echo "=== Application du patch SusFS KernelSU ==="

if [ -d "KernelSU" ]; then
  cd KernelSU
  patch -p1 < /tmp/susfs_ksu.patch 2>&1 | tee /tmp/susfs_ksu.log || true
  cd ..
else
  echo "⚠️ KernelSU/ introuvable, patch SusFS KernelSU sauté"
fi

echo "=== Application du patch SusFS kernel 4.19 ==="

patch -p1 < /tmp/susfs_kernel.patch 2>&1 | tee /tmp/susfs_kernel.log || true

echo "=== Vérification des .rej ==="

REJ_COUNT=$(find . -name "*.rej" -type f | wc -l)
if [ "$REJ_COUNT" -gt 0 ]; then
  echo "❌ $REJ_COUNT rejet(s) détecté(s) :"
  find . -name "*.rej" -type f
  echo "Le build s'arrête car les patches SusFS ne sont pas appliqués proprement."
  exit 1
else
  echo "✅ Aucun rejet"
fi

echo "=== Vérification des fichiers critiques SusFS ==="

for f in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
  if [ ! -f "$f" ]; then
    echo "❌ $f manquant — le patch SusFS n'a pas été appliqué correctement"
    exit 1
  fi
done
echo "✅ Fichiers SusFS présents"

echo "=== Configuration ==="

export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out

CONFIG=$(find arch/arm64/configs/ \
  \( -name "*kiev*" -o -name "*lito*" -o -name "*sm8250*" \) \
  | head -1)

if [ -z "$CONFIG" ]; then
  echo "❌ Aucune config trouvée dans arch/arm64/configs/"
  exit 1
fi

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

echo "=== Vérification config ==="

grep -E "CONFIG_KSU=|CONFIG_KSU_MANUAL_HOOK|CONFIG_KPROBES" out/.config || {
  echo "⚠️ Certaines options KernelSU sont absentes de .config"
}

echo "=== Patch signatures + tactile ==="

if [ -f "kernel/module.c" ]; then
  sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
  echo "✅ Patch signatures appliqué"
else
  echo "⚠️ kernel/module.c introuvable"
fi

if [ -f "techpack/display/msm/msm_drv.c" ]; then
  printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
  echo "✅ Patch tactile appliqué"
else
  echo "⚠️ techpack/display/msm/msm_drv.c introuvable"
fi

echo "=== Compilation finale ==="

make O=out LLVM=1 \
  CROSS_COMPILE="$CROSS_COMPILE" \
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
  -j"$(nproc)" Image 2>&1 | tee build.log

if [ ! -f "out/arch/arm64/boot/Image" ]; then
  echo "❌ BUILD FAILED"
  grep -i "error:" build.log | head -20 || true
  exit 1
fi
echo "✅ Compilation kernel réussie"

echo "=== Vérification KernelSU / SusFS ==="

echo "--- Config ---"
grep -E "CONFIG_KSU=|CONFIG_KSU_MANUAL_HOOK|CONFIG_KSU_SUSFS" out/.config || true

echo "--- Symboles vmlinux ---"
if [ -f "out/vmlinux" ]; then
  nm out/vmlinux 2>/dev/null | grep -E "ksu_|susfs_" | head -30 || true
else
  echo "⚠️ out/vmlinux introuvable"
fi

echo "=== Compilation de ksud ==="

cd "$GITHUB_WORKSPACE"

curl --proto '=https' --tlsv1.2 -sSf \
  https://sh.rustup.rs | sh -s -- -y

# shellcheck source=/dev/null
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

test -f src/su.rs || { echo "❌ src/su.rs manquant"; exit 1; }
test -f src/cli.rs || { echo "❌ src/cli.rs manquant"; exit 1; }

grep -n "pub fn root_shell" src/su.rs || { echo "❌ root_shell non trouvé"; exit 1; }
grep -n 'arg0 == "su"' src/cli.rs || { echo "❌ arg0 == su non trouvé"; exit 1; }

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
  echo "❌ ksud introuvable après compilation"
  exit 1
fi

cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"
chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud compilé"

cd "$GITHUB_WORKSPACE"

echo "=== Téléchargement des images stock ==="

if ! curl -fLo boot-stock.img \
  "https://mirrorbits.lineageos.org/full/kiev/20260809/boot.img"; then
  echo "⚠️ Téléchargement boot.img échoué, génération fallback avec mkbootimg"
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
fi

curl -fLo dtbo-stock.img \
  "https://mirrorbits.lineageos.org/full/kiev/20260809/dtbo.img" 2>/dev/null || true

if [ -f "boot-stock.img" ]; then
  echo "=== Repack boot.img avec Magisk ==="

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
  set -e

  if [ ! -f "kernel" ] || [ ! -f "ramdisk.cpio" ]; then
    echo "❌ Échec du unpack magiskboot"
    exit 1
  fi

  cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

  echo "=== Injection ksud dans ramdisk ==="
  ./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" \
    "mkdir 0755 data/adb" \
    "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"

  echo "=== Injection SU dans ramdisk ==="
  cp "$GITHUB_WORKSPACE/ksud" local_su_binary
  ./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" \
    "mkdir 0755 system/bin" \
    "add 06755 system/bin/su ./local_su_binary"
  rm -f local_su_binary

  echo "=== Vérification contenu ramdisk ==="
  ./magiskboot cpio ramdisk.cpio list | grep -E 'su|ksud' || true

  echo "=== Repack final ==="
  ./magiskboot repack boot.img new-boot.img || {
    echo "❌ Échec du repack"
    exit 1
  }

  mv new-boot.img ../final_boot.img
  cd ..
  echo "✅ Repack terminé"
else
  echo "ℹ️ Pas de boot-stock.img, utilisation du fallback mkbootimg"
fi

echo "=== Copie vers output ==="
mkdir -p output

cp final_boot.img output/Backslashxx-SusFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/ 2>/dev/null || true
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true

echo "=== BUILD TERMINÉ ==="
ls -lh output/
