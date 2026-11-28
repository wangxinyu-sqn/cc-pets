#import "CCPetsSlackConfiguration.h"
#import "CCPetsBridge.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsL10n.h"
#import <Security/Security.h>
#import <sys/stat.h>
#import <fcntl.h>

NSString *CCBridgeSlackConfigPath(void) {
    return [CCBridgeHomeDirectory() stringByAppendingPathComponent:@"bridge-remote.json"];
}

static BOOL Matches(id value, NSString *pattern) {
    return [value isKindOfClass:NSString.class] && [value rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}

BOOL CCBridgeSlackValidChannel(NSString *channel) {
    return Matches(channel, @"^[CG][A-Z0-9]+\\z");
}

BOOL CCBridgeSlackValidHostName(NSString *name) {
    return Matches(name, @"^[A-Za-z0-9][A-Za-z0-9._-]{0,39}\\z");
}

static BOOL ValidConfiguration(NSDictionary *config) {
    if (![config isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *versions = config[@"credential_versions"];
    if (versions && ![versions isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[@"app_token", @"bot_token"]) {
        if (versions[key] && (![versions[key] isKindOfClass:NSString.class] ||
            ![[NSUUID alloc] initWithUUIDString:versions[key]])) return NO;
        NSString *reference = config[key];
        if (!reference) continue;
        if (![reference isKindOfClass:NSString.class]) return NO;
        if (!reference.length) continue;
        NSString *prefix = @"keychain:";
        if (![reference hasPrefix:prefix] || ![[NSUUID alloc] initWithUUIDString:[reference substringFromIndex:prefix.length]]) return NO;
    }
    if (config[@"enabled"] && CFGetTypeID((__bridge CFTypeRef)config[@"enabled"]) != CFBooleanGetTypeID()) return NO;
    NSArray *agents = config[@"agents"];
    NSDictionary *discovery = [config[@"discovery"] isKindOfClass:NSDictionary.class] ? config[@"discovery"] : nil;
    if (config[@"discovery"] && (!discovery || !CCBridgeSlackValidChannel(discovery[@"channel"]) ||
        (discovery[@"name"] && !CCBridgeSlackValidHostName(discovery[@"name"])))) return NO;
    if (agents && ![agents isKindOfClass:NSArray.class]) return NO;
    if (!discovery && !agents.count && [config[@"enabled"] boolValue]) return NO;
    NSMutableSet *names = [NSMutableSet set], *endpoints = [NSMutableSet set];
    for (id item in agents) {
        if (![item isKindOfClass:NSDictionary.class]) return NO;
        NSDictionary *agent = item;
        NSString *name = agent[@"name"], *bot = agent[@"bot_id"], *user = agent[@"user_id"], *channel = agent[@"channel"];
        if (agent[@"bridge"] && CFGetTypeID((__bridge CFTypeRef)agent[@"bridge"]) != CFBooleanGetTypeID()) return NO;
        if (![name isKindOfClass:NSString.class] || ![CCBridgeNormalizeSessionName(name) isEqual:name] || !Matches(bot, @"^B[A-Z0-9]+\\z") ||
            !Matches(user, @"^[UW][A-Z0-9]+\\z") || !Matches(channel, @"^[CG][A-Z0-9]+\\z")) return NO;
        NSString *endpoint = [NSString stringWithFormat:@"%@/%@", channel, bot];
        if ([names containsObject:name] || [endpoints containsObject:endpoint]) return NO;
        [names addObject:name];
        [endpoints addObject:endpoint];
    }
    return YES;
}

static NSDictionary *ReadRemoteConfiguration(NSString *path) {
    if ([path.lastPathComponent isEqual:@"bridge-slack.json"]) return nil;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return nil;
    NSFileHandle *file = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode)) return nil;
    NSData *data = [file readDataToEndOfFileAndReturnError:nil];
    id root = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [root isKindOfClass:NSDictionary.class] ? root : nil;
}

NSDictionary *CCBridgeSlackLoadConfiguration(NSString *path) {
    NSDictionary *config = ReadRemoteConfiguration(path)[@"slack"];
    return ValidConfiguration(config) ? config : nil;
}

BOOL CCBridgeSlackAutoStartEnabled(NSDictionary *config) {
    return [config[@"enabled"] boolValue] && [config[@"app_token"] length] && [config[@"bot_token"] length];
}

static NSMutableDictionary *CredentialQuery(NSString *path, NSString *key, NSString *identifier) {
    NSURL *directory = [NSURL fileURLWithPath:path].URLByDeletingLastPathComponent;
    NSString *canonicalPath = [directory.URLByStandardizingPath.URLByResolvingSymlinksInPath.path stringByAppendingPathComponent:path.lastPathComponent];
    NSString *scope = CCBridgeSHA1Hex(canonicalPath);
    return [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService: [@"CC Pets Slack." stringByAppendingString:scope],
              (__bridge id)kSecAttrAccount: [NSString stringWithFormat:@"%@.%@", key, identifier]} mutableCopy];
}

static NSString *KeychainError(OSStatus status) {
    return CFBridgingRelease(SecCopyErrorMessageString(status, NULL)) ?: L(@"Keychain is unavailable.");
}

static OSStatus ReadItemData(NSDictionary *item, NSData **data) {
    NSMutableDictionary *query = [item mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    *data = CFBridgingRelease(result);
    return status;
}

// Raw UTF-8 items from previous builds are the initial version. During rotation both
// values live in the same protected item until the atomic config write selects the new one.
static NSString *TokenForVersion(NSData *data, NSString *version) {
    if (!data) return nil;
    NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!version && ([raw hasPrefix:@"xapp-"] || [raw hasPrefix:@"xoxb-"])) return raw;
    id values = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
    id value = [values isKindOfClass:NSDictionary.class] ? values[version ?: @"initial"] : nil;
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSData *TokenData(NSDictionary *values) {
    return [NSPropertyListSerialization dataWithPropertyList:values format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
}

static OSStatus UpdateItem(NSDictionary *item, NSData *data) {
    return SecItemUpdate((__bridge CFDictionaryRef)item,
        (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: data});
}

NSString *CCBridgeSlackReadToken(NSString *path, NSDictionary *config, NSString *key, NSError **error) {
    NSString *identifier = config[key];
    if (!identifier.length) return nil;
    NSData *data = nil;
    OSStatus status = ReadItemData(CredentialQuery(path, key, identifier), &data);
    NSString *token = status == errSecSuccess ? TokenForVersion(data, config[@"credential_versions"][key]) : nil;
    if (!token && error) {
        if (status == errSecSuccess) status = errSecDecode;
        NSString *reason = status == errSecItemNotFound ? L(@"Enter the token again.") : KeychainError(status);
        *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
    return token;
}

static OSStatus StageToken(NSString *path, NSString *key, NSString *token, NSMutableDictionary *next,
    NSMutableDictionary *versions, NSMutableArray *created, NSMutableDictionary *previous, NSMutableDictionary *finalValues) {
    NSString *reference = next[key];
    BOOL existing = reference.length > 0;
    if (!existing) reference = [@"keychain:" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSMutableDictionary *item = CredentialQuery(path, key, reference);
    NSData *data = nil;
    OSStatus status = existing ? ReadItemData(item, &data) : errSecItemNotFound;
    if (status == errSecItemNotFound) {
        item[(__bridge id)kSecAttrLabel] = [key isEqual:@"app_token"] ? @"CC Pets Slack App-Level Token" : @"CC Pets Slack Bot Token";
        item[(__bridge id)kSecValueData] = [token dataUsingEncoding:NSUTF8StringEncoding];
        status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
        if (status == errSecSuccess) {
            next[key] = reference;
            [versions removeObjectForKey:key];
            [created addObject:key];
        }
        return status;
    }
    if (status != errSecSuccess) return status;
    NSString *oldToken = TokenForVersion(data, versions[key]);
    if (!oldToken) return errSecDecode;
    if ([oldToken isEqual:token]) return errSecSuccess;
    NSString *revision = NSUUID.UUID.UUIDString;
    NSData *staged = TokenData(@{versions[key] ?: @"initial": oldToken, revision: token});
    status = UpdateItem(item, staged);
    if (status == errSecSuccess) {
        previous[key] = data;
        finalValues[key] = TokenData(@{revision: token});
        versions[key] = revision;
    }
    return status;
}

BOOL CCBridgeSlackSaveConfiguration(NSDictionary *original, NSDictionary *changes, NSString *appToken,
                                    NSString *botToken, BOOL removeTokens, NSString **error) {
    NSString *path = CCBridgeSlackConfigPath();
    NSMutableDictionary *next = [changes mutableCopy];
    for (NSString *key in @[@"app_token", @"bot_token"]) next[key] = original[key] ?: @"";
    if (!ValidConfiguration(next)) {
        *error = L(@"Check the discovery channel, computer name and bot addresses. Each bot must have a unique name and channel/bot pair.");
        return NO;
    }
    if ((appToken.length && ![appToken hasPrefix:@"xapp-"]) || (botToken.length && ![botToken hasPrefix:@"xoxb-"])) {
        *error = L(@"Use an xapp- App-Level Token and an xoxb- Bot Token.");
        return NO;
    }
    if ([next[@"enabled"] boolValue] && (removeTokens || (!appToken.length && ![original[@"app_token"] length]) ||
                                          (!botToken.length && ![original[@"bot_token"] length]))) {
        *error = L(@"Configure both Slack tokens in Bridge → Remote Connections.");
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *failure = nil;
    if (![fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                        attributes:nil error:&failure]) {
        *error = failure.localizedDescription;
        return NO;
    }
    NSString *lock = nil;
    BOOL committed = NO;
    NSMutableArray *created = [NSMutableArray array];
    NSMutableDictionary *previous = [NSMutableDictionary dictionary], *finalValues = [NSMutableDictionary dictionary];
    NSMutableDictionary *versions = [original[@"credential_versions"] mutableCopy] ?: [NSMutableDictionary dictionary];
    @try {
        lock = CCBridgeAcquireLock(@"remote-configuration");
        NSMutableDictionary *root = [ReadRemoteConfiguration(path) mutableCopy];
        if (!root && ![fm fileExistsAtPath:path]) root = [NSMutableDictionary dictionary];
        NSDictionary *disk = root[@"slack"];
        if (!lock || !root || (disk != original && ![disk isEqual:original])) {
            *error = L(@"Slack configuration changed. Reopen Remote Connections before saving.");
            return NO;
        }
        NSArray *keys = @[@"app_token", @"bot_token"];
        if (removeTokens) {
            // Disable before revocation. Retain the references on failure so removal can be retried.
            root[@"slack"] = next;
            CCBridgeWriteJSON(path, root);
            for (NSString *key in keys) {
                NSString *identifier = original[key];
                if (!identifier.length) continue;
                OSStatus status = SecItemDelete((__bridge CFDictionaryRef)CredentialQuery(path, key, identifier));
                if (status != errSecSuccess && status != errSecItemNotFound) {
                    *error = KeychainError(status);
                    return NO;
                }
            }
        }
        NSDictionary *inputs = @{keys[0]: appToken ?: @"", keys[1]: botToken ?: @""};
        for (NSString *key in keys) {
            if (removeTokens) { next[key] = @""; [versions removeObjectForKey:key]; continue; }
            NSString *token = inputs[key];
            if (!token.length) continue;
            OSStatus status = StageToken(path, key, token, next, versions, created, previous, finalValues);
            if (status != errSecSuccess) { *error = KeychainError(status); return NO; }
        }
        next[@"credential_versions"] = versions.count ? versions : nil;
        root[@"slack"] = next;
        CCBridgeWriteJSON(path, root);
        committed = YES;
    } @catch (NSException *exception) {
        *error = exception.reason;
    } @finally {
        if (lock) {
            // Even if cleanup is denied or the process exits, the published version is readable.
            NSDictionary *cleanup = committed ? finalValues : previous;
            for (NSString *key in cleanup) UpdateItem(CredentialQuery(path, key, next[key]), cleanup[key]);
            if (!committed) {
                for (NSString *key in created) SecItemDelete((__bridge CFDictionaryRef)CredentialQuery(path, key, next[key]));
            }
            CCBridgeReleaseLock(lock);
        }
    }
    return committed;
}
