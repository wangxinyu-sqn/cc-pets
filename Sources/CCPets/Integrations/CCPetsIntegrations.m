#import "CCPetsL10n.h"
#import "CCPetsIntegrations.h"
#import "CCPetsAntigravityConfig.h"
#import "CCPetsJSON.h"
#import "CCPetsHookMerge.h"
#import "CCPetsProfiles.h"
#import "CCPetsCLISupport.h"
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

NSString *const CCPetsClaudeHookMarker = @"CC_PETS_CLAUDE_AGENT_HOOK=1";
NSString *const CCPetsLegacyClaudeHookMarker = @"CLAUDE_PET_AGENT_HOOK=1";
NSString *const CCPetsCodexHookMarker = @"CC_PETS_CODEX_AGENT_HOOK=1";
NSString *const CCPetsLegacyCodexHookMarker = @"CODEX_PET_AGENT_HOOK=1";
NSString *const CCPetsStatusLineMarker = @"CC_PETS_CLAUDE_STATUS_LINE=1";
NSString *const CCPetsLegacyStatusLineMarker = @"CLAUDE_PET_STATUS_LINE=1";
NSString *const CCPetsStatusLineStartMarker = @"# >>> cc-pets-statusline >>>";
NSString *const CCPetsStatusLineEndMarker = @"# <<< cc-pets-statusline <<<";
NSString *const CCPetsCreatedStatusLineMarker = @"# CC Pets created this status line script";

// 安装用：读不到文件算空配置，读到了却解析失败要报错退出，直接覆盖会把用户的配置整个冲掉。
static CCPetsJSONObject *LoadConfig(NSString *path, NSString **errorMessage) {
    NSString *message = nil;
    id config = CCPetsReadConfig(path, &message);
    if (!config && message) {
        if (errorMessage) *errorMessage = message;
        return nil;
    }
    if (config && (![config isKindOfClass:CCPetsJSONObject.class] ||
        (config[@"hooks"] && ![config[@"hooks"] isKindOfClass:CCPetsJSONObject.class]))) {
        if (errorMessage) *errorMessage = L(@"Expected a JSON object.");
        return nil;
    }
    config = config ?: [CCPetsJSONObject new];
    if (!config[@"hooks"]) config[@"hooks"] = [CCPetsJSONObject new];
    return config;
}

// 从源码目录安装时指向 .build/release，从 App 里修复时指向包内的程序；两种都要认，
// 否则另一种写进去的条目永远摘不掉，每装一次就多一份。
BOOL CCPetsIsManagedHookCommand(id value, NSString *marker, NSString *executable) {
    NSMutableDictionary *env = [NSMutableDictionary dictionary];
    NSArray *args = CCPetsHookInvocation(value, env);
    if (args.count != 2 || ![args.lastObject isEqual:@"--hook"] || ![[args[0] lastPathComponent] isEqual:executable]) return NO;
    NSArray *pair = [marker componentsSeparatedByString:@"="];
    if ([env[pair.firstObject] isEqual:pair.lastObject]) return YES;
    return [executable isEqual:@"cc-pets"] && !env[@"CC_PETS_CLAUDE_AGENT_HOOK"] &&
        !env[@"CC_PETS_CODEX_AGENT_HOOK"] && !env[@"CLAUDE_PET_AGENT_HOOK"] && !env[@"CODEX_PET_AGENT_HOOK"];
}

static BOOL ReconcilePetHooks(CCPetsJSONObject *config, NSArray *signatures, NSString *command, NSArray *events) {
    CCPetsJSONObject *hooks = config[@"hooks"];
    if (![hooks isKindOfClass:CCPetsJSONObject.class]) return NO;
    NSMutableOrderedSet *all = [NSMutableOrderedSet orderedSetWithArray:hooks.keys];
    [all addObjectsFromArray:events];
    BOOL changed = NO;
    for (NSString *event in all) {
        NSArray *desired = [events containsObject:event] ? @[@{@"hooks": @[@{@"type": @"command", @"command":command, @"timeout":@3}]}] : @[];
        id current = hooks[event];
        if (current && ![current isKindOfClass:NSArray.class] && !desired.count) continue;
        NSArray *entries = CCPetsMergeHookEntries(current, desired, YES, ^NSString *(id candidate) {
            for (NSArray *signature in signatures)
                if (CCPetsIsManagedHookCommand(candidate, signature[0], signature[1])) return @"pet";
            return nil;
        });
        if ([CCPetsJSONStringify(entries) isEqual:CCPetsJSONStringify(current ?: @[])]) continue;
        changed = YES;
        if (entries.count) hooks[event] = entries; else [hooks removeObjectForKey:event];
    }
    if (changed && !hooks.keys.count) [config removeObjectForKey:@"hooks"];
    return changed;
}

#pragma mark - Claude status line

static NSString *FirstCapture(NSString *pattern, NSRegularExpressionOptions options, NSString *text,
                              NSInteger group, NSTextCheckingResult **matchOut) {
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern options:options error:nil];
    NSTextCheckingResult *match = [expression firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (matchOut) *matchOut = match;
    if (!match) return nil;
    NSRange range = [match rangeAtIndex:group];
    return range.location == NSNotFound ? @"" : [text substringWithRange:range];
}

static NSString *Unquote(NSString *value) {
    NSString *inner = FirstCapture(@"\\A(['\"])(.*)\\1\\z", NSRegularExpressionDotMatchesLineSeparators, value, 2, NULL);
    return inner ?: value;
}

static NSString *Trim(NSString *value) {
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// 能就地插 prelude 的 status line 命令：一个脚本的绝对路径（可带 `~/`），或者
// `bash ~/.claude/statusline-command.sh` 这类带解释器前缀的写法。带 -c 的不算：
// `-c` 后面是命令串而不是脚本路径。
//
// 返回 nil 表示无法注入；否则 script 是展开后用于读写的绝对路径，target 保留用户原来的写法
// （含 `~/`，官方默认就是 `~/.claude/statusline.sh`，不能展开后写回配置），
// interpreter / flags 表示原命令是否带解释器前缀、前缀上是否带选项。
NSDictionary<NSString *, id> *CCPetsParseStatusLineCommand(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *candidate = Unquote(Trim(value));
    BOOL hasInterpreter = NO;
    NSString *flags = @"";
    NSTextCheckingResult *match = nil;
    FirstCapture(@"\\A(?:/usr/bin/env\\s+)?(?:[^\\s'\"]*/)?(?:ba|z|k|da)?sh((?:\\s+-[A-Za-z]+)*)\\s+(.+)\\z",
        NSRegularExpressionDotMatchesLineSeparators, candidate, 0, &match);
    if (match) {
        NSString *matchedFlags = [candidate substringWithRange:[match rangeAtIndex:1]];
        BOOL runsCommandString = FirstCapture(@"-[A-Za-z]*c(?=\\s|\\z)", 0, matchedFlags, 0, NULL) != nil;
        if (!runsCommandString) {
            hasInterpreter = YES;
            flags = Trim(matchedFlags);
            candidate = Unquote(Trim([candidate substringWithRange:[match rangeAtIndex:2]]));
        }
    }
    NSString *resolved = candidate;
    if ([resolved hasPrefix:@"~/"]) {
        resolved = [CCPetsHomeDirectory() stringByAppendingPathComponent:[resolved substringFromIndex:2]];
    }
    if (![resolved hasPrefix:@"/"]) return nil;
    if (FirstCapture(@"[\\s;&|<>`$()]", 0, resolved, 0, NULL)) return nil;
    return @{@"script": CCPetsResolvePath(resolved), @"target": candidate,
             @"interpreter": @(hasInterpreter), @"flags": @(flags.length > 0)};
}

static NSString *ReplacePattern(NSString *text, NSString *pattern, NSString *replacement) {
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    return [expression stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length)
        withTemplate:[NSRegularExpression escapedTemplateForString:replacement]];
}

static NSString *RemoveStatusLineBlock(NSString *text) {
    NSString *block = [NSString stringWithFormat:@"(?:\\A|\\n)%@\\n[\\s\\S]*?\\n%@(?=\\n|\\z)",
        [NSRegularExpression escapedPatternForString:CCPetsStatusLineStartMarker],
        [NSRegularExpression escapedPatternForString:CCPetsStatusLineEndMarker]];
    return ReplacePattern(text, block, @"");
}

// prelude 把 Claude 喂给 status line 的 JSON 先存一份，交给 cc-pets --claude-usage 记录额度，
// 再把 stdin 换回这份内容，原脚本照常读到完整输入。
static NSString *StatusLinePrelude(NSString *binary) {
    NSString *quoted = CCPetsShellQuote(binary);
    return [@[
        CCPetsStatusLineStartMarker,
        @"CC_PETS_STATUSLINE_INPUT=\"$(/usr/bin/mktemp \"${TMPDIR:-/tmp}/cc-pets-statusline.XXXXXX\")\" || exit 1",
        @"/bin/cat > \"${CC_PETS_STATUSLINE_INPUT}\"",
        [NSString stringWithFormat:@"if [ -x %@ ]; then", quoted],
        [NSString stringWithFormat:@"  %@ --claude-usage < \"${CC_PETS_STATUSLINE_INPUT}\" >/dev/null 2>&1 || true", quoted],
        @"fi",
        @"exec 0< \"${CC_PETS_STATUSLINE_INPUT}\"",
        @"/bin/rm -f \"${CC_PETS_STATUSLINE_INPUT}\"",
        @"unset CC_PETS_STATUSLINE_INPUT",
        CCPetsStatusLineEndMarker
    ] componentsJoinedByString:@"\n"];
}

// 返回是否插入成功；hadShebang 记录原脚本有没有 shebang，决定能不能去掉 command 里的解释器前缀。
static BOOL InstallStatusLinePrelude(NSString *scriptPath, NSString *binary, BOOL createIfMissing) {
    NSString *original = nil;
    mode_t mode = 0700;
    struct stat info;
    if (stat(scriptPath.fileSystemRepresentation, &info) == 0) {
        if (!S_ISREG(info.st_mode)) return NO;
        NSData *data = [NSData dataWithContentsOfFile:scriptPath];
        original = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (!original) return NO;
        mode = info.st_mode & 07777;
    } else if (createIfMissing) {
        [NSFileManager.defaultManager createDirectoryAtPath:scriptPath.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:nil];
        original = [NSString stringWithFormat:@"#!/bin/zsh\n%@\n", CCPetsCreatedStatusLineMarker];
    } else {
        return NO;
    }

    NSString *cleaned = RemoveStatusLineBlock(original);
    BOOL hasShebang = [cleaned hasPrefix:@"#!"];
    NSRange newline = [cleaned rangeOfString:@"\n"];
    NSString *shebang = @"#!/bin/zsh";
    NSString *body = cleaned;
    if (hasShebang) {
        shebang = newline.location == NSNotFound ? cleaned : [cleaned substringToIndex:newline.location];
        body = newline.location == NSNotFound ? @"" : [cleaned substringFromIndex:newline.location + 1];
    }
    NSString *updated = [NSString stringWithFormat:@"%@\n%@\n%@", shebang, StatusLinePrelude(binary), body];
    if (![updated isEqual:original] && !CCPetsWriteFileAtomically(scriptPath, updated, mode | 0100, NULL)) return NO;
    if ([updated isEqual:original] && !(mode & 0100) && chmod(scriptPath.fileSystemRepresentation, mode | 0100) != 0) return NO;
    return YES;
}

// 包装器形态的 command 末尾是 base64 编码的原命令；Buffer.from 容忍缺失的填充，这里补齐后再解。
static NSString *DecodeWrappedStatusLine(NSString *command) {
    NSString *encoded = FirstCapture(@"'([A-Za-z0-9+/=]*)'\\s*\\z", 0, command, 1, NULL);
    if (!encoded) return @"";
    encoded = [encoded stringByReplacingOccurrencesOfString:@"=" withString:@""];
    while (encoded.length % 4 != 0) encoded = [encoded stringByAppendingString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
    if (!data) return @"";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?:
        [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
}

BOOL CCPetsIsManagedStatusLine(NSString *command, NSString *marker) {
    return [command hasPrefix:[marker stringByAppendingString:@" "]] &&
        FirstCapture(@"/bin/claude-statusline-with-pet' '[A-Za-z0-9+/=]*'\\z", 0, command, 0, NULL) != nil;
}

#pragma mark - 安装入口

NSArray<NSString *> *CCPetsClaudeIntegrationFilesAtHome(NSString *claudeHome) {
    NSString *settings = [claudeHome stringByAppendingPathComponent:@"settings.json"];
    CCPetsJSONObject *config = LoadConfig(settings, NULL);
    CCPetsJSONObject *statusLine = config[@"statusLine"];
    NSString *command = [statusLine isKindOfClass:CCPetsJSONObject.class] &&
        [statusLine[@"command"] isKindOfClass:NSString.class] ? statusLine[@"command"] : @"";
    if (CCPetsIsManagedStatusLine(command, CCPetsStatusLineMarker) ||
        CCPetsIsManagedStatusLine(command, CCPetsLegacyStatusLineMarker)) command = DecodeWrappedStatusLine(command);
    if (command.length == 0) command = [claudeHome stringByAppendingPathComponent:@"statusline-command.sh"];
    NSString *script = CCPetsParseStatusLineCommand(command)[@"script"];
    return script.length > 0 ? @[settings, script] : @[settings];
}

int InstallClaudeHooksAtHome(NSString *binary, NSString *claudeHome) {
    if (binary.length == 0) {
        CCPetsPrintLine(stderr, L(@"Usage: cc-pets --install-claude-hooks /absolute/path/to/cc-pets"));
        return 2;
    }
    binary = CCPetsResolvePath(binary);
    claudeHome = CCPetsResolvePath(claudeHome);
    NSString *settingsPath = [claudeHome stringByAppendingPathComponent:@"settings.json"];
    [NSFileManager.defaultManager createDirectoryAtPath:claudeHome withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *errorMessage = nil;
    CCPetsJSONObject *config = LoadConfig(settingsPath, &errorMessage);
    if (!config) {
        CCPetsPrintLine(stderr, [NSString stringWithFormat:L(@"Can't parse %1$@: %2$@"), settingsPath, errorMessage]);
        return 1;
    }

    NSDictionary *registered = CCPetsProfileForHome(CCPetsProfileProviderClaude, claudeHome);
    NSString *profileID = registered[@"id"] ?: CCPetsProfileID(CCPetsProfileProviderClaude, claudeHome);
    NSString *profileName = registered[@"displayName"] ?: CCPetsProfileDefaultDisplayName(CCPetsProfileProviderClaude, claudeHome);
    NSString *command = [NSString stringWithFormat:@"%@ CC_PETS_PROFILE_ID=%@ CC_PETS_PROFILE_NAME=%@ CC_PETS_PROFILE_HOME=%@ %@ --hook",
        CCPetsClaudeHookMarker, CCPetsShellQuote(profileID), CCPetsShellQuote(profileName),
        CCPetsShellQuote(claudeHome), CCPetsShellQuote(binary)];
    ReconcilePetHooks(config, @[@[CCPetsClaudeHookMarker, @"cc-pets"], @[CCPetsLegacyClaudeHookMarker, @"codex-pet"]], command, @[
        @"SessionStart", @"UserPromptSubmit", @"PreToolUse", @"PermissionRequest", @"PostToolUse",
        @"PostToolUseFailure", @"Notification", @"SubagentStart", @"SubagentStop", @"TaskCreated",
        @"TaskCompleted", @"Stop", @"StopFailure", @"SessionEnd"
    ]);

    // 找出用户原本的 status line 命令。已经被我们包装过的，从 base64 里还原出原命令。
    NSString *originalCommand = @"";
    CCPetsJSONObject *statusLine = config[@"statusLine"];
    if ([statusLine isKindOfClass:CCPetsJSONObject.class]) {
        NSString *current = [statusLine[@"command"] isKindOfClass:NSString.class] ? statusLine[@"command"] : @"";
        if (CCPetsIsManagedStatusLine(current, CCPetsStatusLineMarker) || CCPetsIsManagedStatusLine(current, CCPetsLegacyStatusLineMarker)) {
            originalCommand = DecodeWrappedStatusLine(current);
        } else {
            originalCommand = current;
        }
    } else {
        statusLine = [CCPetsJSONObject new];
        statusLine[@"type"] = @"command";
    }
    BOOL createdStatusLine = NO;
    if (originalCommand.length == 0) {
        originalCommand = [claudeHome stringByAppendingPathComponent:@"statusline-command.sh"];
        createdStatusLine = YES;
    }
    statusLine = [statusLine copy];
    statusLine[@"type"] = @"command";
    statusLine[@"command"] = originalCommand;
    config[@"statusLine"] = statusLine;

    NSDictionary<NSString *, id> *parsed = CCPetsParseStatusLineCommand(originalCommand);
    BOOL statusLineInstalled = parsed &&
        InstallStatusLinePrelude(parsed[@"script"], binary, createdStatusLine);

    // 解析不出脚本路径的命令（`bun x ccstatusline`、`npx …`、带管道或 `sh -c` 的命令行）没法就地插
    // prelude，而 status line 是 Claude 额度的唯一来源。回退到包装器：command 换成
    // claude-statusline-with-pet + base64 编码的原命令，它先把 stdin 喂给 cc-pets --claude-usage，
    // 再原样转发给原命令执行。卸载侧认这个形态，能原样还原。
    NSString *packageDirectory = binary.stringByDeletingLastPathComponent
        .stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    NSString *wrapper = [packageDirectory stringByAppendingPathComponent:@"bin/claude-statusline-with-pet"];
    BOOL statusLineWrapped = NO;
    struct stat wrapperInfo;
    if (!statusLineInstalled && stat(wrapper.fileSystemRepresentation, &wrapperInfo) == 0) {
        // 包内文件不可写（只读安装）时权限位通常本来就是对的，失败不影响。
        chmod(wrapper.fileSystemRepresentation, (wrapperInfo.st_mode & 07777) | 0100);
        NSString *encoded = [[originalCommand dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
        statusLine[@"type"] = @"command";
        statusLine[@"command"] = [NSString stringWithFormat:@"%@ %@ '%@'", CCPetsStatusLineMarker, CCPetsShellQuote(wrapper), encoded];
        statusLineWrapped = YES;
    }

    if (!statusLineInstalled && !statusLineWrapped) {
        CCPetsPrintLine(stderr, [NSString stringWithFormat:L(@"Claude status line not hooked up: %@"), originalCommand]);
        CCPetsPrintLine(stderr, L(@"Claude hooks still work, but the pet can't show Claude quota % (token usage is unaffected)."));
    }

    if (!CCPetsWriteChangedConfig(settingsPath, config, 0600, &errorMessage)) {
        CCPetsPrintLine(stderr, errorMessage);
        return 1;
    }
    CCPetsPrintLine(stdout, [NSString stringWithFormat:L(@"Claude Code hooks installed in %@"), settingsPath]);
    if (statusLineInstalled) {
        CCPetsPrintLine(stdout, L(@"Claude quota tracking added to your existing status line. The pet shows quota after the first API response."));
    } else if (statusLineWrapped) {
        CCPetsPrintLine(stdout, L(@"Claude quota tracking added to the status line through a wrapper; your original command still runs. The pet shows quota after the first API response."));
    }
    return 0;
}

int InstallClaudeHooks(NSString *binary) {
    if (!CCPetsClaudeCLIInstalled()) {
        CCPetsPrintLine(stdout, L(@"Claude Code CLI not detected; skipping Claude hooks and status line setup."));
        CCPetsPrintLine(stdout, L(@"If you install Claude Code later, run cc-pets install to set it up."));
        return 0;
    }
    return InstallClaudeHooksAtHome(binary, CCPetsClaudeHome());
}

int InstallCodexHooksAtHome(NSString *binary, NSString *codexHome) {
    if (binary.length == 0) {
        CCPetsPrintLine(stderr, L(@"Usage: cc-pets --install-codex-hooks /absolute/path/to/cc-pets"));
        return 2;
    }
    binary = CCPetsResolvePath(binary);
    codexHome = CCPetsResolvePath(codexHome);
    NSString *hooksPath = [codexHome stringByAppendingPathComponent:@"hooks.json"];
    [NSFileManager.defaultManager createDirectoryAtPath:codexHome withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *errorMessage = nil;
    CCPetsJSONObject *config = LoadConfig(hooksPath, &errorMessage);
    if (!config) {
        CCPetsPrintLine(stderr, [NSString stringWithFormat:L(@"Can't parse %1$@: %2$@"), hooksPath, errorMessage]);
        return 1;
    }

    NSDictionary *registered = CCPetsProfileForHome(CCPetsProfileProviderCodex, codexHome);
    NSString *profileID = registered[@"id"] ?: CCPetsProfileID(CCPetsProfileProviderCodex, codexHome);
    NSString *profileName = registered[@"displayName"] ?: CCPetsProfileDefaultDisplayName(CCPetsProfileProviderCodex, codexHome);
    NSString *command = [NSString stringWithFormat:@"%@ CC_PETS_PROFILE_ID=%@ CC_PETS_PROFILE_NAME=%@ CC_PETS_PROFILE_HOME=%@ %@ --hook",
        CCPetsCodexHookMarker, CCPetsShellQuote(profileID), CCPetsShellQuote(profileName),
        CCPetsShellQuote(codexHome), CCPetsShellQuote(binary)];
    ReconcilePetHooks(config, @[@[CCPetsCodexHookMarker, @"cc-pets"], @[CCPetsLegacyCodexHookMarker, @"codex-pet"]], command, @[
        @"SessionStart", @"UserPromptSubmit", @"PreToolUse", @"PermissionRequest", @"PostToolUse",
        @"SubagentStart", @"SubagentStop", @"Stop", @"SessionEnd"
    ]);

    if (!CCPetsWriteChangedConfig(hooksPath, config, 0600, &errorMessage)) {
        CCPetsPrintLine(stderr, errorMessage);
        return 1;
    }
    CCPetsPrintLine(stdout, [NSString stringWithFormat:L(@"Codex agent hooks installed in %@"), hooksPath]);
    CCPetsPrintLine(stdout, L(@"Next time you start Codex, run /hooks and trust the CC Pets hooks."));
    return 0;
}

int InstallCodexHooks(NSString *binary) {
    if (!CCPetsCodexCLIInstalled()) {
        CCPetsPrintLine(stdout, L(@"Codex CLI not detected; skipping Codex hooks."));
        CCPetsPrintLine(stdout, L(@"If you install Codex later, run cc-pets install to set it up."));
        return 0;
    }
    return InstallCodexHooksAtHome(binary, CCPetsCodexHome());
}

#pragma mark - 卸载入口

NSString *const CCPetsShimStartMarker = @"# >>> cc-pets-shims >>>";
NSString *const CCPetsShimEndMarker = @"# <<< cc-pets-shims <<<";

// 去掉脚本里的 prelude。脚本本来就是安装器新建的（去掉之后只剩创建标记），直接删掉并通过
// created 告诉调用方，status line 配置也要一起删。返回脚本是否有变化。
static BOOL RemoveStatusLinePrelude(NSString *scriptPath, BOOL keepScript, BOOL *created) {
    *created = NO;
    struct stat info;
    if (scriptPath.length == 0 || stat(scriptPath.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode)) return NO;
    NSData *data = [NSData dataWithContentsOfFile:scriptPath];
    NSString *original = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!original) return NO;
    NSString *updated = RemoveStatusLineBlock(original);
    if ([updated isEqualToString:original]) return NO;
    if ([updated isEqualToString:[NSString stringWithFormat:@"#!/bin/zsh\n%@\n", CCPetsCreatedStatusLineMarker]]) {
        if (keepScript) return CCPetsWriteFileAtomically(scriptPath, @"#!/bin/zsh\n", info.st_mode & 07777, NULL);
        *created = unlink(scriptPath.fileSystemRepresentation) == 0;
        return *created;
    }
    return CCPetsWriteFileAtomically(scriptPath, updated, info.st_mode & 07777, NULL);
}

// 读改写一份 JSON 配置。文件不存在、顶层不是对象或 updater 没改动时都不写。
// 解析失败只报错不写，*failed 置位，其余集成照常清理。
static BOOL UpdateConfig(NSString *path, BOOL *failed, BOOL (^updater)(CCPetsJSONObject *config)) {
    NSString *errorMessage = nil;
    id config = CCPetsReadConfig(path, &errorMessage);
    if (!config) {
        if (errorMessage) {
            CCPetsPrintLine(stderr, [NSString stringWithFormat:L(@"Can't parse %1$@, left unchanged: %2$@"), path, errorMessage]);
            *failed = YES;
        }
        return NO;
    }
    if (![config isKindOfClass:CCPetsJSONObject.class] || !updater(config)) return NO;
    if (!CCPetsWriteChangedConfig(path, config, 0600, &errorMessage)) {
        CCPetsPrintLine(stderr, errorMessage);
        *failed = YES;
        return NO;
    }
    return YES;
}

static NSString *RemoveMarkedBlock(NSString *text, NSString *startMarker, NSString *endMarker) {
    NSString *pattern = [NSString stringWithFormat:@"(?:\\A|\\n)%@\\n[\\s\\S]*?%@(?=\\n|\\z)",
        [NSRegularExpression escapedPatternForString:startMarker],
        [NSRegularExpression escapedPatternForString:endMarker]];
    return ReplacePattern(text, pattern, @"");
}

// .zshrc 里的段落。cc-pets-codex / cc-pets-claude 是 alias 时代的写法：alias 区分大小写，挡不住
// Claude / CODEX，已被 cc-pets-shims 的 PATH shim 取代；安装前的清理也会走这里，顺带迁移掉。
static NSString *ShimPathFromLine(NSString *line) {
    if (![line hasPrefix:@"path=("] || ![line hasSuffix:@" $path)"]) return nil;
    NSString *literal = [line substringWithRange:NSMakeRange(6, line.length - 6 - @" $path)".length)];
    NSArray *words = CCPetsHookWords(literal);
    return words.count == 1 ? words.firstObject : nil;
}

static BOOL RemoveShellIntegration(NSString *shellRC, BOOL preparingInstall) {
    struct stat info;
    if (shellRC.length == 0 || stat(shellRC.fileSystemRepresentation, &info) != 0) return NO;
    NSData *data = [NSData dataWithContentsOfFile:shellRC];
    NSString *original = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!original) return NO;
    NSString *updated = original;
    NSString *shimDir = CCPetsEnvironmentValue(@"CC_PETS_SHIM_DIR") ?: [CCPetsHomeDirectory() stringByAppendingPathComponent:@".cc-pets/shims"];
    NSMutableArray *kept = [NSMutableArray array];
    BOOL inBlock = NO;
    NSArray *lines = [original componentsSeparatedByString:@"\n"];
    BOOL correctBlock = NO;
    for (NSString *line in lines) {
        if ([line isEqual:CCPetsShimStartMarker]) inBlock = YES;
        if ([line isEqual:CCPetsShimEndMarker]) inBlock = NO;
        if (inBlock && [ShimPathFromLine(line) isEqual:shimDir]) correctBlock = YES;
    }
    inBlock = NO;
    for (NSString *line in lines) {
        if ([line isEqual:CCPetsShimStartMarker]) {
            inBlock = YES;
            if (!preparingInstall || !correctBlock) continue;
        } else if ([line isEqual:CCPetsShimEndMarker]) {
            inBlock = NO;
            if (!preparingInstall || !correctBlock) continue;
        }
        NSString *target = ShimPathFromLine(line);
        if (inBlock && (!preparingInstall || !correctBlock) && ([line isEqual:@"typeset -U path"] || target)) continue;
        if (!preparingInstall && [target isEqual:shimDir]) continue;
        [kept addObject:line];
    }
    updated = [kept componentsJoinedByString:@"\n"];
    for (NSString *name in @[@"cc-pets-codex", @"cc-pets-claude", @"codex-pet", @"claude-pet"]) {
        updated = RemoveMarkedBlock(updated, [NSString stringWithFormat:@"# >>> %@ >>>", name],
            [NSString stringWithFormat:@"# <<< %@ <<<", name]);
    }
    if ([updated isEqualToString:original]) return NO;
    return CCPetsWriteFileAtomically(shellRC, updated, info.st_mode & 07777, NULL);
}

// 只删指向 bin/<name>-with-pet 的软链，别人放进来的同名文件不动；目录空了再删目录。
static BOOL RemoveShims(void) {
    NSString *directory = CCPetsEnvironmentValue(@"CC_PETS_SHIM_DIR") ?:
        [CCPetsHomeDirectory() stringByAppendingPathComponent:@".cc-pets/shims"];
    if (![NSFileManager.defaultManager fileExistsAtPath:directory]) return NO;
    BOOL changed = NO;
    for (NSString *name in @[@"codex", @"claude", @"agy"]) {
        NSString *shim = [directory stringByAppendingPathComponent:name];
        // lstat：目标包被 npm uninstall 删掉后软链是断的，但仍然要清掉。
        struct stat info;
        if (lstat(shim.fileSystemRepresentation, &info) != 0 || !S_ISLNK(info.st_mode)) continue;
        NSString *target = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:shim error:nil];
        if (![target hasSuffix:[NSString stringWithFormat:@"/bin/%@-with-pet", name]]) continue;
        if (unlink(shim.fileSystemRepresentation) == 0) changed = YES;
    }
    NSArray *remaining = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil];
    if (remaining && remaining.count == 0) rmdir(directory.fileSystemRepresentation);
    return changed;
}

static BOOL RemoveCodexHooksAtHome(NSString *codexHome, BOOL preparingInstall, BOOL *failed) {
    NSArray *signatures = preparingInstall
        ? @[@[CCPetsLegacyCodexHookMarker, @"codex-pet"]]
        : @[@[CCPetsCodexHookMarker, @"cc-pets"], @[CCPetsLegacyCodexHookMarker, @"codex-pet"]];
    NSString *path = [codexHome stringByAppendingPathComponent:@"hooks.json"];
    return UpdateConfig(path, failed, ^BOOL(CCPetsJSONObject *config) {
        return ReconcilePetHooks(config, signatures, nil, @[]);
    });
}

static BOOL RemoveClaudeHooksAtHome(NSString *claudeHome, BOOL preparingInstall, BOOL *failed) {
    NSArray *signatures = preparingInstall
        ? @[@[CCPetsLegacyClaudeHookMarker, @"codex-pet"]]
        : @[@[CCPetsClaudeHookMarker, @"cc-pets"], @[CCPetsLegacyClaudeHookMarker, @"codex-pet"]];
    NSArray<NSString *> *statusLineMarkers = preparingInstall
        ? @[CCPetsLegacyStatusLineMarker] : @[CCPetsStatusLineMarker, CCPetsLegacyStatusLineMarker];
    NSString *path = [claudeHome stringByAppendingPathComponent:@"settings.json"];
    return UpdateConfig(path, failed, ^BOOL(CCPetsJSONObject *config) {
        BOOL changed = ReconcilePetHooks(config, signatures, nil, @[]);
        CCPetsJSONObject *statusLine = config[@"statusLine"];
        BOOL isObject = [statusLine isKindOfClass:CCPetsJSONObject.class];
        NSString *command = isObject && [statusLine[@"command"] isKindOfClass:NSString.class] ? statusLine[@"command"] : @"";
        BOOL wrapped = NO;
        for (NSString *marker in statusLineMarkers) wrapped = wrapped || CCPetsIsManagedStatusLine(command, marker);
        if (wrapped) {
            NSString *originalCommand = DecodeWrappedStatusLine(command);
            if (originalCommand.length > 0) {
                CCPetsJSONObject *restored = [statusLine copy];
                restored[@"command"] = originalCommand;
                config[@"statusLine"] = restored;
            } else {
                [config removeObjectForKey:@"statusLine"];
            }
            changed = YES;
        }
        // 安装前不动注入的 prelude，紧接着的安装会原位替换它。
        if (!preparingInstall) {
            CCPetsJSONObject *current = config[@"statusLine"];
            id currentCommand = [current isKindOfClass:CCPetsJSONObject.class] ? current[@"command"] : nil;
            BOOL created = NO;
            BOOL keepScript = isObject && current.keys.count > 2;
            if (RemoveStatusLinePrelude(CCPetsParseStatusLineCommand(currentCommand)[@"script"], keepScript, &created)) changed = YES;
            if (created) {
                [current removeObjectForKey:@"type"];
                [current removeObjectForKey:@"command"];
                if (!current.keys.count) [config removeObjectForKey:@"statusLine"];
            }
        }
        return changed;
    });
}

int UninstallClaudeHooksAtHome(NSString *claudeHome) {
    BOOL failed = NO;
    BOOL changed = RemoveClaudeHooksAtHome(CCPetsResolvePath(claudeHome), NO, &failed);
    if (changed) CCPetsPrintLine(stdout, [NSString stringWithFormat:L(@"Removed the CC Pets hooks in %@ and restored the original status line."),
        [claudeHome stringByAppendingPathComponent:@"settings.json"]]);
    return failed ? 1 : 0;
}

int UninstallCodexHooksAtHome(NSString *codexHome) {
    BOOL failed = NO;
    BOOL changed = RemoveCodexHooksAtHome(CCPetsResolvePath(codexHome), NO, &failed);
    if (changed) CCPetsPrintLine(stdout, [NSString stringWithFormat:L(@"Removed the CC Pets hooks in %@."),
        [codexHome stringByAppendingPathComponent:@"hooks.json"]]);
    return failed ? 1 : 0;
}

static BOOL RemoveAntigravityHooksForUninstall(NSDictionary *profile, BOOL *failed) {
    BOOL installed = CCPetsAntigravityPetHooksInstalled(profile);
    @try {
        if (CCPetsRemoveAntigravityPetHooks(profile)) return installed;
    } @catch (NSException *exception) {
        CCPetsPrintLine(stderr, exception.reason ?: exception.name);
    }
    *failed = YES;
    return NO;
}

int UninstallIntegrations(BOOL preparingInstall, NSString *shellRC) {
    BOOL failed = NO;
    // 安装/卸载的隐式范围只包含官方默认 Home；环境变量指向的自定义 Home 必须先显式登记。
    NSString *defaultCodexHome = [CCPetsHomeDirectory() stringByAppendingPathComponent:@".codex"];
    NSString *defaultClaudeHome = [CCPetsHomeDirectory() stringByAppendingPathComponent:@".claude"];
    NSString *defaultAntigravityHome = [CCPetsHomeDirectory() stringByAppendingPathComponent:@".gemini"];
    NSString *codexHooksPath = [defaultCodexHome stringByAppendingPathComponent:@"hooks.json"];
    BOOL codexChanged = RemoveCodexHooksAtHome(defaultCodexHome, preparingInstall, &failed);
    NSString *claudeSettingsPath = [defaultClaudeHome stringByAppendingPathComponent:@"settings.json"];
    BOOL claudeChanged = RemoveClaudeHooksAtHome(defaultClaudeHome, preparingInstall, &failed);
    BOOL antigravityChanged = NO;
    if (!preparingInstall) {
        NSDictionary *profile = CCPetsProfileForHome(CCPetsProfileProviderAntigravity, defaultAntigravityHome) ?:
            @{@"provider": CCPetsProfileProviderAntigravity, @"home": defaultAntigravityHome,
              @"id": CCPetsProfileID(CCPetsProfileProviderAntigravity, defaultAntigravityHome)};
        antigravityChanged = RemoveAntigravityHooksForUninstall(profile, &failed);
    }
    BOOL profileChanged = NO;

    // 显式登记的 Home 也属于安装范围。默认 Home 已迁移进注册表时按规范化路径去重。
    NSMutableSet<NSString *> *handledHomes = [NSMutableSet setWithObjects:
        CCPetsResolvePath(defaultCodexHome), CCPetsResolvePath(defaultClaudeHome),
        CCPetsRealPath(defaultAntigravityHome) ?: CCPetsResolvePath(defaultAntigravityHome), nil];
    for (NSDictionary *profile in CCPetsProfiles()) {
        NSString *home = CCPetsResolvePath(profile[@"home"]);
        if (home.length == 0 || [handledHomes containsObject:home]) continue;
        [handledHomes addObject:home];
        NSString *provider = profile[@"provider"];
        BOOL changed;
        if ([provider isEqualToString:CCPetsProfileProviderAntigravity]) {
            changed = !preparingInstall && RemoveAntigravityHooksForUninstall(profile, &failed);
        } else if ([provider isEqualToString:CCPetsProfileProviderClaude]) {
            changed = RemoveClaudeHooksAtHome(home, preparingInstall, &failed);
        } else {
            changed = RemoveCodexHooksAtHome(home, preparingInstall, &failed);
        }
        if (changed) {
            profileChanged = YES;
            CCPetsPrintLine(stdout, [NSString stringWithFormat:L(@"%1$@ the CC Pets hooks in %2$@."),
                preparingInstall ? L(@"Migrated") : L(@"Removed"), home]);
        }
    }

    BOOL shellChanged = RemoveShellIntegration(shellRC, preparingInstall);
    // shim 只在真正卸载时删：安装前删掉的话，重建失败就会留下一个没有 codex / claude 的 PATH 目录。
    BOOL shimChanged = !preparingInstall && RemoveShims();

    NSString *action = preparingInstall ? L(@"Migrated") : L(@"Removed");
    if (codexChanged) {
        CCPetsPrintLine(stdout, [NSString stringWithFormat:L(@"%1$@ the CC Pets hooks in %2$@."), action, codexHooksPath]);
    }
    if (claudeChanged) {
        CCPetsPrintLine(stdout, [NSString stringWithFormat:L(@"%1$@ the CC Pets hooks in %2$@ and restored the original status line."),
            action, claudeSettingsPath]);
    }
    if (antigravityChanged) {
        CCPetsPrintLine(stdout, [NSString stringWithFormat:L(@"Removed the CC Pets hooks in %@."), defaultAntigravityHome]);
    }
    if (shellChanged) {
        CCPetsPrintLine(stdout, [NSString stringWithFormat:L(@"%1$@ the CC Pets shell integration in %2$@."), action, shellRC]);
    }
    if (shimChanged) {
        NSString *directory = CCPetsEnvironmentValue(@"CC_PETS_SHIM_DIR") ?:
            [CCPetsHomeDirectory() stringByAppendingPathComponent:@".cc-pets/shims"];
        CCPetsPrintLine(stdout, [NSString stringWithFormat:L(@"%1$@ the codex / claude / agy shims in %2$@."), action, directory]);
    }
    if (!codexChanged && !claudeChanged && !antigravityChanged && !profileChanged && !shellChanged && !shimChanged && !preparingInstall && !failed) {
        CCPetsPrintLine(stdout, L(@"No CC Pets integrations to remove."));
    }
    return failed ? 1 : 0;
}

#pragma mark - 自动更新配置

// 应用内更新走 `node npm-cli.js install -g cc-pets@latest`。npm 装包时把自己用的 node 和 npm-cli
// 通过 npm_node_execpath / npm_execpath 告诉 postinstall，这里记下真实路径。拿不到时只提示不报错：
// 自动更新是锦上添花，不能因此让安装失败。
int ConfigureUpdater(void) {
    NSString *nodeCandidate = CCPetsEnvironmentValue(@"npm_node_execpath") ?: CCPetsFindRealExecutable(@"node", nil);
    NSString *npmCandidate = CCPetsEnvironmentValue(@"npm_execpath");
    if (!nodeCandidate || !npmCandidate) {
        CCPetsPrintLine(stderr, L(@"Auto-update config not saved: npm didn't provide the node/npm-cli paths."));
        return 0;
    }
    NSString *nodePath = CCPetsRealPath(nodeCandidate);
    NSString *npmCliPath = CCPetsRealPath(npmCandidate);
    if (!nodePath || !npmCliPath) {
        CCPetsPrintLine(stderr, L(@"Auto-update config not saved: the node/npm-cli paths don't exist."));
        return 0;
    }
    NSString *supportDirectory = CCPetsEnvironmentValue(@"CC_PETS_APPLICATION_SUPPORT_DIR") ?:
        [CCPetsHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/CC Pets"];
    NSString *applicationsDirectory = CCPetsEnvironmentValue(@"CC_PETS_APPLICATIONS_DIR") ?:
        [CCPetsHomeDirectory() stringByAppendingPathComponent:@"Applications"];
    [NSFileManager.defaultManager createDirectoryAtPath:supportDirectory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:nil];
    CCPetsJSONObject *configuration = [CCPetsJSONObject new];
    configuration[@"schemaVersion"] = @2;
    configuration[@"nodePath"] = nodePath;
    configuration[@"npmCliPath"] = npmCliPath;
    configuration[@"appPath"] = [applicationsDirectory stringByAppendingPathComponent:@"CC Pets.app"];
    NSString *error = nil;
    NSString *file = [supportDirectory stringByAppendingPathComponent:@"updater.json"];
    NSString *text = [CCPetsJSONStringify(configuration) stringByAppendingString:@"\n"];
    if ([text isEqual:[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil]]) return 0;
    if (!CCPetsWriteFileAtomically(file, text, 0600, &error)) {
        CCPetsPrintLine(stderr, error);
        return 1;
    }
    return 0;
}
