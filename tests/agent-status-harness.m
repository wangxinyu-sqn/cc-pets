#import <Foundation/Foundation.h>
#import "CCPetsEvents.h"

// 状态机的两个坑，都来自"事件顺序不等于语义顺序"：
//
// 1. Stop 之后还会飘来 SubagentStop / PostToolUse（实测 Stop 后 4 秒）。它们和
//    UserPromptSubmit 一样都归一成 thinking，只看 state 分不出来——必须按事件名拦，
//    否则"任务已完成"会被打回"正在思考"，看起来像任务又活了。
// 2. 拦得太宽也不行：新一轮真实动作（用户提问、工具调用、需要关注）必须能解除终态。

static BOOL IsTrailingEvent(NSString *event) {
    return [event isEqualToString:@"SubagentStop"] || [event isEqualToString:@"PostToolUse"] ||
        [event isEqualToString:@"TaskCompleted"];
}

static BOOL CheckNormalized(NSString *event, BOOL failed, NSString *expected) {
    NSString *actual = NormalizedStateForEvent(event, failed);
    if ([actual isEqualToString:expected]) return YES;
    NSLog(@"%@ 应归一成 %@，实际 %@", event, expected, actual);
    return NO;
}

int main(void) {
    @autoreleasepool {
        BOOL ok = YES;
        ok &= CheckNormalized(@"Stop", NO, @"completed");
        ok &= CheckNormalized(@"StopFailure", NO, @"failed");
        ok &= CheckNormalized(@"SessionStart", NO, @"starting");
        ok &= CheckNormalized(@"UserPromptSubmit", NO, @"thinking");
        ok &= CheckNormalized(@"SubagentStop", NO, @"thinking");
        ok &= CheckNormalized(@"PostToolUse", NO, @"thinking");

        // 尾巴事件和"新一轮真实动作"归一后的 state 完全一样，这正是必须按事件名区分的原因。
        if (![NormalizedStateForEvent(@"SubagentStop", NO)
                isEqualToString:NormalizedStateForEvent(@"UserPromptSubmit", NO)]) {
            NSLog(@"前提失效：尾巴事件与新一轮动作的 state 已能区分，拦截逻辑需要重新审视");
            ok = NO;
        }
        for (NSString *event in @[@"SubagentStop", @"PostToolUse", @"TaskCompleted"]) {
            if (!IsTrailingEvent(event)) {
                NSLog(@"%@ 应被认定为终态之后的尾巴事件", event);
                ok = NO;
            }
        }
        for (NSString *event in @[@"UserPromptSubmit", @"PreToolUse", @"PermissionRequest",
                                  @"Notification", @"SessionStart"]) {
            if (IsTrailingEvent(event)) {
                NSLog(@"%@ 是新一轮真实动作，必须能解除终态", event);
                ok = NO;
            }
        }
        if (!ok) return EXIT_FAILURE;
        puts("Agent 状态归一与终态尾巴事件判定测试通过");
    }
    return EXIT_SUCCESS;
}
