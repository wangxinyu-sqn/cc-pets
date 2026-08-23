#import <Foundation/Foundation.h>
#import "CCPetsVersion.h"

// 刚发布新版本时，registry 的 /latest 已经报出新版本，而同一时刻
// `npm install cc-pets@<新版本>` 解析到的包元数据可能还是旧的，直接报 ETARGET。
// 实测过一次：重试即成功。所以这类失败要自动重试，而不是弹"更新失败"。
//
// 但判定不能放太宽：权限、磁盘、脚本失败都是真的装不上，重试只会拖时间并掩盖问题。

static BOOL Check(NSString *label, NSString *log, BOOL expected) {
    BOOL actual = UpdateFailureIsTransient(log);
    if (actual == expected) return YES;
    NSLog(@"%@: 判定为 %@，期望 %@", label, actual ? @"暂时性" : @"永久性",
        expected ? @"暂时性" : @"永久性");
    return NO;
}

int main(void) {
    @autoreleasepool {
        BOOL ok = YES;
        // 用户实际遇到的那条日志。
        ok &= Check(@"ETARGET", @"npm error code ETARGET\n"
            "npm error notarget No matching version found for cc-pets@1.0.6.\n", YES);
        ok &= Check(@"DNS 解析失败", @"npm error code ENOTFOUND\nnpm error network", YES);
        ok &= Check(@"连接超时", @"npm error code ETIMEDOUT", YES);
        ok &= Check(@"连接被重置", @"npm error code ECONNRESET", YES);
        ok &= Check(@"registry 限流", @"npm error 429 Too Many Requests", YES);
        ok &= Check(@"registry 不可用", @"npm error 503 Service Unavailable", YES);

        // 这些是真失败，重试没有意义，必须如实上报。
        ok &= Check(@"权限不足", @"npm error code EACCES\nnpm error Missing write access", NO);
        ok &= Check(@"磁盘写满", @"npm error code ENOSPC\nnpm error No space left on device", NO);
        ok &= Check(@"安装脚本失败", @"npm error code ELIFECYCLE\nnpm error errno 1", NO);
        ok &= Check(@"空日志", @"", NO);
        ok &= Check(@"空指针", nil, NO);

        if (!ok) return EXIT_FAILURE;
        puts("自动更新暂时性故障判定测试通过");
    }
    return EXIT_SUCCESS;
}
