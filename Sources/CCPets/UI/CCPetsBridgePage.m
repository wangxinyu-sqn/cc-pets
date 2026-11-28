#import "CCPetsBridgePage.h"
#import "CCPetsBridge.h"
#import "CCPetsFormBuilder.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsL10n.h"
#import "CCPetsSlackEditor.h"
#import "CCPetsUIStyle.h"
#import "CCPetsWorkbench.h"

@protocol CCBridgePageActions <CCPetsWorkbenchSource>
- (BOOL)bridgeCommandRunning;
- (BOOL)currentBridgeStateForSwitch:(NSButton *)sender;
- (void)toggleBridgeEnabled:(NSButton *)sender;
- (void)toggleBridgeWake:(NSButton *)sender;
- (void)toggleBridgeEditGuard:(NSButton *)sender;
- (void)toggleBridgeTabTitle:(NSButton *)sender;
- (void)toggleBridgeApproval:(NSButton *)sender;
- (void)toggleBridgeBadge:(NSButton *)sender;
- (void)toggleBridgeNotification:(NSButton *)sender;
@end

static id<CCBridgePageActions> Actions(void) { return (id)NSApp.delegate; }

@interface CCPetsBridgePage ()
@property(nonatomic) CCPetsFormBuilder *form;
@property(nonatomic) NSSegmentedControl *tabs;
@property(nonatomic) NSButton *enable;
@property(nonatomic) CCPetsSlackEditor *remote;
@property(nonatomic) NSTimer *timer;
@property(nonatomic) NSDictionary *lastMessages;
@property(nonatomic) NSMutableArray<NSButton *> *settings;
@end

@implementation CCPetsBridgePage

- (void)loadView {
    self.tabs = [NSSegmentedControl segmentedControlWithLabels:@[L(@"Message Activity"), L(@"Remote Connections"), L(@"Bridge Settings")]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(selectTab:)];
    CCPetsApplyAccent(self.tabs);
    self.tabs.selectedSegment = 0;
    NSStackView *toolbar = [NSStackView stackViewWithViews:@[self.tabs]];
    toolbar.distribution = NSStackViewDistributionGravityAreas;
    self.form = [[CCPetsFormBuilder alloc] initWithTitle:L(@"Bridge") subtitle:@"" toolbar:toolbar];
    self.view = self.form.view;
    self.enable = [CCPetsSwitch new];
    self.enable.target = Actions();
    self.enable.action = @selector(toggleBridgeEnabled:);
    [self.enable setAccessibilityLabel:L(@"Enable Bridge")];
    [self.form setAccessoryViews:@[[NSTextField labelWithString:L(@"Enable Bridge")], self.enable]];
    [self renderTab];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakSelf.view.window && weakSelf.tabs.selectedSegment == 0) [Actions() markWorkbenchMessagesSeen];
    });
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
        if (weakSelf.view.window.isVisible && !weakSelf.view.window.isMiniaturized) [weakSelf refresh];
    }];
}

- (void)viewWillDisappear {
    [self.timer invalidate];
    self.timer = nil;
    [super viewWillDisappear];
}

- (void)dealloc { [_timer invalidate]; }

- (void)selectTab:(id)sender {
    if (self.tabs.selectedSegment == 0) [Actions() markWorkbenchMessagesSeen];
    [self renderTab];
}

- (void)showSettings {
    self.tabs.selectedSegment = 2;
    [self renderTab];
}

- (void)renderTab {
    [self.form removeAllContent];
    self.settings = [NSMutableArray array];
    self.lastMessages = nil;
    self.remote = nil;
    if (self.tabs.selectedSegment == 1) {
        self.remote = [[CCPetsSlackEditor alloc] initWithForm:self.form];
    } else if (self.tabs.selectedSegment == 2) {
        [self buildSettings];
    }
    [self refresh];
    [self.form.scrollView.contentView scrollToPoint:NSZeroPoint];
}

- (NSView *)setting:(NSString *)title detail:(NSString *)detail action:(SEL)action tag:(NSInteger)tag {
    CCPetsSwitch *button = [CCPetsSwitch new];
    button.target = Actions();
    button.action = action;
    [button setAccessibilityLabel:title];
    button.tag = tag;
    [self.settings addObject:button];
    return [CCPetsFormBuilder rowWithTitle:title subtitle:detail controls:@[button]];
}

- (void)buildSettings {
    [self.form addGroupWithTitle:L(@"Session Behavior") rows:@[
        [self setting:L(@"Auto-wake") detail:L(@"Wake idle sessions automatically. When off, messages wait in the inbox until that session's next input, which saves tokens. Codex needs a session restart") action:@selector(toggleBridgeWake:) tag:0],
        [self setting:L(@"Edit guard") detail:L(@"Pause once with an explanation when editing a file another session reserved; retrying goes through. Codex needs a session restart") action:@selector(toggleBridgeEditGuard:) tag:0],
        [self setting:L(@"Tab nicknames") detail:L(@"Append Bridge nicknames to terminal tab titles. Restart CLI sessions after turning this on.") action:@selector(toggleBridgeTabTitle:) tag:0]
    ] footer:nil];
    NSArray *names = @[L(@"Read"), L(@"Send"), L(@"Reserve"), L(@"Rename")];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < names.count; i++) {
        [rows addObject:[self setting:names[i] detail:nil action:@selector(toggleBridgeApproval:) tag:i+1]];
    }
    [self.form addGroupWithTitle:L(@"Auto-approve") rows:rows footer:L(@"Each group applies to the integrated Agents. Restart sessions to reload tool permissions")];
    [self.form addGroupWithTitle:L(@"Pet alerts") rows:@[
        [self setting:L(@"Bridge unread badge") detail:nil action:@selector(toggleBridgeBadge:) tag:0],
        [self setting:L(@"Bridge message notifications") detail:L(@"Only who sent it to whom, never the message") action:@selector(toggleBridgeNotification:) tag:0]
    ] footer:nil];
}

- (void)refresh {
    BOOL enabled = CCBridgeEnabled();
    BOOL busy = [Actions() bridgeCommandRunning];
    self.enable.enabled = !busy;
    if (!busy) self.enable.state = enabled;
    if (enabled) {
        NSDictionary *sessions = CCBridgeSessions();
        self.form.subtitleLabel.stringValue = [NSString stringWithFormat:L(@"%lu sessions · %lu reserved"),
            (unsigned long)sessions.count, (unsigned long)CCBridgeActiveReservationCount([NSSet setWithArray:sessions.allKeys])];
    } else {
        self.form.subtitleLabel.stringValue = L(@"Bridge is off");
    }
    if (self.remote) { [self.remote refreshStatus]; return; }
    if (self.tabs.selectedSegment == 2) {
        for (NSButton *button in self.settings) {
            button.enabled = enabled && !busy;
            if (button.action == @selector(toggleBridgeBadge:)) button.state = [NSUserDefaults.standardUserDefaults boolForKey:BridgeBadgeEnabledKey];
            else if (button.action == @selector(toggleBridgeNotification:)) button.state = [NSUserDefaults.standardUserDefaults boolForKey:BridgeNotificationKey];
            else if (!busy) button.state = [Actions() currentBridgeStateForSwitch:button];
        }
        return;
    }
    NSDictionary *messages = [Actions() workbenchMessages] ?: @{};
    if ([self.lastMessages isEqual:messages]) return;
    self.lastMessages = messages;
    NSPoint origin = self.form.scrollView.contentView.bounds.origin;
    [self.form removeAllContent];
    [self.form addGroupWithTitle:nil rows:[self messageRows:messages] footer:nil];
    [self.form.scrollView.documentView layoutSubtreeIfNeeded];
    [self.form.scrollView.contentView scrollToPoint:origin];
}

- (void)jumpToTerminal:(NSButton *)sender { [Actions() focusBridgeSessionWithID:sender.identifier]; }

#pragma mark 消息

- (NSView *)messageRowWithLeading:(NSView *)leading title:(NSView *)title detail:(NSView *)detail
    trailing:(NSArray<NSView *> *)trailing {
    NSView *row = [NSView new];
    NSStackView *right = [NSStackView stackViewWithViews:trailing];
    right.spacing = 8;
    right.alignment = NSLayoutAttributeCenterY;
    [right setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [right setContentCompressionResistancePriority:NSLayoutPriorityRequired
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    for (NSView *view in @[leading, title, detail, right]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:view];
        [view.centerYAnchor constraintEqualToAnchor:row.centerYAnchor].active = YES;
    }
    [title setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [detail setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:40],
        [leading.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [leading.widthAnchor constraintEqualToConstant:44],
        // 标题不设宽度上限：右边空着时名字能完整显示，最宽只到 detail / 右侧按钮之前。
        [title.leadingAnchor constraintEqualToAnchor:leading.trailingAnchor constant:8],
        [detail.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:12],
        [detail.trailingAnchor constraintLessThanOrEqualToAnchor:right.leadingAnchor constant:-12],
        [right.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
    ]];
    return row;
}

// 发件人 → 收件人，名字加粗，箭头淡一些。
- (NSTextField *)routeFrom:(NSString *)from to:(NSString *)to {
    NSMutableAttributedString *text = [NSMutableAttributedString new];
    NSDictionary *strong = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
                             NSForegroundColorAttributeName: CCPetsInkColor()};
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:from ?: @"" attributes:strong]];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"  →  " attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName: CCPetsTertiaryInkColor()}]];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:to ?: @"" attributes:strong]];
    // 富文本标签默认会折行；这里一律单行，名字太长就在末尾省略，不把"→ 收件人"挤到第二行。
    // 抗压缩优先级比右边的说明高：位置不够时先让说明让位。
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    [text addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(0, text.length)];
    NSTextField *label = [NSTextField labelWithAttributedString:text];
    label.usesSingleLineMode = YES;
    label.cell.wraps = NO;
    label.maximumNumberOfLines = 1;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    // 窗口太窄仍被截断时，悬停能看到完整的发件人和收件人。
    label.toolTip = [NSString stringWithFormat:@"%@ → %@", from ?: @"", to ?: @""];
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

- (NSArray<NSView *> *)messageRows:(NSDictionary *)messages {
    NSMutableArray<NSView *> *rows = [NSMutableArray array];
    if (![messages[@"enabled"] boolValue]) {
        NSView *row = [CCPetsFormBuilder rowWithTitle:L(@"Bridge is off")
            subtitle:L(@"Enable Bridge to exchange messages between sessions.") controls:@[]];
        return @[row];
    }
    for (NSDictionary *entry in messages[@"pending"]) {
        NSString *session = entry[@"session"];
        NSUInteger count = [entry[@"count"] unsignedIntegerValue];
        NSTextField *icon = CCPetsLabel(@"", 12, NSFontWeightRegular, CCPetsTertiaryInkColor());
        NSTextField *name = CCPetsLabel(entry[@"displayName"] ?: entry[@"name"], 12, NSFontWeightSemibold, CCPetsInkColor());
        NSTextField *detail = CCPetsLabel(count == 1 ? L(@"1 message waiting. Say anything in that terminal to deliver it.")
            : [NSString stringWithFormat:L(@"%lu messages waiting. Say anything in that terminal to deliver them."),
                (unsigned long)count], 12, NSFontWeightRegular, CCPetsSecondaryInkColor());
        CCPetsChipView *chip = [[CCPetsChipView alloc] initWithText:L(@"Waiting") kind:CCPetsStatusWarn];
        NSButton *jump = [NSButton buttonWithTitle:L(@"Go to Terminal") target:self action:@selector(jumpToTerminal:)];
        jump.identifier = session;
        [rows addObject:[self messageRowWithLeading:icon title:name detail:detail trailing:@[chip, jump]]];
    }
    NSArray *deliveries = messages[@"deliveries"];
    for (NSDictionary *delivery in deliveries) {
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:[delivery[@"at"] doubleValue]];
        NSTextField *time = CCPetsNumberLabel([NSDateFormatter localizedStringFromDate:date
            dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle], 12, NSFontWeightRegular,
            CCPetsTertiaryInkColor());
        NSTextField *route = [self routeFrom:CCBridgeSessionDisplayName(delivery[@"fromIdentity"])
            to:CCBridgeSessionDisplayName(delivery[@"toIdentity"])];
        NSString *locations = [NSString stringWithFormat:@"%@ → %@",
            [delivery[@"fromIdentity"][@"remote"] boolValue] ? L(@"Remote") : L(@"Local"),
            [delivery[@"toIdentity"][@"remote"] boolValue] ? L(@"Remote") : L(@"Local")];
        NSTextField *detail = CCPetsLabel(locations, 12, NSFontWeightRegular, CCPetsSecondaryInkColor());
        BOOL unseen = [delivery[@"unseen"] boolValue];
        CCPetsChipView *chip = [[CCPetsChipView alloc] initWithText:unseen ? L(@"Unread") : L(@"Delivered")
            kind:unseen ? CCPetsStatusWork : CCPetsStatusOK];
        NSDictionary *terminalIdentity = delivery[@"terminalIdentity"];
        NSString *session = terminalIdentity[@"session"];
        NSButton *jump = [NSButton buttonWithTitle:L(@"Go to Terminal") target:self action:@selector(jumpToTerminal:)];
        jump.identifier = session;
        jump.toolTip = [NSString stringWithFormat:L(@"Jump to %@'s terminal"), CCBridgeSessionDisplayName(terminalIdentity)];
        [rows addObject:[self messageRowWithLeading:time title:route detail:detail trailing:@[chip, jump]]];
    }
    if (rows.count == 0) {
        [rows addObject:[CCPetsFormBuilder rowWithTitle:L(@"No messages recently") controls:@[]]];
    }
    return rows;
}

@end
