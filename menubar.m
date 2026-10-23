#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>
#import <Carbon/Carbon.h>
#import <math.h>
#import <objc/message.h>
#import <unistd.h>

static const int kLimitValues[5] = {80, 85, 90, 95, 100};
static const UInt32 kLimitKeyCodes[5] = {kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5};
static EventHotKeyRef gHotKeys[6];
static BOOL gHotKeyHandlerInstalled = NO;
static id gHotKeyOwner = nil;

static UInt32 settingsKeyCode(void) {
    if (![NSUserDefaults.standardUserDefaults objectForKey:@"settingsHotKeyCode"]) return kVK_ANSI_B;
    return (UInt32)[NSUserDefaults.standardUserDefaults integerForKey:@"settingsHotKeyCode"];
}

static UInt32 settingsMods(void) {
    if (![NSUserDefaults.standardUserDefaults objectForKey:@"settingsHotKeyModifiers"]) return controlKey | optionKey;
    return (UInt32)[NSUserDefaults.standardUserDefaults integerForKey:@"settingsHotKeyModifiers"];
}

static NSString *keyCharacter(UInt32 keyCode) {
    TISInputSourceRef source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource();
    if (!source) return @"";
    NSString *result = @"";
    CFDataRef data = (CFDataRef)TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData);
    if (data) {
        const UCKeyboardLayout *layout = (const UCKeyboardLayout *)CFDataGetBytePtr(data);
        UInt32 deadKeyState = 0;
        UniChar chars[4] = {0};
        UniCharCount length = 0;
        UCKeyTranslate(layout, (UInt16)keyCode, kUCKeyActionDisplay, 0, LMGetKbdType(), kUCKeyTranslateNoDeadKeysBit, &deadKeyState, 4, &length, chars);
        if (length > 0) result = [[NSString stringWithCharacters:chars length:length] lowercaseString];
    }
    CFRelease(source);
    return result;
}

static NSString *shortcutLabel(UInt32 keyCode, UInt32 mods) {
    NSMutableString *label = [NSMutableString string];
    if (mods & controlKey) [label appendString:@"⌃"];
    if (mods & optionKey) [label appendString:@"⌥"];
    if (mods & shiftKey) [label appendString:@"⇧"];
    if (mods & cmdKey) [label appendString:@"⌘"];
    NSString *character = keyCharacter(keyCode);
    [label appendString:character.length ? character.uppercaseString : @"?"];
    return label;
}

static NSEventModifierFlags eventModifiers(UInt32 mods) {
    NSEventModifierFlags flags = 0;
    if (mods & controlKey) flags |= NSEventModifierFlagControl;
    if (mods & optionKey) flags |= NSEventModifierFlagOption;
    if (mods & shiftKey) flags |= NSEventModifierFlagShift;
    if (mods & cmdKey) flags |= NSEventModifierFlagCommand;
    return flags;
}

static BOOL reservedLimitShortcut(UInt32 keyCode, UInt32 mods) {
    if (mods != (controlKey | optionKey)) return NO;
    for (int index = 0; index < 5; index++) {
        if (keyCode == kLimitKeyCodes[index]) return YES;
    }
    return NO;
}

static id chargeClient(void) {
    static id instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *bundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/PowerUI.framework"];
        if (![bundle loadAndReturnError:nil]) return;
        Class cls = NSClassFromString(@"PowerUISmartChargeClient");
        instance = ((id (*)(id, SEL, id))objc_msgSend)(
            [cls alloc], @selector(initWithClientName:), @"맥북 배터리 제어");
    });
    return instance;
}

static NSString *errorText(NSError *error) {
    if (!error) return nil;
    return error.localizedDescription.length ? error.localizedDescription : error.description;
}

static NSDictionary *chargeStatus(void) {
    id charge = chargeClient();
    if (!charge) return @{@"supported": @NO, @"error": @"충전 제어 기능을 불러오지 못했습니다."};
    BOOL supported = ((BOOL (*)(id, SEL))objc_msgSend)(charge, @selector(isMCLSupported));
    NSError *__autoreleasing limitError = nil;
    unsigned char limit = ((unsigned char (*)(id, SEL, NSError *__autoreleasing *))objc_msgSend)(
        charge, @selector(getMCLLimitWithError:), &limitError);
    NSError *__autoreleasing enabledError = nil;
    unsigned long long enabled = ((unsigned long long (*)(id, SEL, NSError *__autoreleasing *))objc_msgSend)(
        charge, @selector(isMCLCurrentlyEnabled:), &enabledError);
    NSError *__autoreleasing availableError = nil;
    id available = ((id (*)(id, SEL, NSError *__autoreleasing *))objc_msgSend)(
        charge, @selector(availableChargeLimitsWithError:), &availableError);
    NSMutableArray *limits = [NSMutableArray array];
    if ([available isKindOfClass:[NSArray class]]) {
        for (id value in available) [limits addObject:@([value integerValue])];
    }
    if (limits.count == 0) [limits addObjectsFromArray:@[@80, @85, @90, @95, @100]];
    return @{
        @"supported": @(supported),
        @"enabled": @(enabled != 0),
        @"limit": @(limit),
        @"available": limits,
        @"error": errorText(limitError ?: enabledError ?: availableError) ?: [NSNull null]
    };
}

static int activeChargeLimit(NSDictionary *charge) {
    if (![charge[@"enabled"] boolValue]) return 100;
    int limit = [charge[@"limit"] intValue];
    if (limit < 80 || limit > 100) return 100;
    return limit;
}

static BOOL userInitiatedChange(void) {
    NSEvent *event = NSApp.currentEvent;
    if (!event) return NO;
    switch (event.type) {
        case NSEventTypeLeftMouseDown:
        case NSEventTypeLeftMouseUp:
        case NSEventTypeRightMouseDown:
        case NSEventTypeRightMouseUp:
        case NSEventTypeOtherMouseDown:
        case NSEventTypeOtherMouseUp:
        case NSEventTypeKeyDown:
        case NSEventTypeKeyUp:
            return YES;
        default:
            return NO;
    }
}

static NSString *setChargeLimit(int limit) {
    id charge = chargeClient();
    if (!charge) return @"충전 제어 기능을 불러오지 못했습니다.";
    NSError *__autoreleasing setError = nil;
    BOOL setOK = ((BOOL (*)(id, SEL, unsigned char, NSError *__autoreleasing *))objc_msgSend)(
        charge, @selector(setMCLLimit:error:), (unsigned char)limit, &setError);
    if (!setOK) return errorText(setError) ?: @"충전 한도를 바꾸지 못했습니다.";
    NSError *__autoreleasing modeError = nil;
    SEL mode = limit >= 100 ? @selector(disableMCL:) : @selector(enableMCL:);
    BOOL modeOK = ((BOOL (*)(id, SEL, NSError *__autoreleasing *))objc_msgSend)(charge, mode, &modeError);
    if (!modeOK) return errorText(modeError) ?: @"충전 한도 적용 상태를 바꾸지 못했습니다.";
    return nil;
}

static NSDictionary *batteryDict(id node) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        if (node[@"CycleCount"] && node[@"Voltage"]) return node;
        for (id value in [node allValues]) {
            NSDictionary *found = batteryDict(value);
            if (found) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in node) {
            NSDictionary *found = batteryDict(value);
            if (found) return found;
        }
    }
    return nil;
}

static NSString *commandOutput(NSString *launchPath, NSArray<NSString *> *arguments) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:launchPath];
    task.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) return @"";
    [task waitUntilExit];
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static NSDictionary *readBattery(void) {
    NSString *pm = commandOutput(@"/usr/bin/pmset", @[@"-g", @"batt"]);
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)%;\\s*([^;]+);\\s*(\\d+:\\d+)?" options:0 error:nil];
    NSTextCheckingResult *match = [pattern firstMatchInString:pm options:0 range:NSMakeRange(0, pm.length)];
    NSNumber *percent = nil;
    NSString *state = @"unknown";
    NSString *remaining = nil;
    if (match) {
        percent = @([[pm substringWithRange:[match rangeAtIndex:1]] integerValue]);
        state = [[pm substringWithRange:[match rangeAtIndex:2]] lowercaseString];
        if ([match rangeAtIndex:3].location != NSNotFound) remaining = [pm substringWithRange:[match rangeAtIndex:3]];
    }
    NSString *source = [pm containsString:@"Battery Power"] ? @"battery" : @"ac";

    NSTask *ioreg = [[NSTask alloc] init];
    ioreg.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/ioreg"];
    ioreg.arguments = @[@"-rn", @"AppleSmartBattery", @"-a"];
    NSPipe *pipe = [NSPipe pipe];
    ioreg.standardOutput = pipe;
    ioreg.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSDictionary *info = @{};
    if ([ioreg launchAndReturnError:nil]) {
        [ioreg waitUntilExit];
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
        info = batteryDict(plist) ?: @{};
    }
    NSDictionary *pack = [info[@"BatteryData"] isKindOfClass:[NSDictionary class]] ? info[@"BatteryData"] : @{};
    double design = [pack[@"DesignCapacity"] ?: info[@"DesignCapacity"] doubleValue];
    double full = [pack[@"FullChargeCapacity"] ?: info[@"FullChargeCapacity"] doubleValue];
    NSNumber *health = design > 0 ? @(lround(full / design * 100.0)) : nil;
    NSNumber *power = pack[@"BatteryPower"] ?: info[@"BatteryPower"];
    NSNumber *voltage = info[@"Voltage"];
    if (!percent) percent = info[@"CurrentCapacity"];

    NSMutableDictionary *status = [@{
        @"state": state,
        @"source": source,
        @"charge": chargeStatus()
    } mutableCopy];
    NSNumber *amperage = info[@"InstantAmperage"] ?: info[@"Amperage"];
    if (percent) status[@"percent"] = percent;
    if (remaining) status[@"timeRemaining"] = remaining;
    if (health) status[@"healthPercent"] = health;
    if (info[@"CycleCount"]) status[@"cycleCount"] = info[@"CycleCount"];
    if (info[@"DesignCycleCount9C"]) status[@"designCycles"] = info[@"DesignCycleCount9C"];
    if (full > 0) status[@"fullMah"] = @(lround(full));
    if (design > 0) status[@"designMah"] = @(lround(design));
    if (pack[@"RemainingCapacity"]) status[@"remainingMah"] = pack[@"RemainingCapacity"];
    if (power) status[@"powerWatts"] = @(round([power doubleValue] / 10.0) / 100.0);
    if (voltage) status[@"voltage"] = @(round([voltage doubleValue] / 10.0) / 100.0);
    if (amperage) status[@"amperage"] = @(round([amperage doubleValue] / 10.0) / 100.0);
    return status;
}

static NSString *stateLabel(NSDictionary *status) {
    NSDictionary *labels = @{
        @"charging": @"충전 중",
        @"discharging": @"배터리 사용 중",
        @"charged": @"완충됨",
        @"finishing charge": @"충전 마무리",
        @"not charging": @"충전 멈춤"
    };
    return labels[status[@"state"]] ?: @"상태 확인 중";
}

static NSString *remainingLabel(NSString *text) {
    if (text.length == 0) return nil;
    NSArray *parts = [text componentsSeparatedByString:@":"];
    if (parts.count != 2) return text;
    int hours = [parts[0] intValue];
    int minutes = [parts[1] intValue];
    if (hours == 0 && minutes == 0) return nil;
    if (hours == 0) return [NSString stringWithFormat:@"%d분 남음", minutes];
    if (minutes == 0) return [NSString stringWithFormat:@"%d시간 남음", hours];
    return [NSString stringWithFormat:@"%d시간 %d분 남음", hours, minutes];
}

static NSString *symbolName(NSDictionary *status) {
    int percent = [status[@"percent"] intValue];
    BOOL charging = [status[@"state"] isEqualToString:@"charging"] || [status[@"state"] isEqualToString:@"finishing charge"];
    int bucket = 0;
    if (percent >= 95) bucket = 100;
    else if (percent >= 70) bucket = 75;
    else if (percent >= 40) bucket = 50;
    else if (percent >= 15) bucket = 25;
    return [NSString stringWithFormat:charging ? @"battery.%dpercent.bolt" : @"battery.%dpercent", bucket];
}

@interface BatteryApp : NSObject <NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *menu;
@property (nonatomic, strong) NSDictionary *status;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSWindow *settingsWindow;
@property (nonatomic, strong) NSTextField *percentLabel;
@property (nonatomic, strong) NSTextField *stateLabel;
@property (nonatomic, strong) NSTextField *timeLabel;
@property (nonatomic, strong) NSProgressIndicator *meter;
@property (nonatomic, strong) NSTextField *healthValue;
@property (nonatomic, strong) NSTextField *cycleValue;
@property (nonatomic, strong) NSTextField *powerValue;
@property (nonatomic, strong) NSTextField *voltageValue;
@property (nonatomic, strong) NSTextField *capacityValue;
@property (nonatomic, strong) NSTextField *remainingValue;
@property (nonatomic, strong) NSTextField *amperageValue;
@property (nonatomic, strong) NSTextField *sourceValue;
@property (nonatomic, strong) NSButton *topUpButton;
@property (nonatomic, strong) NSButton *calibrationButton;
@property (nonatomic, strong) NSButton *sailCheckbox;
@property (nonatomic, strong) NSPopUpButton *lowerPopup;
@property (nonatomic, strong) NSPopUpButton *upperPopup;
@property (nonatomic, strong) NSSegmentedControl *limitControl;
@property (nonatomic, strong) NSTextField *noteLabel;
@property (nonatomic, copy) NSArray<NSNumber *> *limitValues;
@property (nonatomic, assign) BOOL suppressLimitChange;
@property (nonatomic, strong) NSButton *shortcutButton;
@property (nonatomic, strong) id keyMonitor;
@property (nonatomic, assign) BOOL recordingShortcut;
@end

@interface BatteryApp (HotKeys)
- (void)openSettings:(id)sender;
- (void)applyLimit:(int)limit;
@end

static OSStatus HotKeyPressed(EventHandlerCallRef nextHandler, EventRef event, void *userData) {
    (void)nextHandler;
    (void)userData;
    EventHotKeyID hotKeyID;
    GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hotKeyID), NULL, &hotKeyID);
    UInt32 ident = hotKeyID.id;
    dispatch_async(dispatch_get_main_queue(), ^{
        BatteryApp *owner = gHotKeyOwner;
        if (!owner) return;
        if (ident == 1) {
            [owner openSettings:nil];
        } else if (ident >= 10 && ident < 15) {
            [owner applyLimit:kLimitValues[ident - 10]];
        }
    });
    return noErr;
}

@implementation BatteryApp

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    pid_t mine = getpid();
    for (NSRunningApplication *running in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"local.ssc.macbook-battery"]) {
        if (running.processIdentifier != mine) [running forceTerminate];
    }
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.menu = [[NSMenu alloc] init];
    self.menu.delegate = self;
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.menu = self.menu;
    self.statusItem.button.imagePosition = NSImageLeft;
    self.statusItem.button.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
    gHotKeyOwner = self;
    [self installMainMenu];
    [self registerHotKeys];
    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:8 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--settings"]) [self openSettings:nil];
}

- (void)refresh {
    self.status = readBattery();
    [self applyAutomaticModes];
    NSNumber *percent = self.status[@"percent"];
    NSDictionary *charge = self.status[@"charge"];
    NSString *title = percent ? [NSString stringWithFormat:@"%@%%", percent] : @"배터리";
    int limit = [charge[@"limit"] intValue];
    if ([charge[@"enabled"] boolValue] && limit > 0 && limit < 100) {
        title = [title stringByAppendingFormat:@" · %d", limit];
    }
    self.statusItem.button.title = title;
    NSImage *image = [NSImage imageWithSystemSymbolName:symbolName(self.status) accessibilityDescription:@"배터리"];
    image.template = YES;
    self.statusItem.button.image = image;
    self.statusItem.button.toolTip = @"맥북 배터리 제어";
    [self updateSettingsWindow];
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self refresh];
    [self rebuildMenu];
}

- (NSMenuItem *)disabledItem:(NSString *)title {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.enabled = NO;
    return item;
}

- (void)rebuildMenu {
    [self.menu removeAllItems];
    NSDictionary *status = self.status ?: @{};
    NSString *headline = stateLabel(status);
    NSString *remaining = remainingLabel(status[@"timeRemaining"]);
    if (remaining) headline = [headline stringByAppendingFormat:@"  ·  %@", remaining];
    [self.menu addItem:[self disabledItem:headline]];
    [self.menu addItem:[NSMenuItem separatorItem]];

    if (status[@"healthPercent"]) {
        [self.menu addItem:[self disabledItem:[NSString stringWithFormat:@"성능 최대치   %@%%", status[@"healthPercent"]]]];
    }
    if (status[@"cycleCount"]) {
        [self.menu addItem:[self disabledItem:[NSString stringWithFormat:@"충전 횟수   %@", status[@"cycleCount"]]]];
    }
    if (status[@"powerWatts"]) {
        double watts = [status[@"powerWatts"] doubleValue];
        [self.menu addItem:[self disabledItem:[NSString stringWithFormat:@"지금 전력   %@ %.1fW", watts < 0 ? @"방전" : @"충전", fabs(watts)]]];
    }
    if (status[@"voltage"]) {
        [self.menu addItem:[self disabledItem:[NSString stringWithFormat:@"전압   %.2fV", [status[@"voltage"] doubleValue]]]];
    }
    if (status[@"fullMah"] && status[@"designMah"]) {
        [self.menu addItem:[self disabledItem:[NSString stringWithFormat:@"용량   %@ / %@ mAh", status[@"fullMah"], status[@"designMah"]]]];
    }
    if (status[@"remainingMah"]) {
        [self.menu addItem:[self disabledItem:[NSString stringWithFormat:@"남은 용량   %@ mAh", status[@"remainingMah"]]]];
    }
    if (status[@"amperage"]) {
        [self.menu addItem:[self disabledItem:[NSString stringWithFormat:@"전류   %.2fA", [status[@"amperage"] doubleValue]]]];
    }
    NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:@"batteryMode"] ?: @"none";
    if ([mode isEqualToString:@"topup"]) [self.menu addItem:[self disabledItem:@"한 번만 완충 중"]];
    if ([mode isEqualToString:@"calibration"]) [self.menu addItem:[self disabledItem:@"배터리 보정 중"]];
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"sailEnabled"]) [self.menu addItem:[self disabledItem:@"범위 유지 켜짐"]];

    [self.menu addItem:[NSMenuItem separatorItem]];
    [self.menu addItem:[self disabledItem:@"충전 한도"]];
    NSDictionary *charge = status[@"charge"];
    if ([charge[@"error"] isKindOfClass:[NSString class]]) {
        [self.menu addItem:[self disabledItem:charge[@"error"]]];
    }
    int current = activeChargeLimit(charge);
    NSDictionary *limitKeys = @{@80: @"1", @85: @"2", @90: @"3", @95: @"4", @100: @"5"};
    for (NSNumber *limit in charge[@"available"]) {
        NSString *key = limitKeys[limit] ?: @"";
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@%%", limit] action:@selector(chooseLimit:) keyEquivalent:key];
        item.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
        item.target = self;
        item.tag = limit.integerValue;
        item.state = limit.integerValue == current ? NSControlStateValueOn : NSControlStateValueOff;
        item.enabled = [charge[@"supported"] boolValue];
        [self.menu addItem:item];
    }

    [self.menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *topUp = [[NSMenuItem alloc] initWithTitle:@"한 번만 완충" action:@selector(startTopUp:) keyEquivalent:@""];
    topUp.target = self;
    [self.menu addItem:topUp];
    BOOL calibrating = [[NSUserDefaults.standardUserDefaults stringForKey:@"batteryMode"] isEqualToString:@"calibration"];
    NSMenuItem *calibration = [[NSMenuItem alloc] initWithTitle:(calibrating ? @"보정 끝내기" : @"보정 시작") action:(calibrating ? @selector(endCalibration:) : @selector(startCalibration:)) keyEquivalent:@""];
    calibration.target = self;
    [self.menu addItem:calibration];
    NSMenuItem *sail = [[NSMenuItem alloc] initWithTitle:@"범위 유지" action:@selector(toggleSail:) keyEquivalent:@""];
    sail.target = self;
    sail.state = [NSUserDefaults.standardUserDefaults boolForKey:@"sailEnabled"] ? NSControlStateValueOn : NSControlStateValueOff;
    [self.menu addItem:sail];

    [self.menu addItem:[NSMenuItem separatorItem]];
    NSString *settingsKey = keyCharacter(settingsKeyCode());
    NSMenuItem *dashboard = [[NSMenuItem alloc] initWithTitle:@"설정…" action:@selector(openSettings:) keyEquivalent:settingsKey.length ? settingsKey : @""];
    dashboard.keyEquivalentModifierMask = eventModifiers(settingsMods());
    dashboard.target = self;
    [self.menu addItem:dashboard];

    SMAppService *service = [SMAppService mainAppService];
    NSMenuItem *login = [[NSMenuItem alloc] initWithTitle:@"로그인할 때 열기" action:@selector(toggleLogin:) keyEquivalent:@""];
    login.target = self;
    login.state = service.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self.menu addItem:login];

    [self.menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"종료" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    [self.menu addItem:quit];
}

- (void)chooseLimit:(NSMenuItem *)item {
    [self applyLimit:(int)item.tag];
}

- (void)applyLimit:(int)limit {
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"sailEnabled"];
    [NSUserDefaults.standardUserDefaults setObject:@"none" forKey:@"batteryMode"];
    NSString *failure = setChargeLimit(limit);
    if (failure && !self.settingsWindow.isVisible) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp activate];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"충전 한도를 바꾸지 못했습니다";
        alert.informativeText = failure;
        [alert runModal];
        if (!self.settingsWindow.isVisible) [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }
    if (self.settingsWindow) {
        self.noteLabel.stringValue = failure ?: (limit >= 100 ? @"충전 제한을 껐습니다." : [NSString stringWithFormat:@"충전 한도를 %d%%로 맞춰 두었습니다.", limit]);
        self.noteLabel.textColor = failure ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    }
    [self refresh];
}

- (void)installMainMenu {
    NSMenu *menuBar = [[NSMenu alloc] init];

    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"맥북 배터리 제어"];
    NSMenuItem *settings = [[NSMenuItem alloc] initWithTitle:@"설정…" action:@selector(openSettings:) keyEquivalent:@","];
    settings.target = self;
    [appMenu addItem:settings];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"종료" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    [appMenu addItem:quit];
    appItem.submenu = appMenu;
    [menuBar addItem:appItem];

    NSMenuItem *batteryItem = [[NSMenuItem alloc] init];
    NSMenu *batteryMenu = [[NSMenu alloc] initWithTitle:@"배터리"];
    for (int index = 0; index < 5; index++) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"충전 한도 %d%%", kLimitValues[index]] action:@selector(chooseLimit:) keyEquivalent:[NSString stringWithFormat:@"%d", index + 1]];
        item.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
        item.target = self;
        item.tag = kLimitValues[index];
        [batteryMenu addItem:item];
    }
    batteryItem.submenu = batteryMenu;
    [menuBar addItem:batteryItem];

    NSMenuItem *windowItem = [[NSMenuItem alloc] init];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"윈도우"];
    [windowMenu addItemWithTitle:@"닫기" action:@selector(performClose:) keyEquivalent:@"w"];
    [windowMenu addItemWithTitle:@"최소화" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    windowItem.submenu = windowMenu;
    [menuBar addItem:windowItem];

    NSApp.mainMenu = menuBar;
    NSApp.windowsMenu = windowMenu;
}

- (void)registerHotKeys {
    for (int index = 0; index < 6; index++) {
        if (gHotKeys[index]) {
            UnregisterEventHotKey(gHotKeys[index]);
            gHotKeys[index] = NULL;
        }
    }
    if (!gHotKeyHandlerInstalled) {
        EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
        InstallApplicationEventHandler(HotKeyPressed, 1, &spec, NULL, NULL);
        gHotKeyHandlerInstalled = YES;
    }
    EventHotKeyID settingsID = {'MBBT', 1};
    RegisterEventHotKey(settingsKeyCode(), settingsMods(), settingsID, GetApplicationEventTarget(), 0, &gHotKeys[0]);
    for (int index = 0; index < 5; index++) {
        EventHotKeyID ident = {'MBBT', (UInt32)(10 + index)};
        RegisterEventHotKey(kLimitKeyCodes[index], controlKey | optionKey, ident, GetApplicationEventTarget(), 0, &gHotKeys[index + 1]);
    }
}

- (void)beginShortcutRecording:(id)sender {
    if (self.keyMonitor) [NSEvent removeMonitor:self.keyMonitor];
    self.recordingShortcut = YES;
    self.shortcutButton.title = @"키를 누르세요";
    self.keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        NSUInteger flags = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl | NSEventModifierFlagShift);
        if (event.keyCode == kVK_Escape) {
            [self finishShortcutRecording];
            return nil;
        }
        UInt32 carbon = 0;
        if (flags & NSEventModifierFlagControl) carbon |= controlKey;
        if (flags & NSEventModifierFlagOption) carbon |= optionKey;
        if (flags & NSEventModifierFlagShift) carbon |= shiftKey;
        if (flags & NSEventModifierFlagCommand) carbon |= cmdKey;
        if (carbon == 0 || reservedLimitShortcut(event.keyCode, carbon)) {
            NSBeep();
            return nil;
        }
        [NSUserDefaults.standardUserDefaults setInteger:event.keyCode forKey:@"settingsHotKeyCode"];
        [NSUserDefaults.standardUserDefaults setInteger:carbon forKey:@"settingsHotKeyModifiers"];
        [self registerHotKeys];
        [self finishShortcutRecording];
        return nil;
    }];
}

- (void)finishShortcutRecording {
    if (self.keyMonitor) {
        [NSEvent removeMonitor:self.keyMonitor];
        self.keyMonitor = nil;
    }
    self.recordingShortcut = NO;
    self.shortcutButton.title = shortcutLabel(settingsKeyCode(), settingsMods());
}

- (void)rememberLimit {
    NSDictionary *charge = self.status[@"charge"];
    int limit = [charge[@"enabled"] boolValue] ? [charge[@"limit"] intValue] : 100;
    if (limit < 80 || limit > 100) limit = 100;
    [NSUserDefaults.standardUserDefaults setInteger:limit forKey:@"savedLimit"];
}

- (void)restoreLimit {
    int saved = (int)[NSUserDefaults.standardUserDefaults integerForKey:@"savedLimit"];
    if (saved < 80 || saved > 100) saved = 100;
    [NSUserDefaults.standardUserDefaults setObject:@"none" forKey:@"batteryMode"];
    setChargeLimit(saved);
}

- (void)applyAutomaticModes {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *mode = [defaults stringForKey:@"batteryMode"] ?: @"none";
    int percent = [self.status[@"percent"] intValue];
    if ([mode isEqualToString:@"topup"] && percent >= 100) {
        [self restoreLimit];
        self.status = readBattery();
        if (self.noteLabel) {
            self.noteLabel.stringValue = @"완충되어 이전 충전 한도로 되돌렸습니다.";
            self.noteLabel.textColor = NSColor.secondaryLabelColor;
        }
        return;
    }
    if ([mode isEqualToString:@"none"] && [defaults boolForKey:@"sailEnabled"]) {
        int lower = [self sailLower];
        int upper = [self sailUpper];
        NSDictionary *charge = self.status[@"charge"];
        int currentLimit = [charge[@"limit"] intValue];
        BOOL enabled = [charge[@"enabled"] boolValue];
        int desired = percent <= lower || percent >= upper ? upper : lower;
        if (currentLimit != desired || !enabled) {
            setChargeLimit(desired);
            self.status = readBattery();
        }
    }
}

- (int)sailLower {
    int value = (int)[NSUserDefaults.standardUserDefaults integerForKey:@"sailLower"];
    return (value == 80 || value == 85 || value == 90) ? value : 80;
}

- (int)sailUpper {
    int value = (int)[NSUserDefaults.standardUserDefaults integerForKey:@"sailUpper"];
    int lower = [self sailLower];
    if (value <= lower || value > 100) return lower >= 90 ? 100 : 90;
    return value;
}

- (void)startTopUp:(id)sender {
    [self rememberLimit];
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"sailEnabled"];
    [NSUserDefaults.standardUserDefaults setObject:@"topup" forKey:@"batteryMode"];
    setChargeLimit(100);
    self.status = readBattery();
    if (self.noteLabel) {
        self.noteLabel.stringValue = @"한 번만 100%까지 충전한 뒤 이전 한도로 돌아갑니다.";
        self.noteLabel.textColor = NSColor.secondaryLabelColor;
    }
    [self updateStatusItem];
    [self updateSettingsWindow];
}

- (void)startCalibration:(id)sender {
    [self rememberLimit];
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"sailEnabled"];
    [NSUserDefaults.standardUserDefaults setObject:@"calibration" forKey:@"batteryMode"];
    setChargeLimit(100);
    self.status = readBattery();
    if (self.noteLabel) {
        self.noteLabel.stringValue = @"보정 중입니다. 100%까지 충전한 뒤 보정 끝내기를 누르세요.";
        self.noteLabel.textColor = NSColor.secondaryLabelColor;
    }
    [self updateStatusItem];
    [self updateSettingsWindow];
}

- (void)endCalibration:(id)sender {
    [self restoreLimit];
    self.status = readBattery();
    if (self.noteLabel) {
        self.noteLabel.stringValue = @"보정을 끝내고 이전 충전 한도로 되돌렸습니다.";
        self.noteLabel.textColor = NSColor.secondaryLabelColor;
    }
    [self updateStatusItem];
    [self updateSettingsWindow];
}

- (void)toggleSail:(id)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL on = ![defaults boolForKey:@"sailEnabled"];
    [defaults setBool:on forKey:@"sailEnabled"];
    if (on) [defaults setObject:@"none" forKey:@"batteryMode"];
    [self refresh];
}

- (void)sailToggled:(NSButton *)sender {
    if (self.suppressLimitChange || !userInitiatedChange()) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:sender.state == NSControlStateValueOn forKey:@"sailEnabled"];
    if (sender.state == NSControlStateValueOn) [defaults setObject:@"none" forKey:@"batteryMode"];
    [self refresh];
}

- (void)sailBoundsChanged:(id)sender {
    if (self.suppressLimitChange || !userInitiatedChange()) return;
    int lower = [[self.lowerPopup.titleOfSelectedItem stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"%"]] intValue];
    int upper = [[self.upperPopup.titleOfSelectedItem stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"%"]] intValue];
    if (upper <= lower) upper = lower >= 90 ? 100 : lower + 10;
    [NSUserDefaults.standardUserDefaults setInteger:lower forKey:@"sailLower"];
    [NSUserDefaults.standardUserDefaults setInteger:upper forKey:@"sailUpper"];
    [self refresh];
}

- (void)dischargeTo:(NSButton *)sender {
    [self applyLimit:(int)sender.tag];
    if (self.noteLabel) {
        self.noteLabel.stringValue = [NSString stringWithFormat:@"방전 목표 %d%%. 전원을 연결하면 그 값까지 배터리를 사용합니다.", (int)sender.tag];
        self.noteLabel.textColor = NSColor.secondaryLabelColor;
    }
}

- (void)updateStatusItem {
    NSNumber *percent = self.status[@"percent"];
    NSDictionary *charge = self.status[@"charge"];
    NSString *title = percent ? [NSString stringWithFormat:@"%@%%", percent] : @"배터리";
    int limit = [charge[@"limit"] intValue];
    if ([charge[@"enabled"] boolValue] && limit > 0 && limit < 100) {
        title = [title stringByAppendingFormat:@" · %d", limit];
    }
    self.statusItem.button.title = title;
    NSImage *image = [NSImage imageWithSystemSymbolName:symbolName(self.status) accessibilityDescription:@"배터리"];
    image.template = YES;
    self.statusItem.button.image = image;
}

- (NSTextField *)label:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight color:(NSColor *)color {
    NSTextField *field = [NSTextField labelWithString:text];
    field.font = [NSFont systemFontOfSize:size weight:weight];
    field.textColor = color;
    return field;
}

- (NSTextField *)addStat:(NSString *)caption frame:(NSRect)frame to:(NSView *)content {
    NSView *box = [[NSView alloc] initWithFrame:frame];
    box.wantsLayer = YES;
    box.layer.cornerRadius = 10;
    box.layer.backgroundColor = [NSColor.quaternaryLabelColor CGColor];
    NSTextField *captionField = [self label:caption size:12 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    captionField.frame = NSMakeRect(12, 46, frame.size.width - 24, 18);
    NSTextField *value = [self label:@"–" size:18 weight:NSFontWeightSemibold color:NSColor.labelColor];
    value.frame = NSMakeRect(12, 16, frame.size.width - 24, 26);
    [box addSubview:captionField];
    [box addSubview:value];
    [content addSubview:box];
    return value;
}

- (NSButton *)actionButton:(NSString *)title action:(SEL)action frame:(NSRect)frame {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.bezelStyle = NSBezelStyleRounded;
    button.frame = frame;
    return button;
}

- (void)buildSettingsWindow {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 680)
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
    window.title = @"배터리 설정";
    window.delegate = self;
    window.releasedWhenClosed = NO;
    [window center];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:window.contentView.bounds];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 620, 1080)];
    scroll.documentView = content;
    [window.contentView addSubview:scroll];

    self.percentLabel = [self label:@"–%" size:56 weight:NSFontWeightSemibold color:NSColor.labelColor];
    self.percentLabel.font = [NSFont monospacedDigitSystemFontOfSize:56 weight:NSFontWeightSemibold];
    self.percentLabel.frame = NSMakeRect(28, 980, 250, 68);
    self.stateLabel = [self label:@"상태 확인 중" size:20 weight:NSFontWeightSemibold color:NSColor.labelColor];
    self.stateLabel.alignment = NSTextAlignmentRight;
    self.stateLabel.frame = NSMakeRect(280, 1016, 292, 28);
    self.timeLabel = [self label:@"" size:14 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    self.timeLabel.alignment = NSTextAlignmentRight;
    self.timeLabel.frame = NSMakeRect(280, 988, 292, 22);
    self.meter = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(28, 956, 544, 12)];
    self.meter.indeterminate = NO;
    self.meter.minValue = 0;
    self.meter.maxValue = 100;
    self.meter.style = NSProgressIndicatorStyleBar;

    CGFloat boxWidth = 127;
    CGFloat gap = 12;
    CGFloat row1 = 856;
    CGFloat row2 = 760;
    self.healthValue = [self addStat:@"성능 최대치" frame:NSMakeRect(28, row1, boxWidth, 84) to:content];
    self.cycleValue = [self addStat:@"충전 횟수" frame:NSMakeRect(28 + (boxWidth + gap), row1, boxWidth, 84) to:content];
    self.powerValue = [self addStat:@"지금 전력" frame:NSMakeRect(28 + (boxWidth + gap) * 2, row1, boxWidth, 84) to:content];
    self.voltageValue = [self addStat:@"전압" frame:NSMakeRect(28 + (boxWidth + gap) * 3, row1, boxWidth, 84) to:content];
    self.capacityValue = [self addStat:@"완충 용량" frame:NSMakeRect(28, row2, boxWidth, 84) to:content];
    self.remainingValue = [self addStat:@"남은 용량" frame:NSMakeRect(28 + (boxWidth + gap), row2, boxWidth, 84) to:content];
    self.amperageValue = [self addStat:@"전류" frame:NSMakeRect(28 + (boxWidth + gap) * 2, row2, boxWidth, 84) to:content];
    self.sourceValue = [self addStat:@"전원" frame:NSMakeRect(28 + (boxWidth + gap) * 3, row2, boxWidth, 84) to:content];

    NSTextField *limitTitle = [self label:@"충전 한도" size:13 weight:NSFontWeightSemibold color:NSColor.labelColor];
    limitTitle.frame = NSMakeRect(28, 720, 200, 20);
    NSTextField *description = [self label:@"전원에 연결하면 고른 퍼센트에서 충전을 멈춥니다. 지금 잔량보다 낮추면 그 값까지 방전한 뒤 유지합니다." size:13 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    description.frame = NSMakeRect(28, 674, 544, 40);
    description.cell.wraps = YES;
    description.cell.scrollable = NO;
    self.limitValues = @[@80, @85, @90, @95, @100];
    self.suppressLimitChange = YES;
    self.limitControl = [NSSegmentedControl segmentedControlWithLabels:@[@"80%", @"85%", @"90%", @"95%", @"100%"] trackingMode:NSSegmentSwitchTrackingSelectOne target:nil action:NULL];
    self.limitControl.segmentStyle = NSSegmentStyleRounded;
    self.limitControl.frame = NSMakeRect(28, 630, 544, 32);
    self.noteLabel = [self label:@"" size:13 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    self.noteLabel.frame = NSMakeRect(28, 598, 544, 22);

    NSTextField *modeTitle = [self label:@"한 번만 완충 · 보정" size:13 weight:NSFontWeightSemibold color:NSColor.labelColor];
    modeTitle.frame = NSMakeRect(28, 560, 300, 20);
    NSTextField *modeDescription = [self label:@"한 번만 완충은 100%에 도달하면 이전 한도로 돌아갑니다. 보정은 직접 끝낼 때까지 100%를 유지합니다." size:13 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    modeDescription.frame = NSMakeRect(28, 514, 544, 40);
    modeDescription.cell.wraps = YES;
    modeDescription.cell.scrollable = NO;
    self.topUpButton = [self actionButton:@"한 번만 완충" action:@selector(startTopUp:) frame:NSMakeRect(28, 470, 250, 32)];
    self.calibrationButton = [self actionButton:@"보정 시작" action:@selector(startCalibration:) frame:NSMakeRect(292, 470, 250, 32)];

    NSTextField *sailTitle = [self label:@"범위 유지" size:13 weight:NSFontWeightSemibold color:NSColor.labelColor];
    sailTitle.frame = NSMakeRect(28, 424, 200, 20);
    NSTextField *sailDescription = [self label:@"전원에 연결된 동안 하한까지 배터리로 쓴 다음, 다시 상한까지 충전합니다." size:13 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    sailDescription.frame = NSMakeRect(28, 388, 544, 32);
    sailDescription.cell.wraps = YES;
    sailDescription.cell.scrollable = NO;
    self.sailCheckbox = [NSButton checkboxWithTitle:@"범위 유지 사용" target:self action:@selector(sailToggled:)];
    self.sailCheckbox.frame = NSMakeRect(28, 350, 200, 24);
    self.lowerPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(240, 346, 120, 28) pullsDown:NO];
    [self.lowerPopup addItemsWithTitles:@[@"80%", @"85%", @"90%"]];
    self.lowerPopup.target = self;
    self.lowerPopup.action = @selector(sailBoundsChanged:);
    self.upperPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(372, 346, 120, 28) pullsDown:NO];
    [self.upperPopup addItemsWithTitles:@[@"85%", @"90%", @"95%", @"100%"]];
    self.upperPopup.target = self;
    self.upperPopup.action = @selector(sailBoundsChanged:);

    NSTextField *shortcutTitle = [self label:@"설정 열기" size:13 weight:NSFontWeightSemibold color:NSColor.labelColor];
    shortcutTitle.frame = NSMakeRect(28, 292, 140, 20);
    self.shortcutButton = [NSButton buttonWithTitle:shortcutLabel(settingsKeyCode(), settingsMods()) target:self action:@selector(beginShortcutRecording:)];
    self.shortcutButton.bezelStyle = NSBezelStyleRounded;
    self.shortcutButton.frame = NSMakeRect(400, 286, 172, 30);
    NSTextField *shortcutHint = [self label:@"충전 한도  ⌃⌥1 80%   ⌃⌥2 85%   ⌃⌥3 90%   ⌃⌥4 95%   ⌃⌥5 100%" size:12 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    shortcutHint.frame = NSMakeRect(28, 252, 544, 18);

    for (NSView *view in @[self.percentLabel, self.stateLabel, self.timeLabel, self.meter, limitTitle, description, self.limitControl, self.noteLabel, modeTitle, modeDescription, self.topUpButton, self.calibrationButton, sailTitle, sailDescription, self.sailCheckbox, self.lowerPopup, self.upperPopup, shortcutTitle, self.shortcutButton, shortcutHint]) {
        [content addSubview:view];
    }
    self.limitControl.target = self;
    self.limitControl.action = @selector(limitChanged:);
    self.settingsWindow = window;
}

- (void)performWithoutControlActions:(void (^)(void))block {
    NSSegmentedControl *limit = self.limitControl;
    NSPopUpButton *lower = self.lowerPopup;
    NSPopUpButton *upper = self.upperPopup;
    NSButton *sail = self.sailCheckbox;
    SEL limitAction = limit.action;
    id limitTarget = limit.target;
    SEL lowerAction = lower.action;
    id lowerTarget = lower.target;
    SEL upperAction = upper.action;
    id upperTarget = upper.target;
    SEL sailAction = sail.action;
    id sailTarget = sail.target;
    limit.action = NULL;
    limit.target = nil;
    lower.action = NULL;
    lower.target = nil;
    upper.action = NULL;
    upper.target = nil;
    sail.action = NULL;
    sail.target = nil;
    block();
    limit.target = limitTarget;
    limit.action = limitAction;
    lower.target = lowerTarget;
    lower.action = lowerAction;
    upper.target = upperTarget;
    upper.action = upperAction;
    sail.target = sailTarget;
    sail.action = sailAction;
}

- (void)updateSettingsWindow {
    if (!self.settingsWindow) return;
    self.suppressLimitChange = YES;
    NSDictionary *status = self.status ?: @{};
    NSNumber *percent = status[@"percent"];
    self.percentLabel.stringValue = percent ? [NSString stringWithFormat:@"%@%%", percent] : @"–%";
    self.stateLabel.stringValue = stateLabel(status);
    self.timeLabel.stringValue = remainingLabel(status[@"timeRemaining"]) ?: @"";
    self.meter.doubleValue = percent.doubleValue;
    self.healthValue.stringValue = status[@"healthPercent"] ? [NSString stringWithFormat:@"%@%%", status[@"healthPercent"]] : @"–";
    self.cycleValue.stringValue = status[@"cycleCount"] ? [NSString stringWithFormat:@"%@", status[@"cycleCount"]] : @"–";
    if (status[@"powerWatts"]) {
        double watts = [status[@"powerWatts"] doubleValue];
        self.powerValue.stringValue = [NSString stringWithFormat:@"%@ %.1fW", watts < 0 ? @"방전" : @"충전", fabs(watts)];
    } else {
        self.powerValue.stringValue = @"–";
    }
    self.voltageValue.stringValue = status[@"voltage"] ? [NSString stringWithFormat:@"%.2fV", [status[@"voltage"] doubleValue]] : @"–";
    if (status[@"designCycles"]) {
        self.cycleValue.stringValue = [NSString stringWithFormat:@"%@ / %@", status[@"cycleCount"] ?: @"–", status[@"designCycles"]];
    }
    self.capacityValue.stringValue = status[@"fullMah"] ? [NSString stringWithFormat:@"%@ mAh", status[@"fullMah"]] : @"–";
    self.remainingValue.stringValue = status[@"remainingMah"] ? [NSString stringWithFormat:@"%@ mAh", status[@"remainingMah"]] : @"–";
    self.amperageValue.stringValue = status[@"amperage"] ? [NSString stringWithFormat:@"%.2fA", [status[@"amperage"] doubleValue]] : @"–";
    self.sourceValue.stringValue = [status[@"source"] isEqualToString:@"ac"] ? @"어댑터" : @"배터리";
    NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:@"batteryMode"] ?: @"none";
    self.topUpButton.title = [mode isEqualToString:@"topup"] ? @"완충 취소" : @"한 번만 완충";
    self.topUpButton.action = [mode isEqualToString:@"topup"] ? @selector(endCalibration:) : @selector(startTopUp:);
    self.calibrationButton.title = [mode isEqualToString:@"calibration"] ? @"보정 끝내기" : @"보정 시작";
    self.calibrationButton.action = [mode isEqualToString:@"calibration"] ? @selector(endCalibration:) : @selector(startCalibration:);
    NSDictionary *charge = status[@"charge"];
    int current = activeChargeLimit(charge);
    NSUInteger index = [self.limitValues indexOfObject:@(current)];
    [self performWithoutControlActions:^{
        self.sailCheckbox.state = [NSUserDefaults.standardUserDefaults boolForKey:@"sailEnabled"] ? NSControlStateValueOn : NSControlStateValueOff;
        [self.lowerPopup selectItemWithTitle:[NSString stringWithFormat:@"%d%%", [self sailLower]]];
        [self.upperPopup selectItemWithTitle:[NSString stringWithFormat:@"%d%%", [self sailUpper]]];
        self.limitControl.enabled = [charge[@"supported"] boolValue];
        if (index != NSNotFound && self.limitControl.selectedSegment != (NSInteger)index) {
            self.limitControl.selectedSegment = (NSInteger)index;
        }
    }];
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            self.suppressLimitChange = NO;
        });
    });
    if ([charge[@"error"] isKindOfClass:[NSString class]] && [self.noteLabel.stringValue length] == 0) {
        self.noteLabel.stringValue = charge[@"error"];
        self.noteLabel.textColor = NSColor.systemRedColor;
    }
}

- (void)openSettings:(id)sender {
    if (!self.settingsWindow) [self buildSettingsWindow];
    [self updateSettingsWindow];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activate];
    [self.settingsWindow makeKeyAndOrderFront:nil];
    NSScrollView *scroll = self.settingsWindow.contentView.subviews.firstObject;
    if ([scroll isKindOfClass:[NSScrollView class]]) {
        NSView *document = scroll.documentView;
        CGFloat y = NSHeight(document.frame) - NSHeight(scroll.contentView.bounds);
        if (y < 0) y = 0;
        [scroll.contentView scrollToPoint:NSMakePoint(0, y)];
        [scroll reflectScrolledClipView:scroll.contentView];
    }
}

- (void)windowWillClose:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

- (void)limitChanged:(NSSegmentedControl *)control {
    if (self.suppressLimitChange || !userInitiatedChange()) return;
    NSInteger index = control.selectedSegment;
    if (index < 0 || (NSUInteger)index >= self.limitValues.count) return;
    int limit = self.limitValues[index].intValue;
    if (limit == activeChargeLimit(self.status[@"charge"])) return;
    [self applyLimit:limit];
}

- (void)toggleLogin:(id)sender {
    SMAppService *service = [SMAppService mainAppService];
    NSError *error = nil;
    BOOL ok = service.status == SMAppServiceStatusEnabled ? [service unregisterAndReturnError:&error] : [service registerAndReturnError:&error];
    if (!ok) {
        [NSApp activateIgnoringOtherApps:YES];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"로그인 항목을 바꾸지 못했습니다";
        alert.informativeText = error.localizedDescription ?: @"시스템 설정에서 로그인 항목을 허용해 주세요.";
        [alert runModal];
    }
}

@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        BatteryApp *delegate = [BatteryApp new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
