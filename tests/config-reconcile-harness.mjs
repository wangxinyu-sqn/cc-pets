// Exercise the production entry points against independent Codex, Claude and agy Homes.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const project = fileURLToPath(new URL("..", import.meta.url));
const cli = path.join(project, ".build/release/cc-pets");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "cc-pets-config-merge-"));
const home = path.join(root, "user");
const claude = path.join(home, ".claude"), codex = path.join(home, ".codex"), agy = path.join(home, ".gemini");
const claudeConfig = path.join(home, ".claude.json"), claudeSettings = path.join(claude, "settings.json");
const codexHooks = path.join(codex, "hooks.json"), toml = path.join(codex, "config.toml");
const agySettings = path.join(agy, "antigravity-cli/settings.json"), agyHooks = path.join(agy, "config/hooks.json");
const agyMcp = path.join(agy, "config/mcp_config.json");
const read = file => JSON.parse(fs.readFileSync(file, "utf8"));
const write = (file, value) => fs.writeFileSync(file, JSON.stringify(value), {mode: 0o600});
const env = {...process.env, HOME: home, CC_PETS_HOME: path.join(home, ".cc-pets"), CODEX_HOME: codex,
  CLAUDE_CONFIG_DIR: claude, CC_PETS_APPLICATION_SUPPORT_DIR: path.join(root, "support"),
  CC_PETS_STATE_DIR: path.join(root, "state"), CC_PETS_SHIM_DIR: path.join(root, "shims"),
  CC_PETS_ASSUME_CLI: "1", CC_BRIDGE_SKIP_MCP: "0", CC_PETS_LANGUAGE: "en",
  CODEX_REAL_BIN: "/usr/bin/false", CLAUDE_REAL_BIN: "/usr/bin/false", AGY_REAL_BIN: "/usr/bin/false"};
function run(...args) {
  const result = spawnSync(cli, args, {env, cwd: home, encoding: "utf8"});
  assert.equal(result.status, 0, result.stdout + result.stderr);
}
const enable = () => run("bridge","enable","--wake=off","--codex-approve=", "--claude-allow=check_inbox", "--agy-allow=check_inbox");
const repair = () => { run("profile","repair-all","--pet-hooks-only"); run("bridge","refresh"); };
const user = tag => ({type:"command", command:"echo " + tag});
try {
  for (const dir of [claude,codex,path.dirname(agySettings),path.dirname(agyMcp)]) fs.mkdirSync(dir,{recursive:true});
  run("profile","ensure-defaults");
  run("profile","repair-all","--pet-hooks-only");
  enable();
  for (const file of [claudeSettings,codexHooks]) {
    const config = read(file);
    const groups = config.hooks.SessionStart;
    for (const group of groups) {
      group.hooks[0].command = "USER_VAR=keep " + group.hooks[0].command.replaceAll("'", '"');
      group.hooks[0].userLabel = "keep";
      group.hooks.unshift(user("before"));
      group.hooks.push(user("after"));
    }
    // Unknown handlers, explicit policy, group metadata and empty groups must survive.
    groups.unshift({hooks:[]}, {matcher:"X", hooks:[user("other")]});
    if (file === claudeSettings) {
      config.permissions.allow.unshift("mcp__cc-bridge__send_message");
      config.permissions.ask = ["mcp__cc-bridge__set_name"];
    }
    write(file, config);
  }
  const ag = read(agyHooks);
  const pet = ag["cc-pets-cli"];
  pet.userLabel = "keep";
  pet.Stop.unshift(user("before"));
  pet.Stop.push(user("after"));
  ag.handWritten = {PreToolUse:pet.PreToolUse};
  delete pet.PreToolUse;
  ag.handWritten.PreToolUse[0].hooks.unshift(user("before"));
  ag.handWritten.PreToolUse[0].hooks.push(user("after"));
  write(agyHooks, ag);
  const settings = read(agySettings);
  settings.permissions.allow.unshift("mcp(cc-bridge/send_message)");
  settings.permissions.deny = ["mcp(cc-bridge/release_files)"];
  write(agySettings,settings);
  const c = read(claudeConfig);
  Object.assign(c.mcpServers["cc-bridge"], {alwaysLoad:true, custom:{value:42}});
  c.mcpServers["cc-bridge"].env.MY_VAR = "keep";
  write(claudeConfig,c);
  const a = read(agyMcp);
  a.mcpServers["cc-bridge"].timeoutSeconds = 30;
  a.mcpServers["cc-bridge"].env.MY_VAR = "keep";
  write(agyMcp,a);
  fs.writeFileSync(toml, '[mcp_servers.cc-bridge]\ncommand="/old/cc-pets"\nargs=["bridge","mcp"]\nstartup_timeout_sec=30\n[mcp_servers.cc-bridge.env]\nMY_VAR="keep"\n');
  const files = [claudeSettings,codexHooks,agyHooks,agySettings,claudeConfig,agyMcp];
  const snapshots = files.map(file => [fs.readFileSync(file,"utf8"), fs.statSync(file).ino]);
  repair(); repair();
  files.forEach((file,i) => {
    assert.equal(fs.readFileSync(file,"utf8"),snapshots[i][0],file);
    assert.equal(fs.statSync(file).ino,snapshots[i][1],file);
  });
  // A missing handler gets added and a stale command is fixed at its previous position.
  const dirty = read(claudeSettings);
  const slot = dirty.hooks.SessionStart.find(g => g.hooks.some(h => h.command.includes("--hook")));
  slot.hooks[1].command = slot.hooks[1].command.replace(cli, "/old/cc-pets");
  delete dirty.hooks.TaskCompleted;
  write(claudeSettings,dirty);
  repair();
  const fixed = read(claudeSettings);
  assert.ok(fixed.hooks.TaskCompleted.length);
  const handlers = fixed.hooks.SessionStart.find(g => g.hooks.some(h => h.command.includes("--hook"))).hooks;
  assert.deepEqual([handlers[0],handlers[2]], [user("before"), user("after")]);
  assert.ok(handlers[1].command.includes(cli));
  assert.equal(handlers[1].userLabel,"keep");
  assert.match(handlers[1].command, /USER_VAR=/);

  run("bridge","disable");
  assert.match(fs.readFileSync(toml,"utf8"),/enabled\s*=\s*false/);
  assert.match(fs.readFileSync(toml,"utf8"),/startup_timeout_sec=30/);
  assert.match(fs.readFileSync(toml,"utf8"),/MY_VAR="keep"/);
  assert.deepEqual(read(claudeSettings).permissions.allow, ["mcp__cc-bridge__send_message"]);
  assert.deepEqual(read(agySettings).permissions.allow, ["mcp(cc-bridge/send_message)"]);
  assert.deepEqual(read(agySettings).permissions.deny,settings.permissions.deny);
  assert.deepEqual(read(agyHooks), ag, "Bridge disable keeps pet hooks");
  assert.equal(read(agyMcp).mcpServers["cc-bridge"].disabled,true);
  assert.equal(read(agyMcp).mcpServers["cc-bridge"].env.MY_VAR,"keep");
  assert.ok(!read(claudeConfig).mcpServers?.["cc-bridge"]);
  enable();
  assert.deepEqual(read(claudeConfig).mcpServers["cc-bridge"],c.mcpServers["cc-bridge"]);
  assert.deepEqual(read(agyMcp),a);
  run("bridge","disable");
  run("--uninstall-integrations");
  assert.deepEqual(read(agyHooks)["cc-pets-cli"], {userLabel:"keep", Stop:[user("before"),user("after")]});
  assert.deepEqual(read(agyHooks).handWritten.PreToolUse[0].hooks, [user("before"),user("after")]);
  for(const file of [claudeSettings,codexHooks]) {
    const hooks = read(file).hooks.SessionStart;
    assert.deepEqual(hooks[0],{hooks:[]});
    assert.deepEqual(hooks[1],{matcher:"X",hooks:[user("other")]});
    assert.ok(hooks.slice(2).every(g => JSON.stringify(g.hooks) === JSON.stringify([user("before"),user("after")])));
  }
  // All three protect another program that happens to use the same server name.
  const foreign = {command:"/other/program", args:["bridge","mcp"], env:{KEEP:"y"}};
  for(const file of [claudeConfig,agyMcp]) write(file,{mcpServers:{"cc-bridge":foreign}});
  const otherToml = '[mcp_servers.cc-bridge]\ncommand="/other/program"\nargs=["bridge","mcp"]\n';
  fs.writeFileSync(toml,otherToml);
  for (const [file,rule] of [[claudeSettings,"mcp__cc-bridge__check_inbox"],[agySettings,"mcp(cc-bridge/check_inbox)"]]) {
    const doc=read(file); doc.permissions.allow.push(rule); write(file,doc);
  }
  const conflict = spawnSync(cli,["bridge","enable","--wake=off","--claude-allow=check_inbox","--agy-allow=check_inbox"],{env,cwd:home});
  assert.equal(conflict.status,1);
  run("bridge","disable");
  for(const file of [claudeConfig,agyMcp]) assert.deepEqual(read(file).mcpServers["cc-bridge"],foreign);
  assert.equal(fs.readFileSync(toml,"utf8"),otherToml);
  assert.ok(read(claudeSettings).permissions.allow.includes("mcp__cc-bridge__check_inbox"));
  assert.ok(read(agySettings).permissions.allow.includes("mcp(cc-bridge/check_inbox)"));
  console.log("config-reconcile-harness: Codex, Claude and agy passed");
} finally { fs.rmSync(root,{recursive:true,force:true}); }
