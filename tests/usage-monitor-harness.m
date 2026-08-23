#import <Foundation/Foundation.h>
#import "CCPetsUsageMonitor.h"
#import "CCPetsPaths.h"

static NSData *CodexLine(double five, double week) {
    NSString *line = [NSString stringWithFormat:
        @"{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\","
         "\"rate_limits\":{\"primary\":{\"window_minutes\":300,\"used_percent\":%.1f},"
         "\"secondary\":{\"window_minutes\":10080,\"used_percent\":%.1f}}}}\n",
        five, week];
    return [line dataUsingEncoding:NSUTF8StringEncoding];
}

int main(void) {
    @autoreleasepool {
        NSString *codexHome = NSProcessInfo.processInfo.environment[@"CC_PETS_CODEX_HOME"];
        NSString *sessionDirectory = [codexHome stringByAppendingPathComponent:@"sessions/2026/07/31"];
        [NSFileManager.defaultManager createDirectoryAtPath:sessionDirectory
            withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *sessionPath = [sessionDirectory stringByAppendingPathComponent:@"rollout-test.jsonl"];
        [CodexLine(10, 20) writeToFile:sessionPath atomically:NO];

        __block BOOL succeeded = NO;
        CCPetsUsageMonitor *monitor = [CCPetsUsageMonitor new];
        __weak CCPetsUsageMonitor *weakMonitor = monitor;
        // 额度快照文件还没写出来时，reader 给的是 @{@"week": NSNull}（缺额度不该否决
        // Token 统计，见 ClaudeUsageReader.refresh）。两条数据源各走各的事件流，谁先到达
        // 没有保证，因此这里按"还没到齐"处理，继续等下一次回调，而不是直接下标 NSNull。
        monitor.changeHandler = ^(NSDictionary *codex, NSDictionary *claude) {
            NSDictionary *codexWeek = [codex[@"week"] isKindOfClass:NSDictionary.class]
                ? codex[@"week"] : nil;
            NSDictionary *claudeWeek = [claude[@"week"] isKindOfClass:NSDictionary.class]
                ? claude[@"week"] : nil;
            if ([codexWeek[@"used_percent"] doubleValue] == 88.0 &&
                [claudeWeek[@"used_percentage"] doubleValue] == 22.0) {
                succeeded = YES;
                [weakMonitor stop];
                CFRunLoopStop(CFRunLoopGetMain());
            }
        };
        [monitor start];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{
                NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:sessionPath];
                [handle seekToEndOfFile];
                [handle writeData:CodexLine(77, 88)];
                [handle closeFile];
                NSData *claude = [NSJSONSerialization dataWithJSONObject:@{
                    @"five_hour": @{@"used_percentage": @11},
                    @"seven_day": @{@"used_percentage": @22}
                } options:0 error:nil];
                // 状态目录要自己建：监听侧是异步启动的，不能指望它先于这次写入把目录建出来
                // ——目录不存在时 writeToFile: 只会静默失败，测试会退化成干等超时。
                NSString *claudePath = ClaudeUsagePath();
                [NSFileManager.defaultManager
                    createDirectoryAtPath:claudePath.stringByDeletingLastPathComponent
                    withIntermediateDirectories:YES attributes:nil error:nil];
                [claude writeToFile:claudePath options:NSDataWritingAtomic error:nil];
            });
        // 某些受限 CI 沙箱不允许连接 fseventsd；这种情况下验证 120 秒兜底所用的
        // 同一 refreshNow 路径。正常系统收到 FSEvents 后会在此之前结束。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{ [weakMonitor refreshNow]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
                [weakMonitor stop];
                CFRunLoopStop(CFRunLoopGetMain());
            });
        CFRunLoopRun();
        if (!succeeded) {
            fputs("额度事件监听运行时测试超时\n", stderr);
            return EXIT_FAILURE;
        }
        puts("额度事件监听与兜底运行时测试通过");
    }
    return EXIT_SUCCESS;
}
