#import <Foundation/Foundation.h>

BOOL CCBridgeSlackValidChannel(NSString *channel);
BOOL CCBridgeSlackValidHostName(NSString *name);
NSString *CCBridgeSlackConfigPath(void);
NSDictionary *CCBridgeSlackLoadConfiguration(NSString *path);
BOOL CCBridgeSlackAutoStartEnabled(NSDictionary *config);
NSString *CCBridgeSlackReadToken(NSString *path, NSDictionary *config, NSString *key, NSError **error);

// Empty token fields keep existing items. Publish both references in one atomic file replacement.
BOOL CCBridgeSlackSaveConfiguration(NSDictionary *original, NSDictionary *changes, NSString *appToken,
                                    NSString *botToken, BOOL removeTokens, NSString **error);
