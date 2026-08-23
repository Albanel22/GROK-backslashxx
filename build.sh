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

echo "=== Clonage du kernel ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git \
  -b lineage-23.2 --depth=1 kernel_sources

cd kernel_sources

echo "=== Intégration Backslashxx KernelSU ==="
rm -rf drivers/kernelsu kernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/backslashxx/KernelSU/master/kernel/setup.sh" | bash

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

echo "=== Téléchargement du repo JackA1ltman ==="

git clone --depth=1 \
  https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git \
  /tmp/jack_repo 2>/dev/null || true

echo "=== Application du patch SusFS 4.19 ==="

PATCH_419=$(find /tmp/jack_repo/Patches -name "*4.19*" -name "*.patch" | head -1)

if [ -n "$PATCH_419" ]; then
  echo "Application du patch: $PATCH_419"
  patch -p1 < "$PATCH_419" 2>&1 | tee /tmp/susfs_patch.log || true
else
  echo "Recherche des patches..."
  find /tmp/jack_repo/Patches -name "*.patch" | head -20
fi

echo "=== Vérification des .rej ==="

find . -name "*.rej" -type f | while read -r rej; do
  echo "REJ: $rej"
done

echo "=== Corrections post-patch ==="

sed -i '1617d' fs/proc/task_mmu.c 2>/dev/null || true

if ! grep -q "susfs_def.h" fs/namespace.c; then
  sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#define CL_COPY_MNT_NS BIT(25)\n#endif' fs/namespace.c
fi

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
    content = re.sub(
        pattern,
        extern_decl + '\n' + r'\1',
        content,
        count=1
    )

    old_code = '''	bool ruid_new, euid_new, suid_new;'''

    new_code = '''	bool ruid_new, euid_new, suid_new;
#ifdef CONFIG_KSU_SUSFS
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif'''

    if old_code in content:
        content = content.replace(old_code, new_code, 1)
    else:

        old_code2 = '''	kuid_t kruid, keuid, ksuid;'''

        new_code2 = '''	kuid_t kruid, keuid, ksuid;
#ifdef CONFIG_KSU_SUSFS
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif'''

        if old_code2 in content:
            content = content.replace(old_code2, new_code2, 1)

with open('kernel/sys.c', 'w') as f:
    f.write(content)
PYEOF

  python3 /tmp/hook_setresuid.py
fi

echo "=== Correction SUS_MOUNT (vfs_create_mount) ==="

python3 << 'PYEOF'
import re
with open('fs/namespace.c', 'r') as f:
    content = f.read()

# Ajouter la fonction susfs_alloc_non_unshare_ksu_vfsmnt
if 'susfs_alloc_non_unshare_ksu_vfsmnt' not in content:
    susfs_func = '''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
static struct mount *susfs_alloc_non_unshare_ksu_vfsmnt(const char *name)
{
	struct mount *mnt = kmem_cache_zalloc(mnt_cache, GFP_KERNEL);
	int res;
	if (mnt) {
		res = ida_alloc_min(&mnt_id_ida, DEFAULT_KSU_MNT_ID, GFP_KERNEL);
		if (res < 0)
			goto out_free_cache;
		mnt->mnt_id = res;
		if (name) {
			mnt->mnt_devname = kstrdup_const(name, GFP_KERNEL_ACCOUNT);
			if (!mnt->mnt_devname)
				goto out_free_id;
		}
#ifdef CONFIG_SMP
		mnt->mnt_pcp = alloc_percpu(struct mnt_pcp);
		if (!mnt->mnt_pcp)
			goto out_free_devname;
		this_cpu_add(mnt->mnt_pcp->mnt_count, 1);
#else
		mnt->mnt_count = 1;
		mnt->mnt_writers = 0;
#endif
		INIT_HLIST_NODE(&mnt->mnt_hash);
		INIT_LIST_HEAD(&mnt->mnt_child);
		INIT_LIST_HEAD(&mnt->mnt_mounts);
		INIT_LIST_HEAD(&mnt->mnt_list);
		INIT_LIST_HEAD(&mnt->mnt_expire);
		INIT_LIST_HEAD(&mnt->mnt_share);
		INIT_LIST_HEAD(&mnt->mnt_slave_list);
		INIT_LIST_HEAD(&mnt->mnt_slave);
		INIT_HLIST_NODE(&mnt->mnt_mp_list);
		INIT_LIST_HEAD(&mnt->mnt_umounting);
		init_fs_pin(&mnt->mnt_umount, drop_mountpoint);
	}
	return mnt;
#ifdef CONFIG_SMP
out_free_devname:
	kfree_const(mnt->mnt_devname);
#endif
out_free_id:
	mnt_free_id(mnt);
out_free_cache:
	kmem_cache_free(mnt_cache, mnt);
	return NULL;
}
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
'''
    pattern = r'(static struct mount \*alloc_vfsmnt\(const char \*name\))'
    content = re.sub(pattern, susfs_func + '\n' + r'\1', content, count=1)
    print("OK: susfs_alloc_non_unshare_ksu_vfsmnt ajoutée")

# Corriger vfs_create_mount
old_code = '''	mnt = alloc_vfsmnt(fc->source ?: "none");'''
new_code = '''#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	if (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted)) {
		if (susfs_is_current_ksu_domain()) {
			mnt = susfs_alloc_non_unshare_ksu_vfsmnt(fc->source ?: "none");
			goto bypass_orig_flow;
		}
	}
#endif
	mnt = alloc_vfsmnt(fc->source ?: "none");
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bypass_orig_flow:
#endif'''

if old_code in content:
    content = content.replace(old_code, new_code, 1)
    print("OK: vfs_create_mount corrigé")
else:
    print("INFO: vfs_create_mount déjà corrigé ou pattern différent")

with open('fs/namespace.c', 'w') as f:
    f.write(content)
PYEOF

echo "=== Correction SUS_MAP (pagemap_read) ==="

python3 << 'PYEOF'
import re
with open('fs/proc/task_mmu.c', 'r') as f:
    content = f.read()

# Ajouter la déclaration vma si nécessaire
if 'struct vm_area_struct *vma;' not in content:
    old_decl = '''	int ret = 0, copied = 0;'''
    new_decl = '''	int ret = 0, copied = 0;
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
	struct vm_area_struct *vma;
#endif'''
    if old_decl in content:
        content = content.replace(old_decl, new_decl, 1)
        print("OK: déclaration vma ajoutée")

old_code = '''		ret = walk_page_range(start_vaddr, end, &pagemap_walk);'''
new_code = '''#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		vma = find_vma(mm, start_vaddr);
		if (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))
			goto bypass_orig_flow;
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP
		ret = walk_page_range(start_vaddr, end, &pagemap_walk);
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
bypass_orig_flow:
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP'''

if old_code in content:
    content = content.replace(old_code, new_code, 1)
    print("OK: pagemap_read corrigé")
else:
    print("INFO: pagemap_read déjà corrigé ou pattern différent")

with open('fs/proc/task_mmu.c', 'w') as f:
    f.write(content)
PYEOF

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
