#!/bin/zsh
set -eu

# GitHub Actions 已经在 macOS runner 上跑完整测试，本地 pre-push 钩子是它的前哨：
# 推送前先在本机强制跑一遍 npm test，避免把编译不过的提交推上去。
#
# 用法：./scripts/install-git-hooks.sh
# 跳过单次检查：git push --no-verify

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
HOOKS_DIR="$(git -C "${PROJECT_DIR}" rev-parse --git-path hooks)"
if [[ "${HOOKS_DIR}" != /* ]]; then
  HOOKS_DIR="${PROJECT_DIR}/${HOOKS_DIR}"
fi
HOOK_PATH="${HOOKS_DIR}/pre-push"

mkdir -p "${HOOKS_DIR}"
if [[ -e "${HOOK_PATH}" ]] && ! grep -Fq 'cc-pets-pre-push' "${HOOK_PATH}" 2>/dev/null; then
  print -u2 "已存在非本项目管理的 pre-push 钩子：${HOOK_PATH}"
  print -u2 "请先备份或手动合并，避免覆盖你自己的钩子。"
  exit 1
fi

cat > "${HOOK_PATH}" <<'HOOK'
#!/bin/zsh
# cc-pets-pre-push
set -eu

if [[ "${CC_PETS_SKIP_PRE_PUSH:-0}" == "1" ]]; then
  print "已跳过 cc-pets pre-push 检查（CC_PETS_SKIP_PRE_PUSH=1）。"
  exit 0
fi

PROJECT_DIR="$(git rev-parse --show-toplevel)"
print "pre-push：正在跑 CC_PETS_STRICT=1 npm test …"
if ! CC_PETS_STRICT=1 npm --prefix "${PROJECT_DIR}" test; then
  print -u2 ""
  print -u2 "测试未通过，已阻止推送。"
  print -u2 "确认要跳过：git push --no-verify"
  exit 1
fi
HOOK
chmod +x "${HOOK_PATH}"
print "已安装 pre-push 钩子: ${HOOK_PATH}"
print "推送前会自动跑 CC_PETS_STRICT=1 npm test；跳过单次检查用 git push --no-verify。"
