#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const nodeCandidate = process.env.npm_node_execpath || process.execPath;
const npmCandidate = process.env.npm_execpath;

if (!nodeCandidate || !npmCandidate) {
  console.warn("未记录自动更新配置：npm 没有提供 node/npm-cli 路径。");
  process.exit(0);
}

let nodePath;
let npmCliPath;
try {
  nodePath = fs.realpathSync(nodeCandidate);
  npmCliPath = fs.realpathSync(npmCandidate);
} catch {
  console.warn("未记录自动更新配置：node/npm-cli 路径不存在。");
  process.exit(0);
}

if (!path.isAbsolute(nodePath) || !path.isAbsolute(npmCliPath)) {
  console.warn("未记录自动更新配置：node/npm-cli 路径不是绝对路径。");
  process.exit(0);
}

const supportDirectory = process.env.CC_PETS_APPLICATION_SUPPORT_DIR ||
  path.join(os.homedir(), "Library", "Application Support", "CC Pets");
const applicationsDirectory = process.env.CC_PETS_APPLICATIONS_DIR ||
  path.join(os.homedir(), "Applications");
const configPath = path.join(supportDirectory, "updater.json");
fs.mkdirSync(supportDirectory, {recursive: true, mode: 0o700});
fs.writeFileSync(configPath, `${JSON.stringify({
  schemaVersion: 2,
  nodePath,
  npmCliPath,
  appPath: path.join(applicationsDirectory, "CC Pets.app")
}, null, 2)}\n`, {mode: 0o600});
fs.chmodSync(configPath, 0o600);
