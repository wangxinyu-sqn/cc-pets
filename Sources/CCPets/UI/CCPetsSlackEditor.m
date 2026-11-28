#import "CCPetsSlackEditor.h"
#import "CCPetsBridge.h"
#import "CCPetsBridgeSlack.h"
#import "CCPetsFormBuilder.h"
#import "CCPetsL10n.h"
#import "CCPetsSlackConfiguration.h"
#import "CCPetsUIStyle.h"

@interface CCPetsSlackEditor () <NSTextFieldDelegate>
@property(nonatomic) NSView *card;
@property(nonatomic) NSDictionary *original;
@property(nonatomic) NSButton *enabled;
@property(nonatomic) NSTextField *status, *feedback, *keychainNotice;
@property(nonatomic) NSButton *saveButton, *removeButton;
@property(nonatomic) NSMutableDictionary<NSString *, NSTextField *> *errors;
@property(nonatomic) NSURLSession *testSession;
@property(nonatomic) id clickMonitor;
@property(nonatomic) NSSecureTextField *appToken, *botToken;
@property(nonatomic) NSTextField *channel, *computer;
@end

@implementation CCPetsSlackEditor

static NSTextField *Input(NSString *value, NSString *placeholder, BOOL secure) {
    NSTextField *field = secure ? [NSSecureTextField new] : [NSTextField new];
    field.stringValue = value ?: @"";
    field.placeholderString = placeholder;
    field.usesSingleLineMode = YES;
    field.cell.wraps = NO;
    field.lineBreakMode = NSLineBreakByClipping;
    field.cell.scrollable = YES;
    if (secure) ((NSSecureTextFieldCell *)field.cell).echosBullets = YES;
    [field.widthAnchor constraintEqualToConstant:210].active = YES;
    return field;
}

static NSString *Trim(NSTextField *field) {
    return [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (instancetype)initWithForm:(CCPetsFormBuilder *)form {
    if ((self = [super init])) {
        _card = [form addGroupWithTitle:nil rows:@[] footer:nil];
        [form.stack setCustomSpacing:8 afterView:_card];
        _keychainNotice = CCPetsWrappingLabel(L(@"CC Pets accesses Keychain only to save and retrieve your two Slack connection tokens. If macOS asks, you can allow access once. Always Allow usually lets this app read that token again without asking."),
            12, NSFontWeightRegular, CCPetsSecondaryInkColor());
        _keychainNotice.translatesAutoresizingMaskIntoConstraints = NO;
        [form.stack addArrangedSubview:_keychainNotice];
        [_keychainNotice.leadingAnchor constraintEqualToAnchor:form.stack.leadingAnchor constant:14].active = YES;
        [_keychainNotice.trailingAnchor constraintEqualToAnchor:form.stack.trailingAnchor constant:-14].active = YES;
        [self loadConfiguration];
        __weak typeof(self) weakSelf = self;
        __weak NSView *page = form.view;
        _clickMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent *(NSEvent *event) {
            [weakSelf endEditingForClick:event inPage:page];
            return event;
        }];
    }
    return self;
}

- (void)dealloc {
    if (_clickMonitor) [NSEvent removeMonitor:_clickMonitor];
}

- (void)endEditingForClick:(NSEvent *)event inPage:(NSView *)page {
    NSWindow *window = page.window;
    if (!window || event.window != window || !NSPointInRect([page convertPoint:event.locationInWindow fromView:nil], page.bounds)) return;
    BOOL editing = NO;
    for (NSTextField *field in @[self.appToken, self.botToken, self.channel, self.computer]) {
        if (NSPointInRect([field convertPoint:event.locationInWindow fromView:nil], field.bounds)) return;
        if (field.currentEditor && field.currentEditor == window.firstResponder) editing = YES;
    }
    if (editing) [window makeFirstResponder:nil];
}

- (NSView *)rowForField:(NSTextField *)field key:(NSString *)key title:(NSString *)title {
    [field setAccessibilityLabel:title];
    field.delegate = self;
    NSTextField *error = CCPetsLabel(@"", 11, NSFontWeightRegular, NSColor.systemRedColor);
    error.alignment = NSTextAlignmentRight;
    [error setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow - 1
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    error.hidden = YES;
    self.errors[key] = error;
    return [CCPetsFormBuilder rowWithTitle:title controls:@[error, field]];
}

- (void)loadConfiguration {
    self.keychainNotice.hidden = YES;
    self.errors = [NSMutableDictionary dictionary];
    self.original = CCBridgeSlackLoadConfiguration(CCBridgeSlackConfigPath());
    self.enabled = [CCPetsSwitch new];
    self.enabled.target = self;
    self.enabled.action = @selector(toggleConnection:);
    [self.enabled setAccessibilityLabel:L(@"Enable Slack connection")];
    self.enabled.state = [self.original[@"enabled"] boolValue];
    self.status = CCPetsLabel(@"", 12, NSFontWeightRegular, CCPetsSecondaryInkColor());
    NSString *configured = L(@"Configured · type to replace");
    self.appToken = (id)Input(nil, [self.original[@"app_token"] length] ? configured : @"xapp-…", YES);
    self.botToken = (id)Input(nil, [self.original[@"bot_token"] length] ? configured : @"xoxb-…", YES);
    self.channel = Input(self.original[@"discovery"][@"channel"], @"C…", NO);
    self.computer = Input(self.original[@"discovery"][@"name"], @"mac-a", NO);

    self.saveButton = [NSButton buttonWithTitle:L(@"Test connection and save") target:self action:@selector(save:)];
    NSMutableArray *buttons = [NSMutableArray arrayWithObject:self.saveButton];
    self.removeButton = nil;
    if ([self.original[@"app_token"] length] || [self.original[@"bot_token"] length]) {
        self.removeButton = [NSButton buttonWithTitle:L(@"Remove credentials…") target:self action:@selector(removeCredentials:)];
        [buttons addObject:self.removeButton];
    }
    self.feedback = CCPetsLabel(@"", 12, NSFontWeightRegular, CCPetsSecondaryInkColor());
    self.feedback.hidden = YES;
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.feedback setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *footer = [NSStackView stackViewWithViews:[@[self.feedback, spacer] arrayByAddingObjectsFromArray:buttons]];
    footer.alignment = NSLayoutAttributeCenterY;
    footer.spacing = 8;
    footer.edgeInsets = NSEdgeInsetsMake(8, 14, 8, 14);
    [CCPetsFormBuilder replaceRowsInCard:self.card withRows:@[
        [CCPetsFormBuilder rowWithTitle:@"Slack" controls:@[self.status, self.enabled]],
        [self rowForField:self.appToken key:@"app_token" title:@"App-Level Token"],
        [self rowForField:self.botToken key:@"bot_token" title:@"Bot Token"],
        [self rowForField:self.channel key:@"channel" title:L(@"Channel ID")],
        [self rowForField:self.computer key:@"name" title:L(@"Computer name")], footer
    ]];
    [self refreshStatus];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    self.feedback.hidden = YES;
    self.keychainNotice.hidden = YES;
    for (NSTextField *label in self.errors.allValues) label.hidden = YES;
}

- (void)showFeedback:(NSString *)text color:(NSColor *)color {
    self.feedback.textColor = color;
    self.feedback.stringValue = text;
    self.feedback.toolTip = text;
    self.feedback.hidden = NO;
    NSAccessibilityPostNotificationWithUserInfo(self.card, NSAccessibilityAnnouncementRequestedNotification,
        @{NSAccessibilityAnnouncementKey: text, NSAccessibilityPriorityKey: @(NSAccessibilityPriorityMedium)});
}

- (void)showFieldErrors:(NSDictionary<NSString *, NSString *> *)errors {
    for (NSString *key in self.errors) {
        NSTextField *label = self.errors[key];
        label.stringValue = errors[key] ?: @"";
        label.toolTip = errors[key];
        label.hidden = !label.stringValue.length;
    }
    if (errors.count) [self showFeedback:L(@"Settings were not saved. Check the highlighted fields.") color:NSColor.systemRedColor];
}

- (void)setTesting:(BOOL)testing {
    for (NSControl *control in @[self.enabled, self.appToken, self.botToken, self.channel, self.computer, self.saveButton])
        control.enabled = !testing;
    self.removeButton.enabled = !testing;
}

- (void)refreshStatus {
    BOOL savedEnabled = [self.original[@"enabled"] boolValue];
    self.status.hidden = (self.enabled.state == NSControlStateValueOn) != savedEnabled;
    if (self.status.hidden) return;
    NSString *status;
    if (!savedEnabled) {
        status = CCBridgeSlackAdapterRunning() ? L(@"Running in a terminal") : L(@"Off");
    } else if (!CCBridgeSlackAutoStartEnabled(self.original)) status = L(@"Configure both Slack tokens in Bridge → Remote Connections.");
    else if (!CCBridgeEnabled()) status = L(@"Waiting for Bridge to be enabled");
    else status = CCBridgeSlackConnectionDescription();
    self.status.stringValue = status ?: @"";
    self.status.toolTip = status;
}

- (void)showError:(NSString *)message {
    NSAlert *alert = [NSAlert new];
    alert.messageText = L(@"Slack settings");
    alert.informativeText = message;
    [alert beginSheetModalForWindow:self.card.window completionHandler:nil];
}

- (BOOL)commit:(NSDictionary *)changes app:(NSString *)app bot:(NSString *)bot remove:(BOOL)remove {
    NSString *error = nil;
    if (!CCBridgeSlackSaveConfiguration(self.original, changes, app, bot, remove, &error)) {
        if (remove) [self loadConfiguration];
        [self showError:error];
        return NO;
    }
    [self loadConfiguration];
    return YES;
}

- (void)toggleConnection:(NSButton *)sender {
    // First-time setup can be completed and saved with Bridge still off.
    BOOL edited = self.appToken.stringValue.length || self.botToken.stringValue.length ||
        ![Trim(self.channel) isEqual:self.original[@"discovery"][@"channel"] ?: @""] ||
        ![Trim(self.computer) isEqual:self.original[@"discovery"][@"name"] ?: @""];
    if (edited) { [self refreshStatus]; return; }
    if (sender.state == NSControlStateValueOn &&
        (![self.original[@"discovery"][@"channel"] length] || ![self.original[@"discovery"][@"name"] length] ||
         ![self.original[@"app_token"] length] || ![self.original[@"bot_token"] length])) {
        [self refreshStatus];
        return;
    }
    // Only an explicit test and save may request interactive Keychain access.
    NSMutableDictionary *changes = [self.original mutableCopy] ?: [NSMutableDictionary dictionary];
    changes[@"enabled"] = sender.state == NSControlStateValueOn ? @YES : @NO;
    if (![self commit:changes app:nil bot:nil remove:NO]) sender.state = [self.original[@"enabled"] boolValue];
}

- (void)save:(id)sender {
    if (self.testSession) return;
    [self.card.window makeFirstResponder:nil];
    NSString *app = Trim(self.appToken), *bot = Trim(self.botToken);
    NSString *channel = Trim(self.channel), *name = Trim(self.computer);
    NSMutableDictionary *issues = [NSMutableDictionary dictionary];
    NSDictionary *original = self.original;
    if (!app.length && ![original[@"app_token"] length]) issues[@"app_token"] = L(@"Required");
    else if (app.length && ![app hasPrefix:@"xapp-"]) issues[@"app_token"] = L(@"Enter a token starting with xapp-.");
    if (!bot.length && ![original[@"bot_token"] length]) issues[@"bot_token"] = L(@"Required");
    else if (bot.length && ![bot hasPrefix:@"xoxb-"]) issues[@"bot_token"] = L(@"Enter a token starting with xoxb-.");
    if (!channel.length) issues[@"channel"] = L(@"Required");
    else if (!CCBridgeSlackValidChannel(channel)) issues[@"channel"] = L(@"Enter a Slack channel ID starting with C or G.");
    if (!name.length) issues[@"name"] = L(@"Required");
    else if (!CCBridgeSlackValidHostName(name)) issues[@"name"] = L(@"Use 1–40 letters, digits, dots, underscores or hyphens, starting with a letter or digit.");
    [self showFieldErrors:issues];
    if (issues.count) return;

    NSMutableDictionary *changes = [original mutableCopy] ?: [NSMutableDictionary dictionary];
    changes[@"enabled"] = self.enabled.state == NSControlStateValueOn ? @YES : @NO;
    NSMutableDictionary *discovery = [original[@"discovery"] mutableCopy] ?: [NSMutableDictionary dictionary];
    discovery[@"channel"] = channel;
    discovery[@"name"] = name;
    changes[@"discovery"] = discovery;

    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForResource = 25;
    configuration.URLCache = nil;
    NSURLSession *http = [NSURLSession sessionWithConfiguration:configuration];
    self.testSession = http;
    self.keychainNotice.hidden = NO;
    [self.card.superview layoutSubtreeIfNeeded];
    [self.keychainNotice scrollRectToVisible:self.keychainNotice.bounds];
    [self.card.window displayIfNeeded];
    [self setTesting:YES];
    [self showFeedback:L(@"Testing Slack connection…") color:CCPetsSecondaryInkColor()];
    // The worker owns the bounded probe until it closes the session. Leaving the page drops the save callback.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *errors = CCBridgeSlackTestConnection(http, original, app, bot, channel);
        [http invalidateAndCancel];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) editor = weakSelf;
            if (!editor || editor.testSession != http) return;
            editor.testSession = nil;
            [editor setTesting:NO];
            if (errors.count) { [editor showFieldErrors:errors]; return; }
            if ([editor commit:changes app:app bot:bot remove:NO]) {
                [editor showFeedback:L(@"Slack connection test passed. Settings saved.") color:CCPetsStatusColor(CCPetsStatusOK)];
            } else {
                [editor showFeedback:L(@"Connection verified, but the settings could not be saved.") color:NSColor.systemRedColor];
            }
        });
    });
}

- (void)removeCredentials:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = L(@"Remove Slack credentials?");
    alert.informativeText = L(@"This disables the connection and removes both tokens from Keychain.");
    [alert addButtonWithTitle:L(@"Cancel")];
    [alert addButtonWithTitle:L(@"Remove")];
    [alert beginSheetModalForWindow:self.card.window completionHandler:^(NSModalResponse choice) {
        if (choice != NSAlertSecondButtonReturn) return;
        NSMutableDictionary *changes = [self.original mutableCopy];
        changes[@"enabled"] = @NO;
        [self commit:changes app:nil bot:nil remove:YES];
    }];
}
@end
