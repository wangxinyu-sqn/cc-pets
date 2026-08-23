#import <Foundation/Foundation.h>
#import "CCPetsPaths.h"

static void Expect(BOOL condition, const char *message) {
    if (condition) return;
    fprintf(stderr, "断言失败：%s\n", message);
    exit(EXIT_FAILURE);
}

static void WriteFile(NSString *path, NSString *contents) {
    NSFileManager *manager = NSFileManager.defaultManager;
    [manager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    Expect([contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil],
        "无法写入测试文件");
}

int main(void) {
    @autoreleasepool {
        NSFileManager *manager = NSFileManager.defaultManager;
        NSString *codexPets = CodexPetsDirectory();
        NSString *ownPets = OwnPetsDirectory();

        // 有图的正常素材、只有 pet.json 没有图的半成品、以及一个普通文件。
        WriteFile([codexPets stringByAppendingPathComponent:@"alpha/spritesheet.webp"], @"sprite");
        WriteFile([codexPets stringByAppendingPathComponent:@"alpha/pet.json"],
            @"{\"spriteVersionNumber\":2}");
        WriteFile([codexPets stringByAppendingPathComponent:@"halfbaked/pet.json"], @"{}");
        WriteFile([codexPets stringByAppendingPathComponent:@"loose.txt"], @"not a pet");
        // 自己目录里已经有同名素材，导入不能覆盖它。
        WriteFile([ownPets stringByAppendingPathComponent:@"alpha/spritesheet.png"], @"mine");

        WriteFile([codexPets stringByAppendingPathComponent:@"beta/spritesheet.png"], @"sprite");

        NSUInteger imported = ImportCodexPets();
        Expect(imported == 1, "只应导入 beta 一个素材");

        NSString *beta = [ownPets stringByAppendingPathComponent:@"beta"];
        Expect([manager fileExistsAtPath:[beta stringByAppendingPathComponent:@"spritesheet.png"]],
            "beta 的精灵图没有复制过来");
        NSString *sidecarPath = [beta stringByAppendingPathComponent:@".source.json"];
        NSData *sidecarData = [NSData dataWithContentsOfFile:sidecarPath];
        Expect(sidecarData != nil, "导入的素材没有写 .source.json");
        NSDictionary *sidecar = [NSJSONSerialization JSONObjectWithData:sidecarData options:0 error:nil];
        Expect([sidecar[@"source"] isEqualToString:@"codex"], ".source.json 的 source 不是 codex");
        Expect([sidecar[@"slug"] isEqualToString:@"beta"], ".source.json 的 slug 不对");
        Expect([sidecar[@"installedAt"] isKindOfClass:NSString.class], ".source.json 缺少 installedAt");

        // 同名目录必须保持原样，不能被 Codex 那边的同名素材覆盖。
        NSString *keptPath = [ownPets stringByAppendingPathComponent:@"alpha/spritesheet.png"];
        NSString *kept = [NSString stringWithContentsOfFile:keptPath encoding:NSUTF8StringEncoding error:nil];
        Expect([kept isEqualToString:@"mine"], "已存在的同名素材被导入覆盖了");
        Expect(![manager fileExistsAtPath:[ownPets stringByAppendingPathComponent:@"alpha/spritesheet.webp"]],
            "已存在的同名素材目录被写入了 Codex 的文件");

        // 没有精灵图的目录和普通文件都不该被当成素材。
        Expect(![manager fileExistsAtPath:[ownPets stringByAppendingPathComponent:@"halfbaked"]],
            "没有精灵图的目录不应被导入");
        Expect(![manager fileExistsAtPath:[ownPets stringByAppendingPathComponent:@"loose.txt"]],
            "普通文件不应被导入");

        // 再跑一次应当完全幂等：已经导入过的都会因为同名而跳过。
        Expect(ImportCodexPets() == 0, "重复导入不应再产生新素材");

        puts("Codex 素材导入测试通过");
    }
    return EXIT_SUCCESS;
}
