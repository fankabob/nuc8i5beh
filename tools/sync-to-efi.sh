#!/bin/bash
#
# sync-to-efi.sh -- 把仓库中的 EFI 单向同步到实际引导分区
#
#   仓库 : <本脚本所在仓库>/EFI   （git 存档副本，路径按脚本位置自动推导）
#   分区 : /Volumes/EFI/EFI        （真正在用的那份）
#
# ===== 核心安全规则（勿删改）=====
#   分区上的三码 SystemSerialNumber / MLB / SystemUUID / ROM 是独立生成、
#   正在使用的机器身份，与仓库中的那套不同（见 .workbuddy/memory/MEMORY.md）。
#   同步 config.plist 时本脚本**强制保留分区上的这四个值**，绝不用仓库的覆盖，
#   否则 iMessage / Find My 等依赖机器身份的绑定会立即失效。
#
# 用法:
#   tools/sync-to-efi.sh diff      仅列出两侧差异，不改动任何文件
#   tools/sync-to-efi.sh config    只同步 OC/config.plist（三码受保护）
#   tools/sync-to-efi.sh kexts     只同步 OC/Kexts
#   tools/sync-to-efi.sh acpi      只同步 OC/ACPI
#   tools/sync-to-efi.sh drivers   只同步 OC/Drivers
#   tools/sync-to-efi.sh tools     只同步 OC/Tools
#   tools/sync-to-efi.sh all       同步 BOOT + OC 下全部子目录 + config.plist
#
# 可选参数:
#   -n, --dry-run   只预览将要做的改动，不写入任何内容
#   -y, --yes       跳过交互确认
#   -h, --help      显示帮助
#
# 每次真正写入前会把分区完整备份到 ~/efi-backups/<时间戳>-presync/，
# 脚本结束时会打印回滚命令。
#
set -uo pipefail

# 仓库根目录按脚本自身位置推导（本脚本位于 <仓库>/tools/ 下），
# 这样换机器 / 换用户名都能直接用，也不必把个人路径写死在仓库里。
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_EFI="$REPO_ROOT/EFI"
TARGET_EFI="/Volumes/EFI/EFI"
BACKUP_ROOT="$HOME/efi-backups"

# 受保护字段：key|type（type 为 string 或 data）
PROTECTED=(
  "PlatformInfo.Generic.SystemSerialNumber|string"
  "PlatformInfo.Generic.MLB|string"
  "PlatformInfo.Generic.SystemUUID|string"
  "PlatformInfo.Generic.ROM|data"
)

DRY_RUN=0
ASSUME_YES=0
MODE=""
WORK=""
BK=""
RC=0

# ---------------------------------------------------------------- 基础工具

die() { printf '\n\033[31m错误\033[0m: %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[33m  注意\033[0m: %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

usage() {
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
}

# 脱敏显示敏感值
mask() {
  local v="$1"
  local n="${#v}"
  if [ "$n" -gt 8 ]; then
    printf '%s…%s' "${v:0:4}" "${v: -4}"
  else
    printf '%s' "$v" | sed 's/./*/g'
  fi
}

count_files() {
  find "$1" -type f ! -name '._*' ! -name '.DS_Store' 2>/dev/null | wc -l | tr -d ' '
}

read_key() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

# ---------------------------------------------------------------- 前置检查

preflight() {
  [ -d "$REPO_EFI/OC" ] || die "仓库 EFI 目录不存在: $REPO_EFI"
  [ -d "$TARGET_EFI/OC" ] || die "EFI 分区未挂载或路径不对: $TARGET_EFI"
  # 目标必须位于 /Volumes 下的一个真实挂载卷内（ESP 通常挂在 /Volumes/EFI）
  local mnt
  mnt="$(df -P "$TARGET_EFI" 2>/dev/null | awk 'NR==2{print $NF}')"
  case "$mnt" in
    /Volumes/*) ;;
    *) die "$TARGET_EFI 不在 /Volumes 下的挂载卷中（当前挂载点为 ${mnt:-未知}），请先挂载 EFI 分区" ;;
  esac
  command -v plutil >/dev/null 2>&1 || die "找不到 plutil（本脚本依赖 macOS 自带的 /usr/bin/plutil）"
}

# ---------------------------------------------------------------- 差异预览

do_diff() {
  step "两侧差异（已排除 ._* 与 .DS_Store）"
  local out
  out="$(diff -r -q -x '._*' -x '.DS_Store' "$REPO_EFI" "$TARGET_EFI" 2>&1)"
  if [ -z "$out" ]; then
    echo "  两侧完全一致 ✓"
    return 0
  fi
  printf '%s\n' "$out" | while IFS= read -r line; do
    case "$line" in
      "Only in $TARGET_EFI"*) printf '  \033[33m[仅分区有]\033[0m %s\n' "${line#Only in }" ;;
      "Only in $REPO_EFI"*)   printf '  \033[36m[仅仓库有]\033[0m %s\n' "${line#Only in }" ;;
      "Files "*)              printf '  \033[31m[内容不同]\033[0m %s\n' "$line" ;;
      *)                      printf '  %s\n' "$line" ;;
    esac
  done
  echo
  echo "  （[仅分区有] 的 APPLE/UPDATERS/* 是 macOS 自己写入的固件更新器，属正常）"
}

# ---------------------------------------------------------------- 备份

make_backup() {
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  BK="$BACKUP_ROOT/$ts-presync"
  step "备份 EFI 分区"
  mkdir -p "$BK" || die "无法创建备份目录: $BK"
  cp -R "$TARGET_EFI" "$BK/EFI-partition" || die "备份失败，已中止（分区未做任何改动）"
  sync
  local a b
  a="$(find "$TARGET_EFI" -type f 2>/dev/null | wc -l | tr -d ' ')"
  b="$(find "$BK/EFI-partition" -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ "$a" = "$b" ] || die "备份文件数不符（源 $a / 备份 $b），已中止"
  echo "  $BK/EFI-partition  （$b 个文件，已复验）"
}

# ---------------------------------------------------------------- 同步 config.plist

sync_config() {
  local src="$REPO_EFI/OC/config.plist"
  local dst="$TARGET_EFI/OC/config.plist"

  step "同步 OC/config.plist（三码受保护）"
  [ -f "$src" ] || die "源不存在: $src"
  [ -f "$dst" ] || die "目标不存在: $dst（首次部署请手工处理，本脚本只做增量同步）"

  local tmp="$WORK/config.plist.synced"
  cp "$src" "$tmp" || die "复制到临时文件失败"

  echo "  以下字段将保留分区侧的值（不会被仓库覆盖）:"
  local spec key type val flag
  for spec in "${PROTECTED[@]}"; do
    key="${spec%%|*}"; type="${spec##*|}"
    val="$(read_key "$dst" "$key")"
    [ -n "$val" ] || die "分区 $key 读取为空，拒绝同步（避免写入空值）"
    if [ "$type" = "data" ]; then flag="-data"; else flag="-string"; fi
    plutil -replace "$key" "$flag" "$val" "$tmp" >/dev/null \
      || die "写入 $key 失败"
    printf '    %-20s %s\n' "${key##*.}" "$(mask "$val")"
  done

  plutil -lint "$tmp" >/dev/null 2>&1 || die "生成的 config.plist 语法无效，已中止"

  # 复核：写入后必须与分区值逐一相等
  for spec in "${PROTECTED[@]}"; do
    key="${spec%%|*}"
    [ "$(read_key "$tmp" "$key")" = "$(read_key "$dst" "$key")" ] \
      || die "复核失败: $key 未被正确保留"
  done
  echo "  复核: 四个字段已确认等于分区值 ✓"

  # 展示除三码外还有哪些差异会被带过去
  local extra
  extra="$(diff <(plutil -convert xml1 -o - "$dst") \
                <(plutil -convert xml1 -o - "$tmp") 2>/dev/null | grep -c '^[<>]')"
  echo "  另有 $extra 行内容差异将按仓库版本写入"

  if [ "$DRY_RUN" = 1 ]; then
    echo "  [dry-run] 未写入。"
    return 0
  fi

  cp "$tmp" "$dst" || die "写入目标 config.plist 失败"
  sync
  echo "  已写入 $dst"
}

# ---------------------------------------------------------------- 同步目录

sync_dir() {
  local rel="$1"
  local src="$REPO_EFI/$rel"
  local dst="$TARGET_EFI/$rel"

  step "同步 $rel"
  [ -d "$src" ] || die "源目录不存在: $src"

  case "$dst" in
    "$TARGET_EFI"/*) ;;
    *) die "拒绝操作不安全的路径: $dst" ;;
  esac

  local n; n="$(count_files "$src")"
  [ "$n" -gt 0 ] || die "源目录内没有任何文件，拒绝同步: $rel"

  if [ "$DRY_RUN" = 1 ]; then
    local cur; cur=$([ -d "$dst" ] && count_files "$dst" || echo 0)
    echo "  [dry-run] 将用仓库的 $n 个文件替换分区现有的 $cur 个"
    return 0
  fi

  [ -d "$dst" ] && rm -rf "$dst"
  mkdir -p "$dst" || die "创建目标目录失败: $dst"
  cp -R "$src"/. "$dst"/ || die "复制失败: $rel"
  sync

  local m; m="$(count_files "$dst")"
  if [ "$n" = "$m" ]; then
    printf '  %d 个文件已同步 ✓\n' "$m"
  else
    printf '  文件数不一致: 源 %d / 目标 %d ✗\n' "$n" "$m"
    RC=1
  fi
}

# ---------------------------------------------------------------- 收尾

# 清理写入过程中带上来的 macOS 元数据。
# 注意两点：
#   1. AppleDouble 文件存放在**父目录**（如 OC/._Kexts 是 Kexts 目录的元数据），
#      删除子目录时不会连带删掉，所以必须全盘扫一遍；
#   2. APPLE/ 是 macOS 自己写入的固件更新器目录，不属于我们管，保持不动。
clean_metadata() {
  find "$TARGET_EFI" -name '._*' -not -path "*/APPLE/*" -delete >/dev/null 2>&1
  find "$TARGET_EFI" -name '.DS_Store' -not -path "*/APPLE/*" -delete >/dev/null 2>&1
  return 0
}

finish() {
  step "最终校验"
  if [ -f "$TARGET_EFI/OC/config.plist" ]; then
    plutil -lint "$TARGET_EFI/OC/config.plist" >/dev/null 2>&1 \
      && echo "  分区 config.plist 语法 OK ✓" \
      || { echo "  分区 config.plist 语法有误 ✗"; RC=1; }
  fi

  # 复查三码确实还在分区侧
  local spec key
  for spec in "${PROTECTED[@]}"; do
    key="${spec%%|*}"
    [ -n "$(read_key "$TARGET_EFI/OC/config.plist" "$key")" ] \
      || { echo "  ✗ $key 丢失！请立刻从备份回滚"; RC=1; }
  done
  [ "$RC" = 0 ] && echo "  三码四项仍在分区侧，未被覆盖 ✓"

  # 清理元数据
  local before after
  before="$(find "$TARGET_EFI" -name '._*' 2>/dev/null | wc -l | tr -d ' ')"
  clean_metadata
  after="$(find "$TARGET_EFI" -name '._*' 2>/dev/null | wc -l | tr -d ' ')"
  echo "  已清理 macOS 元数据: ._ 文件 $before -> $after"

  if [ -n "$BK" ]; then
    echo
    echo "  备份位置: $BK/EFI-partition"
    echo "  回滚命令: cp -R \"$BK/EFI-partition\"/. \"$TARGET_EFI\"/"
  fi
  [ "$RC" = 0 ] || die "同步过程中存在问题，请检查上方输出"
}

# ---------------------------------------------------------------- 主流程

# 无论从哪条路径退出（含报错），都清掉临时目录
trap '[ -n "$WORK" ] && rm -rf "$WORK"' EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    -h|--help)    usage; exit 0 ;;
    diff|config|kexts|acpi|drivers|tools|all) MODE="$1" ;;
    *)            usage; die "未知参数: $1" ;;
  esac
  shift
done

[ -n "$MODE" ] || { usage; exit 1; }

preflight

if [ "$MODE" = "diff" ]; then
  do_diff
  exit 0
fi

# 要同步的目录（all 模式自动发现 OC 下的所有子目录）
if [ "$MODE" = "all" ]; then
  DIRS="BOOT"
  for d in "$REPO_EFI"/OC/*/; do
    [ -d "$d" ] || continue
    DIRS="$DIRS OC/$(basename "$d")"
  done
elif [ "$MODE" = "config" ]; then
  DIRS=""
elif [ "$MODE" = "kexts" ]; then
  DIRS="OC/Kexts"
elif [ "$MODE" = "acpi" ]; then
  DIRS="OC/ACPI"
elif [ "$MODE" = "drivers" ]; then
  DIRS="OC/Drivers"
elif [ "$MODE" = "tools" ]; then
  DIRS="OC/Tools"
fi

echo "模式: $MODE$([ "$DRY_RUN" = 1 ] && echo '  [dry-run]')"
echo "方向: $REPO_EFI  ->  $TARGET_EFI"

if [ "$DRY_RUN" != 1 ] && [ "$ASSUME_YES" != 1 ]; then
  echo
  warn "即将向 EFI 分区写入内容，会影响下一次开机。"
  printf '  确认继续？[y/N] '
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "已取消，未做任何改动。"; exit 0 ;; esac
fi

WORK="$(mktemp -d /tmp/sync-to-efi.XXXXXX)" || die "无法创建临时目录"

if [ "$DRY_RUN" != 1 ]; then
  make_backup
fi

for r in $DIRS; do
  sync_dir "$r"
done

if [ "$MODE" = "config" ] || [ "$MODE" = "all" ]; then
  sync_config
fi

if [ "$DRY_RUN" != 1 ]; then
  finish
else
  step "dry-run 结束，未写入任何内容"
fi
