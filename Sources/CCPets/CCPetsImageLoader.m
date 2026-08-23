#import "CCPetsImageLoader.h"
#import <ImageIO/ImageIO.h>

NSImage *LoadPetSpriteImage(NSString *path, NSSize cellSize, NSInteger rowCount) {
    if (path.length == 0 || rowCount <= 0) return nil;
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return nil;
    NSDictionary *properties = CFBridgingRelease(
        CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CGFloat sourceWidth = [properties[(NSString *)kCGImagePropertyPixelWidth] doubleValue];
    CGFloat sourceHeight = [properties[(NSString *)kCGImagePropertyPixelHeight] doubleValue];
    CGFloat desiredWidth = MAX(1.0, cellSize.width) * 8.0;
    CGFloat desiredHeight = MAX(1.0, cellSize.height) * rowCount;
    CGFloat scale = MIN(1.0, MAX(desiredWidth / MAX(1.0, sourceWidth),
        desiredHeight / MAX(1.0, sourceHeight)));
    if (scale >= 0.98) {
        CFRelease(source);
        return [[NSImage alloc] initWithContentsOfFile:path];
    }
    CGFloat maximumPixelSize = ceil(MAX(sourceWidth, sourceHeight) * scale);
    NSDictionary *options = @{
        (NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maximumPixelSize),
        (NSString *)kCGImageSourceShouldCacheImmediately: @YES
    };
    CGImageRef imageRef = CGImageSourceCreateThumbnailAtIndex(
        source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!imageRef) return [[NSImage alloc] initWithContentsOfFile:path];
    NSImage *image = [[NSImage alloc] initWithCGImage:imageRef
        size:NSMakeSize(CGImageGetWidth(imageRef), CGImageGetHeight(imageRef))];
    CGImageRelease(imageRef);
    return image;
}
