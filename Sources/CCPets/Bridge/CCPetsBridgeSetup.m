#import "CCPetsL10n.h"
#import "CCPetsBridgeSetup.h"
#import "CCPetsCodexConfig.h"
#import "CCPetsBridge.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsAntigravityConfig.h"
#import "CCPetsCLISupport.h"
#import "CCPetsJSON.h"
#import "CCPetsHookMerge.h"
#import "CCPetsProfiles.h"
#import <sys/stat.h>
#import <unistd.h>

#define LF(localized, values) CCPetsInterpolate(localized, values)

NSString *const CCBridgeHookMarker = @"CC_BRIDGE_HOOK=";
NSString *const CCBridgeMCPName = @"cc-bridge";
// 正式发布前这个功能叫过 "Agent Bus"（cc-pets bus）。启用过旧版的机器上还留着旧标记的 hooks、
// 旧名字的 MCP 注册和旧审批块，安装 / 卸载时一并识别清理，不留两套。
static NSArray<NSString *> *MCPNames(void) {
    return @[CCBridgeMCPName, @"cc-pets-bus"];
}

// 文件预留提醒只挂在编辑类工具上，避免每次 shell / 读文件都多跑一次 hook。
static NSString *const ClaudeEditMatcher = @"Edit|Write|MultiEdit|NotebookEdit";
static NSString *const CodexEditMatcher = @"apply_patch|Edit|Write";

BOOL CCBridgeShouldTouchMCP(void) {
    return ![CCPetsEnvironmentValue(@"CC_BRIDGE_SKIP_MCP") isEqualToString:@"1"];
}

// 写进 hooks 的命令直接调原生二进制，不经过 bin/cc-pets：hook 在对方 CLI 的关键路径上，越轻越好。
static NSString *BridgeCommand(NSString *provider, NSString *subcommand, NSDictionary *profile) {
    NSString *identity = @"";
    if ([profile[@"id"] isKindOfClass:NSString.class]) {
        identity = [NSString stringWithFormat:@" CC_PETS_PROFILE_ID=%@ CC_PETS_PROFILE_NAME=%@ CC_PETS_PROFILE_HOME=%@",
            CCPetsShellQuote(profile[@"id"]), CCPetsShellQuote(profile[@"displayName"] ?: profile[@"slug"] ?: provider),
            CCPetsShellQuote(profile[@"home"] ?: @"")];
    }
    return [NSString stringWithFormat:@"%@%@%@ %@ bridge %@", CCBridgeHookMarker, provider, identity,
        CCPetsShellQuote(CCPetsExecutablePath()), subcommand];
}

static NSString *BridgeHookRole(id command) {
    NSMutableDictionary *env = [NSMutableDictionary dictionary];
    NSArray *args = CCPetsHookInvocation(command, env);
    if (args.count != 3 || ![@[@"hook", @"watch"] containsObject:args.lastObject]) return nil;
    if ([args[1] isEqual:@"bridge"] && CCPetsIsPetExecutable(args[0])) return args.lastObject;
    BOOL legacy = [args[1] hasSuffix:@"/scripts/bus/cli.mjs"] || [args[1] hasSuffix:@"/scripts/bridge/cli.mjs"];
    return legacy && (env[@"CC_BRIDGE_HOOK"] || env[@"CC_PETS_BUS_HOOK"]) ? args.lastObject : nil;
}

#pragma mark - JSON 配置

static CCPetsJSONObject *ReadJSONConfig(NSString *file) {
    NSString *error = nil;
    id config = CCPetsReadConfig(file, &error);
    if (!config && error) [NSException raise:@"CCBridgeConfig" format:@"%@: %@", file, error];
    if (!config) return [CCPetsJSONObject new];
    if (![config isKindOfClass:CCPetsJSONObject.class]) {
        [NSException raise:@"CCBridgeConfig" format:@"%@", LF(L(@"{file} isn't a JSON object"), @{@"file": file})];
    }
    return config;
}

static void WriteJSONConfig(NSString *file, CCPetsJSONObject *config) {
    struct stat info;
    mode_t mode = stat(file.fileSystemRepresentation, &info) == 0 ? (info.st_mode & 0777) : 0600;
    NSString *error = nil;
    if (!CCPetsWriteChangedConfig(file, config, mode, &error)) [NSException raise:@"CCBridgeConfig" format:@"%@", error];
}

// 返回是否摘掉了东西。事件下一个 group 都不剩就删掉事件，hooks 空了也删掉。
static BOOL ReconcileBridgeHooks(CCPetsJSONObject *config, CCPetsJSONObject *desired) {
    CCPetsJSONObject *hooks = config[@"hooks"];
    if (hooks && ![hooks isKindOfClass:CCPetsJSONObject.class]) [NSException raise:@"CCBridgeConfig" format:@"Expected a hooks object"];
    hooks = hooks ?: [CCPetsJSONObject new];
    NSMutableOrderedSet *events = [NSMutableOrderedSet orderedSetWithArray:hooks.keys];
    [events addObjectsFromArray:desired.keys ?: @[]];
    BOOL changed = NO;
    for (NSString *event in events) {
        id current = hooks[event];
        NSArray *wanted = desired[event] ?: @[];
        if (current && ![current isKindOfClass:NSArray.class] && !wanted.count) continue;
        NSArray *entries = CCPetsMergeHookEntries(current, wanted, YES, ^NSString *(id command) { return BridgeHookRole(command); });
        if ([CCPetsJSONStringify(entries) isEqual:CCPetsJSONStringify(current ?: @[])]) continue;
        changed = YES;
        if (entries.count) hooks[event] = entries; else [hooks removeObjectForKey:event];
    }
    if (changed) {
        if (hooks.keys.count) config[@"hooks"] = hooks; else [config removeObjectForKey:@"hooks"];
    }
    return changed;
}

static CCPetsJSONObject *Handler(NSString *command, BOOL asyncRewake, NSInteger timeout) {
    CCPetsJSONObject *handler = [CCPetsJSONObject new];
    handler[@"type"] = @"command";
    handler[@"command"] = command;
    if (asyncRewake) handler[@"asyncRewake"] = @YES;
    handler[@"timeout"] = @(timeout);
    return handler;
}

static void AddHook(CCPetsJSONObject *config, NSString *event, CCPetsJSONObject *handler, NSString *matcher) {
    if (![config[@"hooks"] isKindOfClass:CCPetsJSONObject.class]) config[@"hooks"] = [CCPetsJSONObject new];
    CCPetsJSONObject *hooks = config[@"hooks"];
    NSMutableArray *groups = [hooks[event] isKindOfClass:NSArray.class] ? [hooks[event] mutableCopy] : [NSMutableArray array];
    CCPetsJSONObject *group = [CCPetsJSONObject new];
    if (matcher) group[@"matcher"] = matcher;
    group[@"hooks"] = @[handler];
    [groups addObject:group];
    hooks[event] = groups;
}

// Claude：同步 hook 维护注册表；asyncRewake watcher 负责投递（单例锁保证同时只有一个）。
// watcher 只挂 SessionStart / Stop，不挂 UserPromptSubmit：由 UserPromptSubmit 拉起的 watcher 在回合中途
// exit 2 时，Claude Code 会显示成 "Stop hook blocking error from command UserPromptSubmit"，像报错。
// Stop 拉起的 watcher 会一直活过下一个忙碌回合，中途投递照常；watcher 超时退出后，用户开口时信箱里
// 已有的消息由同步 hook 注入。
//
// 选项决定装哪些：关闭"自动唤醒"时不装 watcher；关闭"编辑前预留拦截"时不装 PreToolUse。
// hook / watcher 自己也会再读一次选项兜底。
static void AddClaudeHooks(CCPetsJSONObject *config, NSDictionary *options, NSDictionary *profile) {
    for (NSString *event in @[@"SessionStart", @"UserPromptSubmit", @"Stop", @"SessionEnd"]) {
        AddHook(config, event, Handler(BridgeCommand(@"Claude", @"hook", profile), NO, 10), nil);
    }
    if ([options[@"editGuard"] boolValue]) {
        AddHook(config, @"PreToolUse", Handler(BridgeCommand(@"Claude", @"hook", profile), NO, 10), ClaudeEditMatcher);
    }
    if ([options[@"wake"] boolValue]) {
        for (NSString *event in @[@"SessionStart", @"Stop"]) {
            AddHook(config, event, Handler(BridgeCommand(@"Claude", @"watch", profile), YES, 3600), nil);
        }
    }
}

static void AddCodexHooks(CCPetsJSONObject *config, NSDictionary *options, NSDictionary *profile) {
    for (NSString *event in @[@"SessionStart", @"UserPromptSubmit", @"Stop", @"SessionEnd"]) {
        AddHook(config, event, Handler(BridgeCommand(@"Codex", @"hook", profile), NO, 10), nil);
    }
    if ([options[@"editGuard"] boolValue]) {
        AddHook(config, @"PreToolUse", Handler(BridgeCommand(@"Codex", @"hook", profile), NO, 10), CodexEditMatcher);
    }
}

// Claude 的工具放行写在 settings.json 的 permissions.allow 里，条目形如 mcp__cc-bridge__send_message。
// 只增删这个前缀下的条目（含旧名 cc-pets-bus），不碰用户其他的放行规则。返回是否有变化。
static BOOL ApplyClaudeAllow(CCPetsJSONObject *config, NSArray *tools, NSArray *oldTools) {
    NSMutableArray *wanted = [NSMutableArray array];
    NSMutableSet *revoke = [NSMutableSet set];
    for (NSString *tool in tools) [wanted addObject:[@"mcp__cc-bridge__" stringByAppendingString:tool]];
    for (NSString *tool in oldTools) {
        [revoke addObject:[@"mcp__cc-bridge__" stringByAppendingString:tool]];
        [revoke addObject:[@"mcp__cc-pets-bus__" stringByAppendingString:tool]];
    }
    return CCPetsMergeAllows(config, wanted, revoke);
}

#pragma mark - MCP

NSString *CCBridgeDescribeCodexQueue(NSDictionary *probe) {
    NSString *version = [probe[@"version"] isKindOfClass:NSString.class]
        ? LF(L(@" ({version})"), @{@"version": probe[@"version"]}) : @"";
    NSString *status = probe[@"status"];
    if ([status isEqualToString:@"supported"]) return nil;
    if ([status isEqualToString:@"unsupported"]) {
        return [LF(L(@"This Codex{version} doesn't support codex queue, so messages to Codex can't wake it; they go to its inbox "),
            @{@"version": version}) stringByAppendingString:
            L(@"and are picked up via check_inbox or with the next input. Upgrading Codex enables wake-up without re-enabling CC Bridge.")];
    }
    if ([status isEqualToString:@"missing"]) {
        return L(@"codex executable not found, so messages to Codex can only go to its inbox; set CODEX_REAL_BIN and run cc-pets bridge enable.");
    }
    return L(@"Couldn't tell whether Codex supports codex queue; failed deliveries fall back to the inbox.");
}

#pragma mark - 安装 / 卸载

// Claude's per-project disable list cannot suspend a user registration across all projects.
// Park a customized registration privately beside the profile and restore it on re-enable.
static NSString *ClaudeGlobalConfig(NSString *home) {
    NSString *official = CCPetsRealPath([CCPetsHomeDirectory() stringByAppendingPathComponent:@".claude"]);
    NSString *directory = official && [CCPetsRealPath(home) isEqual:official] ? CCPetsHomeDirectory() : home;
    return [directory stringByAppendingPathComponent:@".claude.json"];
}

static BOOL ClaudeBridgeTransport(id server) {
    return [server isKindOfClass:CCPetsJSONObject.class] && !server[@"url"] &&
        (!server[@"type"] || [server[@"type"] isEqual:@"stdio"]) && CCPetsIsBridgeTransport(server[@"command"], server[@"args"]);
}

static BOOL ClaudeAllowsBelongToBridge(NSString *home) {
    id servers = ReadJSONConfig(ClaudeGlobalConfig(home))[@"mcpServers"];
    if (servers && ![servers isKindOfClass:CCPetsJSONObject.class]) return NO;
    id active = servers[CCBridgeMCPName];
    return !active || ClaudeBridgeTransport(active);
}

static CCPetsJSONObject *ClaudeCustomFields(CCPetsJSONObject *server) {
    CCPetsJSONObject *custom = [server copy];
    [custom removeObjectForKey:@"command"];
    [custom removeObjectForKey:@"type"];
    NSArray *args = server[@"args"];
    if (args.count > 2) custom[@"args"] = [args subarrayWithRange:NSMakeRange(2, args.count - 2)];
    else [custom removeObjectForKey:@"args"];
    CCPetsJSONObject *environment = [server[@"env"] copy];
    if (environment && ![environment isKindOfClass:CCPetsJSONObject.class])
        [NSException raise:@"CCBridgeConfig" format:@"Invalid Claude MCP environment"];
    [environment removeObjectForKey:@"CODEX_REAL_BIN"];
    if (environment.keys.count) custom[@"env"] = environment; else [custom removeObjectForKey:@"env"];
    return custom;
}

static void ReconcileClaudeMCP(NSString *home, BOOL install) {
    NSString *file = ClaudeGlobalConfig(home);
    NSString *backup = [home stringByAppendingPathComponent:@".cc-pets-paused-mcp.json"];
    CCBridgeWithLock([@"claude-mcp-" stringByAppendingString:CCBridgeSHA1Hex(file)], ^id {
        CCPetsJSONObject *doc = ReadJSONConfig(file), *servers = doc[@"mcpServers"];
        if (servers && ![servers isKindOfClass:CCPetsJSONObject.class]) [NSException raise:@"CCBridgeConfig" format:@"Invalid mcpServers in %@", file];
        servers = servers ?: [CCPetsJSONObject new];
        CCPetsJSONObject *parked = ReadJSONConfig(backup);
        NSString *restored = nil;
        for (NSString *name in [MCPNames() reverseObjectEnumerator]) {
            BOOL enable = install && [name isEqual:CCBridgeMCPName];
            NSString *savedName = parked[name] ? name : @"cc-pets-bus";
            CCPetsJSONObject *saved = enable ? parked[savedName] : nil;
            CCPetsJSONObject *active = servers[name], *server = active ?: saved;
            if (!server && !enable) continue;
            if (server && !ClaudeBridgeTransport(server)) {
                if (enable) [NSException raise:@"CCBridgeConfig" format:@"MCP %@ already has another transport in %@", name, file];
                continue;
            }
            CCPetsJSONObject *previous = enable ? saved : parked[name];
            if (previous && active && (!ClaudeBridgeTransport(previous) ||
                ![CCPetsJSONStringify(ClaudeCustomFields(active)) isEqual:CCPetsJSONStringify(ClaudeCustomFields(previous))])) {
                [NSException raise:@"CCBridgeConfig" format:@"Conflicting active and saved MCP %@ in %@", name, backup];
            }
            if (!server) server = [CCPetsJSONObject new];
            CCPetsJSONObject *env = server[@"env"];
            if (env && ![env isKindOfClass:CCPetsJSONObject.class]) [NSException raise:@"CCBridgeConfig" format:@"Invalid MCP environment in %@", file];
            if (enable) {
                if (saved) restored = savedName;
                server[@"command"] = CCPetsExecutablePath();
                NSArray *args = server[@"args"];
                server[@"args"] = args.count > 2 ? [@[@"bridge",@"mcp"] arrayByAddingObjectsFromArray:
                    [args subarrayWithRange:NSMakeRange(2, args.count-2)]] : @[@"bridge",@"mcp"];
                NSString *codex = CCPetsFindRealExecutable(@"codex", @"CODEX_REAL_BIN");
                env = env ?: [CCPetsJSONObject new];
                if (codex) env[@"CODEX_REAL_BIN"] = codex; else [env removeObjectForKey:@"CODEX_REAL_BIN"];
                if (env.keys.count || server[@"env"]) server[@"env"] = env;
                if (!server[@"type"]) server[@"type"] = @"stdio";
                servers[name] = server;
            } else {
                if (ClaudeCustomFields(server).keys.count) {
                    parked[name] = server;
                    NSString *error = nil;
                    if (!CCPetsWriteChangedConfig(backup, parked, 0600, &error)) [NSException raise:@"CCBridgeConfig" format:@"%@", error];
                    parked = ReadJSONConfig(backup);
                }
                [servers removeObjectForKey:name];
            }
        }
        if (servers.keys.count) doc[@"mcpServers"] = servers; else [doc removeObjectForKey:@"mcpServers"];
        if (doc.sourceData || servers.keys.count) WriteJSONConfig(file, doc);
        if (restored) {
            [parked removeObjectForKey:restored];
            if (parked.keys.count) WriteJSONConfig(backup, parked);
            else if (unlink(backup.fileSystemRepresentation) && errno != ENOENT)
                [NSException raise:@"CCBridgeConfig" format:@"Cannot remove %@", backup];
        }
        return nil;
    });
}

static BOOL RemoveJSONHooks(NSString *file, NSArray *oldTools);

NSArray<NSString *> *CCBridgeInstallForProfile(NSDictionary *profile, NSDictionary *rawOptions, BOOL registerMcp) {
    NSString *provider = [profile[@"provider"] isKindOfClass:NSString.class] ? profile[@"provider"] : @"";
    NSString *home = [profile[@"home"] isKindOfClass:NSString.class] ? profile[@"home"] : @"";
    if ([provider isEqual:@"antigravity"]) {
        NSDictionary *options = CCBridgeNormalizeOptions(rawOptions);
        BOOL appEnabled = [options[@"antigravityApp"] boolValue];
        // The App's MCP and Sidecar must run the same Bridge build, including when upgrading
        // an existing CLI-only MCP registration from a different installation.
        BOOL ensureMcp = appEnabled && CCBridgeShouldTouchMCP() && CCPetsProfileIsOfficialDefault(profile);
        NSArray *report = CCPetsInstallAntigravityBridge(profile, options[@"antigravityAllow"], registerMcp || ensureMcp);
        CCPetsConfigureAntigravityBridgeTitle(profile, [options[@"tabTitle"] boolValue]);
        return [report arrayByAddingObjectsFromArray:CCPetsConfigureAntigravityAppSidecar(profile, appEnabled)];
    }
    if (home.length == 0 || (![provider isEqualToString:@"claude"] && ![provider isEqualToString:@"codex"])) {
        [NSException raise:@"CCBridgeConfig" format:@"Invalid Agent profile."];
    }
    NSDictionary *options = CCBridgeNormalizeOptions(rawOptions);
    NSMutableArray<NSString *> *report = [NSMutableArray array];
    [NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:nil];
    if ([provider isEqualToString:@"claude"]) {
        if (!ClaudeAllowsBelongToBridge(home)) [NSException raise:@"CCBridgeConfig" format:@"MCP cc-bridge already has another transport in %@", ClaudeGlobalConfig(home)];
        if (registerMcp) ReconcileClaudeMCP(home, YES);
        NSString *settingsPath = [home stringByAppendingPathComponent:@"settings.json"];
        CCPetsJSONObject *config = ReadJSONConfig(settingsPath);
        CCPetsJSONObject *desired = [CCPetsJSONObject new];
        AddClaudeHooks(desired, options, profile);
        ReconcileBridgeHooks(config, desired[@"hooks"]);
        ApplyClaudeAllow(config, options[@"claudeAllow"], CCBridgeOptions()[@"claudeAllow"]);
        WriteJSONConfig(settingsPath, config);
        [report addObject:LF(L(@"Claude Code hooks written to {path}"), @{@"path": settingsPath})];
        if (registerMcp) {
            [report addObject:LF(L(@"Claude Code MCP registered: {MCP_NAME} (on first use, Claude asks according to your permission settings)"), @{@"MCP_NAME": CCBridgeMCPName})];
        }
        return report;
    }

    NSString *hooksPath = [home stringByAppendingPathComponent:@"hooks.json"];
    CCPetsJSONObject *config = ReadJSONConfig(hooksPath);
    CCPetsJSONObject *desired = [CCPetsJSONObject new];
    AddCodexHooks(desired, options, profile);
    ReconcileBridgeHooks(config, desired[@"hooks"]);
    WriteJSONConfig(hooksPath, config);
    [report addObject:LF(L(@"Codex hooks written to {path}. Next time you start Codex, run /hooks and trust the cc-pets bridge hooks."), @{@"path": hooksPath})];
    NSString *codex = CCPetsFindRealExecutable(@"codex", @"CODEX_REAL_BIN");
    CCBridgeReconcileCodexConfig(home, registerMcp ? CCPetsCodexRegister : CCPetsCodexConfigureApprovals, options[@"codexApprove"], codex);
    if (registerMcp) {
        [report addObject:LF(L(@"Codex MCP registered: {MCP_NAME}"), @{@"MCP_NAME": CCBridgeMCPName})];
        if ([options[@"wake"] boolValue]) {
            NSString *notice = CCBridgeDescribeCodexQueue(CCBridgeProbeCodexQueue(codex));
            if (notice) [report addObject:notice];
        }
    }
    return report;
}

NSArray<NSString *> *CCBridgeUninstallForProfile(NSDictionary *profile, BOOL unregisterMcp, NSDictionary *oldOptions) {
    NSString *provider = [profile[@"provider"] isKindOfClass:NSString.class] ? profile[@"provider"] : @"";
    if ([provider isEqual:@"antigravity"]) {
        CCPetsConfigureAntigravityBridgeTitle(profile, NO);
        NSArray *sidecar = CCPetsConfigureAntigravityAppSidecar(profile, NO);
        return [sidecar arrayByAddingObjectsFromArray:CCPetsRemoveAntigravityBridge(profile, unregisterMcp, oldOptions[@"antigravityAllow"])];
    }
    NSString *home = [profile[@"home"] isKindOfClass:NSString.class] ? profile[@"home"] : @"";
    NSMutableArray<NSString *> *report = [NSMutableArray array];
    if ([provider isEqualToString:@"claude"]) {
        if (RemoveJSONHooks([home stringByAppendingPathComponent:@"settings.json"], ClaudeAllowsBelongToBridge(home) ? oldOptions[@"claudeAllow"] : nil)) {
            [report addObject:L(@"Removed the cc-bridge hooks and tool permissions from Claude Code.")];
        }
        if (unregisterMcp) ReconcileClaudeMCP(home, NO);
    } else if ([provider isEqualToString:@"codex"]) {
        if (RemoveJSONHooks([home stringByAppendingPathComponent:@"hooks.json"], nil)) {
            [report addObject:L(@"Removed the cc-bridge hooks from Codex.")];
        }
        if ([NSFileManager.defaultManager fileExistsAtPath:[home stringByAppendingPathComponent:@"config.toml"]])
            CCBridgeReconcileCodexConfig(home, unregisterMcp ? CCPetsCodexUnregister : CCPetsCodexConfigureApprovals, @[], nil);
    }
    return report;
}

// 文件不存在、或里面本来就没有我们的东西时不改写——用户的文件不该因为一次卸载被重排格式。
static BOOL RemoveJSONHooks(NSString *file, NSArray *oldTools) {
    if (![NSFileManager.defaultManager fileExistsAtPath:file]) return NO;
    CCPetsJSONObject *config = ReadJSONConfig(file);
    BOOL changed = ReconcileBridgeHooks(config, nil);
    if (oldTools && ApplyClaudeAllow(config, @[], oldTools)) changed = YES;
    if (!changed) return NO;
    WriteJSONConfig(file, config);
    return YES;
}
