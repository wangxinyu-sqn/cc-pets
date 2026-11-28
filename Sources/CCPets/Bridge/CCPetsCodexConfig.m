#import "CCPetsCodexConfig.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsCLISupport.h"
#import "CCPetsL10n.h"
#import "CCPetsHookMerge.h"
#import "tomlc17.h"
#import <sys/stat.h>

static NSString *const Begin = @"# >>> cc-bridge >>>";
static NSString *const End = @"# <<< cc-bridge <<<";
static NSString *const InlineMark = @"# cc-pets inline approvals: ";
static NSString *const ResumeMark = @"# cc-pets restore enabled: ";

static void ConfigError(NSString *reason) __attribute__((noreturn));
static void ConfigError(NSString *reason) {
    @throw [NSException exceptionWithName:@"CCBridgeConfig" reason:reason userInfo:nil];
}

// A duplicate table can make the original document unparsable. Locate our comments
// before parsing, taking care never to match text inside a TOML multiline string.
static unichar EndQuote(NSString *line, unichar multiline) {
    unichar quote = multiline;
    for (NSUInteger i = 0; i < line.length;) {
        unichar c = [line characterAtIndex:i++];
        if (quote && c == '\\' && quote == '"') { i++; continue; }
        if (!quote && c == '#') break;
        if ((c != '"' && c != '\'') || (quote && quote != c)) continue;
        NSUInteger run = 1;
        while (i < line.length && [line characterAtIndex:i] == c) { i++; run++; }
        if (multiline) {
            if (run >= 3) quote = multiline = 0;
        } else if (quote) {
            quote = 0;
        } else if (run >= 3 && run < 6) {
            quote = multiline = c;
        } else if (run == 1) {
            quote = c;
        }
    }
    return multiline;
}

static NSString *Trim(NSString *line) {
    return [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// A formatter may move our markers around unrelated settings. Only discard a block
// if its contents still have the shape we wrote. Edited blocks become user-owned.
static BOOL OwnedBlock(NSArray<NSString *> *lines, NSMutableSet *inlineTools, NSString **resume) {
    NSMutableArray *keys = [NSMutableArray array];
    NSString *priorEnabled = nil;
    BOOL needsValue = NO;
    for (NSString *raw in lines) {
        NSString *line = Trim(raw);
        if (!line.length) continue;
        if ([line hasPrefix:InlineMark]) {
            [keys addObjectsFromArray:[[line substringFromIndex:InlineMark.length] componentsSeparatedByString:@","]];
        } else if ([line hasPrefix:ResumeMark]) {
            priorEnabled = [line substringFromIndex:ResumeMark.length];
            if (![@[@"true", @"default"] containsObject:priorEnabled]) return NO;
        } else if ([line hasPrefix:@"# Written by cc-pets "] || [line hasPrefix:@"# 由 cc-pets "]) {
            continue;
        } else if (needsValue && [line isEqual:@"approval_mode = \"approve\""]) {
            needsValue = NO;
        } else if (!needsValue && [line rangeOfString:@"^\\[mcp_servers\\.(cc-bridge|cc-pets-bus)\\.tools\\.[a-z_]+\\]$"
                                             options:NSRegularExpressionSearch].location != NSNotFound) {
            needsValue = YES;
        } else return NO;
    }
    if (needsValue) return NO;
    [inlineTools addObjectsFromArray:keys];
    if (priorEnabled) *resume = priorEnabled;
    return YES;
}

static NSString *ExtractBlock(NSString *text, NSMutableSet *inlineTools, NSString **resume) {
    NSMutableArray *kept = [NSMutableArray array];
    NSString *closing = nil;
    NSUInteger start = 0;
    unichar quote = 0;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *mark = Trim(line);
        if (!quote && ([mark isEqual:Begin] || [mark isEqual:@"# >>> cc-pets-bus >>>"])) {
            start = kept.count;
            closing = [mark isEqual:Begin] ? End : @"# <<< cc-pets-bus <<<";
        } else if (!quote && ([mark isEqual:End] || [mark isEqual:@"# <<< cc-pets-bus <<<"])) {
            if ([mark isEqual:closing]) {
                NSArray *body = [kept subarrayWithRange:NSMakeRange(start + 1, kept.count - start - 1)];
                if (OwnedBlock(body, inlineTools, resume)) {
                    if (start && !Trim(kept[start - 1]).length) start--;
                    [kept removeObjectsInRange:NSMakeRange(start, kept.count - start)];
                } else [kept removeObjectAtIndex:start];
            }
            closing = nil;
            continue;
        }
        [kept addObject:line];
        quote = EndQuote(line, quote);
    }
    return [kept componentsJoinedByString:@"\n"];
}

static NSString *StringValue(toml_datum_t value) {
    if (value.type != TOML_STRING) return nil;
    return [[NSString alloc] initWithBytes:value.u.str.ptr length:value.u.str.len encoding:NSUTF8StringEncoding];
}

static NSString *Literal(id value) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:value
        options:NSJSONWritingFragmentsAllowed | NSJSONWritingWithoutEscapingSlashes error:nil];
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}

// Collect byte spans, including each table header. Inline assignments already own
// their nested values, so they are removed as a unit. Synthesized dotted parents
// have no source span of their own.
static void CollectEntries(toml_datum_t node, NSMutableArray<NSValue *> *entries) {
    if (node.end) [entries addObject:[NSValue value:&node withObjCType:@encode(toml_datum_t)]];
    if (node.end && node.key_begin != node.value_begin) return;
    if (node.type == TOML_TABLE)
        for (int i = 0; i < node.u.tab.size; i++) CollectEntries(node.u.tab.value[i], entries);
    if (node.type == TOML_ARRAY)
        for (int i = 0; i < node.u.arr.size; i++) CollectEntries(node.u.arr.elem[i], entries);
}

@interface CCPetsTomlEditor : NSObject {
    toml_result_t _parsed;
    NSMutableData *_bytes;
}
@property(nonatomic, readonly) NSString *text;
@property(nonatomic, readonly) NSString *newline;
- (instancetype)initWithText:(NSString *)text;
- (toml_datum_t)node:(NSArray<NSString *> *)path;
- (void)put:(NSString *)literal at:(NSArray<NSString *> *)path;
- (void)remove:(NSArray<NSString *> *)path;
@end

@implementation CCPetsTomlEditor
- (instancetype)initWithText:(NSString *)text {
    if ((self = [super init])) {
        _bytes = [[text dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        _newline = [text containsString:@"\r\n"] ? @"\r\n" : @"\n";
        [self parse];
    }
    return self;
}
- (void)parse {
    if (_parsed.ok) toml_free(_parsed);
    _parsed = (toml_result_t){0};
    if (_bytes.length > INT_MAX) ConfigError(@"config.toml is too large");
    _parsed = toml_parse(_bytes.bytes ?: "", (int)_bytes.length);
    if (!_parsed.ok) ConfigError(@(_parsed.errmsg));
}
- (void)dealloc { if (_parsed.ok) toml_free(_parsed); }
- (NSString *)text { return [[NSString alloc] initWithData:_bytes encoding:NSUTF8StringEncoding]; }
- (toml_datum_t)node:(NSArray<NSString *> *)path {
    toml_datum_t node = _parsed.toptab;
    for (NSString *key in path) {
        if (node.type == TOML_UNKNOWN) return node;
        if (node.type != TOML_TABLE) ConfigError([NSString stringWithFormat:@"Expected table on path %@", [path componentsJoinedByString:@"."]]);
        node = toml_get(node, key.UTF8String);
    }
    return node;
}
- (void)put:(NSString *)literal at:(NSArray<NSString *> *)path {
    toml_datum_t scope = _parsed.toptab, node = scope;
    NSUInteger prefix = 0;
    for (NSUInteger i = 0; i < path.count; i++) {
        if (node.type != TOML_TABLE) ConfigError(@"Expected a table in the cc-bridge registration");
        node = toml_get(node, path[i].UTF8String);
        if (node.type == TOML_UNKNOWN) break;
        if (i + 1 < path.count && node.end) { scope = node; prefix = i + 1; }
    }
    NSRange range;
    NSString *replacement = literal;
    const uint8_t *bytes = _bytes.bytes;
    if (node.type != TOML_UNKNOWN) {
        if (!node.end || node.key_begin == node.value_begin) ConfigError(@"Cannot replace a TOML table with a scalar");
        range = NSMakeRange(node.value_begin, node.end - node.value_begin);
    } else {
        NSString *key = [[path subarrayWithRange:NSMakeRange(prefix, path.count - prefix)] componentsJoinedByString:@"."];
        NSString *assignment = [NSString stringWithFormat:@"%@ = %@", key, literal];
        NSUInteger offset = 0;
        if (scope.end && scope.key_begin != scope.value_begin) {
            offset = scope.value_begin + 1; // directly after '{'
            replacement = scope.u.tab.size ? [assignment stringByAppendingString:@", "] : assignment;
        } else {
            offset = scope.end;
            if (scope.end) {
                while (offset < _bytes.length && bytes[offset] != '\n') offset++;
                if (offset < _bytes.length) offset++;
            }
            NSString *separator = offset && bytes[offset-1] != '\n' ? _newline : @"";
            replacement = [NSString stringWithFormat:@"%@%@%@", separator, assignment, _newline];
        }
        range = NSMakeRange(offset, 0);
    }
    [_bytes replaceBytesInRange:range withBytes:replacement.UTF8String length:[replacement lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
    [self parse];
}

- (void)remove:(NSArray<NSString *> *)path {
    NSMutableArray<NSValue *> *entries = [NSMutableArray array];
    CollectEntries([self node:path], entries);
    if (!entries.count) return;
    [entries sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        toml_datum_t x, y;
        [a getValue:&x size:sizeof x]; [b getValue:&y size:sizeof y];
        return [@(y.key_begin) compare:@(x.key_begin)];
    }];
    for (NSValue *entry in entries) {
        toml_datum_t value;
        [entry getValue:&value size:sizeof value];
        NSUInteger start = value.key_begin, end = value.end;
        const uint8_t *bytes = _bytes.bytes;
        if (value.inline_comma > 0) {
            // Remove the separator separately; keep comments between it and the key.
            [_bytes replaceBytesInRange:NSMakeRange(start, end - start) withBytes:NULL length:0];
            start = value.inline_comma - 1;
            end = start + 1;
        } else if (value.inline_comma < 0) {
            // First member: remove the following comma if one remains.
            NSUInteger i = end;
            while (i < _bytes.length) {
                if (bytes[i] == '#') { while (i < _bytes.length && bytes[i] != '\n') i++; }
                else if (strchr(" \t\r\n", bytes[i])) i++;
                else break;
            }
            if (i < _bytes.length && bytes[i] == ',') [_bytes replaceBytesInRange:NSMakeRange(i, 1) withBytes:NULL length:0];
        } else {
            while (start && (bytes[start-1] == ' ' || bytes[start-1] == '\t')) start--;
            while (end < _bytes.length && strchr(" \t\r", bytes[end])) end++;
            if (end < _bytes.length && bytes[end] == '\n') end++;
        }
        [_bytes replaceBytesInRange:NSMakeRange(start, end - start) withBytes:NULL length:0];
    }
    [self parse];
}
@end

static BOOL OwnsTransport(toml_datum_t server) {
    if (server.type != TOML_TABLE || toml_get(server, "url").type != TOML_UNKNOWN) return NO;
    toml_datum_t cmd = toml_get(server, "command"), args = toml_get(server, "args");
    if (cmd.type == TOML_UNKNOWN && args.type == TOML_UNKNOWN)
        return toml_get(server, "tools").type == TOML_TABLE || toml_get(server, "default_tools_approval_mode").type != TOML_UNKNOWN;
    if (args.type != TOML_ARRAY || args.u.arr.size < 2) return NO;
    return CCPetsIsBridgeTransport(StringValue(cmd), @[StringValue(args.u.arr.elem[0]) ?: @"", StringValue(args.u.arr.elem[1]) ?: @""]);
}

static BOOL HasUserServerFields(toml_datum_t server) {
    for (int i = 0; i < server.u.tab.size; i++) {
        NSString *key = [[NSString alloc] initWithBytes:server.u.tab.key[i] length:server.u.tab.len[i] encoding:NSUTF8StringEncoding];
        if ([key isEqual:@"command"]) continue;
        toml_datum_t value = server.u.tab.value[i];
        if ([key isEqual:@"args"] && value.type == TOML_ARRAY && value.u.arr.size == 2) continue;
        if ([key isEqual:@"tools"] && value.type == TOML_TABLE && !value.u.tab.size) continue;
        if ([key isEqual:@"env"] && value.type == TOML_TABLE && (!value.u.tab.size ||
            (value.u.tab.size == 1 && toml_get(value, "CODEX_REAL_BIN").type != TOML_UNKNOWN))) continue;
        return YES;
    }
    return NO;
}

static void SetTransport(CCPetsTomlEditor *editor, NSArray *server, NSString *binary, NSString *codex) {
    if ([editor node:[server arrayByAddingObject:@"url"]].type != TOML_UNKNOWN)
        ConfigError(@"cc-bridge already uses an HTTP transport");
    NSArray *command = [server arrayByAddingObject:@"command"];
    if (![StringValue([editor node:command]) isEqual:binary]) [editor put:Literal(binary) at:command];
    NSArray *argsPath = [server arrayByAddingObject:@"args"];
    toml_datum_t args = [editor node:argsPath];
    if (args.type != TOML_ARRAY || args.u.arr.size < 2 || ![StringValue(args.u.arr.elem[0]) isEqual:@"bridge"] ||
        ![StringValue(args.u.arr.elem[1]) isEqual:@"mcp"]) {
        NSMutableArray *arguments = [NSMutableArray arrayWithObjects:@"bridge", @"mcp", nil];
        for (int i = 2; args.type == TOML_ARRAY && i < args.u.arr.size; i++) {
            NSString *argument = StringValue(args.u.arr.elem[i]);
            if (!argument) ConfigError(@"Expected a string in cc-bridge.args");
            [arguments addObject:argument];
        }
        [editor put:Literal(arguments) at:argsPath];
    }
    NSArray *env = [server arrayByAddingObjectsFromArray:@[@"env", @"CODEX_REAL_BIN"]];
    if (!codex.length) [editor remove:env];
    else if (![StringValue([editor node:env]) isEqual:codex]) [editor put:Literal(codex) at:env];
}

static NSString *ReconciledText(NSString *original, CCPetsCodexConfigMode mode, NSArray<NSString *> *wanted, NSString *codex) {
    NSMutableSet<NSString *> *inlineTools = [NSMutableSet set];
    NSString *resume = nil;
    NSString *base = ExtractBlock(original, inlineTools, &resume);
    CCPetsTomlEditor *editor = [[CCPetsTomlEditor alloc] initWithText:base];
    BOOL registering = mode == CCPetsCodexRegister, unregistering = mode == CCPetsCodexUnregister;
    NSArray *server = @[@"mcp_servers", @"cc-bridge"], *tools = [server arrayByAddingObject:@"tools"];
    toml_datum_t existing = [editor node:server];
    if (existing.type != TOML_UNKNOWN && !OwnsTransport(existing)) {
        if (unregistering || (!registering && !wanted.count)) return original;
        ConfigError(@"The cc-bridge server name is in use by another transport");
    }
    NSArray *legacy = @[@"mcp_servers", @"cc-pets-bus"];
    toml_datum_t old = [editor node:legacy];
    if ((registering || unregistering) && OwnsTransport(old)) {
        if (HasUserServerFields(old)) ConfigError(@"Legacy cc-pets-bus has custom settings; migrate its registration first");
        [editor remove:legacy];
    }
    for (NSString *key in inlineTools.allObjects) {
        NSArray *path = [tools arrayByAddingObject:key];
        toml_datum_t item = [editor node:path];
        if (item.type != TOML_TABLE || item.u.tab.size != 1 || ![StringValue(toml_get(item, "approval_mode")) isEqual:@"approve"])
            [inlineTools removeObject:key]; // the user has changed this entry
        else if (![wanted containsObject:key]) {
            [editor remove:path];
            [inlineTools removeObject:key];
        }
    }
    NSArray *enabledPath = [server arrayByAddingObject:@"enabled"];
    toml_datum_t enabled = [editor node:enabledPath];
    toml_datum_t rules = [editor node:tools];
    if (rules.type != TOML_UNKNOWN && rules.type != TOML_TABLE) ConfigError(@"Expected a table for cc-bridge.tools");
    if (registering) {
        if (resume && enabled.type == TOML_BOOLEAN && !enabled.u.boolean) {
            if ([resume isEqual:@"true"]) [editor put:@"true" at:enabledPath];
            else [editor remove:enabledPath];
        }
        resume = nil;
        SetTransport(editor, server, CCPetsExecutablePath(), codex);
    } else if (unregistering && [editor node:server].type != TOML_UNKNOWN) {
        if (HasUserServerFields([editor node:server])) {
            // Keep the complete transport usable when the user enables it again.
            if (enabled.type == TOML_UNKNOWN || (enabled.type == TOML_BOOLEAN && enabled.u.boolean)) {
                resume = enabled.type == TOML_UNKNOWN ? @"default" : @"true";
                [editor put:@"false" at:enabledPath];
            }
            if ([editor node:[server arrayByAddingObject:@"url"]].type == TOML_UNKNOWN &&
                [editor node:[server arrayByAddingObject:@"command"]].type == TOML_UNKNOWN)
                SetTransport(editor, server, CCPetsExecutablePath(), codex);
        } else {
            [editor remove:server];
            resume = nil;
        }
    }
    NSMutableArray *missing = [NSMutableArray array];
    for (NSString *key in wanted) {
        NSArray *path = [tools arrayByAddingObject:key];
        if ([editor node:path].type != TOML_UNKNOWN) continue;
        // An inline table cannot be extended with a [table] header at EOF.
        if (([editor node:@[@"mcp_servers"]].flag | [editor node:server].flag | [editor node:tools].flag) & TOML_FLAG_INLINED) {
            [editor put:@"{ approval_mode = \"approve\" }" at:path];
            [inlineTools addObject:key];
        } else [missing addObject:key];
    }
    NSMutableString *candidate = [editor.text mutableCopy];
    if (resume || inlineTools.count || missing.count) {
        NSMutableArray *block = [NSMutableArray arrayWithObjects:Begin,
            L(@"# Written by cc-pets bridge enable / configure; cc-pets bridge disable removes it."), nil];
        if (resume) [block addObject:[ResumeMark stringByAppendingString:resume]];
        if (inlineTools.count) {
            NSArray *ordered = [inlineTools.allObjects sortedArrayUsingSelector:@selector(compare:)];
            [block addObject:[InlineMark stringByAppendingString:[ordered componentsJoinedByString:@","]]];
        }
        for (NSString *key in missing) {
            [block addObjectsFromArray:@[[NSString stringWithFormat:@"[mcp_servers.cc-bridge.tools.%@]", key],
                                         @"approval_mode = \"approve\"", @""]];
        }
        [block addObject:End];
        if (candidate.length && ![candidate hasSuffix:@"\n"]) [candidate appendString:editor.newline];
        if (candidate.length) [candidate appendString:editor.newline];
        [candidate appendString:[block componentsJoinedByString:editor.newline]];
        [candidate appendString:editor.newline];
    }
    // Validate the complete file, including the approvals appended after editing.
    return [[[CCPetsTomlEditor alloc] initWithText:candidate] text];
}

void CCBridgeReconcileCodexConfig(NSString *home, CCPetsCodexConfigMode mode, NSArray<NSString *> *tools, NSString *codex) {
    NSString *file = [[home stringByAppendingPathComponent:@"config.toml"] stringByResolvingSymlinksInPath];
    CCBridgeWithLock([@"codex-config-" stringByAppendingString:CCBridgeSHA1Hex(file)], ^id {
        struct stat info;
        BOOL exists = stat(file.fileSystemRepresentation, &info) == 0;
        if (!exists && errno != ENOENT) ConfigError([NSString stringWithFormat:@"%@: %s", file, strerror(errno)]);
        NSData *before = exists ? [NSData dataWithContentsOfFile:file] : nil;
        if (exists && !before) ConfigError([NSString stringWithFormat:@"Cannot read %@", file]);
        NSString *original = exists ? [[NSString alloc] initWithData:before encoding:NSUTF8StringEncoding] : @"";
        if (!original) ConfigError([NSString stringWithFormat:@"Cannot read UTF-8 from %@", file]);
        NSString *candidate;
        @try { candidate = ReconciledText(original, mode, tools, codex); }
        @catch (NSException *error) { ConfigError([NSString stringWithFormat:@"%@: %@", file, error.reason]); }
        if ([candidate isEqual:original]) return nil;
        NSData *current = [NSData dataWithContentsOfFile:file];
        if ((exists && ![current isEqual:before]) || (!exists && [NSFileManager.defaultManager fileExistsAtPath:file]))
            ConfigError([NSString stringWithFormat:@"%@ changed during the update; retry", file]);
        if (before.length >= 3 && !memcmp(before.bytes, "\xEF\xBB\xBF", 3)) candidate = [@"\uFEFF" stringByAppendingString:candidate];
        NSString *error = nil;
        if (!CCPetsWriteFileAtomically(file, candidate, exists ? info.st_mode & 0777 : 0600, &error)) ConfigError(error);
        return nil;
    });
}
