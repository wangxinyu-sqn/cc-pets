#import "CCPetsBridge.h"
#import "CCPetsBridgeSlack.h"
#import "CCPetsBridgePage.h"
#import "CCPetsSlackEditor.h"
#import "CCPetsAppDelegate+Private.h"
#import <objc/runtime.h>
#import "CCPetsMainWindow.h"
#import "CCPetsUIStyle.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsSlackConfiguration.h"
#import <Security/Security.h>

// Only this test executable supplies these Security entry points. It never
// opens the user's keychain and can exercise a failure on the second item.
static NSMutableDictionary<NSString *, NSData *> *items;
static BOOL denyBotWrite;
static BOOL simulateAdapter, allowKeychainUI = YES;
static NSUInteger itemReads, itemAdds, itemDeletes;

OSStatus SecKeychainSetUserInteractionAllowed(Boolean state) {
    allowKeychainUI = state;
    return errSecSuccess;
}

static NSString *ItemKey(NSDictionary *item) {
    return [NSString stringWithFormat:@"%@/%@", item[(__bridge id)kSecAttrService], item[(__bridge id)kSecAttrAccount]];
}
OSStatus SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    NSDictionary *item = (__bridge NSDictionary *)attributes;
    itemAdds++;
    if (denyBotWrite && [item[(__bridge id)kSecAttrAccount] hasPrefix:@"bot_token."]) return errSecAuthFailed;
    NSString *key = ItemKey(item);
    if (items[key]) return errSecDuplicateItem;
    items[key] = item[(__bridge id)kSecValueData];
    return errSecSuccess;
}
OSStatus SecItemUpdate(CFDictionaryRef attributes, CFDictionaryRef changes) {
    NSDictionary *query = (__bridge NSDictionary *)attributes;
    NSString *key = ItemKey(query);
    if (!items[key]) return errSecItemNotFound;
    if (denyBotWrite && [query[(__bridge id)kSecAttrAccount] hasPrefix:@"bot_token."]) return errSecAuthFailed;
    items[key] = ((__bridge NSDictionary *)changes)[(__bridge id)kSecValueData];
    return errSecSuccess;
}
OSStatus SecItemCopyMatching(CFDictionaryRef attributes, CFTypeRef *result) {
    itemReads++;
    if (simulateAdapter) {
        NSCAssert(!allowKeychainUI, @"background retrieval must prohibit system prompts");
        return errSecInteractionNotAllowed;
    }
    NSData *data = items[ItemKey((__bridge NSDictionary *)attributes)];
    if (!data) return errSecItemNotFound;
    *result = CFBridgingRetain(data);
    return errSecSuccess;
}
OSStatus SecItemDelete(CFDictionaryRef attributes) {
    itemDeletes++;
    [items removeObjectForKey:ItemKey((__bridge NSDictionary *)attributes)];
    return errSecSuccess;
}

static NSControl *FindControl(NSView *root, Class type, SEL action, NSString *label) {
    if ([root isKindOfClass:type]) {
        NSControl *control = (NSControl *)root;
        if ((!action || control.action == action) && (!label || [control.accessibilityLabel isEqual:label])) return control;
    }
    for (NSView *child in root.subviews) {
        NSControl *found = FindControl(child, type, action, label);
        if (found) return found;
    }
    return nil;
}

// Give the responder chain a key window without taking focus from the user's app.
@interface PasteTestApplication : NSApplication
@property(nonatomic) NSWindow *editingWindow;
@end
@implementation PasteTestApplication
- (NSWindow *)keyWindow { return self.editingWindow ?: super.keyWindow; }
@end

// The session double only accepts the three read-only checks and a transient WebSocket.
@interface SlackProbeTask : NSObject
@property(copy) void (^onResume)(void);
@end
@implementation SlackProbeTask
- (void)resume { if (self.onResume) self.onResume(); }
@end

@interface SlackProbeSocket : SlackProbeTask
@property(copy) NSString *frame;
@property BOOL closed;
@end
@implementation SlackProbeSocket
- (void)receiveMessageWithCompletionHandler:(void (^)(NSURLSessionWebSocketMessage *, NSError *))handler {
    handler([[NSURLSessionWebSocketMessage alloc] initWithString:self.frame], nil);
}
- (void)cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)code reason:(NSData *)reason { self.closed = YES; }
@end

@interface SlackProbeSession : NSObject
@property(copy) NSString *failure;
@property(nonatomic) NSInteger requests;
@property(nonatomic) SlackProbeSocket *socket;
@end
@implementation SlackProbeSession
- (void)invalidateAndCancel {}
- (id)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    ++self.requests;
    NSString *method = request.URL.lastPathComponent;
    NSDictionary *reply = nil;
    if ([method isEqual:@"auth.test"]) reply = @{@"ok": @YES, @"bot_id": @"B1", @"team_id": @"T1", @"user_id": @"U1"};
    if ([method isEqual:@"conversations.history"]) {
        NSCAssert([request.HTTPMethod isEqual:@"GET"] && [request.URL.query containsString:@"channel=C123"], @"channel read probe");
        reply = @{@"ok": @YES};
    }
    if ([method isEqual:@"apps.connections.open"]) reply = @{@"ok": @YES, @"url": @"wss://example.invalid/probe"};
    NSCAssert(reply, @"unexpected request");
    if ([method isEqual:self.failure]) reply = @{@"ok": @NO, @"error": @"invalid_auth"};
    SlackProbeTask *task = [SlackProbeTask new];
    task.onResume = ^{
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
        handler([NSJSONSerialization dataWithJSONObject:reply options:0 error:nil], response, nil);
    };
    return task;
}
- (id)webSocketTaskWithURL:(NSURL *)url {
    self.socket = [SlackProbeSocket new];
    self.socket.frame = [self.failure isEqual:@"socket"] ? @"{}" : @"{\"type\":\"hello\"}";
    return self.socket;
}
@end

static void WaitForProbe(NSButton *button) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!button.enabled && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    NSCAssert(button.enabled, @"probe finished");
}

static void ClickAndWait(NSButton *button) {
    [button sendAction:button.action to:button.target];
    WaitForProbe(button);
}

static NSString *TestAppToken(void) {
    return [@"xapp-" stringByPaddingToLength:128 withString:@"a" startingAtIndex:0];
}

@interface CCPetsSlackEditor (FocusTest)
- (void)endEditingForClick:(NSEvent *)event inPage:(NSView *)page;
@end

static void PasteIntoBridgeFields(NSView *view, NSArray<NSTextField *> *fields) {
    // Accessory apps may start with a system-supplied application-only menu.
    NSMenu *initial = [NSMenu new];
    [initial addItemWithTitle:@"CC Pets" action:nil keyEquivalent:@""].submenu = [NSMenu new];
    NSApp.mainMenu = initial;
    AppDelegate *delegate = [AppDelegate new];
    [delegate installMainMenu];

    PasteTestApplication *application = (PasteTestApplication *)NSApp;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 700, 450)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.contentView = view;
    application.editingWindow = window;
    NSEvent *paste = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:window.windowNumber context:nil
        characters:@"v" charactersIgnoringModifiers:@"v" isARepeat:NO keyCode:9];

    // Exercise AppKit's actual paste: implementation with a process-private test pasteboard.
    NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
    Method general = class_getClassMethod(NSPasteboard.class, @selector(generalPasteboard));
    IMP substitute = imp_implementationWithBlock(^id(id receiver) { return board; });
    IMP previous = method_setImplementation(general, substitute);
    @try {
        NSArray *values = @[TestAppToken(), @"xoxb-ui", @"C123", @"test-mac"];
        for (NSUInteger i = 0; i < fields.count; i++) {
            [board clearContents];
            [board setString:values[i] forType:NSPasteboardTypeString];
            NSTextField *field = fields[i];
            NSCAssert([window makeFirstResponder:field], @"focus the Bridge input");
            NSCAssert([NSApp.mainMenu performKeyEquivalent:paste], @"Edit menu handles Command-V");
            NSCAssert([field.stringValue isEqual:values[i]], @"paste reaches the focused input");
        }
        [window.contentView setFrameSize:NSMakeSize(700, 650)];
        [window.contentView layoutSubtreeIfNeeded];
        [window makeFirstResponder:fields.firstObject];
        CCPetsSlackEditor *editor = (id)FindControl(view, NSButton.class, NSSelectorFromString(@"save:"), nil).target;
        NSEvent *click = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(3, 3)
            modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
        [editor endEditingForClick:click inPage:view];
        NSCAssert(!fields.firstObject.currentEditor && [fields.firstObject.stringValue isEqual:TestAppToken()], @"outside click keeps the full pasted token and ends editing");
        NSCAssert(fields.firstObject.cell.scrollable && !fields.firstObject.cell.wraps, @"long tokens fit on one masked line");
    } @finally {
        method_setImplementation(general, previous);
        imp_removeBlock(substitute);
        [board releaseGlobally];
        application.editingWindow = nil;
    }
}

static void CheckRemoteForm(NSString *path) {
    NSDictionary *root = CCBridgeReadJSON(path);
    NSMutableDictionary *slack = [root[@"slack"] mutableCopy];
    NSArray *peers = @[@{@"name": @"reviewer", @"channel": @"C123", @"bot_id": @"B123", @"user_id": @"U123"}];
    slack[@"agents"] = peers;
    [slack removeObjectForKey:@"discovery"];
    NSMutableDictionary *fixture = [root mutableCopy];
    fixture[@"slack"] = slack;
    CCBridgeWriteJSON(path, fixture);
    [PasteTestApplication sharedApplication];
    NSCAssert([CCPetsMainWindowResolvePage(@"bridge") isEqual:@"bridge"], @"CLI and sidebar route");
    CCPetsBridgePage *page = [CCPetsBridgePage new];
    NSSegmentedControl *tabs = (id)FindControl(page.view, NSSegmentedControl.class, NULL, nil);
    NSCAssert(tabs.segmentCount == 3, @"bridge tabs");
    NSCAssert([tabs.selectedSegmentBezelColor isEqual:CCPetsAccentFillColor()], @"shared accent on Bridge tabs");
    tabs.selectedSegment = 1;
    NSUInteger beforeOpen = itemReads;
    [tabs sendAction:tabs.action to:tabs.target];
    NSCAssert(itemReads == beforeOpen, @"opening Remote Connections must not query Keychain");
    NSSecureTextField *app = (id)FindControl(page.view, NSSecureTextField.class, NULL, @"App-Level Token");
    NSSecureTextField *bot = (id)FindControl(page.view, NSSecureTextField.class, NULL, @"Bot Token");
    NSButton *save = (id)FindControl(page.view, NSButton.class, NSSelectorFromString(@"save:"), nil);
    NSTextField *notice = [save.target valueForKey:@"keychainNotice"];
    NSCAssert(notice.hidden, @"the keychain notice stays out of the normal form");
    NSCAssert(app && bot && save && !app.stringValue.length && !bot.stringValue.length, @"secure credential fields");
    NSView *card = save.superview;
    while (card && ![card isKindOfClass:CCPetsCardView.class]) card = card.superview;
    NSCAssert(card && [app isDescendantOf:card] && [bot isDescendantOf:card], @"one Slack configuration card");
    NSTextField *channel = (id)FindControl(page.view, NSTextField.class, NULL, L(@"Channel ID"));
    NSTextField *computer = (id)FindControl(page.view, NSTextField.class, NULL, L(@"Computer name"));
    PasteIntoBridgeFields(page.view, @[app, bot, channel, computer]);
    SlackProbeSession *probe = [SlackProbeSession new];
    Method factory = class_getClassMethod(NSURLSession.class, @selector(sessionWithConfiguration:));
    IMP substitute = imp_implementationWithBlock(^id(id cls, NSURLSessionConfiguration *config) { return probe; });
    IMP previous = method_setImplementation(factory, substitute);
    computer.stringValue = @"";
    ClickAndWait(save);
    NSCAssert(notice.hidden && !probe.requests && items.count == 0, @"required fields apply with Slack off");
    computer.stringValue = @"test-mac";
    for (NSString *failure in @[@"auth.test", @"conversations.history", @"apps.connections.open", @"socket"]) {
        probe.failure = failure;
        ClickAndWait(save);
        NSCAssert(items.count == 0 && [CCBridgeReadJSON(path) isEqual:fixture] && [app.stringValue isEqual:TestAppToken()],
            @"failed tests preserve the draft and the entire previous configuration");
    }
    NSCAssert(probe.socket.closed, @"close even on failed hello");
    probe.failure = nil;
    [save sendAction:save.action to:save.target];
    NSCAssert(!notice.hidden && !save.enabled, @"explain credential access before testing and storing");
    NSStackView *section = (id)card.superview;
    NSCAssert([section isKindOfClass:NSStackView.class] && notice.superview == section &&
        [section.arrangedSubviews indexOfObjectIdenticalTo:card] + 1 == [section.arrangedSubviews indexOfObjectIdenticalTo:notice],
        @"the purpose notice appears directly below the Slack card");
    WaitForProbe(save);
    NSCAssert(probe.socket.closed, @"successful temporary connection closed");
    NSDictionary *saved = CCBridgeSlackLoadConfiguration(path);
    NSCAssert([CCBridgeSlackReadToken(path, saved, @"bot_token", nil) isEqual:@"xoxb-ui"], @"UI save");
    NSCAssert([saved[@"agents"] isEqual:peers], @"saving the card preserves manually configured peers");
    NSCAssert(!CCBridgeSlackAutoStartEnabled(saved), @"setup while Bridge disabled");
    app = (id)FindControl(page.view, NSSecureTextField.class, NULL, @"App-Level Token");
    NSCAssert(app && !app.stringValue.length, @"saved secrets cleared from the form");
    NSButton *toggle = (id)FindControl(page.view, NSButton.class, NSSelectorFromString(@"toggleConnection:"), nil);
    toggle.state = NSControlStateValueOn;
    NSUInteger beforeEnable = itemReads;
    ClickAndWait(toggle);
    NSCAssert(itemReads == beforeEnable, @"enabling an existing configuration does not ask for access");
    method_setImplementation(factory, previous);
    imp_removeBlock(substitute);
    NSCAssert(CCBridgeSlackAutoStartEnabled(CCBridgeSlackLoadConfiguration(path)), @"persist a boolean switch");
    [page showSettings];
    NSCAssert(tabs.selectedSegment == 2, @"alerts shortcut");
}

int main(void) {
    @autoreleasepool {
        unsetenv("SLACK_APP_TOKEN");
        unsetenv("SLACK_BOT_TOKEN");
        NSString *home = CCBridgeHomeDirectory();
        NSCAssert([home hasPrefix:@"/tmp/cc-pets-"] || [home hasPrefix:@"/private/tmp/cc-pets-"], @"isolated test home required");
        [NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:nil];
        items = [NSMutableDictionary dictionary];
        NSString *path = CCBridgeSlackConfigPath(), *error = nil;
        NSString *legacy = [home stringByAppendingPathComponent:@"bridge-slack.json"];
        CCBridgeWriteJSON(legacy, @{@"enabled": @YES, @"app_token": @"xapp-obsolete"});
        NSCAssert([path.lastPathComponent isEqual:@"bridge-remote.json"], @"shared remote file");
        NSCAssert(!CCBridgeSlackLoadConfiguration(path) && !CCBridgeSlackLoadConfiguration(legacy), @"ignore legacy");
        NSDictionary *sibling = @{@"enabled": @YES, @"rooms": @[@"a", @"b"]};
        CCBridgeWriteJSON(path, @{@"future": sibling});
        NSDictionary *changes = @{@"enabled": @YES, @"discovery": @{@"channel": @"C0CM5SP8ZFD", @"name": @"cc-bridge"}};
        denyBotWrite = YES;
        NSCAssert(!CCBridgeSlackSaveConfiguration(nil, changes, @"xapp-first", @"xoxb-first", NO, &error), @"denied");
        NSCAssert(items.count == 0 && !CCBridgeSlackLoadConfiguration(path), @"failed pair fully rolled back");
        denyBotWrite = NO;
        NSCAssert(CCBridgeSlackSaveConfiguration(nil, changes, @"xapp-first", @"xoxb-first", NO, &error), @"save");
        NSDictionary *first = CCBridgeSlackLoadConfiguration(path);
        NSCAssert(CCBridgeSlackAutoStartEnabled(first) && items.count == 2, @"two items, auto-start");
        NSCAssert([first[@"app_token"] hasPrefix:@"keychain:"] && [first[@"bot_token"] hasPrefix:@"keychain:"], @"references only");
        NSString *json = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        NSCAssert(![json containsString:@"xapp-"] && ![json containsString:@"xoxb-"], @"no plaintext in file");
        NSCAssert([CCBridgeReadJSON(path)[@"future"] isEqual:sibling], @"preserve sibling");
        NSUInteger adds = itemAdds, deletes = itemDeletes;
        denyBotWrite = YES;
        NSCAssert(!CCBridgeSlackSaveConfiguration(first, changes, @"xapp-next", @"xoxb-next", NO, &error), @"failed second update");
        NSCAssert([CCBridgeSlackReadToken(path, first, @"app_token", nil) isEqual:@"xapp-first"] &&
            [CCBridgeSlackLoadConfiguration(path) isEqual:first], @"failed rotation preserves original version");
        denyBotWrite = NO;
        NSCAssert(CCBridgeSlackSaveConfiguration(first, changes, nil, @"xoxb-rotated", NO, &error), @"rotate one");
        NSDictionary *second = CCBridgeSlackLoadConfiguration(path);
        NSCAssert(items.count == 2 && [second[@"app_token"] isEqual:first[@"app_token"]], @"other item unchanged");
        NSCAssert([first[@"bot_token"] isEqual:second[@"bot_token"]] && itemAdds == adds && itemDeletes == deletes,
            @"rotation preserves the keychain item and its access controls");
        NSCAssert([CCBridgeSlackReadToken(path, second, @"app_token", nil) isEqual:@"xapp-first"], @"read app");
        NSCAssert([CCBridgeSlackReadToken(path, second, @"bot_token", nil) isEqual:@"xoxb-rotated"], @"read rotated bot");
        NSCAssert(!CCBridgeSlackSaveConfiguration(first, changes, nil, nil, NO, &error), @"stale editor rejected");
        NSMutableDictionary *off = [second mutableCopy];
        off[@"enabled"] = @NO;
        NSCAssert(CCBridgeSlackSaveConfiguration(second, off, nil, nil, NO, &error), @"disable");
        NSDictionary *disabled = CCBridgeSlackLoadConfiguration(path);
        NSCAssert(!CCBridgeSlackAutoStartEnabled(disabled) && items.count == 2, @"off retains tokens");
        NSCAssert(CCBridgeSlackSaveConfiguration(disabled, disabled, nil, nil, YES, &error), @"remove");
        NSCAssert(items.count == 0 && [CCBridgeSlackLoadConfiguration(path)[@"bot_token"] isEqual:@""], @"empty placeholder");
        CheckRemoteForm(path);
        CCBridgeWriteJSON([home stringByAppendingPathComponent:@"bridge-enabled"], @{});
        simulateAdapter = YES;
        NSCAssert(CCBridgeRunSlack(@[]) == CCBridgeSlackKeychainAccessRequired, @"adapter reports authorization needed");
        NSCAssert([CCBridgeSlackConnectionDescription() isEqual:L(@"Keychain access needed. Click Test connection and save in Remote Connections.")], @"actionable status");
        simulateAdapter = NO;
        CCBridgeWriteJSON(path, @{@"slack": @{@"app_token": @"xapp-plaintext"}});
        NSCAssert(!CCBridgeSlackLoadConfiguration(path), @"reject plaintext");
        NSCAssert([CCBridgeReadJSON(legacy)[@"app_token"] isEqual:@"xapp-obsolete"], @"leave legacy file untouched");
        puts("Slack configuration checks passed");
    }
    return 0;
}
