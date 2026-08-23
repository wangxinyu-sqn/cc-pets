#import <Cocoa/Cocoa.h>

// 按桌宠实际绘制尺寸解码精灵图，避免让超大外部素材长期占用完整 RGBA 内存。
NSImage *LoadPetSpriteImage(NSString *path, NSSize cellSize, NSInteger rowCount);
