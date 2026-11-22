#!/usr/bin/env bash
# MEMI 輕音 鸿蒙版 — 命令行构建 / 部署脚本
# 用法：
#   ./build.sh              增量构建 debug HAP
#   ./build.sh clean        清空构建产物后重建
#   ./build.sh release      构建 release HAP
#   ./build.sh run          构建 + 安装到已连接设备 + 启动 + 抓 3 秒日志
#   ./build.sh log          实时跟 MEMI 日志
#
# 模拟器可直接跑（不校验签名）；配置签名后产物自动变为 signed。

set -e

# DevEco Studio 安装位置，可用环境变量覆盖：
#   DEVECO_HOME="/path/to/DevEco Studio" ./build.sh
DEVECO_WIN="${DEVECO_HOME:-D:/Huawei/DevEco Studio}"
DEVECO="$(cygpath -u "$DEVECO_WIN" 2>/dev/null || printf '%s' "$DEVECO_WIN")"
PROJECT="$(cd "$(dirname "$0")" && pwd)/app"
BUNDLE="${MEMI_BUNDLE:-com.mmc.merimusicplayer}"
ABILITY="EntryAbility"

export JAVA_HOME="${DEVECO_WIN}/jbr"
export NODE_HOME="${DEVECO_WIN}/tools/node"
export DEVECO_SDK_HOME="${DEVECO_WIN}/sdk"
export PATH="$DEVECO/tools/node:$PATH"

HVIGOR="$DEVECO/tools/hvigor/bin/hvigorw"
HDC="$DEVECO/sdk/default/openharmony/toolchains/hdc.exe"

# hdc 是原生 exe，git bash 会擅自改写 /data/... 这种参数。
# 注意：不能全局 export MSYS_NO_PATHCONV，否则 hvigorw 的目录解析会错，只能按调用加前缀。
hdc() {
  MSYS_NO_PATHCONV=1 "$HDC" "$@"
}

cd "$PROJECT"

# 优先取已签名产物，没有则退回 unsigned
latest_hap() {
  local hap
  hap=$(find "$PROJECT/entry/build" -name "*-signed.hap" 2>/dev/null | head -1)
  [ -n "$hap" ] || hap=$(find "$PROJECT/entry/build" -name "*.hap" 2>/dev/null | head -1)
  printf '%s\n' "$hap"
}

build() {
  echo "==> hvigor assembleHap"
  "$HVIGOR" --no-daemon "$@"
  HAP=$(latest_hap)
  echo
  echo "==> 产物: $HAP"
  ls -lh "$HAP" | awk '{print "    "$5"  "$9}'
}

require_device() {
  local target
  target=$(hdc list targets | head -1 | tr -d '\r')
  if [ -z "$target" ] || [ "$target" = "[Empty]" ]; then
    echo "没有可用设备。先启动模拟器（DevEco → Tools → Device Manager）"
    exit 1
  fi
  echo "==> 目标设备: $target"
}

case "${1:-debug}" in
  clean)
    "$HVIGOR" --no-daemon clean
    build assembleHap
    ;;
  release)
    build assembleHap --mode module -p product=default -p buildMode=release
    ;;
  run)
    build assembleHap
    require_device
    HAP=$(latest_hap)
    # hdc 只认 Windows 形式的本地路径
    hdc install -r "$(cygpath -w "$HAP")" | tail -1
    hdc shell "hilog -r" >/dev/null 2>&1
    hdc shell "aa start -a $ABILITY -b $BUNDLE" | tail -1
    sleep 3
    echo "==> MEMI 日志:"
    hdc shell "hilog -x -T MEMI" 2>&1 | tail -20
    ;;
  log)
    require_device
    hdc shell "hilog -T MEMI" || true
    ;;
  debug|*)
    build assembleHap
    ;;
esac
