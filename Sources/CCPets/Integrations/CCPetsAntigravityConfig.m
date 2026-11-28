#import "CCPetsAntigravityConfig.h"
#import "CCPetsBridge.h"
#import "CCPetsBridgeSetup.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsCLISupport.h"
#import "CCPetsJSON.h"
#import "CCPetsHookMerge.h"
#import "CCPetsL10n.h"
#import "CCPetsProfiles.h"
#import <errno.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const HookName = @"cc-pets-cli";
static NSString *const HookMarker = @"CC_PETS_AGY_HOOK=1 ";
static NSString *const MCPMarker = @"CC_PETS_AGY_MCP";
static NSString *const StatusLineMarker = @"CC_PETS_AGY_STATUS_LINE='";
static NSString *const BridgeTitleMarker = @"CC_PETS_AGY_BRIDGE_TITLE='";
static NSString *const AppSidecarName = @"cc-pets-bridge";
static NSString *const AppSidecarDescription = @"CC Pets Bridge delivery for Antigravity App";

static NSString *ProfileFile(NSDictionary *profile, NSString *relative) {
    NSString *home = profile[@"home"];
    if (![home isKindOfClass:NSString.class] || !home.isAbsolutePath) {
        [NSException raise:@"CCPetsAntigravityConfig" format:@"Invalid Antigravity profile home"];
    }
    return [home stringByAppendingPathComponent:relative];
}

static CCPetsJSONObject *Object(id value) {
    return [value isKindOfClass:CCPetsJSONObject.class] ? value : nil;
}

static CCPetsJSONObject *ReadAgyDocument(NSString *path, NSString **errorMessage, BOOL editing) {
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&readError];
    if (!data) {
        if (errorMessage && !([readError.domain isEqual:NSCocoaErrorDomain] &&
            (readError.code == NSFileReadNoSuchFileError || readError.code == NSFileNoSuchFileError))) {
            *errorMessage = readError.localizedDescription;
        }
        return nil;
    }
    const unsigned char *bytes = data.bytes;
    NSUInteger index = 0;
    while (index < data.length && (bytes[index] == ' ' || bytes[index] == '\t' ||
        bytes[index] == '\r' || bytes[index] == '\n')) index++;
    if (index == data.length) {
        CCPetsJSONObject *empty = editing ? [CCPetsJSONObject new] : nil;
        empty.sourceData = data;
        return empty;
    }
    id document = CCPetsJSONParse(data, errorMessage);
    if (document && !Object(document)) {
        if (errorMessage) *errorMessage = L(@"Expected a JSON object.");
        return nil;
    }
    ((CCPetsJSONObject *)document).sourceData = data;
    return document;
}

CCPetsJSONObject *CCPetsReadAntigravityConfig(NSString *path, NSString **errorMessage) {
    return ReadAgyDocument(path, errorMessage, NO);
}

static CCPetsJSONObject *ReadConfig(NSString *path) {
    NSString *error = nil;
    CCPetsJSONObject *document = ReadAgyDocument(path, &error, YES);
    if (error) [NSException raise:@"CCPetsAntigravityConfig" format:@"%@: %@", path, error];
    return document;
}

static BOOL UpdateConfig(NSString *path, BOOL (^update)(CCPetsJSONObject *)) {
    NSString *lock = [@"agy-config-" stringByAppendingString:CCBridgeSHA1Hex(path)];
    return [CCBridgeWithLock(lock, ^id {
        CCPetsJSONObject *document = ReadConfig(path) ?: [CCPetsJSONObject new];
        if (!update(document)) return @NO;
        NSError *directoryError = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:&directoryError]) {
            [NSException raise:@"CCPetsAntigravityConfig" format:@"%@", directoryError.localizedDescription];
        }
        struct stat info;
        mode_t mode = stat(path.fileSystemRepresentation, &info) == 0 ? info.st_mode & 0777 : 0600;
        NSString *error = nil;
        if (!CCPetsWriteChangedConfig(path, document, mode, &error)) {
            [NSException raise:@"CCPetsAntigravityConfig" format:@"%@", error];
        }
        return @YES;
    }) boolValue];
}

static NSArray<NSString *> *Events(void) {
    return @[@"SessionStart", @"PreInvocation", @"PreToolUse", @"PostToolUse", @"Stop"];
}

static NSString *ProfileEnvironment(NSDictionary *profile) {
    return [NSString stringWithFormat:@"CC_PETS_PROFILE_ID=%@ CC_PETS_PROFILE_NAME=%@ CC_PETS_PROFILE_HOME=%@",
        CCPetsShellQuote(profile[@"id"] ?: @""), CCPetsShellQuote(profile[@"displayName"] ?: @"Antigravity"),
        CCPetsShellQuote(profile[@"home"])];
}

// The managed command carries its previous settings so repair/uninstall does not require a second file.
static CCPetsJSONObject *WrappedCommandBackup(id command, NSString *marker) {
    if (![command isKindOfClass:NSString.class] || ![command hasPrefix:marker]) return nil;
    NSString *suffix = [command substringFromIndex:marker.length];
    NSRange end = [suffix rangeOfString:@"';"];
    if (end.location == NSNotFound) return nil;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:[suffix substringToIndex:end.location] options:0];
    return data ? Object(CCPetsJSONParse(data, NULL)) : nil;
}

static void ChangeStatusLine(NSDictionary *profile, BOOL install) {
    UpdateConfig(ProfileFile(profile, @"antigravity-cli/settings.json"), ^BOOL(CCPetsJSONObject *document) {
        CCPetsJSONObject *line = Object(document[@"statusLine"]);
        // Let the CLI keep its existing behavior for an older or unrecognized form.
        if (document[@"statusLine"] && !line) return NO;
        id command = line[@"command"];
        if (command && ![command isKindOfClass:NSString.class]) return NO;
        CCPetsJSONObject *previous = WrappedCommandBackup(command, StatusLineMarker);
        if (!install) {
            if (!previous) return NO;
            NSString *previousCommand = previous[@"command"];
            if (previousCommand) line[@"command"] = previousCommand;
            else [line removeObjectForKey:@"command"];
            if (previousCommand.length == 0 && [line[@"stack_with_default"] isEqual:@YES]) {
                if (previous[@"stack_with_default"]) line[@"stack_with_default"] = previous[@"stack_with_default"];
                else [line removeObjectForKey:@"stack_with_default"];
            }
            if (line.keys.count == 0) [document removeObjectForKey:@"statusLine"];
            return YES;
        }
        if ([command hasPrefix:StatusLineMarker] && !previous) return NO;
        previous = previous ?: line ?: [CCPetsJSONObject new];
        if (!line) line = [CCPetsJSONObject new];
        NSString *oldCommand = previous[@"command"];
        NSString *snapshot = [[CCPetsJSONStringify(previous) dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
        NSString *collect = [NSString stringWithFormat:@"%@%@'; agy_status_input=$(/bin/cat); /usr/bin/printf '%%s' \"$agy_status_input\" | %@ %@ --agy-status-line >/dev/null 2>&1 || :",
            StatusLineMarker, snapshot, ProfileEnvironment(profile), CCPetsShellQuote(CCPetsExecutablePath())];
        if (oldCommand.length > 0) {
            collect = [collect stringByAppendingFormat:@"; /usr/bin/printf '%%s' \"$agy_status_input\" | /bin/sh -c %@", CCPetsShellQuote(oldCommand)];
        } else {
            line[@"stack_with_default"] = @YES;
        }
        if ([line[@"command"] isEqual:collect]) return NO;
        line[@"command"] = collect;
        document[@"statusLine"] = line;
        return YES;
    });
}

static BOOL IsJSONBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

void CCPetsConfigureAntigravityBridgeTitle(NSDictionary *profile, BOOL enabled) {
    UpdateConfig(ProfileFile(profile, @"antigravity-cli/settings.json"), ^BOOL(CCPetsJSONObject *document) {
        id configured = document[@"title"];
        CCPetsJSONObject *title = Object(configured);
        if (configured && !title && !IsJSONBoolean(configured)) return NO;
        id currentCommand = title[@"command"];
        if (currentCommand && ![currentCommand isKindOfClass:NSString.class]) return NO;
        CCPetsJSONObject *backup = WrappedCommandBackup(currentCommand, BridgeTitleMarker);
        if (!enabled) {
            if (!backup) return NO;
            id original = backup[@"title"];
            NSString *originalCommand = Object(original)[@"command"];
            if (originalCommand) title[@"command"] = originalCommand;
            else [title removeObjectForKey:@"command"];

            if (IsJSONBoolean(original) && (title.keys.count == 0 ||
                (title.keys.count == 1 && IsJSONBoolean(title[@"enabled"])))) {
                // Keep a user's later /title toggle as well as the legacy boolean shape.
                document[@"title"] = title[@"enabled"] ?: @YES;
            } else if (!original && title.keys.count == 0) {
                [document removeObjectForKey:@"title"];
            }
            return YES;
        }

        if ([currentCommand hasPrefix:BridgeTitleMarker] && !backup) return NO;
        if (!backup) {
            backup = [CCPetsJSONObject new];
            if (configured) backup[@"title"] = configured;
        }
        if (!title) {
            title = [CCPetsJSONObject new];
            if (IsJSONBoolean(configured)) title[@"enabled"] = configured;
        }
        NSString *originalCommand = Object(backup[@"title"])[@"command"];
        NSString *snapshot = [[CCPetsJSONStringify(backup) dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
        // A sentinel keeps trailing newlines in the JSON while command substitution stores it.
        NSMutableString *managed = [NSMutableString stringWithFormat:
            @"%@%@'; agy_title_input=$(/bin/cat && /usr/bin/printf x) || exit $?; agy_title_input=${agy_title_input%%x}; ",
            BridgeTitleMarker, snapshot];
        NSString *render = [NSString stringWithFormat:
            @"/usr/bin/printf '%%s' \"$agy_title_input\" | %@ %@ --agy-bridge-title",
            ProfileEnvironment(profile), CCPetsShellQuote(CCPetsExecutablePath())];
        if (originalCommand.length > 0) {
            [managed appendFormat:@"agy_title_original=$(/usr/bin/printf '%%s' \"$agy_title_input\" | /bin/sh -c %@) || exit $?; ",
                CCPetsShellQuote(originalCommand)];
            [managed appendFormat:@"%@ \"$agy_title_original\" || /usr/bin/printf '%%s\\n' \"$agy_title_original\"", render];
        } else {
            [managed appendString:render];
        }
        if ([currentCommand isEqual:managed]) return NO;
        title[@"command"] = managed;
        document[@"title"] = title;
        return YES;
    });
}

static BOOL IsToolEvent(NSString *event) {
    return [event isEqual:@"PreToolUse"] || [event isEqual:@"PostToolUse"];
}

static NSString *AgyHookRole(id command) {
    NSArray *args = CCPetsHookInvocation(command, nil);
    if (args.count != 3 || !CCPetsIsPetExecutable(args[0]) || ![args[1] isEqual:@"--agy-hook"]) return nil;
    return [Events() containsObject:args[2]] ? @"pet" : nil;
}

static BOOL HasHook(CCPetsJSONObject *group, NSString *event) {
    id entries = group[event];
    if (![entries isKindOfClass:NSArray.class]) return NO;
    for (id entry in entries) {
        NSArray *handlers = IsToolEvent(event) ? Object(entry)[@"hooks"] : @[entry];
        if (![handlers isKindOfClass:NSArray.class]) continue;
        for (id handler in handlers) if (AgyHookRole(Object(handler)[@"command"])) return YES;
    }
    return NO;
}

BOOL CCPetsAntigravityPetHooksInstalled(NSDictionary *profile) {
    @try {
        CCPetsJSONObject *document = ReadConfig(ProfileFile(profile, @"config/hooks.json"));
        for (NSString *event in Events()) {
            BOOL found = NO;
            for (NSString *key in document.keys) {
                CCPetsJSONObject *group = Object(document[key]);
                if (![group[@"enabled"] isEqual:@NO] && HasHook(group, event)) { found = YES; break; }
            }
            if (!found) return NO;
        }
        return YES;
    } @catch (NSException *exception) { return NO; }
}

static BOOL ReconcileAgyHooks(NSDictionary *profile, BOOL install) {
    return UpdateConfig(ProfileFile(profile, @"config/hooks.json"), ^BOOL(CCPetsJSONObject *document) {
        BOOL changed = NO;
        for (NSString *event in Events()) {
            NSString *slot = HookName;
            if (!HasHook(Object(document[slot]), event)) {
                for (NSString *key in document.keys) {
                    if (HasHook(Object(document[key]), event)) { slot = key; break; }
                }
            }
            NSMutableOrderedSet *groups = [NSMutableOrderedSet orderedSetWithArray:document.keys];
            if (install) [groups addObject:slot];
            for (NSString *key in groups) {
                CCPetsJSONObject *group = Object(document[key]);
                BOOL target = install && [key isEqual:slot];
                if (!target && !HasHook(group, event)) continue;
                if (!group && document[key]) [NSException raise:@"CCPetsHooks" format:@"%@", L(@"The Antigravity hook name is already in use.")];
                group = group ?: [CCPetsJSONObject new];
                NSArray *wanted = @[];
                if (target) {
                    NSString *command = [NSString stringWithFormat:@"%@%@ %@ --agy-hook %@", HookMarker,
                        ProfileEnvironment(profile), CCPetsShellQuote(CCPetsExecutablePath()), event];
                    NSDictionary *handler = @{@"type": @"command", @"command": command, @"timeout": @10};
                    wanted = IsToolEvent(event) ? @[@{@"matcher": @"*", @"hooks": @[handler]}] : @[handler];
                }
                NSArray *entries = CCPetsMergeHookEntries(group[event], wanted, IsToolEvent(event), ^NSString *(id cmd) { return AgyHookRole(cmd); });
                if ([CCPetsJSONStringify(entries) isEqual:CCPetsJSONStringify(group[event] ?: @[])]) continue;
                changed = YES;
                if (entries.count) group[event] = entries; else [group removeObjectForKey:event];
                if (!group.keys.count && [key isEqual:HookName]) [document removeObjectForKey:key]; else document[key] = group;
            }
        }
        return changed;
    });
}

NSArray<NSString *> *CCPetsInstallAntigravityPetHooks(NSDictionary *profile) {
    ReconcileAgyHooks(profile, YES);
    ChangeStatusLine(profile, YES);
    return @[CCPetsInterpolate(L(@"Antigravity CLI hooks configured in {path}."), @{@"path": ProfileFile(profile, @"config/hooks.json")})];
}

BOOL CCPetsRemoveAntigravityPetHooks(NSDictionary *profile) {
    ReconcileAgyHooks(profile, NO);
    ChangeStatusLine(profile, NO);
    return YES;
}

static BOOL OwnsMCP(id candidate) {
    CCPetsJSONObject *server = Object(candidate);
    return CCPetsIsPetExecutable(server[@"command"]) && CCPetsIsBridgeTransport(server[@"command"], server[@"args"]) &&
        !server[@"serverUrl"] && !server[@"url"];
}

BOOL CCPetsAntigravityBridgeInstalled(NSDictionary *profile) {
    @try {
        CCPetsJSONObject *mcp = ReadConfig(ProfileFile(profile, @"config/mcp_config.json"));
        CCPetsJSONObject *server = Object(Object(mcp[@"mcpServers"])[CCBridgeMCPName]);
        NSString *command = server[@"command"];
        return CCPetsAntigravityPetHooksInstalled(profile) && OwnsMCP(server) && ![server[@"disabled"] isEqual:@YES] &&
            [command isKindOfClass:NSString.class] && command.isAbsolutePath &&
            [NSFileManager.defaultManager isExecutableFileAtPath:command];
    } @catch (NSException *exception) { return NO; }
}

static BOOL ChangeMCP(NSDictionary *profile, BOOL enabled) {
    NSString *path = ProfileFile(profile, @"config/mcp_config.json");
    return UpdateConfig(path, ^BOOL(CCPetsJSONObject *document) {
        CCPetsJSONObject *servers = Object(document[@"mcpServers"]);
        id current = servers[CCBridgeMCPName];
        if (!enabled) {
            if (!OwnsMCP(current)) return NO;
            CCPetsJSONObject *server = Object(current), *env = Object(server[@"env"]);
            if (server[@"env"] && !env) [NSException raise:@"CCPetsAntigravityConfig" format:@"Invalid MCP environment"];
            BOOL custom = [server[@"args"] count] > 2;
            for (NSString *key in server.keys) if (![@[@"command",@"args",@"env"] containsObject:key]) custom = YES;
            for (NSString *key in env.keys) if (![@[MCPMarker,@"CC_PETS_HOME",@"CC_PETS_STATE_DIR"] containsObject:key]) custom = YES;
            if (custom) {
                if ([server[@"disabled"] isEqual:@YES]) return NO;
                env = env ?: [CCPetsJSONObject new];
                env[MCPMarker] = server[@"disabled"] ? @"paused:false" : @"paused:default";
                server[@"env"] = env;
                server[@"disabled"] = @YES;
                return YES;
            }
            [servers removeObjectForKey:CCBridgeMCPName];
            if (servers.keys.count == 0) [document removeObjectForKey:@"mcpServers"];
            return YES;
        }
        if ((document[@"mcpServers"] && !servers) || (current && !OwnsMCP(current))) {
            [NSException raise:@"CCPetsAntigravityConfig" format:@"%@: %@", path, L(@"The Antigravity MCP server name is already in use.")];
        }
        if (!servers) servers = [CCPetsJSONObject new];
        CCPetsJSONObject *server = Object(current) ?: [CCPetsJSONObject new];
        CCPetsJSONObject *environment = Object(server[@"env"]) ?: [CCPetsJSONObject new];
        NSString *command = CCPetsExecutablePath();
        if (server[@"env"] && !Object(server[@"env"])) [NSException raise:@"CCPetsAntigravityConfig" format:@"Invalid MCP environment"];
        NSString *marker = environment[MCPMarker];
        BOOL changed = ![server[@"command"] isEqual:command] || ![marker isEqual:@"1"];
        if ([server[@"disabled"] isEqual:@YES] && [marker isEqual:@"paused:false"]) server[@"disabled"] = @NO;
        if ([server[@"disabled"] isEqual:@YES] && [marker isEqual:@"paused:default"]) [server removeObjectForKey:@"disabled"];
        for (NSString *key in @[@"CC_PETS_HOME", @"CC_PETS_STATE_DIR"]) {
            NSString *value = CCPetsEnvironmentValue(key);
            id old = environment[key];
            if (!(old == value || [old isEqual:value])) changed = YES;
            if (value) environment[key] = value;
            else [environment removeObjectForKey:key];
        }
        if (!changed) return NO;
        environment[MCPMarker] = @"1";
        server[@"command"] = command;
        if (!current) server[@"args"] = @[@"bridge", @"mcp"];
        server[@"env"] = environment;
        servers[CCBridgeMCPName] = server;
        document[@"mcpServers"] = servers;
        return YES;
    });
}

static NSString *AllowRule(NSString *tool) {
    return [NSString stringWithFormat:@"mcp(%@/%@)", CCBridgeMCPName, tool];
}

static BOOL AgyAllowsBelongToBridge(NSDictionary *profile) {
    id servers = ReadConfig(ProfileFile(profile, @"config/mcp_config.json"))[@"mcpServers"];
    return (!servers || Object(servers)) && (!servers[CCBridgeMCPName] || OwnsMCP(servers[CCBridgeMCPName]));
}

static void SetAllows(NSDictionary *profile, NSArray *allowed, NSArray *oldTools) {
    UpdateConfig(ProfileFile(profile, @"antigravity-cli/settings.json"), ^BOOL(CCPetsJSONObject *document) {
        NSMutableArray *wanted = [NSMutableArray array];
        NSMutableSet *revoke = [NSMutableSet set];
        for (NSString *tool in allowed) [wanted addObject:AllowRule(tool)];
        for (NSString *tool in oldTools) [revoke addObject:AllowRule(tool)];
        return CCPetsMergeAllows(document, wanted, revoke);
    });
}

NSArray<NSString *> *CCPetsInstallAntigravityBridge(NSDictionary *profile, NSArray<NSString *> *allowed, BOOL registerMcp) {
    if (!AgyAllowsBelongToBridge(profile)) [NSException raise:@"CCPetsAntigravityConfig" format:@"%@", L(@"The Antigravity MCP server name is already in use.")];
    NSMutableArray *report = [CCPetsInstallAntigravityPetHooks(profile) mutableCopy];
    if (registerMcp && ChangeMCP(profile, YES)) [report addObject:L(@"Registered CC Bridge MCP for Antigravity CLI.")];
    SetAllows(profile, allowed, CCBridgeOptions()[@"antigravityAllow"]);
    return report;
}

NSArray<NSString *> *CCPetsRemoveAntigravityBridge(NSDictionary *profile, BOOL unregisterMcp, NSArray *oldTools) {
    if (AgyAllowsBelongToBridge(profile)) SetAllows(profile, @[], oldTools);
    return unregisterMcp && ChangeMCP(profile, NO) ? @[L(@"Removed CC Bridge MCP from Antigravity CLI.")] : @[];
}

static BOOL IsAntigravityAppProfile(NSDictionary *profile) {
    return [profile[@"provider"] isEqual:CCPetsProfileProviderAntigravity] && CCPetsProfileIsOfficialDefault(profile);
}

static NSString *AppSidecarManifestPath(NSDictionary *profile) {
    return ProfileFile(profile, [NSString stringWithFormat:@"config/sidecars/%@/sidecar.json", AppSidecarName]);
}

static NSArray<NSString *> *AppSidecarArguments(void) {
    return @[@"bridge", @"agy-app-sidecar"];
}

static BOOL OwnsAppSidecar(CCPetsJSONObject *manifest) {
    return CCPetsIsPetExecutable(manifest[@"command"]) &&
        [manifest[@"args"] isEqual:AppSidecarArguments()];
}

BOOL CCPetsAntigravityAppSidecarInstalled(NSDictionary *profile) {
    if (!IsAntigravityAppProfile(profile)) return NO;
    @try {
        CCPetsJSONObject *manifest = ReadConfig(AppSidecarManifestPath(profile));
        NSString *command = manifest[@"command"];
        CCPetsJSONObject *mcp = ReadConfig(ProfileFile(profile, @"config/mcp_config.json"));
        CCPetsJSONObject *server = Object(Object(mcp[@"mcpServers"])[CCBridgeMCPName]);
        CCPetsJSONObject *config = ReadConfig(ProfileFile(profile, @"config/config.json"));
        CCPetsJSONObject *state = Object(Object(config[@"sidecars"])[AppSidecarName]);
        return OwnsAppSidecar(manifest) && [command isKindOfClass:NSString.class] && command.isAbsolutePath &&
            [NSFileManager.defaultManager isExecutableFileAtPath:command] &&
            OwnsMCP(server) && [server[@"command"] isEqual:command] &&
            [state[@"enabled"] isEqual:@YES];
    } @catch (NSException *exception) { return NO; }
}

static void FailSidecarCollision(NSString *path) {
    [NSException raise:@"CCPetsAntigravityConfig" format:@"%@: %@", path, L(@"The Antigravity sidecar name is already in use.")];
}

NSArray<NSString *> *CCPetsConfigureAntigravityAppSidecar(NSDictionary *profile, BOOL enabled) {
    if (!IsAntigravityAppProfile(profile)) return @[];
    NSString *manifestPath = AppSidecarManifestPath(profile);
    NSString *configPath = ProfileFile(profile, @"config/config.json");
    NSString *lock = [@"agy-app-sidecar-" stringByAppendingString:CCBridgeSHA1Hex(manifestPath)];
    return CCBridgeWithLock(lock, ^id {
        NSString *error = nil;
        CCPetsJSONObject *manifest = CCPetsReadAntigravityConfig(manifestPath, &error);
        BOOL owned = OwnsAppSidecar(manifest);
        if (!enabled && !owned) return @[];
        if (error) [NSException raise:@"CCPetsAntigravityConfig" format:@"%@: %@", manifestPath, error];

        CCPetsJSONObject *config = ReadConfig(configPath);
        CCPetsJSONObject *sidecars = Object(config[@"sidecars"]);
        id state = sidecars[AppSidecarName];
        if (enabled) {
            struct stat info;
            if (!owned && lstat(manifestPath.fileSystemRepresentation, &info) == 0) FailSidecarCollision(manifestPath);
            if ((state && (!owned || !Object(state))) || (config[@"sidecars"] && !sidecars)) FailSidecarCollision(configPath);

            UpdateConfig(manifestPath, ^BOOL(CCPetsJSONObject *document) {
                if (document.keys.count > 0 && !OwnsAppSidecar(document)) FailSidecarCollision(manifestPath);
                CCPetsJSONObject *environment = Object(document[@"env"]) ?: [CCPetsJSONObject new];
                if (document[@"env"] && !Object(document[@"env"])) FailSidecarCollision(manifestPath);
                for (NSString *key in @[@"CC_PETS_HOME", @"CC_PETS_STATE_DIR"]) {
                    NSString *value = CCPetsEnvironmentValue(key);
                    if (value) environment[key] = value; else [environment removeObjectForKey:key];
                }
                if (!document[@"display_name"]) document[@"display_name"] = @"CC Pets Bridge";
                if (!document[@"description"]) document[@"description"] = AppSidecarDescription;
                document[@"command"] = CCPetsExecutablePath();
                document[@"args"] = AppSidecarArguments();
                if (!document[@"restart_policy"]) document[@"restart_policy"] = @"on-failure";
                if (environment.keys.count > 0) document[@"env"] = environment;
                else [document removeObjectForKey:@"env"];
                return YES;
            });
        }

        BOOL keep = NO;
        for (NSString *key in manifest.keys) if (![@[@"display_name", @"description", @"command", @"args", @"restart_policy", @"env"] containsObject:key]) keep = YES;
        for (NSString *key in Object(manifest[@"env"]).keys) if (![@[@"CC_PETS_HOME", @"CC_PETS_STATE_DIR"] containsObject:key]) keep = YES;
        if (manifest[@"env"] && !Object(manifest[@"env"])) FailSidecarCollision(manifestPath);
        if (state && !Object(state)) FailSidecarCollision(configPath);
        if (owned && (![manifest[@"display_name"] isEqual:@"CC Pets Bridge"] || ![manifest[@"description"] isEqual:AppSidecarDescription] ||
            ![manifest[@"restart_policy"] isEqual:@"on-failure"])) keep = YES;
        for (NSString *key in Object(state).keys) if (![key isEqual:@"enabled"]) keep = YES;

        UpdateConfig(configPath, ^BOOL(CCPetsJSONObject *document) {
            CCPetsJSONObject *entries = Object(document[@"sidecars"]);
            if ((document[@"sidecars"] && !entries) || (entries[AppSidecarName] && !Object(entries[AppSidecarName])))
                FailSidecarCollision(configPath);
            if (!enabled) {
                if (keep) {
                    CCPetsJSONObject *entry = Object(entries[AppSidecarName]) ?: [CCPetsJSONObject new];
                    if ([entry[@"enabled"] isEqual:@NO]) return NO;
                    entries = entries ?: [CCPetsJSONObject new];
                    entry[@"enabled"] = @NO;
                    entries[AppSidecarName] = entry;
                    document[@"sidecars"] = entries;
                    return YES;
                }
                if (!entries[AppSidecarName]) return NO;
                [entries removeObjectForKey:AppSidecarName];
                if (entries.keys.count == 0) [document removeObjectForKey:@"sidecars"];
                return YES;
            }
            id existing = entries[AppSidecarName];
            CCPetsJSONObject *entry = Object(existing);
            if ([entry[@"enabled"] isEqual:@YES]) return NO;
            if ([entry[@"enabled"] isEqual:@NO] && [CCBridgeOptions()[@"antigravityApp"] boolValue])
                return NO; // Preserve a user's disabled Sidecar on an ordinary refresh.
            entries = entries ?: [CCPetsJSONObject new];
            entry = entry ?: [CCPetsJSONObject new];
            entry[@"enabled"] = @YES;
            entries[AppSidecarName] = entry;
            document[@"sidecars"] = entries;
            return YES;
        });

        if (!enabled && !keep) {
            if (![[NSData dataWithContentsOfFile:manifestPath] isEqual:manifest.sourceData]) FailSidecarCollision(manifestPath);
            if (unlink(manifestPath.fileSystemRepresentation) != 0 && errno != ENOENT) {
                NSError *removeError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
                [NSException raise:@"CCPetsAntigravityConfig" format:@"%@: %@", manifestPath, removeError.localizedDescription];
            }
            rmdir(manifestPath.stringByDeletingLastPathComponent.fileSystemRepresentation);
        }
        return @[enabled ? L(@"Antigravity App Sidecar enabled.") : L(@"Antigravity App Sidecar disabled.")];
    });
}
