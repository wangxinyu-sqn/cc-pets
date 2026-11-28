#import <Cocoa/Cocoa.h>
@class CCPetsFormBuilder;

@interface CCPetsSlackEditor : NSObject
- (instancetype)initWithForm:(CCPetsFormBuilder *)form;
- (void)refreshStatus;
@end
