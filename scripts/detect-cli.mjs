// "这台机器上到底装没装 Codex / Claude Code CLI"。安装器据此决定是否写它们的配置：
// 以前无条件 mkdir + 写 hooks.json / settings.json，没装的用户会被凭空造出 ~/.codex、
// ~/.claude，甚至被接管一个他还没有的 status line。
//
// 判据是"配置目录已存在"或"PATH 里有真二进制"，两者取或：
//   - 装了但从没跑过 → 没有配置目录，靠 PATH 认出来；
//   - 装在非标准位置或用别的启动方式 → PATH 里找不到，靠配置目录认出来。
// 安装器自己不再创建这两个目录，所以"目录存在"是一个干净的信号，不会自证。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const shimDirectory = () => path.resolve(
  process.env.CC_PETS_SHIM_DIR || path.join(os.homedir(), ".cc-pets/shims"));

const isDirectory = (target) => {
  try {
    return fs.statSync(target).isDirectory();
  } catch {
    return false;
  }
};

// 不能直接用 `which codex`：安装完成后 shim 目录就排在 PATH 最前面，命中的是我们自己的
// 包装器，等于自己证明自己。这里跳过 shim 目录，并且对解析后落在包装器上的候选再兜一层
// （复制而非软链安装时，shim 可能不在 CC_PETS_SHIM_DIR 里）。
const hasRealExecutable = (name) => {
  const shim = shimDirectory();
  const wrapperNames = new Set([`${name}-with-pet`, "codex-with-pet", "claude-with-pet"]);
  for (const entry of (process.env.PATH || "").split(path.delimiter)) {
    if (!entry) continue;
    let resolvedEntry;
    try {
      resolvedEntry = fs.realpathSync(entry);
    } catch {
      resolvedEntry = path.resolve(entry);
    }
    if (resolvedEntry === shim) continue;
    const candidate = path.join(entry, name);
    try {
      const stats = fs.statSync(candidate);
      if (!stats.isFile() || (stats.mode & 0o111) === 0) continue;
      const real = fs.realpathSync(candidate);
      if (path.dirname(real) === shim) continue;
      if (wrapperNames.has(path.basename(real))) continue;
      return true;
    } catch {
      // 断链或没权限的候选直接跳过，继续看 PATH 里的下一个。
    }
  }
  return false;
};

// 逃生舱：探测漏判时（装在容器里、PATH 被裁剪过、CI 造假环境）用户可以强制安装。
// CODEX_REAL_BIN / CLAUDE_REAL_BIN 沿用 bin/*-with-pet 已有的约定。
const forced = (realBinVariable) =>
  process.env.CC_PETS_ASSUME_CLI === "1" || (process.env[realBinVariable] || "").length > 0;

export const detectCodexCLI = () =>
  forced("CODEX_REAL_BIN") ||
  isDirectory(process.env.CODEX_HOME || path.join(os.homedir(), ".codex")) ||
  hasRealExecutable("codex");

export const detectClaudeCLI = () =>
  forced("CLAUDE_REAL_BIN") ||
  isDirectory(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude")) ||
  hasRealExecutable("claude");
