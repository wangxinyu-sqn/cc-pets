#import "CCPetsVersion.h"
#import <signal.h>
#import <unistd.h>
#import <errno.h>

static NSArray<NSNumber *> *StableVersionComponents(NSString *version) {
    if (![version isKindOfClass:NSString.class]) return nil;
    NSArray<NSString *> *parts = [version componentsSeparatedByString:@"."];
    if (parts.count != 3) return nil;
    NSCharacterSet *nonDigits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet;
    NSMutableArray<NSNumber *> *components = [NSMutableArray arrayWithCapacity:3];
    for (NSString *part in parts) {
        if (part.length == 0 || part.length > 9 ||
            (part.length > 1 && [part hasPrefix:@"0"]) ||
            [part rangeOfCharacterFromSet:nonDigits].location != NSNotFound) return nil;
        [components addObject:@(part.longLongValue)];
    }
    return components;
}

NSComparisonResult CompareStableVersions(NSString *left, NSString *right, BOOL *valid) {
    NSArray<NSNumber *> *leftParts = StableVersionComponents(left);
    NSArray<NSNumber *> *rightParts = StableVersionComponents(right);
    if (!leftParts || !rightParts) {
        if (valid) *valid = NO;
        return NSOrderedSame;
    }
    if (valid) *valid = YES;
    for (NSUInteger index = 0; index < 3; index++) {
        long long leftValue = leftParts[index].longLongValue;
        long long rightValue = rightParts[index].longLongValue;
        if (leftValue < rightValue) return NSOrderedAscending;
        if (leftValue > rightValue) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

int RestartAfterPID(pid_t pid, NSString *appPath, BOOL managed) {
    for (NSUInteger attempt = 0; attempt < 300; attempt++) {
        if (pid <= 1 || (kill(pid, 0) != 0 && errno == ESRCH)) break;
        usleep(100000);
    }
    if (pid > 1 && (kill(pid, 0) == 0 || errno == EPERM)) {
        fprintf(stderr, "等待旧版 CC Pets 退出超时。\n");
        return EXIT_FAILURE;
    }

    NSString *openPath = NSProcessInfo.processInfo.environment[@"CC_PETS_OPEN_PATH"];
    if (openPath.length == 0) openPath = @"/usr/bin/open";
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:openPath];
    NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObjects:@"-g", appPath, nil];
    if (managed) [arguments addObjectsFromArray:@[@"--args", @"--managed"]];
    task.arguments = arguments;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        fprintf(stderr, "无法重新启动 CC Pets: %s\n", error.localizedDescription.UTF8String);
        return EXIT_FAILURE;
    }
    [task waitUntilExit];
    return task.terminationStatus == EXIT_SUCCESS ? EXIT_SUCCESS : EXIT_FAILURE;
}

// 刚发布的版本存在 packument 传播与本机 npm 缓存的竞态：registry 的 /latest 已经报出
// 新版本，而同一时刻 `npm install cc-pets@<新版本>` 解析到的包元数据可能还是旧的，
// 直接报 ETARGET。这类失败重试一次通常就好，不该当成"装不上"弹错误框。
// 网络类错误同理。真正的失败（EACCES、ENOSPC、脚本报错等）不在此列，必须如实上报。
BOOL UpdateFailureIsTransient(NSString *log) {
    if (log.length == 0) return NO;
    static NSArray<NSString *> *markers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        markers = @[@"ETARGET", @"ENOTFOUND", @"EAI_AGAIN", @"ETIMEDOUT", @"ECONNRESET",
                    @"ERR_SOCKET_TIMEOUT", @"ECONNREFUSED", @"ERR_SSL", @"429", @"503"];
    });
    for (NSString *marker in markers) {
        if ([log rangeOfString:marker options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}
