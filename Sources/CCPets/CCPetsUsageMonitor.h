#import <Foundation/Foundation.h>

@interface CCPetsUsageMonitor : NSObject
@property(copy) void (^changeHandler)(NSDictionary *codexUsage, NSDictionary *claudeUsage);
@property(readonly) NSDictionary *codexUsage;
@property(readonly) NSDictionary *claudeUsage;
- (void)start;
- (void)refreshNow;
- (void)stop;
@end
