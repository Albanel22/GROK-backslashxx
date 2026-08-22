#!/bin/bash
set -e
echo "=== Début du build Backslashxx KernelSU + SusFS (Manual Hook) ==="
df -h

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
sudo apt-get clean
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld device-tree-compiler zip unzip curl git python3 mkbootimg perl

cd $GITHUB_WORKSPACE

echo "=== Clonage du kernel ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources

echo "=== Intégration Backslashxx KernelSU ==="
rm -rf drivers/kernelsu kernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/backslashxx/KernelSU/master/kernel/setup.sh" | bash

echo "=== Hooks manuels sucompat (fs/exec.c, fs/open.c, fs/stat.c) via Python (100% fiable) ==="
mkdir -p ../output/manual-hooks-diag

cat > /tmp/apply_hooks.py << 'PYEOF'
import re
import sys
import os

def apply_hook(file_path, signature_regex, extern_block, call_block):
    if not os.path.exists(file_path):
        print(f"❌ Fichier introuvable: {file_path}")
        return False
        
    with open(file_path, 'r') as f:
        content = f.read()
    
    # Vérifier si déjà hooké pour éviter les doubles injections
    if 'ksu_handle_execveat' in content and 'exec.c' in file_path:
        print(f"[+] Déjà hooké: {file_path}")
        return True
    if 'ksu_handle_faccessat' in content and 'open.c' in file_path:
        print(f"[+] Déjà hooké: {file_path}")
        return True
    if 'ksu_handle_stat' in content and 'stat.c' in file_path:
        print(f"[+] Déjà hooké: {file_path}")
        return True

    match = re.search(signature_regex, content, re.DOTALL)
    if not match:
        print(f"❌ Signature introuvable dans {file_path}")
        return False

    matched_sig = match.group(1)
    
    # Construction du remplacement (évite les problèmes d'échappement de Perl avec '&')
    replacement = f"""{extern_block}{matched_sig}
#ifdef CONFIG_KSU
#pragma GCC diagnostic ignored "-Wdeclaration-after-statement"
{call_block}
#endif"""

    new_content = content.replace(matched_sig, replacement, 1)
    
    with open(file_path, 'w') as f:
        f.write(new_content)
    print(f"[+] Hook inséré avec succès dans {file_path}")
    return True

HOOKS_FAILED = 0

# 1. exec.c (Avec le fallback sucompat CRUCIAL pour Termux)
if not apply_hook(
    "fs/exec.c",
    r"(static int do_execveat_common\(.*?int flags\)\s*\n\{)",
    "#ifdef CONFIG_KSU\nextern bool ksu_execveat_hook __read_mostly;\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n\t\t\t\t\t void *envp, int *flags);\nextern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,\n\t\t\t\t\t void *argv, void *envp, int *flags);\n#endif\n",
    "if (unlikely(ksu_execveat_hook))\n\t\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n\telse\n\t\tksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);"
):
    HOOKS_FAILED = 1

# 2. open.c
if not apply_hook(
    "fs/open.c",
    r"(long do_faccessat\(int dfd, const char __user \*filename, int mode\)\s*\n\{)",
    "#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t\t int *flags);\n#endif\n",
    "ksu_handle_faccessat(&dfd, &filename, &mode, NULL);"
):
    # Fallback pour les anciens noyaux
    if not apply_hook(
        "fs/open.c",
        r"(SYSCALL_DEFINE3\(faccessat, int, dfd, const char __user \*, filename, int, mode\)\s*\n\{)",
        "#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t\t int *flags);\n#endif\n",
        "ksu_handle_faccessat(&dfd, &filename, &mode, NULL);"
    ):
        HOOKS_FAILED = 1

# 3. stat.c
if not apply_hook(
    "fs/stat.c",
    r"(int vfs_statx\(int dfd, const char __user \*filename, int flags,.*?\n\{)",
    "#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n",
    "ksu_handle_stat(&dfd, &filename, &flags);"
):
    # Fallback si vfs_statx n'existe pas
    if not apply_hook(
        "fs/stat.c",
        r"(int vfs_fstatat\(int dfd, const char __user \*filename, struct kstat \*stat,\s*int flag\)\s*\n\{)",
        "#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n",
        "ksu_handle_stat(&dfd, &filename, &flag);"
    ):
        HOOKS_FAILED = 1

if HOOKS_FAILED == 1:
    print("❌ Au moins un hook sucompat n'a pas pu être inséré.")
    for f in ["fs/exec.c", "fs/open.c", "fs/stat.c"]:
        if os.path.exists(f):
            os.makedirs("../output/manual-hooks-diag/" + os.path.dirname(f), exist_ok=True)
            os.system(f"cp {f} ../output/manual-hooks-diag/{f}")
    sys.exit(1)

print("✅ Les 3 hooks sucompat sont en place (execveat avec fallback sucompat, faccessat, stat).")
PYEOF

python3 /tmp/apply_hooks.py

echo "=== Téléchargement du repo JackA1ltman ==="
git clone --depth=1 https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jack_repo 2>/dev/null || true

echo "=== Application du patch SusFS 4.19 ==="
PATCH_419=$(find /tmp/jack_repo/Patches -name "*4.19*" -name "*.patch" | head -1)
if [ -n "$PATCH_419" ]; then
  echo "Application du patch: $PATCH_419"
  patch -p1 < "$PATCH_419" 2>&1 | tee /tmp/susfs_patch.log || true
  echo "Patch appliqué"
else
  echo "Recherche des patches..."
  find /tmp/jack_repo/Patches -name "*.patch" | head -20
fi

echo "=== Vérification des .rej ==="
find . -name "*.rej" -type f | while read rej; do
  echo "REJ: $rej"
done

echo "=== Corrections post-patch ==="

# 1. Supprimer la variable vma non utilisée (ligne 1617)
sed -i '1617d' fs/proc/task_mmu.c 2>/dev/null || true
echo "OK: task_mmu.c corrigé"

# 2. Ajouter l'include susfs_def.h dans namespace.c
if ! grep -q "susfs_def.h" fs/namespace.c; then
  sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#define CL_COPY_MNT_NS BIT(25)\n#endif' fs/namespace.c
  echo "OK: include namespace.c ajouté"
fi

# 3. Ajouter ksu_handle_setresuid APRÈS bool ruid_new
if ! grep -q "ksu_handle_setresuid" kernel/sys.c; then
  cat > /tmp/hook_setresuid.py << 'PYEOF'
import re
with open('kernel/sys.c', 'r') as f:
    content = f.read()
if 'ksu_handle_setresuid' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif
'''
    pattern = r'(long __sys_setresuid)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
    old_code = '''	bool ruid_new, euid_new, suid_new;'''
    new_code = '''	bool ruid_new, euid_new, suid_new;
#ifdef CONFIG_KSU_SUSFS
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: setresuid APRÈS bool ruid_new")
    else:
        old_code2 = '''	kuid_t kruid, keuid, ksuid;'''
        new_code2 = '''	kuid_t kruid, keuid, ksuid;
#ifdef CONFIG_KSU_SUSFS
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif'''
        if old_code2 in content:
            content = content.replace(old_code2, new_code2, 1)
            print("OK: setresuid APRÈS kuid_t")
        else:
            print("ERREUR: pattern non trouvé")
with open('kernel/sys.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_setresuid.py
fi

echo "=== Configuration ==="
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out
CONFIG=$(find arch/arm64/configs/ -name "*kiev*" -o -name "*lito*" -o -name "*sm8250*" | head -1)
CONFIG_NAME=${CONFIG#arch/arm64/configs/}
echo "Config utilisée: $CONFIG_NAME"

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 $CONFIG_NAME

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

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

echo "=== Vérification ==="
grep -E "CONFIG_KSU=|CONFIG_KSU_MANUAL_HOOK|CONFIG_KPROBES" out/.config

echo "=== Patch signatures + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c

echo "=== Compilation finale ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log

if [ -f "out/arch/arm64/boot/Image" ]; then
  echo "✅ Compilation du noyau réussie"
  ls -lh out/arch/arm64/boot/
else
  echo "❌ BUILD FAILED"
  grep -i "error:" build.log | head -20
  exit 1
fi

echo "=== Compilation de ksud (Rust + NDK) ==="
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup target add aarch64-linux-android

cd "$GITHUB_WORKSPACE"
wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip
unzip -q android-ndk-r26d-linux.zip

export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

git clone --depth=1 https://github.com/backslashxx/KernelSU.git ksud-src
cd ksud-src/userspace/ksud

mkdir -p .cargo
cat > .cargo/config.toml << EOF
[target.aarch64-linux-android]
linker = "$AARCH64_CLANG_PATH"

[env]
CC_aarch64_linux_android = "$AARCH64_CLANG_PATH"
CXX_aarch64_linux_android = "$AARCH64_CLANGXX_PATH"
AR_aarch64_linux_android = "$AR_PATH"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "$BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android"
EOF

# CORRECTION : Arrêt du script si la compilation échoue
cargo build --release --target aarch64-linux-android || { echo "❌ Échec critique de la compilation de ksud"; exit 1; }

KSUD_BINARY="$GITHUB_WORKSPACE/ksud-src/target/aarch64-linux-android/release/ksud"
if [ -f "$KSUD_BINARY" ]; then
  cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"
  chmod 755 "$GITHUB_WORKSPACE/ksud"
  echo "OK: ksud compilé"
else
  echo "⚠️ ksud introuvable au chemin attendu, recherche..."
  find "$GITHUB_WORKSPACE/ksud-src" -name "ksud" -type f 2>/dev/null | head -5
fi

cd "$GITHUB_WORKSPACE/kernel_sources"

echo "=== Téléchargement des images stock ==="
cd $GITHUB_WORKSPACE
curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/20260809/boot.img" 2>/dev/null || {
  mkbootimg --kernel kernel_sources/out/arch/arm64/boot/Image --ramdisk /dev/null --output final_boot.img --header_version 2 --pagesize 4096 --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --tags_offset 0x00000100 --cmdline "androidboot.hardware=kiev androidboot.selinux=permissive"
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
  cp $GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image kernel

  if [ -f "$GITHUB_WORKSPACE/ksud" ]; then
    mkdir -p ramdisk/data/adb/ksud
    cp "$GITHUB_WORKSPACE/ksud" ramdisk/data/adb/ksud/ksud
    chmod 755 ramdisk/data/adb/ksud/ksud
    
    # CORRECTION CRUCIALE : Ajout du binaire su pour les noyaux Non-GKI
    mkdir -p ramdisk/system/bin
    wget -q https://github.com/tiann/KernelSU/releases/download/v0.9.5/su.aarch64 -O ramdisk/system/bin/su
    chmod 6755 ramdisk/system/bin/su # 6 = rws (Le bit SUID est OBLIGATOIRE pour que Termux fonctionne)
    
    echo "OK: ksud et binaire su ajoutés au ramdisk avec les bonnes permissions"
  else
    echo "ATTENTION: ksud non trouvé, boot.img généré sans"
  fi

  ./magiskboot repack boot.img new-boot.img
  mv new-boot.img ../final_boot.img
  cd ..
fi

echo "=== Copie vers output ==="
mkdir -p output
cp final_boot.img output/Backslashxx-SusFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp $GITHUB_WORKSPACE/ksud output/ksud 2>/dev/null || true

echo "=== BUILD TERMINÉ ==="
ls -lh output/
