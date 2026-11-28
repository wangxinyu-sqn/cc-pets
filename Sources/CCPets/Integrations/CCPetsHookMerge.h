#import <Foundation/Foundation.h>
@class CCPetsJSONObject;

// Recognize a simple invocation without evaluating shell input. Compound commands are user scripts.
NSArray<NSString *> *CCPetsHookWords(id command);
NSArray<NSString *> *CCPetsHookInvocation(id command, NSMutableDictionary *environment);
BOOL CCPetsIsPetExecutable(id path);
BOOL CCPetsIsBridgeTransport(id command, id args);

// Each desired entry describes one Pet handler. The role distinguishes independent
// handlers (e.g. hook and watch) for the same event. nil means this handler is unrelated.
NSArray *CCPetsMergeHookEntries(id current, NSArray *desired, BOOL grouped, NSString *(^role)(id command));

// Preserve explicit allow rules and order; revoke only the supplied rules.
BOOL CCPetsMergeAllows(CCPetsJSONObject *document, NSArray *wanted, NSSet *revoke);
