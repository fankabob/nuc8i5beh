#!/bin/bash
#
# verify-after-reboot.sh -- 重启后核查引导状态
#
# 背景（2026-10-09）:
#   EFI 分区本次只改动了一处 —— CPUFriend 由「两段式 + 全部禁用」改为
#   「合并式 1.3.0 + 启用」（写入时间 22:14）。
#   其余改动（10 个 kext 升级、NVMeFix 对齐、config 标注）都只在仓库里，
#   不影响开机。
#
#   重启前记录（22:51，改造尚未生效）:
#     CPUFriend                           未加载   <- 改造前它是关闭的
#     as.vit9696.Lilu                     1.7.2
#     org.acidanthera.NVMeFix             1.1.3
#     machdep.xcpm.mode                   1
#     machdep.xcpm.vectors_loaded_count   1
#
#   ==> 本次核查的核心就一条: **CPUFriend 是否加载成功**。
#       重启前这里必然是「未加载」，重启后应该变成 1.3.0。
#
#   ⚠ 踩坑记录: CPUFriend 1.3.0 起 bundle id 由 as.vit9696.CPUFriend
#     改为 org.acidanthera.driver.CPUFriend。早期版本的本脚本按旧 id
#     精确匹配，导致新 kext 明明已加载却误报「未加载」。现改为宽匹配
#     "CPUFriend"，兼容新旧两代。
#     校验结果（2026-10-09 23:10，改造后首次引导）: 已加载 1.3.0 ✓
#
# 本脚本只读，不修改任何文件。
# 用法: tools/verify-after-reboot.sh
#
set -uo pipefail

CFG="/Volumes/EFI/EFI/OC/config.plist"
CF_INDEX=10          # CPUFriend 在 config.plist 的 Kernel/Add 中的位置
OK=0
BAD=0

line_of() { kmutil showloaded 2>/dev/null | grep -i "$1" | head -1; }
ver_of()  { printf '%s' "$1" | sed -n 's/.*(\([0-9][0-9.]*\)).*/\1/p'; }

chk() {  # $1=显示名  $2=grep 关键词  $3=期望版本（可空）
  local l v
  l="$(line_of "$2")"
  if [ -z "$l" ]; then
    printf '  %-16s %-12s %s\n' "$1" "未加载" "✗"
    BAD=$((BAD + 1)); return
  fi
  v="$(ver_of "$l")"
  if [ -n "$3" ] && [ "$v" != "$3" ]; then
    printf '  %-16s %-12s %s\n' "$1" "$v" "✗ 期望 $3"
    BAD=$((BAD + 1))
  else
    printf '  %-16s %-12s %s\n' "$1" "$v" "✓"
    OK=$((OK + 1))
  fi
}

# ---------------------------------------------------------------- 环境

echo
echo "================= 重启后状态核查 ================="
echo "系统   : $(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
echo "已运行 : $(uptime | sed 's/^ *//; s/.* up //; s/, *[0-9]* user.*//')"
echo "CPU    : $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"

# ---------------------------------------------------------------- 核心

echo
echo "【1】CPUFriend —— 本次改造的核心"
chk "CPUFriend" "CPUFriend" "1.3.0"
chk "Lilu（依赖）" "as.vit9696.Lilu" "1.7.2"

cf_line="$(line_of "CPUFriend")"
if [ -n "$cf_line" ]; then
  echo
  echo "  ✓ CPUFriend 已加载 —— 改造生效（重启前此处为「未加载」）"
else
  echo
  echo "  ✗ CPUFriend 未加载 —— 改造未生效，请检查下方回滚提示"
fi

# --- 1b: 变频数据是否真正被采用（kext 加载 ≠ 数据生效）---

echo
echo "【1b】变频数据是否真正生效"
if [ -z "$cf_line" ]; then
  echo "  （CPUFriend 未加载，跳过）"
else
  # 注意: 不能用 `ioreg | grep -q` —— grep -q 命中即退出会向 ioreg 发 SIGPIPE，
  # 在 set -o pipefail 下整个管道会被判为失败，导致明明有数据却误报「未生效」。
  # 改用 grep -o | wc -l 完整消费输入，一次拿到计数。
  cf_n="$(ioreg -rn AppleACPICPU 2>/dev/null \
          | grep -o '"cf-frequency-data"' | wc -l | tr -d ' ')"
  if [ "${cf_n:-0}" -gt 0 ]; then
    echo "  cf-frequency-data 已注入 AppleACPICPU    ✓  (${cf_n} 处)"
    OK=$((OK + 1))
  else
    echo "  cf-frequency-data 未出现在 IORegistry     ✗  数据未生效"
    BAD=$((BAD + 1))
  fi

  freq="$(ioreg -rn X86PlatformPlugin -l 2>/dev/null \
          | grep -o '"Frequencies"={[^}]*}' | head -1)"
  if [ -n "$freq" ]; then
    echo "  X86PlatformPlugin 采用的频率表:"
    echo "      $freq"
    case "$freq" in
      *'"3800"'*) echo "  含 3800 档（i5-8259U 最高睿频）       ✓"
                  OK=$((OK + 1)) ;;
      *)          echo "  未发现 3800 档                        ⚠  可能未采用仓库那份数据"
                  BAD=$((BAD + 1)) ;;
    esac
  else
    echo "  未能读取 X86PlatformPlugin 频率表      ⚠  （非致命）"
  fi
fi

# ---------------------------------------------------------------- XCPM

echo
echo "【2】XCPM 电源管理"
m="$(sysctl -n machdep.xcpm.mode 2>/dev/null || echo '?')"
v="$(sysctl -n machdep.xcpm.vectors_loaded_count 2>/dev/null || echo '?')"
printf '  %-24s %-6s %s\n' "xcpm.mode" "$m" "$([ "$m" = 1 ] && echo ✓ || echo ✗)"
printf '  %-24s %-6s %s\n' "vectors_loaded_count" "$v" "$([ "${v:-0}" -gt 0 ] 2>/dev/null && echo ✓ || echo ✗)"
[ "$m" = 1 ] || BAD=$((BAD + 1))
echo "  （这两项重启前就是 1，属既有正常状态，非本次变化点）"

# ---------------------------------------------------------------- 其余 kext

echo
echo "【3】其余第三方 kext（应全部加载）"
chk "NVMeFix"      "NVMeFix"      "1.1.3"
chk "VirtualSMC"   "VirtualSMC"   "1.3.7"
chk "SMCProcessor" "SMCProcessor" "1.3.7"
chk "SMCSuperIO"   "SMCSuperIO"   "1.3.7"
chk "WhateverGreen" "WhateverGreen" "1.7.0"
chk "AppleALC"     "AppleALC"     "1.9.7"
chk "AirportBrcmFixup" "AirportBrcmFixup" "2.2.0"
chk "FeatureUnlock" "FeatureUnlock" "1.1.8"
chk "IntelMausi"   "IntelMausi"   "1.0.8"
chk "RestrictEvents" "RestrictEvents" "1.1.6"

# ---------------------------------------------------------------- NVMe

echo
echo "【4】NVMe 电源管理"
apst="$(ioreg -rn IONVMeController -l 2>/dev/null | grep -o '"apst" = [A-Za-z]*' | head -1)"
printf '  %-16s %s\n' "APST" "${apst:-未读取到}"
if printf '%s' "$apst" | grep -q Yes; then
  echo "  ✓ APST 已开启（NVMeFix 生效）"
fi

# ---------------------------------------------------------------- 配置一致性

echo
echo "【5】EFI 分区配置"
if [ -f "$CFG" ]; then
  st="$(plutil -extract "Kernel.Add.$CF_INDEX.Enabled" raw -o - "$CFG" 2>/dev/null)"
  path="$(plutil -extract "Kernel.Add.$CF_INDEX.BundlePath" raw -o - "$CFG" 2>/dev/null)"
  printf '  Kernel/Add[%s] = %s | Enabled = %s\n' "$CF_INDEX" "${path:-?}" "${st:-?}"
  if [ ! -e "/Volumes/EFI/EFI/OC/Kexts/CPUFriendDataProvider.kext" ]; then
    echo "  CPUFriendDataProvider.kext 已移除（合并式）✓"
  else
    echo "  ⚠ CPUFriendDataProvider.kext 仍存在"
  fi
else
  echo "  EFI 分区未挂载，跳过（主结论不受影响）"
  echo "  可执行: diskutil mount disk0s1"
fi

# ---------------------------------------------------------------- 结论

echo
echo "====================== 结论 ======================"
if [ "$BAD" = 0 ]; then
  echo "  全部通过 ✓（$OK 项正常）"
else
  echo "  共 $BAD 项异常，请查看上方 ✗ 标记"
fi

echo
echo "想看实际变频效果（空载频率能否降到 ~1GHz、功耗与温度）:"
echo "  安装 Intel Power Gadget，或执行  sudo powermetrics --samplers cpu_power -i 1000"

echo
echo "============== 如需回滚 =============="
echo "方式一：只关闭 CPUFriend（保留合并式文件，回到改造前的「未启用」状态）"
echo "  plutil -replace Kernel.Add.$CF_INDEX.Enabled -bool NO \"$CFG\""
echo "  然后重启"
echo
echo "方式二：从备份完整恢复改造前的分区配置与 kext"
echo "  BK=\"\$HOME/efi-backups/20261009-221106\""
echo "  cp \"\$BK/config-plist-partition.plist\" \"$CFG\""
echo "  cp -R \"\$BK/removed-from-EFI/CPUFriend.kext\" \"\$BK/removed-from-EFI/CPUFriendDataProvider.kext\" /Volumes/EFI/EFI/OC/Kexts/"
echo "  然后重启"
echo
