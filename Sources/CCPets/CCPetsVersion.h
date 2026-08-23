#import <Foundation/Foundation.h>

#ifndef CC_PETS_VERSION
#define CC_PETS_VERSION "unknown"
#endif

// 只接受严格的三段纯数字版本号；valid 为 NO 时返回值无意义。
// 自动更新会把比较结果作为是否升级的唯一依据，所以这里刻意不接受预发布号。
NSComparisonResult CompareStableVersions(NSString *left, NSString *right, BOOL *valid);
int RestartAfterPID(pid_t pid, NSString *appPath, BOOL managed);

// npm 安装日志里是否只是暂时性故障（值得自动重试一次），而不是真的装不上。
BOOL UpdateFailureIsTransient(NSString *log);
