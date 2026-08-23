#import <Foundation/Foundation.h>
#import "CCPetsUsage.h"
#import "CCPetsPaths.h"

// 一批 FSEvents 里有多个会话文件同时变更时，选中的必须是额度采样最晚的那个。
// "文件更晚被写"不等于"额度采样更晚"：会话拿到 rate_limits 之后还会继续追加别的行。

static NSString *SessionDirectory(void) {
    NSString *directory = [DefaultCodexHomeDirectory()
        stringByAppendingPathComponent:@"sessions/2026/07/31"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}

static NSURL *WriteSession(NSString *name, NSString *timestamp, double week) {
    NSString *path = [SessionDirectory() stringByAppendingPathComponent:name];
    NSString *line = [NSString stringWithFormat:
        @"{\"timestamp\":\"%@\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\","
         "\"rate_limits\":{\"primary\":{\"window_minutes\":300,\"used_percent\":1},"
         "\"secondary\":{\"window_minutes\":10080,\"used_percent\":%.1f}}}}\n",
        timestamp, week];
    [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    return [NSURL fileURLWithPath:path];
}

// 额度采样偏旧、但尾巴里带一条更晚的耗尽事件的会话——真实形态就是"另一个会话刚更新过
// 额度，这个会话随后撞上限流"。它在竞选里会落选，耗尽标记却必须照样被记下来。
// 耗尽时刻必须晚于当前面板快照，否则按 UsageByMarkingExhaustion 的语义算额度已恢复。
static NSURL *WriteExhaustedSession(NSString *name, NSString *quotaTimestamp,
    NSString *exhaustedTimestamp, double week) {
    NSURL *url = WriteSession(name, quotaTimestamp, week);
    NSString *line = [NSString stringWithFormat:
        @"{\"timestamp\":\"%@\",\"type\":\"event_msg\",\"payload\":{\"type\":\"error\","
         "\"error\":{\"codex_error_info\":\"usage_limit_exceeded\"}}}\n", exhaustedTimestamp];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:url.path];
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
    return url;
}

// 只有 token_count 之外的行，没有任何 rate_limits。
static NSURL *WriteQuotalessSession(NSString *name) {
    NSString *path = [SessionDirectory() stringByAppendingPathComponent:name];
    [@"{\"timestamp\":\"2026-07-31T12:00:00.000Z\",\"type\":\"event_msg\","
      "\"payload\":{\"type\":\"agent_message\",\"message\":\"hi\"}}\n"
        writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    return [NSURL fileURLWithPath:path];
}

static double WeekPercent(NSDictionary *usage) {
    return [usage[@"week"][@"used_percent"] doubleValue];
}

static BOOL Check(BOOL condition, NSString *message) {
    if (condition) return YES;
    fprintf(stderr, "%s\n", message.UTF8String);
    return NO;
}

int main(void) {
    @autoreleasepool {
        // 采样早的那个文件故意后写，mtime 因此更新——正是判据不能看 mtime 的原因。
        NSURL *early = WriteSession(@"rollout-early.jsonl", @"2026-07-31T10:00:00.000Z", 40);
        NSURL *late = WriteSession(@"rollout-late.jsonl", @"2026-07-31T11:00:00.000Z", 70);
        early = WriteSession(@"rollout-early.jsonl", @"2026-07-31T10:00:00.000Z", 40);

        // 采样晚的排在前面：取"遍历到的最后一个"会选错。
        CodexUsageReader *reader = [CodexUsageReader new];
        NSDictionary *usage = [reader refreshForSessionURLs:@[late, early]];
        if (!Check(WeekPercent(usage) == 70,
                   [NSString stringWithFormat:@"采样晚的会话排在前面时选错了: %.1f", WeekPercent(usage)])) {
            return EXIT_FAILURE;
        }

        // 反过来再来一次：结果不能随数组顺序改变。
        reader = [CodexUsageReader new];
        usage = [reader refreshForSessionURLs:@[early, late]];
        if (!Check(WeekPercent(usage) == 70,
                   [NSString stringWithFormat:@"采样晚的会话排在后面时选错了: %.1f", WeekPercent(usage)])) {
            return EXIT_FAILURE;
        }

        // 单个候选也必须正确。
        reader = [CodexUsageReader new];
        usage = [reader refreshForSessionURLs:@[early]];
        if (!Check(WeekPercent(usage) == 40,
                   [NSString stringWithFormat:@"单个候选时选错了: %.1f", WeekPercent(usage)])) {
            return EXIT_FAILURE;
        }

        // 新快照已经显示后，旧响应可能在下一批 FSEvents 里单独迟到。不能因为这一批只有
        // 一个文件就跳过 sampledAt 比较，否则面板仍会从 70 倒退到 40。
        reader = [CodexUsageReader new];
        usage = [reader refreshForSessionURLs:@[late]];
        NSURL *newerSession = reader.sessionURL;
        usage = [reader refreshForSessionURLs:@[early]];
        if (!Check(WeekPercent(usage) == 70,
                   [NSString stringWithFormat:@"单独迟到的旧快照导致额度倒退: %.1f", WeekPercent(usage)])) {
            return EXIT_FAILURE;
        }
        if (!Check([reader.sessionURL.path isEqualToString:newerSession.path],
                   @"单独迟到的旧快照不应切走当前会话")) {
            return EXIT_FAILURE;
        }

        // 60 秒兜底和手动刷新会重新按 mtime 发现会话。early 文件故意后写、mtime 更新，
        // 即使发现步骤选中了它，最终额度也不能覆盖当前更新的采样。
        usage = [reader refreshWithFullDiscovery];
        if (!Check(WeekPercent(usage) == 70,
                   [NSString stringWithFormat:@"全量发现让旧快照覆盖了当前额度: %.1f", WeekPercent(usage)])) {
            return EXIT_FAILURE;
        }

        // 落选的候选里如果带着耗尽事件，标记必须照样记下来。"另一个会话刚更新过额度、
        // 这个会话撞上限流"正是最容易发生耗尽的时刻，而那一批事件整批都不会走 refresh。
        reader = [CodexUsageReader new];
        usage = [reader refreshForSessionURLs:@[late]];
        if (!Check(usage[@"exhaustedAt"] == nil, @"没有耗尽事件时不该有耗尽标记")) {
            return EXIT_FAILURE;
        }
        NSURL *exhausted = WriteExhaustedSession(@"rollout-exhausted.jsonl",
            @"2026-07-31T10:30:00.000Z", @"2026-07-31T11:30:00.000Z", 40);
        usage = [reader refreshForSessionURLs:@[exhausted]];
        if (!Check(WeekPercent(usage) == 70,
                   [NSString stringWithFormat:@"落选候选的旧额度不应生效: %.1f", WeekPercent(usage)])) {
            return EXIT_FAILURE;
        }
        if (!Check(usage[@"exhaustedAt"] != nil, @"落选候选里的耗尽事件被丢掉了")) {
            return EXIT_FAILURE;
        }

        // 候选整篇都没有额度时保持当前会话不动：为一次没有信息量的事件切走，
        // 等于丢掉增量偏移再白做一次冷读。
        reader = [CodexUsageReader new];
        usage = [reader refreshForSessionURLs:@[late]];
        NSURL *previous = reader.sessionURL;
        NSURL *quotaless = WriteQuotalessSession(@"rollout-quotaless.jsonl");
        usage = [reader refreshForSessionURLs:@[quotaless, WriteQuotalessSession(@"rollout-quotaless-2.jsonl")]];
        if (!Check([reader.sessionURL.path isEqualToString:previous.path],
                   @"候选都没有额度时不应切换会话")) {
            return EXIT_FAILURE;
        }
        if (!Check(WeekPercent(usage) == 70,
                   [NSString stringWithFormat:@"候选都没有额度时额度不应变化: %.1f", WeekPercent(usage)])) {
            return EXIT_FAILURE;
        }

        // sessions 目录之外的路径一律不接受，事件流被别处的 .jsonl 污染时不能跟着切走。
        reader = [CodexUsageReader new];
        usage = [reader refreshForSessionURLs:@[late]];
        NSString *outsidePath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"cc-pets-outside-session.jsonl"];
        [@"{}\n" writeToFile:outsidePath atomically:NO encoding:NSUTF8StringEncoding error:nil];
        usage = [reader refreshForSessionURLs:@[[NSURL fileURLWithPath:outsidePath]]];
        if (!Check([reader.sessionURL.path isEqualToString:late.path],
                   @"sessions 目录之外的文件不应被选中")) {
            return EXIT_FAILURE;
        }

        puts("并发会话按额度采样时刻选取测试通过");
    }
    return EXIT_SUCCESS;
}
