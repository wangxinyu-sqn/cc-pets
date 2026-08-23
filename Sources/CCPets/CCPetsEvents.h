#import <Foundation/Foundation.h>

// Agent 事件的记录与状态归一化，同时是 --hook / --provider-event 两个子命令的实现。
NSString *SanitizedShortString(id value, NSUInteger maximumLength);
NSString *ProviderFromEnvironment(void);
NSString *NormalizedStateForEvent(NSString *event, BOOL failed);
BOOL AppendAgentEventRecord(NSDictionary *record);
BOOL HookValueIndicatesFailure(id value);
int RecordHookEvent(void);
int RecordProviderEvent(void);
