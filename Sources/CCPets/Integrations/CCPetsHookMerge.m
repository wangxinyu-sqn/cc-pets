#import "CCPetsHookMerge.h"
#import "CCPetsJSON.h"
#import "CCPetsCLISupport.h"

NSArray<NSString *> *CCPetsHookWords(id command) {
    if (![command isKindOfClass:NSString.class]) return nil;
    NSString *text = command;
    NSMutableArray *words = [NSMutableArray array];
    NSMutableString *word = [NSMutableString string];
    unichar quote = 0;
    BOOL started = NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (!quote && (c == ' ' || c == '\t')) {
            if (started) { [words addObject:word.copy]; [word setString:@""]; started = NO; }
            continue;
        }
        started = YES;
        if (quote && c == quote) { quote = 0; continue; }
        if (!quote && (c == '\'' || c == '"')) { quote = c; continue; }
        if (quote != '\'' && c == '\\') {
            if (++i == text.length) return nil;
            c = [text characterAtIndex:i];
            if (quote == '"' && !(c == '$' || c == '`' || c == '"' || c == '\\')) [word appendString:@"\\"];
        } else if (quote != '\'' && (c == '$' || c == '`' || (!quote && [@";&|<>*?()[]{}#~" containsString:[text substringWithRange:NSMakeRange(i,1)]]))) return nil;
        if (c == '\n' || c == '\r') return nil;
        [word appendString:[text substringWithRange:NSMakeRange(i, 1)]];
    }
    if (quote) return nil;
    if (started) [words addObject:word];
    return words;
}

BOOL CCPetsIsPetExecutable(id path) {
    return [path isKindOfClass:NSString.class] && [[path lastPathComponent] isEqual:@"cc-pets"];
}

BOOL CCPetsIsBridgeTransport(id command, id args) {
    if (![command isKindOfClass:NSString.class] || ![args isKindOfClass:NSArray.class] || [args count] < 2) return NO;
    if (CCPetsIsPetExecutable(command)) return [args[0] isEqual:@"bridge"] && [args[1] isEqual:@"mcp"];
    return [[command lastPathComponent] isEqual:@"node"] && [args[0] isKindOfClass:NSString.class] &&
        ([args[0] hasSuffix:@"/scripts/bridge/cli.mjs"] || [args[0] hasSuffix:@"/scripts/bus/cli.mjs"]) && [args[1] isEqual:@"mcp"];
}

NSArray<NSString *> *CCPetsHookInvocation(id command, NSMutableDictionary *environment) {
    NSArray *words = CCPetsHookWords(command);
    NSUInteger i = [@[@"env", @"/usr/bin/env"] containsObject:words.firstObject ?: @""] ? 1 : 0;
    for (; i < words.count; i++) {
        NSString *word = words[i];
        NSRange eq = [word rangeOfString:@"="];
        if (eq.location == NSNotFound) break;
        NSString *key = [word substringToIndex:eq.location];
        if ([key rangeOfString:@"^[a-zA-Z_][a-zA-Z_0-9]*$" options:NSRegularExpressionSearch].location == NSNotFound) break;
        environment[key] = [word substringFromIndex:NSMaxRange(eq)];
    }
    return i < words.count ? [words subarrayWithRange:NSMakeRange(i, words.count-i)] : nil;
}

static NSString *MergedCommand(NSString *existing, NSString *wanted) {
    if ([existing isEqual:wanted]) return existing;
    NSMutableDictionary *oldEnv = [NSMutableDictionary dictionary], *newEnv = [NSMutableDictionary dictionary];
    NSArray *oldArgs = CCPetsHookInvocation(existing, oldEnv), *newArgs = CCPetsHookInvocation(wanted, newEnv);
    NSMutableArray *extra = [NSMutableArray array];
    for (NSString *key in [oldEnv.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (newEnv[key] || [@[@"CC_PETS_BUS_HOOK", @"CODEX_PET_AGENT_HOOK", @"CLAUDE_PET_AGENT_HOOK"] containsObject:key]) continue;
        [extra addObject:[NSString stringWithFormat:@"%@=%@", key, CCPetsShellQuote(oldEnv[key])]];
        [oldEnv removeObjectForKey:key];
    }
    if ([oldArgs isEqual:newArgs] && [oldEnv isEqual:newEnv]) return existing;
    [extra addObject:wanted];
    return [extra componentsJoinedByString:@" "];
}

static BOOL IsObject(id item) {
    return [item isKindOfClass:CCPetsJSONObject.class] || [item isKindOfClass:NSDictionary.class];
}
static NSString *HandlerRole(id handler, NSString *(^role)(id)) {
    if (!IsObject(handler) || (handler[@"type"] && ![handler[@"type"] isEqual:@"command"])) return nil;
    return role(handler[@"command"]);
}

static BOOL SameMatcher(id a, id b) {
    if ([a isEqual:b] || a == b) return YES;
    return (!a || [a isEqual:@"*"] || [a isEqual:@""]) && (!b || [b isEqual:@"*"] || [b isEqual:@""]);
}

static CCPetsJSONObject *UpdatedHandler(CCPetsJSONObject *handler, id expected) {
    CCPetsJSONObject *result = [handler copy];
    for (NSString *key in @[@"type", @"command", @"timeout", @"asyncRewake"]) {
        id value = expected[key], old = handler[key];
        if ([key isEqual:@"command"]) value = MergedCommand(old, value);
        if (value) {
            if ([old isKindOfClass:CCPetsJSONNumber.class] && [value isKindOfClass:NSNumber.class] &&
                [[NSDecimalNumber decimalNumberWithString:[old literal]] isEqualToNumber:value]) continue;
            result[key] = value;
        } else if (old && !([key isEqual:@"asyncRewake"] && [old isEqual:@NO])) [result removeObjectForKey:key];
    }
    return result;
}

NSArray *CCPetsMergeHookEntries(id current, NSArray *desired, BOOL grouped, NSString *(^role)(id)) {
    if (current && ![current isKindOfClass:NSArray.class])
        [NSException raise:@"CCPetsHooks" format:@"Expected an array of hook entries"];
    NSMutableDictionary *expected = [NSMutableDictionary dictionary], *matchers = [NSMutableDictionary dictionary];
    for (id entry in desired) {
        id handler = grouped ? [entry[@"hooks"] firstObject] : entry;
        NSString *key = role(handler[@"command"]);
        if (!key) [NSException raise:@"CCPetsHooks" format:@"Unrecognized generated hook"];
        expected[key] = handler;
        if (grouped && entry[@"matcher"]) matchers[key] = entry[@"matcher"];
    }

    // Prefer an existing equivalent handler over a stale duplicate, preserving its trust index.
    NSMutableDictionary *selected = [NSMutableDictionary dictionary], *ranks = [NSMutableDictionary dictionary];
    for (id entry in current) {
        if (!IsObject(entry)) continue;
        NSArray *handlers = grouped ? entry[@"hooks"] : @[entry];
        if (![handlers isKindOfClass:NSArray.class]) continue;
        for (id handler in handlers) {
            NSString *key = HandlerRole(handler, role);
            if (!key || !expected[key]) continue;
            NSUInteger rank = SameMatcher(entry[@"matcher"], matchers[key]) ? 2 : 0;
            if ([CCPetsJSONStringify(handler) isEqual:CCPetsJSONStringify(UpdatedHandler(handler, expected[key]))]) rank++;
            if (!selected[key] || rank > [ranks[key] unsignedIntegerValue]) {
                selected[key] = handler;
                ranks[key] = @(rank);
            }
        }
    }
    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet *placed = [NSMutableSet set];
    NSMutableDictionary *relocated = [NSMutableDictionary dictionary];
    for (id entry in current) {
        NSArray *handlers = IsObject(entry) ? (grouped ? entry[@"hooks"] : @[entry]) : nil;
        if (![handlers isKindOfClass:NSArray.class] || !handlers.count) { [result addObject:entry]; continue; }
        NSMutableArray *kept = [NSMutableArray array];
        BOOL touched = NO;
        id matcher = entry[@"matcher"];
        for (id handler in handlers) {
            NSString *key = HandlerRole(handler, role);
            if (!key) { [kept addObject:handler]; continue; }
            touched = YES;
            if (selected[key] != handler) continue;
            id updated = UpdatedHandler(handler, expected[key]);
            if (grouped && !SameMatcher(matcher, matchers[key]) && handlers.count > 1) {
                relocated[key] = updated;
                continue;
            }
            if (!SameMatcher(matcher, matchers[key])) matcher = matchers[key];
            [kept addObject:updated];
            [placed addObject:key];
        }
        if (!touched) [result addObject:entry];
        else if (!grouped) [result addObjectsFromArray:kept];
        else {
            CCPetsJSONObject *group = [entry copy];
            if (matcher) group[@"matcher"] = matcher;
            else [group removeObjectForKey:@"matcher"];
            group[@"hooks"] = kept;
            // Empty unrelated groups or groups carrying user metadata still belong to the user.
            if (kept.count || group.keys.count > (matcher ? 2U : 1U)) [result addObject:group];
        }
    }
    for (id entry in desired) {
        id handler = grouped ? [entry[@"hooks"] firstObject] : entry;
        NSString *key = role(handler[@"command"]);
        if ([placed containsObject:key]) continue;
        if (relocated[key]) {
            CCPetsJSONObject *copy = [CCPetsJSONObject new];
            if (matchers[key]) copy[@"matcher"] = matchers[key];
            copy[@"hooks"] = @[relocated[key]];
            [result addObject:copy];
        } else [result addObject:entry];
    }
    return result;
}

BOOL CCPetsMergeAllows(CCPetsJSONObject *document, NSArray *wanted, NSSet *revoke) {
    CCPetsJSONObject *permissions = document[@"permissions"];
    if (permissions && ![permissions isKindOfClass:CCPetsJSONObject.class])
        [NSException raise:@"CCPetsPermissions" format:@"Expected a permissions object"];
    NSArray *current = permissions[@"allow"];
    if (current && ![current isKindOfClass:NSArray.class])
        [NSException raise:@"CCPetsPermissions" format:@"Expected an allow array"];
    NSMutableArray *next = [NSMutableArray array];
    for (id rule in current) {
        if ([wanted containsObject:rule] && [next containsObject:rule]) continue;
        if (![revoke containsObject:rule] || [wanted containsObject:rule]) [next addObject:rule];
    }
    for (NSString *rule in wanted) {
        if ([next containsObject:rule]) continue;
        BOOL restricted = NO;
        for (NSString *key in @[@"ask", @"deny"]) {
            id rules = permissions[key];
            if ([rules isKindOfClass:NSArray.class] && [rules containsObject:rule]) restricted = YES;
        }
        if (!restricted) [next addObject:rule];
    }
    if ([next isEqual:current ?: @[]]) return NO;
    permissions = permissions ?: [CCPetsJSONObject new];
    if (next.count) permissions[@"allow"] = next;
    else [permissions removeObjectForKey:@"allow"];
    if (permissions.keys.count) document[@"permissions"] = permissions;
    else [document removeObjectForKey:@"permissions"];
    return YES;
}
