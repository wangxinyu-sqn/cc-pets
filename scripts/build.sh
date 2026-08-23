#!/bin/zsh
set -eu

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="${PROJECT_DIR}/.build/release"
CACHE_DIR="${PROJECT_DIR}/.build/clang-cache"
APP_DIR="${BUILD_DIR}/CC Pets.app"
APP_MACOS_DIR="${APP_DIR}/Contents/MacOS"
APP_RESOURCES_DIR="${APP_DIR}/Contents/Resources"
RESOURCE_DIR="${CC_PETS_RESOURCE_DIR:-${PROJECT_DIR}/Sources/CCPets/Resources}"
PACKAGE_VERSION="$(node -p "require('${PROJECT_DIR}/package.json').version")"
mkdir -p "${BUILD_DIR}" "${CACHE_DIR}" "${APP_MACOS_DIR}" "${APP_RESOURCES_DIR}"

# 之前没有任何优化和告警选项：默认等于 -O0，且第一次开启 -Wall -Wextra 就抓到了
# 真实错误（atomic 属性只自定义了一半访问器）。CC_PETS_STRICT=1 时把告警升级为错误，
# 供 CI 使用，本地开发保持只警告。
WARNING_FLAGS=(-Wall -Wextra -Wno-unused-parameter)
if [[ "${CC_PETS_STRICT:-0}" == "1" ]]; then
  WARNING_FLAGS+=(-Werror)
fi

SOURCES=("${PROJECT_DIR}"/Sources/CCPets/*.m(N))
if (( ${#SOURCES[@]} == 0 )); then
  print -u2 "构建失败：Sources/CCPets 下没有找到任何 .m 源文件。"
  exit 1
fi

CLANG_MODULE_CACHE_PATH="${CACHE_DIR}" clang \
  -fobjc-arc \
  -fmodules-cache-path="${CACHE_DIR}" \
  -mmacosx-version-min=13.0 \
  -Os \
  "${WARNING_FLAGS[@]}" \
  "-DCC_PETS_VERSION=\"${PACKAGE_VERSION}\"" \
  -I"${PROJECT_DIR}/Sources/CCPets" \
  -framework Cocoa \
  -framework CoreServices \
  -framework ImageIO \
  -framework IOKit \
  -framework QuartzCore \
  -framework UserNotifications \
  "${SOURCES[@]}" \
  -o "${BUILD_DIR}/cc-pets"

find "${BUILD_DIR}" -maxdepth 1 -type f \( -name '*.webp' -o -name '*.png' \) -delete
find "${APP_MACOS_DIR}" -maxdepth 1 -type f \( -name '*.webp' -o -name '*.png' \) -delete
find "${APP_RESOURCES_DIR}" -maxdepth 1 -type f \( -name '*.webp' -o -name '*.png' \) -delete
SPRITES=("${RESOURCE_DIR}"/*.webp(N) "${RESOURCE_DIR}"/*.png(N))
if (( ${#SPRITES[@]} > 0 )); then
  cp "${SPRITES[@]}" "${BUILD_DIR}/"
  cp "${SPRITES[@]}" "${APP_RESOURCES_DIR}/"
fi
# 默认台词。代码里不再留内置词库，这个文件就是默认台词的唯一来源，
# 首次启动时被拷到 ~/.cc-pets/phrases.txt。
# 裸二进制旁边也放一份：直接跑 .build/release/cc-pets 时没有 app bundle。
cp "${PROJECT_DIR}/Resources/phrases.default.txt" "${APP_RESOURCES_DIR}/phrases.default.txt"
cp "${PROJECT_DIR}/Resources/phrases.default.txt" "${BUILD_DIR}/phrases.default.txt"
cp "${BUILD_DIR}/cc-pets" "${APP_MACOS_DIR}/cc-pets"
cp "${PROJECT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${APP_RESOURCES_DIR}/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${PACKAGE_VERSION}" "${APP_DIR}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${PACKAGE_VERSION}" "${APP_DIR}/Contents/Info.plist"
/usr/bin/codesign --force --sign - "${APP_DIR}" >/dev/null
print "构建完成: ${BUILD_DIR}/cc-pets"
print "应用完成: ${APP_DIR}"
