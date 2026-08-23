#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import "CCPetsImageLoader.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return EXIT_FAILURE;
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        CGImageSourceRef source = CGImageSourceCreateWithURL(
            (__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
        if (!source) return EXIT_FAILURE;
        NSDictionary *properties = CFBridgingRelease(
            CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        CFRelease(source);
        CGFloat originalWidth = [properties[(NSString *)kCGImagePropertyPixelWidth] doubleValue];
        CGFloat originalHeight = [properties[(NSString *)kCGImagePropertyPixelHeight] doubleValue];
        NSImage *image = LoadPetSpriteImage(path, NSMakeSize(140, 150), 9);
        if (!image || image.size.width >= originalWidth || image.size.height >= originalHeight) {
            return EXIT_FAILURE;
        }
        if (image.size.width / 8.0 < 139 || image.size.height / 9.0 < 149) {
            return EXIT_FAILURE;
        }
        printf("精灵图运行时降采样测试通过: %.0fx%.0f -> %.0fx%.0f\n",
            originalWidth, originalHeight, image.size.width, image.size.height);
    }
    return EXIT_SUCCESS;
}
