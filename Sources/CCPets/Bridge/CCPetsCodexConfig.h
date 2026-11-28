#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, CCPetsCodexConfigMode) {
    CCPetsCodexConfigureApprovals,
    CCPetsCodexRegister,
    CCPetsCodexUnregister
};

// Merge Bridge transport and tool permissions in one validated, atomic config.toml edit.
void CCBridgeReconcileCodexConfig(NSString *home, CCPetsCodexConfigMode mode, NSArray<NSString *> *tools, NSString *codex);
