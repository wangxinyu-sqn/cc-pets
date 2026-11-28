#import <Foundation/Foundation.h>

NSString *CCBridgeSlackConnectionDescription(void);
BOOL CCBridgeSlackAdapterRunning(void);

// Synchronous probe for a background queue. Returns a field-keyed error or nil after Socket Mode hello.
NSDictionary<NSString *, NSString *> *CCBridgeSlackTestConnection(NSURLSession *http, NSDictionary *original,
    NSString *appToken, NSString *botToken, NSString *channel);

enum { CCBridgeSlackKeychainAccessRequired = 77 };

// Foreground Socket Mode adapter, also used as the desktop app's child process.
int CCBridgeRunSlack(NSArray<NSString *> *arguments);
