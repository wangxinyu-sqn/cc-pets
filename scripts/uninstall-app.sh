#!/bin/zsh
set -eu

APPLICATIONS_DIR="${CC_PETS_APPLICATIONS_DIR:-${HOME}/Applications}"
TARGET_APP="${APPLICATIONS_DIR}/CC Pets.app"
TARGET_EXECUTABLE="${TARGET_APP}/Contents/MacOS/cc-pets"

if [[ -e "${TARGET_APP}" ]]; then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "${TARGET_APP}/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "${BUNDLE_ID}" != "com.universewang.cc-pets" ]]; then
    print -u2 "拒绝删除：${TARGET_APP} 不是 CC Pets 应用（Bundle ID 不匹配）。"
    exit 2
  fi
fi

if [[ "${CC_PETS_SKIP_APP_STOP:-0}" != "1" ]] && pgrep -f "${TARGET_EXECUTABLE}" >/dev/null 2>&1; then
  pkill -f "${TARGET_EXECUTABLE}" || true
fi

if [[ -e "${TARGET_APP}" ]]; then
  rm -rf "${TARGET_APP}"
  print "已删除应用: ${TARGET_APP}"
else
  print "未安装应用: ${TARGET_APP}"
fi
