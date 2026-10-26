#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>
#import <Carbon/Carbon.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <mach/mach.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <sys/socket.h>
#import <math.h>
#import <objc/message.h>
#import <unistd.h>
#import <string.h>
#import <fcntl.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

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

static NSArray<NSDictionary *> *runnerCatalog(void) {
    static NSArray *catalog;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        catalog = @[
            @{@"id": @"character", @"title": @"초록 모자", @"prefix": @"runner", @"template": @NO},
            @{@"id": @"silhouette", @"title": @"실루엣", @"prefix": @"silhouette", @"template": @YES}
        ];
    });
    return catalog;
}

static NSURL *runnersDirectory(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *base = [files URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [base URLByAppendingPathComponent:@"local.ssc.macbook-battery/runners" isDirectory:YES];
    [files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}

static NSArray<NSDictionary *> *customRunnerSpecs(void) {
    NSURL *root = runnersDirectory();
    NSArray<NSURL *> *folders = [NSFileManager.defaultManager contentsOfDirectoryAtURL:root includingPropertiesForKeys:@[NSURLCreationDateKey, NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    folders = [folders sortedArrayUsingComparator:^NSComparisonResult(NSURL *lhs, NSURL *rhs) {
        NSDate *left = nil;
        NSDate *right = nil;
        [lhs getResourceValue:&left forKey:NSURLCreationDateKey error:nil];
        [rhs getResourceValue:&right forKey:NSURLCreationDateKey error:nil];
        return [left ?: NSDate.distantPast compare:right ?: NSDate.distantPast];
    }];
    NSMutableArray *specs = [NSMutableArray array];
    for (NSURL *folder in folders) {
        NSNumber *isDirectory = nil;
        [folder getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        if (!isDirectory.boolValue) continue;
        NSData *data = [NSData dataWithContentsOfURL:[folder URLByAppendingPathComponent:@"meta.json"]];
        id meta = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![meta isKindOfClass:[NSDictionary class]]) continue;
        NSString *title = meta[@"title"];
        if (![title isKindOfClass:[NSString class]] || title.length == 0) title = folder.lastPathComponent;
        NSMutableDictionary *spec = [@{
            @"id": folder.lastPathComponent,
            @"title": title,
            @"directory": folder.path,
            @"template": @([meta[@"template"] boolValue])
        } mutableCopy];
        if ([meta[@"interval"] isKindOfClass:[NSNumber class]] && [meta[@"interval"] doubleValue] > 0.02) {
            spec[@"interval"] = meta[@"interval"];
        }
        [specs addObject:spec];
    }
    return specs;
}

static NSArray<NSDictionary *> *allRunnerSpecs(void) {
    return [runnerCatalog() arrayByAddingObjectsFromArray:customRunnerSpecs()];
}

static NSString *selectedRunnerID(void) {
    NSString *value = [NSUserDefaults.standardUserDefaults stringForKey:@"runnerID"];
    for (NSDictionary *spec in allRunnerSpecs()) {
        if ([spec[@"id"] isEqualToString:value]) return value;
    }
    return @"character";
}

static BOOL pref(NSString *key) {
    NSDictionary *fallback = @{
        @"showMemory": @YES,
        @"showStorage": @YES,
        @"showBattery": @YES,
        @"showNetwork": @YES,
        @"showMetricsBar": @NO,
        @"barCPU": @YES,
        @"barMemory": @YES,
        @"barStorage": @YES,
        @"barBattery": @YES,
        @"barNetwork": @YES,
        @"slowWhenBusy": @NO,
        @"flipRunner": @NO
    };
    if (![NSUserDefaults.standardUserDefaults objectForKey:key]) return [fallback[key] boolValue];
    return [NSUserDefaults.standardUserDefaults boolForKey:key];
}

static NSImage *horizontallyFlippedImage(NSImage *source) {
    if (!source || source.size.width < 1 || source.size.height < 1) return source;
    NSImage *image = [NSImage imageWithSize:source.size flipped:NO drawingHandler:^BOOL(NSRect dst) {
        [NSGraphicsContext.currentContext saveGraphicsState];
        NSAffineTransform *flip = [NSAffineTransform transform];
        [flip translateXBy:NSWidth(dst) yBy:0];
        [flip scaleXBy:-1 yBy:1];
        [flip concat];
        [source drawInRect:dst fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1 respectFlipped:YES hints:nil];
        [NSGraphicsContext.currentContext restoreGraphicsState];
        return YES;
    }];
    image.template = source.isTemplate;
    return image;
}

static NSArray<NSDictionary *> *customMetricSources(void) {
    id value = [NSUserDefaults.standardUserDefaults arrayForKey:@"customMetricsSources"];
    return [value isKindOfClass:[NSArray class]] ? value : @[];
}

static NSDictionary *customMetricsSnapshot(NSData *data, NSString **errorOut) {
    if (errorOut) *errorOut = nil;
    if (data.length == 0 || data.length > 1024 * 1024) {
        if (errorOut) *errorOut = @"JSON 파일이 비었거나 너무 큽니다.";
        return nil;
    }
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (errorOut) *errorOut = @"JSON 형식이 아닙니다.";
        return nil;
    }
    NSString *title = json[@"title"];
    id metrics = json[@"metrics"];
    id updated = json[@"lastUpdatedDate"];
    if (![title isKindOfClass:[NSString class]] || title.length == 0 || ![metrics isKindOfClass:[NSArray class]] || ![updated isKindOfClass:[NSString class]]) {
        if (errorOut) *errorOut = @"사용자 지표 형식과 맞지 않습니다. title, metrics, lastUpdatedDate가 필요합니다.";
        return nil;
    }
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *date = [formatter dateFromString:updated];
    if (!date) {
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        date = [formatter dateFromString:updated];
    }
    if (!date) {
        if (errorOut) *errorOut = @"마지막 업데이트 시각을 읽지 못했습니다.";
        return nil;
    }
    NSMutableArray *rows = [NSMutableArray array];
    for (id item in metrics) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            if (errorOut) *errorOut = @"지표 항목 형식이 맞지 않습니다.";
            return nil;
        }
        NSString *rowTitle = item[@"title"];
        NSString *value = item[@"formattedValue"];
        if (![rowTitle isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]]) {
            if (errorOut) *errorOut = @"지표 항목에는 title과 formattedValue가 필요합니다.";
            return nil;
        }
        NSMutableDictionary *row = [@{@"title": rowTitle, @"formattedValue": value} mutableCopy];
        if ([item[@"normalizedValue"] isKindOfClass:[NSNumber class]]) {
            double normalized = [item[@"normalizedValue"] doubleValue];
            if (normalized < 0) normalized = 0;
            if (normalized > 1) normalized = 1;
            row[@"normalizedValue"] = @(normalized);
        }
        [rows addObject:row];
    }
    NSString *symbol = [json[@"symbol"] isKindOfClass:[NSString class]] && [json[@"symbol"] length] ? json[@"symbol"] : @"chart.bar.horizontal.page";
    NSMutableDictionary *snapshot = [@{
        @"title": title,
        @"symbol": symbol,
        @"metrics": rows,
        @"updated": date
    } mutableCopy];
    if ([json[@"metricsBarValue"] isKindOfClass:[NSString class]]) snapshot[@"metricsBarValue"] = json[@"metricsBarValue"];
    return snapshot;
}

static NSString *relativeUpdateText(NSDate *date, BOOL failed) {
    if (failed) return @"마지막 업데이트: 실패";
    if (!date) return @"마지막 업데이트: –";
    NSRelativeDateTimeFormatter *formatter = [NSRelativeDateTimeFormatter new];
    formatter.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleFull;
    return [NSString stringWithFormat:@"마지막 업데이트: %@", [formatter localizedStringForDate:date relativeToDate:NSDate.date]];
}

static NSArray<NSDictionary *> *sidebarRows(void) {
    static NSArray *rows;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rows = @[
            @{@"group": @"상태"},
            @{@"title": @"대시보드", @"symbol": @"square.grid.2x2", @"section": @0},
            @{@"group": @"배터리"},
            @{@"title": @"충전 한도", @"symbol": @"battery.100percent", @"section": @1},
            @{@"title": @"한 번만 완충", @"symbol": @"bolt.fill", @"section": @2},
            @{@"title": @"범위 유지", @"symbol": @"arrow.left.and.right", @"section": @3},
            @{@"title": @"보정", @"symbol": @"checkmark.seal", @"section": @4},
            @{@"group": @"시스템"},
            @{@"title": @"러너", @"symbol": @"figure.run", @"section": @5},
            @{@"title": @"시스템 지표", @"symbol": @"chart.bar", @"section": @6},
            @{@"group": @"앱"},
            @{@"title": @"단축키", @"symbol": @"command", @"section": @7},
            @{@"title": @"일반", @"symbol": @"gearshape", @"section": @8}
        ];
    });
    return rows;
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

static NSString *limitText(NSDictionary *charge) {
    if (![charge[@"supported"] boolValue]) return @"사용할 수 없음";
    if (![charge[@"enabled"] boolValue]) return @"제한 없음";
    return [NSString stringWithFormat:@"%d%%", activeChargeLimit(charge)];
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
    NSString *lowerPM = pm.lowercaseString;
    NSRegularExpression *percentPattern = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)%" options:0 error:nil];
    NSTextCheckingResult *percentMatch = [percentPattern firstMatchInString:pm options:0 range:NSMakeRange(0, pm.length)];
    NSNumber *percent = nil;
    if (percentMatch) percent = @([[pm substringWithRange:[percentMatch rangeAtIndex:1]] integerValue]);
    NSRegularExpression *timePattern = [NSRegularExpression regularExpressionWithPattern:@"(\\d+:\\d+)" options:0 error:nil];
    NSTextCheckingResult *timeMatch = [timePattern firstMatchInString:pm options:0 range:NSMakeRange(0, pm.length)];
    NSString *remaining = timeMatch ? [pm substringWithRange:[timeMatch rangeAtIndex:1]] : nil;
    NSString *state = @"unknown";
    if ([lowerPM containsString:@"not charging"]) state = @"not charging";
    else if ([lowerPM containsString:@"finishing charge"]) state = @"finishing charge";
    else if ([lowerPM containsString:@"discharging"]) state = @"discharging";
    else if ([lowerPM containsString:@"charging"]) state = @"charging";
    else if ([lowerPM containsString:@"charged"]) state = @"charged";
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
    NSNumber *temperature = info[@"Temperature"] ?: info[@"VirtualTemperature"];
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
    if (temperature) {
        double raw = temperature.doubleValue;
        if (fabs(raw) > 200) raw /= 100.0;
        if (raw > 0 && raw < 120) status[@"temperature"] = @(round(raw * 10.0) / 10.0);
    }
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

static NSString *modeStatusText(void) {
    NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:@"batteryMode"] ?: @"none";
    if ([mode isEqualToString:@"topup"]) return @"한 번만 완충 중";
    if ([mode isEqualToString:@"calibration"]) return @"배터리 보정 중";
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"sailEnabled"]) return @"범위 유지 켜짐";
    return nil;
}

static NSString *byteText(double bytes, NSByteCountFormatterCountStyle style) {
    if (bytes < 0) bytes = 0;
    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    formatter.countStyle = style;
    formatter.includesUnit = YES;
    return [formatter stringFromByteCount:(long long)llround(bytes)] ?: @"–";
}

static NSString *rateText(double bytesPerSec) {
    return [byteText(bytesPerSec, NSByteCountFormatterCountStyleFile) stringByAppendingString:@"/s"];
}

static CGFloat metricsRateColumnWidth(NSDictionary *attrs) {
    NSArray<NSString *> *samples = @[
        [@"↓" stringByAppendingString:rateText(0)],
        [@"↓" stringByAppendingString:rateText(999)],
        [@"↓" stringByAppendingString:rateText(999.9 * 1024.0 * 1024.0)],
        [@"↓" stringByAppendingString:rateText(999.0 * 1024.0 * 1024.0 * 1024.0)],
        @"↓…"
    ];
    CGFloat width = 0;
    for (NSString *sample in samples) width = MAX(width, ceil([sample sizeWithAttributes:attrs].width));
    return width;
}

static NSDictionary *statusTitleAttributes(void) {
    return @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: NSColor.labelColor
    };
}

static NSImage *symbolImage(NSString *name, CGFloat pointSize) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!image) image = [NSImage imageWithSystemSymbolName:@"circle" accessibilityDescription:nil];
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:pointSize weight:NSFontWeightRegular];
    return [image imageWithSymbolConfiguration:config] ?: image;
}

static void pushSample(NSMutableArray<NSNumber *> *values, double value) {
    [values addObject:@(value)];
    while (values.count > 61) [values removeObjectAtIndex:0];
}

@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface FlippedClipView : NSClipView
@end
@implementation FlippedClipView
- (BOOL)isFlipped { return YES; }
@end

@interface CardView : NSView
@end
@implementation CardView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) self.wantsLayer = YES;
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    self.layer.cornerRadius = 12;
    self.layer.backgroundColor = NSColor.controlBackgroundColor.CGColor;
    self.layer.borderColor = [NSColor.separatorColor colorWithAlphaComponent:0.65].CGColor;
    self.layer.borderWidth = 1;
}
@end

@interface RunnerDropView : CardView
@property (nonatomic, assign) BOOL dropHighlighted;
@property (nonatomic, copy) void (^onDrop)(NSArray<NSURL *> *urls);
@end

@interface RunnerOptionButton : NSButton
@end
@implementation RunnerOptionButton
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.bordered = NO;
        self.imagePosition = NSNoImage;
        self.imageScaling = NSImageScaleProportionallyUpOrDown;
        self.buttonType = NSButtonTypeMomentaryChange;
        self.focusRingType = NSFocusRingTypeNone;
    }
    return self;
}
- (void)setState:(NSControlStateValue)state {
    [super setState:state];
    [self setNeedsDisplay:YES];
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    BOOL on = self.state == NSControlStateValueOn;
    CGFloat inset = on ? 1.5 : 1.0;
    NSRect box = NSInsetRect(self.bounds, inset, inset);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:box xRadius:10 yRadius:10];
    NSColor *fill = on ? [NSColor.controlAccentColor colorWithAlphaComponent:0.16] : [NSColor.quaternaryLabelColor colorWithAlphaComponent:0.12];
    [fill setFill];
    [path fill];
    path.lineWidth = on ? 2.0 : 1.0;
    [(on ? NSColor.controlAccentColor : [NSColor.separatorColor colorWithAlphaComponent:0.9]) setStroke];
    [path stroke];

    NSImage *image = self.image;
    CGFloat titleBand = 28;
    if (image && image.size.width > 0 && image.size.height > 0) {
        NSRect imageArea = NSMakeRect(NSMinX(box) + 8, 8, NSWidth(box) - 16, NSHeight(box) - titleBand - 14);
        CGFloat scale = MIN(imageArea.size.width / image.size.width, imageArea.size.height / image.size.height);
        NSSize draw = NSMakeSize(image.size.width * scale, image.size.height * scale);
        NSRect imageRect = NSMakeRect(NSMidX(imageArea) - draw.width / 2.0, NSMidY(imageArea) - draw.height / 2.0, draw.width, draw.height);
        if (image.isTemplate) {
            NSImage *mask = [image copy];
            mask.template = NO;
            NSImage *tinted = [NSImage imageWithSize:imageRect.size flipped:self.isFlipped drawingHandler:^BOOL(NSRect dst) {
                [NSColor.labelColor setFill];
                NSRectFill(dst);
                [mask drawInRect:dst fromRect:NSZeroRect operation:NSCompositingOperationDestinationIn fraction:1 respectFlipped:YES hints:nil];
                return YES;
            }];
            [tinted drawInRect:imageRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
        } else {
            [image drawInRect:imageRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
        }
    }
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: NSColor.labelColor,
        NSParagraphStyleAttributeName: style
    };
    [self.title drawInRect:NSMakeRect(NSMinX(box) + 8, NSMaxY(box) - titleBand, NSWidth(box) - 16, 18) withAttributes:attrs];
}
@end

@implementation RunnerDropView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self registerForDraggedTypes:@[NSPasteboardTypeFileURL, NSPasteboardTypeURL]];
    return self;
}
- (void)setDropHighlighted:(BOOL)dropHighlighted {
    _dropHighlighted = dropHighlighted;
    [self setNeedsDisplay:YES];
}
- (void)updateLayer {
    [super updateLayer];
    if (!self.dropHighlighted) return;
    self.layer.borderColor = NSColor.controlAccentColor.CGColor;
    self.layer.borderWidth = 2;
}
- (NSArray<NSURL *> *)droppedURLs:(id<NSDraggingInfo>)sender {
    return [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}] ?: @[];
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    if ([self droppedURLs:sender].count == 0) return NSDragOperationNone;
    self.dropHighlighted = YES;
    return NSDragOperationCopy;
}
- (void)draggingExited:(id<NSDraggingInfo>)sender {
    (void)sender;
    self.dropHighlighted = NO;
}
- (void)draggingEnded:(id<NSDraggingInfo>)sender {
    (void)sender;
    self.dropHighlighted = NO;
}
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
    return [self droppedURLs:sender].count > 0;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    self.dropHighlighted = NO;
    NSArray<NSURL *> *urls = [self droppedURLs:sender];
    if (urls.count == 0 || !self.onDrop) return NO;
    self.onDrop(urls);
    return YES;
}
@end

@interface LineGraphView : NSView
@property (nonatomic, copy) NSArray<NSNumber *> *values;
@end
@implementation LineGraphView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) _values = @[];
    return self;
}
- (BOOL)isFlipped { return YES; }
- (NSSize)intrinsicContentSize { return NSMakeSize(120, 16); }
- (void)setValues:(NSArray<NSNumber *> *)values {
    _values = [values copy] ?: @[];
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSUInteger count = self.values.count;
    if (count == 0) return;
    CGFloat width = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    if (width < 2 || height < 2) return;
    NSBezierPath *line = [NSBezierPath bezierPath];
    line.lineWidth = 1.5;
    line.lineJoinStyle = NSLineJoinStyleRound;
    line.lineCapStyle = NSLineCapStyleRound;
    for (NSUInteger index = 0; index < count; index++) {
        double value = MIN(100.0, MAX(0.0, self.values[index].doubleValue));
        CGFloat x = count == 1 ? 0 : width * ((CGFloat)index / (CGFloat)(count - 1));
        CGFloat y = 1.5 + (height - 3.0) * (CGFloat)(1.0 - value / 100.0);
        NSPoint point = NSMakePoint(x, y);
        if (index == 0) [line moveToPoint:point];
        else [line lineToPoint:point];
    }
    NSBezierPath *fill = [line copy];
    [fill lineToPoint:NSMakePoint(width, height)];
    [fill lineToPoint:NSMakePoint(0, height)];
    [fill closePath];
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.22] setFill];
    [fill fill];
    [NSColor.controlAccentColor setStroke];
    [line stroke];
}
@end

@interface BarGraphView : NSView
@property (nonatomic, assign) double value;
@end
@implementation BarGraphView
- (BOOL)isFlipped { return YES; }
- (NSSize)intrinsicContentSize { return NSMakeSize(120, 16); }
- (void)setValue:(double)value {
    _value = value;
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGFloat width = NSWidth(self.bounds);
    CGFloat barHeight = 8;
    CGFloat y = floor((NSHeight(self.bounds) - barHeight) / 2.0);
    NSRect outline = NSMakeRect(0.5, y + 0.5, MAX(1, width - 1), barHeight - 1);
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.9] setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRect:outline];
    border.lineWidth = 1;
    [border stroke];
    CGFloat fillWidth = (width - 1) * MIN(100.0, MAX(0.0, self.value)) / 100.0;
    [[NSColor controlAccentColor] setFill];
    NSRectFill(NSMakeRect(0.5, y + 0.5, fillWidth, barHeight - 1));
}
@end

@interface BarGlyphView : NSView
@property (nonatomic, strong) NSImage *image;
@property (nonatomic, strong) NSImage *icon;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) CGFloat artWidth;
@property (nonatomic, assign) NSSize layoutSize;
@end

@implementation BarGlyphView
- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}
- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (self.image) {
        [self.image drawInRect:self.bounds fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
        return;
    }
    CGFloat scaleX = self.layoutSize.width > 0 ? NSWidth(self.bounds) / self.layoutSize.width : 1;
    CGFloat scaleY = self.layoutSize.height > 0 ? NSHeight(self.bounds) / self.layoutSize.height : 1;
    NSImage *icon = self.icon;
    if (icon && icon.size.width > 0 && icon.size.height > 0) {
        NSSize draw = NSMakeSize(icon.size.width * scaleX, icon.size.height * scaleY);
        NSRect iconRect = NSMakeRect((self.artWidth * scaleX - draw.width) / 2.0,
                                      (NSHeight(self.bounds) - draw.height) / 2.0,
                                      draw.width,
                                      draw.height);
        [icon drawInRect:iconRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }
    if (self.title.length == 0) return;
    NSDictionary *attrs = statusTitleAttributes();
    NSRect textBounds = [self.title boundingRectWithSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin attributes:attrs];
    CGFloat x = self.artWidth * scaleX + 4.0 * scaleX;
    CGFloat y = floor((NSHeight(self.bounds) - NSHeight(textBounds)) / 2.0);
    [self.title drawWithRect:NSMakeRect(x, y, ceil(NSWidth(textBounds)), ceil(NSHeight(textBounds))) options:NSStringDrawingUsesLineFragmentOrigin attributes:attrs];
}
@end

@interface BatteryApp : NSObject <NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSStatusItem *metricsItem;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *barSpacers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSView *> *barOverlays;
@property (nonatomic, copy) NSString *statusGlyphSignature;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *customSlotWidths;
@property (nonatomic, strong) NSDictionary *status;
@property (nonatomic, strong) NSTimer *cpuTimer;
@property (nonatomic, strong) NSTimer *metricsTimer;
@property (nonatomic, strong) NSPopover *popover;
@property (nonatomic, strong) FlippedView *popoverRoot;
@property (nonatomic, copy) NSString *builtPopoverSignature;
@property (nonatomic, strong) NSDate *popoverClosedAt;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *popoverFields;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSImageView *> *popoverIcons;
@property (nonatomic, strong) LineGraphView *popoverCPUGraph;
@property (nonatomic, strong) LineGraphView *popoverMemoryGraph;
@property (nonatomic, strong) BarGraphView *popoverStorageGraph;
@property (nonatomic, strong) NSWindow *settingsWindow;
@property (nonatomic, strong) NSTableView *sidebar;
@property (nonatomic, strong) NSView *settingsContent;
@property (nonatomic, strong) NSArray<NSScrollView *> *pages;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *fields;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSButton *> *metricChecks;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *noteFields;
@property (nonatomic, strong) NSMutableArray<NSControl *> *guardedControls;
@property (nonatomic, strong) NSProgressIndicator *dashMeter;
@property (nonatomic, strong) NSImageView *heroIcon;
@property (nonatomic, strong) LineGraphView *dashCPUGraph;
@property (nonatomic, strong) LineGraphView *dashMemoryGraph;
@property (nonatomic, strong) BarGraphView *dashStorageGraph;
@property (nonatomic, strong) NSButton *topUpButton;
@property (nonatomic, strong) NSButton *calibrationButton;
@property (nonatomic, strong) NSButton *sailCheckbox;
@property (nonatomic, strong) NSPopUpButton *lowerPopup;
@property (nonatomic, strong) NSPopUpButton *upperPopup;
@property (nonatomic, strong) NSSegmentedControl *limitControl;
@property (nonatomic, strong) NSButton *loginCheckbox;
@property (nonatomic, strong) NSPopUpButton *intervalPopup;
@property (nonatomic, strong) NSTextField *speedLabel;
@property (nonatomic, strong) NSImageView *previewView;
@property (nonatomic, copy) NSArray<NSNumber *> *limitValues;
@property (nonatomic, assign) BOOL suppressLimitChange;
@property (nonatomic, strong) NSButton *shortcutButton;
@property (nonatomic, strong) id keyMonitor;
@property (nonatomic, assign) BOOL recordingShortcut;
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSImage *> *> *runnerSets;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSButton *> *runnerChoices;
@property (nonatomic, strong) NSScrollView *runnerPage;
@property (nonatomic, assign) CGFloat runnerGalleryTop;
@property (nonatomic, strong) NSButton *importRunnerButton;
@property (nonatomic, strong) NSButton *removeRunnerButton;
@property (nonatomic, strong) NSSegmentedControl *renderModeControl;
@property (nonatomic, strong) NSPopover *metricsSettingsPopover;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSButton *> *metricsPopoverChecks;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSButton *> *customBarChecks;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *customStatusLabels;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *customWatchers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *customSnapshots;
@property (nonatomic, strong) NSMutableSet<NSString *> *customFailed;
@property (nonatomic, strong) NSScrollView *metricsPage;
@property (nonatomic, assign) CGFloat customMetricsTop;
@property (nonatomic, copy) NSString *customMetricsSignature;
@property (nonatomic, strong) NSMutableDictionary<NSString *, BarGraphView *> *popoverBars;
@property (nonatomic, assign) BOOL runnerImporting;
@property (nonatomic, copy) NSArray<NSImage *> *runnerFrames;
@property (nonatomic, strong) NSTimer *runnerTimer;
@property (nonatomic, assign) NSUInteger runnerFrame;
@property (nonatomic, assign) NSTimeInterval runnerInterval;
@property (nonatomic, assign) BOOL hasCPUSample;
@property (nonatomic, assign) natural_t prevUser, prevNice, prevSystem, prevIdle;
@property (nonatomic, assign) double cpuUsed, cpuUser, cpuSystem;
@property (nonatomic, assign) double memoryUsed, memoryTotal, memoryWired, memoryCompressed;
@property (nonatomic, assign) double storageUsed, storageTotal;
@property (nonatomic, copy) NSString *storageName;
@property (nonatomic, assign) BOOL hasNetworkSample;
@property (nonatomic, assign) uint64_t prevNetIn, prevNetOut;
@property (nonatomic, assign) CFAbsoluteTime prevNetTime;
@property (nonatomic, assign) double netUp, netDown;
@property (nonatomic, copy) NSString *netName;
@property (nonatomic, copy) NSString *netSymbol;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *cpuHistory;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *memoryHistory;
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
    (void)notification;
    pid_t mine = getpid();
    for (NSRunningApplication *running in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"local.ssc.macbook-battery"]) {
        if (running.processIdentifier != mine) [running forceTerminate];
    }
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.cpuHistory = [NSMutableArray array];
    self.memoryHistory = [NSMutableArray array];
    self.fields = [NSMutableDictionary dictionary];
    self.metricChecks = [NSMutableDictionary dictionary];
    self.customBarChecks = [NSMutableDictionary dictionary];
    self.customStatusLabels = [NSMutableDictionary dictionary];
    self.customWatchers = [NSMutableDictionary dictionary];
    self.customSnapshots = [NSMutableDictionary dictionary];
    self.customFailed = [NSMutableSet set];
    self.popoverBars = [NSMutableDictionary dictionary];
    self.noteFields = [NSMutableArray array];
    self.guardedControls = [NSMutableArray array];
    self.barSpacers = [NSMutableDictionary dictionary];
    self.barOverlays = [NSMutableDictionary dictionary];
    self.customSlotWidths = [NSMutableDictionary dictionary];
    self.netName = @"네트워크";
    self.netSymbol = @"network";
    self.storageName = @"저장공간";
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(toggleDashboard:);
    self.statusItem.button.imagePosition = NSImageOnly;
    self.statusItem.button.title = @"";
    self.statusItem.button.toolTip = @"맥북 배터리 제어";
    self.statusItem.button.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
    gHotKeyOwner = self;
    [self installMainMenu];
    [self registerHotKeys];
    [self loadRunner];
    [self startCustomMetrics];
    [self sampleCPU];
    [self refreshMetrics];
    [self updateRunnerSpeed];
    self.cpuTimer = [NSTimer timerWithTimeInterval:1 target:self selector:@selector(sampleCPU) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.cpuTimer forMode:NSRunLoopCommonModes];
    [self restartMetricsTimer];
    NSArray *args = NSProcessInfo.processInfo.arguments;
    if ([args containsObject:@"--settings"]) [self openSettings:nil];
    if ([args containsObject:@"--dashboard"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self toggleDashboard:self.statusItem.button];
        });
    }
}

- (NSTimeInterval)metricsInterval {
    NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:@"updateInterval"];
    if (value != 3 && value != 5 && value != 10) return 5;
    return (NSTimeInterval)value;
}

- (void)restartMetricsTimer {
    [self.metricsTimer invalidate];
    self.metricsTimer = [NSTimer timerWithTimeInterval:[self metricsInterval] target:self selector:@selector(refreshMetrics) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.metricsTimer forMode:NSRunLoopCommonModes];
}

- (double)runnerUnit {
    double unit = self.cpuUsed / 5.0;
    if (unit < 1) unit = 1;
    if (unit > 20) unit = 20;
    if (pref(@"slowWhenBusy")) unit = 0.5 * (21.0 - unit);
    return unit;
}

- (void)sampleCPU {
    host_cpu_load_info_data_t load;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&load, &count) != KERN_SUCCESS) return;
    if (self.hasCPUSample) {
        double user = (load.cpu_ticks[CPU_STATE_USER] - self.prevUser) + (load.cpu_ticks[CPU_STATE_NICE] - self.prevNice);
        double system = load.cpu_ticks[CPU_STATE_SYSTEM] - self.prevSystem;
        double idle = load.cpu_ticks[CPU_STATE_IDLE] - self.prevIdle;
        double total = user + system + idle;
        if (total > 0) {
            self.cpuUser = user / total * 100.0;
            self.cpuSystem = system / total * 100.0;
            self.cpuUsed = (user + system) / total * 100.0;
        }
        [self updateRunnerSpeed];
        [self updateCPUReadouts];
        if (pref(@"showMetricsBar")) [self updateMetricsItem];
    }
    self.prevUser = load.cpu_ticks[CPU_STATE_USER];
    self.prevNice = load.cpu_ticks[CPU_STATE_NICE];
    self.prevSystem = load.cpu_ticks[CPU_STATE_SYSTEM];
    self.prevIdle = load.cpu_ticks[CPU_STATE_IDLE];
    self.hasCPUSample = YES;
}

- (void)sampleMemory {
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS) return;
    double page = (double)vm_kernel_page_size;
    self.memoryTotal = (double)NSProcessInfo.processInfo.physicalMemory;
    self.memoryWired = (double)vm.wire_count * page;
    self.memoryCompressed = (double)vm.compressor_page_count * page;
    self.memoryUsed = ((double)vm.active_count + vm.wire_count + vm.compressor_page_count) * page;
    if (self.memoryUsed > self.memoryTotal) self.memoryUsed = self.memoryTotal;
}

- (void)sampleStorage {
    NSDictionary *values = [[NSURL fileURLWithPath:@"/"] resourceValuesForKeys:@[
        NSURLVolumeTotalCapacityKey,
        NSURLVolumeAvailableCapacityForImportantUsageKey,
        NSURLVolumeAvailableCapacityKey,
        NSURLVolumeLocalizedNameKey,
        NSURLVolumeNameKey
    ] error:nil];
    double total = [values[NSURLVolumeTotalCapacityKey] doubleValue];
    double free = [values[NSURLVolumeAvailableCapacityForImportantUsageKey] doubleValue];
    if (free <= 0) free = [values[NSURLVolumeAvailableCapacityKey] doubleValue];
    if (free > total) free = total;
    self.storageTotal = total;
    self.storageUsed = total > free ? total - free : 0;
    self.storageName = values[NSURLVolumeLocalizedNameKey] ?: values[NSURLVolumeNameKey] ?: @"Macintosh HD";
}

- (void)sampleNetwork {
    struct ifaddrs *list = NULL;
    uint64_t bytesIn = 0;
    uint64_t bytesOut = 0;
    if (getifaddrs(&list) == 0) {
        for (struct ifaddrs *item = list; item; item = item->ifa_next) {
            if (!item->ifa_addr || item->ifa_addr->sa_family != AF_LINK) continue;
            if (!(item->ifa_flags & IFF_UP) || (item->ifa_flags & IFF_LOOPBACK)) continue;
            NSString *name = @(item->ifa_name);
            if ([name hasPrefix:@"lo"] || [name hasPrefix:@"awdl"] || [name hasPrefix:@"llw"] || [name hasPrefix:@"utun"] || [name hasPrefix:@"bridge"] || [name hasPrefix:@"ap"] || [name hasPrefix:@"gif"] || [name hasPrefix:@"stf"]) continue;
            struct if_data *data = (struct if_data *)item->ifa_data;
            if (!data) continue;
            bytesIn += data->ifi_ibytes;
            bytesOut += data->ifi_obytes;
        }
        freeifaddrs(list);
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (self.prevNetTime > 0) {
        double elapsed = now - self.prevNetTime;
        if (elapsed > 0.2) {
            self.netDown = bytesIn >= self.prevNetIn ? (bytesIn - self.prevNetIn) / elapsed : 0;
            self.netUp = bytesOut >= self.prevNetOut ? (bytesOut - self.prevNetOut) / elapsed : 0;
            self.hasNetworkSample = YES;
        }
    }
    self.prevNetIn = bytesIn;
    self.prevNetOut = bytesOut;
    self.prevNetTime = now;

    NSString *iface = @"네트워크";
    NSString *symbol = @"network";
    SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("MacBookBattery"), NULL, NULL);
    if (store) {
        CFDictionaryRef ipv4 = SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Global/IPv4"));
        NSString *primary = nil;
        if (ipv4) {
            primary = ((__bridge NSDictionary *)ipv4)[@"PrimaryInterface"];
            CFRelease(ipv4);
        }
        if (primary.length) {
            NSString *airportKey = [NSString stringWithFormat:@"State:/Network/Interface/%@/AirPort", primary];
            CFDictionaryRef airport = SCDynamicStoreCopyValue(store, (__bridge CFStringRef)airportKey);
            if (airport) {
                iface = @"Wi-Fi";
                symbol = @"wifi";
                CFRelease(airport);
            } else if ([primary hasPrefix:@"en"]) {
                iface = @"이더넷";
                symbol = @"cable.connector";
            } else {
                iface = primary;
                symbol = @"network";
            }
        }
        CFRelease(store);
    }
    self.netName = iface;
    self.netSymbol = symbol;
}

- (void)refreshMetrics {
    [self refreshCustomMetrics];
    [self sampleMemory];
    [self sampleStorage];
    [self sampleNetwork];
    self.status = readBattery();
    [self applyAutomaticModes];
    double memoryPercent = self.memoryTotal > 0 ? self.memoryUsed / self.memoryTotal * 100.0 : 0;
    pushSample(self.cpuHistory, self.cpuUsed);
    pushSample(self.memoryHistory, memoryPercent);
    [self updateStatusItem];
    [self updateMetricsItem];
    [self updateCPUReadouts];
    [self updatePopover];
    [self updateSettingsWindow];
}

- (void)updateCPUReadouts {
    NSString *detail = [NSString stringWithFormat:@"시스템 %.1f%%  ·  사용자 %.1f%%", self.cpuSystem, self.cpuUser];
    NSString *speed = [NSString stringWithFormat:@"%.1f×", [self runnerUnit]];
    self.fields[@"dash.cpu.value"].stringValue = [NSString stringWithFormat:@"%.1f%%", self.cpuUsed];
    self.fields[@"dash.cpu.detail"].stringValue = detail;
    self.fields[@"dash.runner.value"].stringValue = speed;
    self.fields[@"dash.runner.detail"].stringValue = pref(@"slowWhenBusy") ? @"바쁠수록 천천히 달립니다" : @"바쁠수록 빨리 달립니다";
    self.popoverFields[@"cpu.summary"].stringValue = [NSString stringWithFormat:@"CPU  %.1f%%", self.cpuUsed];
    self.popoverFields[@"cpu.detail"].stringValue = detail;
    if (self.speedLabel) self.speedLabel.stringValue = [NSString stringWithFormat:@"지금 속도  %@", speed];
    NSString *tip = [NSString stringWithFormat:@"맥북 배터리 제어\nCPU %.0f%%", self.cpuUsed];
    if (![self.statusItem.button.toolTip isEqualToString:tip]) self.statusItem.button.toolTip = tip;
}

- (NSString *)statusButtonTitle {
    NSNumber *percent = self.status[@"percent"];
    NSString *title = percent ? [NSString stringWithFormat:@"%@%%", percent] : @"배터리";
    NSDictionary *charge = self.status[@"charge"];
    int limit = [charge[@"limit"] intValue];
    if ([charge[@"enabled"] boolValue] && limit > 0 && limit < 100) {
        title = [title stringByAppendingFormat:@" · %d", limit];
    }
    return title;
}

- (NSSize)statusArtSize {
    CGFloat width = 18;
    CGFloat height = 18;
    for (NSImage *frame in self.runnerFrames) {
        width = MAX(width, ceil(frame.size.width));
        height = MAX(height, ceil(frame.size.height));
    }
    return NSMakeSize(width, height);
}

- (CGFloat)statusTitleSlotWidth {
    NSDictionary *attrs = statusTitleAttributes();
    CGFloat width = ceil([@"100%" sizeWithAttributes:attrs].width);
    width = MAX(width, ceil([[self statusButtonTitle] sizeWithAttributes:attrs].width));
    NSDictionary *charge = self.status[@"charge"];
    int limit = [charge[@"limit"] intValue];
    if ([charge[@"enabled"] boolValue] && limit > 0 && limit < 100) {
        width = MAX(width, ceil([@"100% · 80" sizeWithAttributes:attrs].width));
    }
    return width;
}

- (NSImage *)currentStatusIcon {
    if (self.runnerFrames.count > 0) return self.runnerFrames[self.runnerFrame % self.runnerFrames.count];
    NSImage *icon = symbolImage(symbolName(self.status ?: @{}), 15);
    icon.size = NSMakeSize(16, 16);
    return icon;
}

// 버튼의 image 와 title 을 매 프레임 바꾸면 메뉴 막대 칸이 다시 잡히며 한글 조합이 끊긴다.
// 칸 크기가 바뀔 때만 투명 이미지를 두고, 그림과 글자는 그 위 뷰에 그린다.
- (BarGlyphView *)glyphViewOnButton:(NSStatusBarButton *)button key:(NSString *)key size:(NSSize)size {
    if (!button || size.width < 1 || size.height < 1) return nil;
    NSImage *spacer = self.barSpacers[key];
    BOOL sizeChanged = !spacer || fabs(spacer.size.width - size.width) > 0.5 || fabs(spacer.size.height - size.height) > 0.5;
    if (sizeChanged) {
        spacer = [[NSImage alloc] initWithSize:size];
        self.barSpacers[key] = spacer;
        button.image = spacer;
    } else if (button.image != spacer) {
        button.image = spacer;
    }
    BarGlyphView *view = (BarGlyphView *)self.barOverlays[key];
    if (![view isKindOfClass:BarGlyphView.class] || view.superview != button) {
        view = [[BarGlyphView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
        [view setAccessibilityElement:NO];
        [button addSubview:view];
        self.barOverlays[key] = view;
    }
    NSRect imageRect = NSZeroRect;
    if (button.bounds.size.width > 1 && [button.cell respondsToSelector:@selector(imageRectForBounds:)]) {
        imageRect = [(id)button.cell imageRectForBounds:button.bounds];
    }
    if (imageRect.size.width < 1 || imageRect.size.height < 1) imageRect = NSMakeRect(0, 0, size.width, size.height);
    if (!NSEqualRects(view.frame, imageRect)) view.frame = imageRect;
    view.layoutSize = size;
    return view;
}

- (void)refreshStatusButton {
    NSStatusBarButton *button = self.statusItem.button;
    if (!button) return;
    NSSize art = [self statusArtSize];
    NSString *title = [self statusButtonTitle];
    NSSize size = NSMakeSize(art.width + 4.0 + [self statusTitleSlotWidth], MAX(art.height, 18));
    NSString *iconKey = self.runnerFrames.count
        ? [NSString stringWithFormat:@"runner:%lu", (unsigned long)(self.runnerFrame % self.runnerFrames.count)]
        : [NSString stringWithFormat:@"symbol:%@", symbolName(self.status ?: @{})];
    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@|%.2f|%.2f|%.2f", selectedRunnerID(), iconKey, title, art.width, size.width, size.height];
    BarGlyphView *glyph = [self glyphViewOnButton:button key:@"status" size:size];
    if ([signature isEqualToString:self.statusGlyphSignature]) return;
    self.statusGlyphSignature = signature;
    glyph.image = nil;
    glyph.icon = [self currentStatusIcon];
    glyph.title = title;
    glyph.artWidth = art.width;
    [glyph setNeedsDisplay:YES];
    // setImage: 는 메뉴 막대를 다시 배치한다. 그림이 바뀐 프레임만 display 로 그린다.
    [button display];
    NSString *label = [NSString stringWithFormat:@"맥북 배터리 제어, %@", title ?: @""];
    if (![button.accessibilityLabel isEqualToString:label]) button.accessibilityLabel = label;
}

- (void)updateStatusItem {
    [self refreshStatusButton];
}

- (NSImage *)metricsBarImage {
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    NSDictionary *attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.blackColor};
    NSFont *small = [NSFont monospacedDigitSystemFontOfSize:8 weight:NSFontWeightMedium];
    NSDictionary *smallAttrs = @{NSFontAttributeName: small, NSForegroundColorAttributeName: NSColor.blackColor};
    NSMutableArray *items = [NSMutableArray array];
    if (pref(@"barCPU")) [items addObject:@{@"symbol": @"cpu", @"text": [NSString stringWithFormat:@"%.0f%%", self.cpuUsed]}];
    if (pref(@"barMemory") && self.memoryTotal > 0) {
        [items addObject:@{@"symbol": @"memorychip", @"text": [NSString stringWithFormat:@"%.0f%%", self.memoryUsed / self.memoryTotal * 100.0]}];
    }
    if (pref(@"barStorage") && self.storageTotal > 0) {
        [items addObject:@{@"symbol": @"internaldrive", @"text": [NSString stringWithFormat:@"%.0f%%", self.storageUsed / self.storageTotal * 100.0]}];
    }
    if (pref(@"barBattery") && self.status[@"percent"]) {
        [items addObject:@{@"symbol": symbolName(self.status), @"text": [NSString stringWithFormat:@"%@%%", self.status[@"percent"]]}];
    }
    if (pref(@"barNetwork")) {
        NSString *up = self.hasNetworkSample ? [@"↑" stringByAppendingString:rateText(self.netUp)] : @"↑…";
        NSString *down = self.hasNetworkSample ? [@"↓" stringByAppendingString:rateText(self.netDown)] : @"↓…";
        [items addObject:@{@"symbol": self.netSymbol ?: @"network", @"up": up, @"down": down}];
    }
    for (NSDictionary *source in customMetricSources()) {
        if (![source[@"showInBar"] boolValue]) continue;
        NSString *ident = source[@"id"];
        NSDictionary *snap = self.customSnapshots[ident];
        BOOL failed = [self.customFailed containsObject:ident];
        NSString *text = (!failed && [snap[@"metricsBarValue"] isKindOfClass:[NSString class]] && [snap[@"metricsBarValue"] length]) ? snap[@"metricsBarValue"] : @"---";
        if (text.length > 12) text = [[text substringToIndex:12] stringByAppendingString:@"…"];
        NSString *symbol = snap[@"symbol"] ?: @"chart.bar.horizontal.page";
        [items addObject:@{@"symbol": symbol, @"text": text, @"slot": @"custom", @"id": ident ?: @""}];
    }
    if (items.count == 0) {
        NSImage *idle = symbolImage(@"moon.zzz", 13);
        idle.template = YES;
        idle.size = NSMakeSize(18, 18);
        return idle;
    }

    CGFloat cursor = 0;
    NSMutableArray *layout = [NSMutableArray array];
    for (NSDictionary *item in items) {
        CGFloat textWidth = 0;
        if (item[@"text"]) {
            if ([item[@"slot"] isEqualToString:@"custom"]) {
                CGFloat measured = ceil([item[@"text"] sizeWithAttributes:attrs].width);
                NSString *ident = item[@"id"] ?: @"";
                CGFloat kept = MAX(measured, [self.customSlotWidths[ident] doubleValue]);
                if (kept > [self.customSlotWidths[ident] doubleValue] + 0.5) self.customSlotWidths[ident] = @(kept);
                textWidth = kept;
            } else {
                textWidth = ceil([@"100%" sizeWithAttributes:attrs].width);
            }
        } else {
            textWidth = metricsRateColumnWidth(smallAttrs);
        }
        CGFloat width = 15 + textWidth;
        [layout addObject:@{@"item": item, @"x": @(cursor), @"textX": @(cursor + 15), @"textW": @(textWidth), @"w": @(width)}];
        cursor += width + 7;
    }
    CGFloat totalWidth = MAX(1, cursor - 7);
    NSImage *image = [NSImage imageWithSize:NSMakeSize(totalWidth, 18) flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
        (void)dstRect;
        for (NSDictionary *entry in layout) {
            NSDictionary *item = entry[@"item"];
            CGFloat x = [entry[@"x"] doubleValue];
            CGFloat textX = [entry[@"textX"] doubleValue];
            NSImage *icon = symbolImage(item[@"symbol"], 11);
            [icon drawInRect:NSMakeRect(x, 2, 13, 13) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
            CGFloat textW = [entry[@"textW"] doubleValue];
            [NSGraphicsContext.currentContext saveGraphicsState];
            NSRectClip(NSMakeRect(textX, -2, textW, 22));
            if (item[@"text"]) {
                [item[@"text"] drawAtPoint:NSMakePoint(textX, 2) withAttributes:attrs];
            } else {
                [item[@"up"] drawAtPoint:NSMakePoint(textX, 8) withAttributes:smallAttrs];
                [item[@"down"] drawAtPoint:NSMakePoint(textX, -1) withAttributes:smallAttrs];
            }
            [NSGraphicsContext.currentContext restoreGraphicsState];
        }
        return YES;
    }];
    image.template = YES;
    return image;
}

- (void)updateMetricsItem {
    if (!pref(@"showMetricsBar")) {
        if (self.metricsItem) {
            [[NSStatusBar systemStatusBar] removeStatusItem:self.metricsItem];
            self.metricsItem = nil;
        }
        [self.barOverlays removeObjectForKey:@"metrics"];
        [self.barSpacers removeObjectForKey:@"metrics"];
        return;
    }
    NSImage *image = [self metricsBarImage];
    if (!image) {
        if (self.metricsItem) {
            [[NSStatusBar systemStatusBar] removeStatusItem:self.metricsItem];
            self.metricsItem = nil;
        }
        [self.barOverlays removeObjectForKey:@"metrics"];
        [self.barSpacers removeObjectForKey:@"metrics"];
        return;
    }
    if (!self.metricsItem) {
        self.metricsItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
        self.metricsItem.button.target = self;
        self.metricsItem.button.action = @selector(toggleMetricsSettings:);
        self.metricsItem.button.imagePosition = NSImageOnly;
        self.metricsItem.button.title = @"";
        self.metricsItem.button.toolTip = @"지표 막대 설정";
    }
    BarGlyphView *glyph = [self glyphViewOnButton:self.metricsItem.button key:@"metrics" size:image.size];
    glyph.icon = nil;
    glyph.title = nil;
    glyph.image = image;
    [glyph setNeedsDisplay:YES];
    [self.metricsItem.button display];
}

- (void)toggleDashboard:(id)sender {
    NSView *anchor = [sender isKindOfClass:[NSView class]] ? sender : self.statusItem.button;
    if (self.popover.isShown) {
        [self.popover performClose:nil];
        return;
    }
    if (self.popoverClosedAt && [NSDate.date timeIntervalSinceDate:self.popoverClosedAt] < 0.3) return;
    if (!self.popover) {
        self.popover = [[NSPopover alloc] init];
        self.popover.behavior = NSPopoverBehaviorTransient;
        self.popover.animates = YES;
        self.popover.delegate = self;
        self.popoverRoot = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, 360, 240)];
        self.popoverRoot.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        NSViewController *controller = [[NSViewController alloc] initWithNibName:nil bundle:nil];
        controller.view = self.popoverRoot;
        self.popover.contentViewController = controller;
    }
    [self updatePopover];
    [self.popover showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSRectEdgeMinY];
}

- (void)popoverDidClose:(NSNotification *)notification {
    (void)notification;
    self.popoverClosedAt = [NSDate date];
}

- (NSArray<NSString *> *)batteryLineKeys {
    NSMutableArray *keys = [NSMutableArray arrayWithObjects:@"battery.state", @"battery.source", nil];
    NSDictionary *status = self.status ?: @{};
    if (status[@"healthPercent"]) [keys addObject:@"battery.health"];
    if (status[@"cycleCount"]) [keys addObject:@"battery.cycles"];
    if (status[@"powerWatts"]) [keys addObject:@"battery.power"];
    if (status[@"voltage"]) [keys addObject:@"battery.voltage"];
    if (status[@"fullMah"]) [keys addObject:@"battery.capacity"];
    if (status[@"remainingMah"]) [keys addObject:@"battery.remaining"];
    if (status[@"amperage"]) [keys addObject:@"battery.amperage"];
    if (status[@"temperature"]) [keys addObject:@"battery.temp"];
    [keys addObject:@"battery.limit"];
    if (modeStatusText()) [keys addObject:@"battery.mode"];
    return keys;
}

- (NSArray<NSDictionary *> *)popoverRows {
    NSMutableArray *rows = [NSMutableArray array];
    [rows addObject:@{@"symbol": @"cpu", @"icon": @"cpu", @"summary": @"cpu.summary", @"lines": @[@"cpu.detail"], @"graph": @"cpu"}];
    if (pref(@"showMemory")) {
        [rows addObject:@{@"symbol": @"memorychip", @"icon": @"memory", @"summary": @"memory.summary", @"lines": @[@"memory.detail"], @"graph": @"memory"}];
    }
    if (pref(@"showStorage")) {
        [rows addObject:@{@"symbol": @"internaldrive", @"icon": @"storage", @"summary": @"storage.summary", @"lines": @[@"storage.detail"], @"graph": @"storage"}];
    }
    if (pref(@"showBattery")) {
        [rows addObject:@{@"symbol": symbolName(self.status), @"icon": @"battery", @"summary": @"battery.summary", @"lines": [self batteryLineKeys]}];
    }
    if (pref(@"showNetwork")) {
        [rows addObject:@{@"symbol": self.netSymbol ?: @"network", @"icon": @"network", @"summary": @"network.summary", @"lines": @[@"network.up", @"network.down"]}];
    }
    for (NSDictionary *source in customMetricSources()) {
        NSString *ident = source[@"id"] ?: @"";
        NSDictionary *snap = self.customSnapshots[ident];
        NSMutableArray *lines = [NSMutableArray array];
        NSArray *metrics = [snap[@"metrics"] isKindOfClass:[NSArray class]] ? snap[@"metrics"] : @[];
        for (NSUInteger index = 0; index < metrics.count; index++) {
            NSString *marker = metrics[index][@"normalizedValue"] ? @"bar" : @"text";
            [lines addObject:[NSString stringWithFormat:@"cm|%@|%lu|%@", ident, (unsigned long)index, marker]];
        }
        [lines addObject:[NSString stringWithFormat:@"cm|%@|updated", ident]];
        [rows addObject:@{
            @"symbol": snap[@"symbol"] ?: @"chart.bar.horizontal.page",
            @"summary": [NSString stringWithFormat:@"cm|%@|summary", ident],
            @"lines": lines,
            @"custom": ident
        }];
    }
    return rows;
}

- (NSString *)popoverSignature {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *row in [self popoverRows]) {
        [parts addObject:row[@"summary"]];
        [parts addObject:row[@"symbol"] ?: @""];
        [parts addObjectsFromArray:row[@"lines"]];
    }
    return [parts componentsJoinedByString:@"|"];
}

- (NSString *)popoverText:(NSString *)key {
    NSDictionary *status = self.status ?: @{};
    if ([key isEqualToString:@"cpu.summary"]) return [NSString stringWithFormat:@"CPU  %.1f%%", self.cpuUsed];
    if ([key isEqualToString:@"cpu.detail"]) return [NSString stringWithFormat:@"시스템 %.1f%%  ·  사용자 %.1f%%", self.cpuSystem, self.cpuUser];
    if ([key isEqualToString:@"memory.summary"]) {
        if (self.memoryTotal <= 0) return @"메모리  –";
        return [NSString stringWithFormat:@"메모리  %@ / %@", byteText(self.memoryUsed, NSByteCountFormatterCountStyleMemory), byteText(self.memoryTotal, NSByteCountFormatterCountStyleMemory)];
    }
    if ([key isEqualToString:@"memory.detail"]) {
        if (self.memoryTotal <= 0) return @"계산 중";
        double percent = self.memoryUsed / self.memoryTotal * 100.0;
        return [NSString stringWithFormat:@"%.0f%%  ·  와이어드 %@  ·  압축 %@", percent, byteText(self.memoryWired, NSByteCountFormatterCountStyleMemory), byteText(self.memoryCompressed, NSByteCountFormatterCountStyleMemory)];
    }
    if ([key isEqualToString:@"storage.summary"]) return [NSString stringWithFormat:@"저장공간  %@", self.storageName ?: @"–"];
    if ([key isEqualToString:@"storage.detail"]) {
        if (self.storageTotal <= 0) return @"계산 중";
        double percent = self.storageUsed / self.storageTotal * 100.0;
        return [NSString stringWithFormat:@"%@ / %@  ·  %.0f%%", byteText(self.storageUsed, NSByteCountFormatterCountStyleFile), byteText(self.storageTotal, NSByteCountFormatterCountStyleFile), percent];
    }
    if ([key isEqualToString:@"battery.summary"]) return status[@"percent"] ? [NSString stringWithFormat:@"배터리  %@%%", status[@"percent"]] : @"배터리  –";
    if ([key isEqualToString:@"battery.state"]) {
        NSString *remain = remainingLabel(status[@"timeRemaining"]);
        NSString *state = stateLabel(status);
        return remain ? [NSString stringWithFormat:@"%@  ·  %@", state, remain] : state;
    }
    if ([key isEqualToString:@"battery.source"]) return [NSString stringWithFormat:@"전원  %@", [status[@"source"] isEqualToString:@"ac"] ? @"어댑터" : @"배터리"];
    if ([key isEqualToString:@"battery.health"]) return [NSString stringWithFormat:@"성능 최대치  %@%%", status[@"healthPercent"]];
    if ([key isEqualToString:@"battery.cycles"]) {
        if (status[@"designCycles"]) return [NSString stringWithFormat:@"충전 횟수  %@ / %@", status[@"cycleCount"], status[@"designCycles"]];
        return [NSString stringWithFormat:@"충전 횟수  %@", status[@"cycleCount"]];
    }
    if ([key isEqualToString:@"battery.power"]) return [NSString stringWithFormat:@"지금 전력  %@", [self powerText]];
    if ([key isEqualToString:@"battery.voltage"]) return [NSString stringWithFormat:@"전압  %.2fV", [status[@"voltage"] doubleValue]];
    if ([key isEqualToString:@"battery.capacity"]) {
        if (status[@"designMah"]) return [NSString stringWithFormat:@"용량  %@ / %@ mAh", status[@"fullMah"], status[@"designMah"]];
        return [NSString stringWithFormat:@"용량  %@ mAh", status[@"fullMah"]];
    }
    if ([key isEqualToString:@"battery.remaining"]) return [NSString stringWithFormat:@"남은 용량  %@ mAh", status[@"remainingMah"]];
    if ([key isEqualToString:@"battery.amperage"]) return [NSString stringWithFormat:@"전류  %.2fA", [status[@"amperage"] doubleValue]];
    if ([key isEqualToString:@"battery.temp"]) return [NSString stringWithFormat:@"온도  %.1f°C", [status[@"temperature"] doubleValue]];
    if ([key isEqualToString:@"battery.limit"]) return [NSString stringWithFormat:@"충전 한도  %@", limitText(status[@"charge"])];
    if ([key isEqualToString:@"battery.mode"]) return modeStatusText() ?: @"";
    if ([key isEqualToString:@"network.summary"]) return [NSString stringWithFormat:@"네트워크  %@", self.netName ?: @"–"];
    if ([key isEqualToString:@"network.up"]) return self.hasNetworkSample ? [NSString stringWithFormat:@"↑  %@", rateText(self.netUp)] : @"↑  계산 중";
    if ([key isEqualToString:@"network.down"]) return self.hasNetworkSample ? [NSString stringWithFormat:@"↓  %@", rateText(self.netDown)] : @"↓  계산 중";
    if ([key hasPrefix:@"cm|"]) {
        NSArray<NSString *> *bits = [key componentsSeparatedByString:@"|"];
        if (bits.count < 3) return @"";
        NSString *ident = bits[1];
        NSString *part = bits[2];
        NSDictionary *snap = self.customSnapshots[ident];
        BOOL failed = [self.customFailed containsObject:ident];
        if ([part isEqualToString:@"summary"]) {
            if ([snap[@"title"] isKindOfClass:[NSString class]]) return snap[@"title"];
            for (NSDictionary *source in customMetricSources()) {
                if ([source[@"id"] isEqualToString:ident]) return [source[@"path"] lastPathComponent] ?: @"사용자 지표";
            }
            return @"사용자 지표";
        }
        if ([part isEqualToString:@"updated"]) return relativeUpdateText(snap[@"updated"], failed);
        NSArray *metrics = [snap[@"metrics"] isKindOfClass:[NSArray class]] ? snap[@"metrics"] : @[];
        NSInteger index = part.integerValue;
        if (index < 0 || index >= (NSInteger)metrics.count) return @"";
        return [NSString stringWithFormat:@"%@: %@", metrics[index][@"title"], metrics[index][@"formattedValue"]];
    }
    return @"";
}

- (CGFloat)appendPopoverRow:(NSDictionary *)row in:(FlippedView *)inner y:(CGFloat)y divider:(BOOL)divider {
    CGFloat width = NSWidth(inner.frame);
    if (divider) {
        NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(12, y, width - 24, 1)];
        line.boxType = NSBoxSeparator;
        [inner addSubview:line];
        y += 10;
    }
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(12, y, 24, 24)];
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    icon.image = symbolImage(row[@"symbol"], 16);
    [inner addSubview:icon];
    if (row[@"icon"]) self.popoverIcons[row[@"icon"]] = icon;
    NSTextField *summary = [self label:@"–" size:13 weight:NSFontWeightSemibold color:NSColor.labelColor];
    summary.lineBreakMode = NSLineBreakByTruncatingTail;
    summary.frame = NSMakeRect(48, y + 2, width - 64, 18);
    [inner addSubview:summary];
    self.popoverFields[row[@"summary"]] = summary;
    CGFloat textY = y + 26;
    for (NSString *key in row[@"lines"]) {
        NSTextField *line = [self label:@"" size:11 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
        line.lineBreakMode = NSLineBreakByTruncatingTail;
        line.frame = NSMakeRect(48, textY, width - 64, 15);
        [inner addSubview:line];
        self.popoverFields[key] = line;
        textY += 16;
    }
    NSString *graph = row[@"graph"];
    if (graph) {
        NSRect graphFrame = NSMakeRect(48, textY + 2, width - 64, 16);
        NSView *accessory = nil;
        if ([graph isEqualToString:@"cpu"]) {
            self.popoverCPUGraph = [[LineGraphView alloc] initWithFrame:graphFrame];
            accessory = self.popoverCPUGraph;
        } else if ([graph isEqualToString:@"memory"]) {
            self.popoverMemoryGraph = [[LineGraphView alloc] initWithFrame:graphFrame];
            accessory = self.popoverMemoryGraph;
        } else if ([graph isEqualToString:@"storage"]) {
            self.popoverStorageGraph = [[BarGraphView alloc] initWithFrame:graphFrame];
            accessory = self.popoverStorageGraph;
        }
        if (accessory) {
            [inner addSubview:accessory];
            textY += 22;
        }
    }
    return MAX(y + 32, textY + 4);
}

- (void)buildPopoverRows {
    [self.popoverRoot.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.popoverFields = [NSMutableDictionary dictionary];
    self.popoverIcons = [NSMutableDictionary dictionary];
    self.popoverCPUGraph = nil;
    self.popoverMemoryGraph = nil;
    self.popoverStorageGraph = nil;
    self.popoverBars = [NSMutableDictionary dictionary];
    CGFloat width = 360;
    CGFloat y = 10;
    NSTextField *title = [self label:@"맥북 배터리 제어" size:13 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    title.frame = NSMakeRect(16, y, 250, 18);
    [self.popoverRoot addSubview:title];
    NSButton *menuButton = [NSButton buttonWithImage:symbolImage(@"list.bullet", 13) target:self action:@selector(showPopoverMenu:)];
    menuButton.bordered = NO;
    menuButton.frame = NSMakeRect(width - 40, y - 5, 28, 26);
    menuButton.contentTintColor = NSColor.secondaryLabelColor;
    [self.popoverRoot addSubview:menuButton];
    y += 32;

    FlippedView *inner = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, width - 16, 10)];
    CGFloat innerY = 10;
    NSArray *rows = [self popoverRows];
    for (NSUInteger index = 0; index < rows.count; index++) {
        NSDictionary *row = rows[index];
        if (row[@"custom"]) innerY = [self appendCustomPopoverRow:row in:inner y:innerY divider:index > 0];
        else innerY = [self appendPopoverRow:row in:inner y:innerY divider:index > 0];
        innerY += 8;
    }
    inner.frame = NSMakeRect(0, 0, width - 16, innerY + 4);
    CGFloat maxHeight = 640;
    if (NSScreen.mainScreen) maxHeight = MAX(320, NSHeight(NSScreen.mainScreen.visibleFrame) - 140);
    CGFloat visible = MIN(NSHeight(inner.frame), maxHeight);
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, width - 16, visible)];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = NSHeight(inner.frame) > visible + 1;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    FlippedClipView *clip = [[FlippedClipView alloc] initWithFrame:scroll.bounds];
    clip.drawsBackground = NO;
    scroll.contentView = clip;
    scroll.documentView = inner;
    [clip scrollToPoint:NSZeroPoint];

    NSVisualEffectView *card = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(8, y, width - 16, visible)];
    card.material = NSVisualEffectMaterialContentBackground;
    card.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    card.state = NSVisualEffectStateActive;
    card.wantsLayer = YES;
    card.layer.cornerRadius = 12;
    card.layer.masksToBounds = YES;
    scroll.frame = card.bounds;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [card addSubview:scroll];
    [self.popoverRoot addSubview:card];
    y += visible + 10;
    self.popoverRoot.frame = NSMakeRect(0, 0, width, y);
    self.popoverRoot.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.popover.contentSize = self.popoverRoot.frame.size;
}

- (CGFloat)appendCustomPopoverRow:(NSDictionary *)row in:(FlippedView *)inner y:(CGFloat)y divider:(BOOL)divider {
    CGFloat width = NSWidth(inner.frame);
    if (divider) {
        NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(12, y, width - 24, 1)];
        line.boxType = NSBoxSeparator;
        [inner addSubview:line];
        y += 10;
    }
    NSString *ident = row[@"custom"];
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(12, y, 24, 24)];
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    icon.image = symbolImage(row[@"symbol"], 16);
    [inner addSubview:icon];
    self.popoverIcons[row[@"summary"]] = icon;
    NSTextField *summary = [self label:@"–" size:13 weight:NSFontWeightSemibold color:NSColor.labelColor];
    summary.lineBreakMode = NSLineBreakByTruncatingTail;
    summary.frame = NSMakeRect(48, y, width - 60, 18);
    [inner addSubview:summary];
    self.popoverFields[row[@"summary"]] = summary;
    CGFloat textY = y + 22;
    NSDictionary *snap = self.customSnapshots[ident];
    NSArray *metrics = [snap[@"metrics"] isKindOfClass:[NSArray class]] ? snap[@"metrics"] : @[];
    for (NSString *key in row[@"lines"]) {
        BOOL updated = [key hasSuffix:@"|updated"];
        NSTextField *line = [self label:@"" size:11 weight:NSFontWeightRegular color:updated ? NSColor.secondaryLabelColor : NSColor.labelColor];
        line.lineBreakMode = NSLineBreakByTruncatingTail;
        line.frame = NSMakeRect(48, textY, width - 64, 15);
        [inner addSubview:line];
        self.popoverFields[key] = line;
        textY += 16;
        if (updated) continue;
        NSArray<NSString *> *bits = [key componentsSeparatedByString:@"|"];
        if (bits.count < 4 || ![bits[3] isEqualToString:@"bar"]) continue;
        NSInteger index = bits[2].integerValue;
        if (index < 0 || index >= (NSInteger)metrics.count || !metrics[index][@"normalizedValue"]) continue;
        BarGraphView *bar = [[BarGraphView alloc] initWithFrame:NSMakeRect(48, textY, width - 64, 14)];
        [inner addSubview:bar];
        self.popoverBars[key] = bar;
        textY += 16;
    }
    return MAX(y + 32, textY + 4);
}

- (void)fillPopover {
    for (NSString *key in self.popoverFields) {
        self.popoverFields[key].stringValue = [self popoverText:key];
        if ([key hasSuffix:@"|updated"]) {
            NSArray<NSString *> *bits = [key componentsSeparatedByString:@"|"];
            BOOL failed = bits.count >= 2 && [self.customFailed containsObject:bits[1]];
            self.popoverFields[key].textColor = failed ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
        }
    }
    for (NSString *key in self.popoverBars) {
        NSArray<NSString *> *bits = [key componentsSeparatedByString:@"|"];
        if (bits.count < 3) continue;
        NSArray *metrics = self.customSnapshots[bits[1]][@"metrics"];
        NSInteger index = bits[2].integerValue;
        if (![metrics isKindOfClass:[NSArray class]] || index < 0 || index >= (NSInteger)metrics.count) continue;
        NSNumber *normalized = metrics[index][@"normalizedValue"];
        if (normalized) self.popoverBars[key].value = normalized.doubleValue * 100.0;
    }
    self.popoverIcons[@"battery"].image = symbolImage(symbolName(self.status), 16);
    self.popoverIcons[@"network"].image = symbolImage(self.netSymbol ?: @"network", 16);
    self.popoverCPUGraph.values = self.cpuHistory;
    self.popoverMemoryGraph.values = self.memoryHistory;
    self.popoverStorageGraph.value = self.storageTotal > 0 ? self.storageUsed / self.storageTotal * 100.0 : 0;
}

- (void)updatePopover {
    if (!self.popoverRoot) return;
    NSString *signature = [self popoverSignature];
    if (![signature isEqualToString:self.builtPopoverSignature]) {
        [self buildPopoverRows];
        self.builtPopoverSignature = signature;
    }
    [self fillPopover];
}

- (void)showPopoverMenu:(NSButton *)sender {
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *settings = [[NSMenuItem alloc] initWithTitle:@"설정…" action:@selector(openSettings:) keyEquivalent:@""];
    settings.target = self;
    [menu addItem:settings];
    NSMenuItem *activity = [[NSMenuItem alloc] initWithTitle:@"활동 모니터 열기" action:@selector(openActivityMonitor:) keyEquivalent:@""];
    activity.target = self;
    [menu addItem:activity];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"종료" action:@selector(terminate:) keyEquivalent:@""];
    quit.target = NSApp;
    [menu addItem:quit];
    NSPoint point = NSMakePoint(NSMinX(sender.bounds), NSMaxY(sender.bounds) + 4);
    [menu popUpMenuPositioningItem:nil atLocation:point inView:sender];
}

- (void)openActivityMonitor:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:@"/System/Applications/Utilities/Activity Monitor.app"]];
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
    (void)sender;
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

- (void)chooseLimit:(NSMenuItem *)item {
    [self applyLimit:(int)item.tag];
}

- (void)showNote:(NSString *)text error:(BOOL)error {
    NSColor *color = error ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    for (NSTextField *field in self.noteFields) {
        field.stringValue = text ?: @"";
        field.textColor = color;
    }
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
    [self showNote:(failure ?: (limit >= 100 ? @"충전 제한을 껐습니다." : [NSString stringWithFormat:@"충전 한도를 %d%%로 맞춰 두었습니다.", limit])) error:failure != nil];
    [self refreshMetrics];
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
        [self showNote:@"완충되어 이전 충전 한도로 되돌렸습니다." error:NO];
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
    (void)sender;
    [self rememberLimit];
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"sailEnabled"];
    [NSUserDefaults.standardUserDefaults setObject:@"topup" forKey:@"batteryMode"];
    setChargeLimit(100);
    self.status = readBattery();
    [self showNote:@"한 번만 100%까지 충전한 뒤 이전 한도로 돌아갑니다." error:NO];
    [self updateStatusItem];
    [self updateSettingsWindow];
    [self updatePopover];
}

- (void)startCalibration:(id)sender {
    (void)sender;
    [self rememberLimit];
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"sailEnabled"];
    [NSUserDefaults.standardUserDefaults setObject:@"calibration" forKey:@"batteryMode"];
    setChargeLimit(100);
    self.status = readBattery();
    [self showNote:@"보정 중입니다. 100%까지 충전한 뒤 보정 끝내기를 누르세요." error:NO];
    [self updateStatusItem];
    [self updateSettingsWindow];
    [self updatePopover];
}

- (void)endCalibration:(id)sender {
    (void)sender;
    [self restoreLimit];
    self.status = readBattery();
    [self showNote:@"이전 충전 한도로 되돌렸습니다." error:NO];
    [self updateStatusItem];
    [self updateSettingsWindow];
    [self updatePopover];
}

- (void)sailToggled:(NSButton *)sender {
    if (self.suppressLimitChange || !userInitiatedChange()) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:sender.state == NSControlStateValueOn forKey:@"sailEnabled"];
    if (sender.state == NSControlStateValueOn) [defaults setObject:@"none" forKey:@"batteryMode"];
    [self refreshMetrics];
}

- (void)sailBoundsChanged:(id)sender {
    (void)sender;
    if (self.suppressLimitChange || !userInitiatedChange()) return;
    int lower = [[self.lowerPopup.titleOfSelectedItem stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"%"]] intValue];
    int upper = [[self.upperPopup.titleOfSelectedItem stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"%"]] intValue];
    if (upper <= lower) upper = lower >= 90 ? 100 : lower + 10;
    [NSUserDefaults.standardUserDefaults setInteger:lower forKey:@"sailLower"];
    [NSUserDefaults.standardUserDefaults setInteger:upper forKey:@"sailUpper"];
    [self refreshMetrics];
}

- (void)limitChanged:(NSSegmentedControl *)control {
    if (self.suppressLimitChange || !userInitiatedChange()) return;
    NSInteger index = control.selectedSegment;
    if (index < 0 || (NSUInteger)index >= self.limitValues.count) return;
    int limit = self.limitValues[index].intValue;
    if (limit == activeChargeLimit(self.status[@"charge"])) return;
    [self applyLimit:limit];
}

- (void)intervalChanged:(NSPopUpButton *)sender {
    if (self.suppressLimitChange || !userInitiatedChange()) return;
    [NSUserDefaults.standardUserDefaults setInteger:sender.selectedTag forKey:@"updateInterval"];
    [self restartMetricsTimer];
}

- (void)metricFlagChanged:(NSButton *)sender {
    if (self.suppressLimitChange || !userInitiatedChange()) return;
    if ([sender.identifier isEqualToString:@"showMetricsBar"] && sender.state == NSControlStateValueOn && !pref(@"showMetricsBar")) {
        sender.state = NSControlStateValueOff;
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"지표 막대를 표시할까요?";
        alert.informativeText = @"노치가 있는 MacBook에서는 메뉴 막대에 지표 막대가 가려지거나, 옆의 항목을 누르기 어려울 수 있습니다.";
        [alert addButtonWithTitle:@"표시"];
        [alert addButtonWithTitle:@"마음이 바뀌었어요"];
        void (^apply)(NSModalResponse) = ^(NSModalResponse response) {
            if (response != NSAlertFirstButtonReturn) {
                [self updateSettingsWindow];
                return;
            }
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"showMetricsBar"];
            [self updateMetricsItem];
            [self updateSettingsWindow];
        };
        if (self.settingsWindow.isVisible) [alert beginSheetModalForWindow:self.settingsWindow completionHandler:apply];
        else apply([alert runModal]);
        return;
    }
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn forKey:sender.identifier];
    if ([sender.identifier isEqualToString:@"flipRunner"]) {
        [self applySelectedRunnerFrames];
        [self applyStatusImage];
        self.previewView.image = self.runnerFrames.firstObject;
    }
    self.builtPopoverSignature = nil;
    [self updateRunnerSpeed];
    [self updateMetricsItem];
    [self updatePopover];
    [self updateCPUReadouts];
    [self updateSettingsWindow];
}

- (void)loginCheckboxChanged:(NSButton *)sender {
    if (self.suppressLimitChange || !userInitiatedChange()) return;
    SMAppService *service = [SMAppService mainAppService];
    BOOL enabled = service.status == SMAppServiceStatusEnabled;
    BOOL want = sender.state == NSControlStateValueOn;
    if (want == enabled) return;
    NSError *error = nil;
    BOOL ok = want ? [service registerAndReturnError:&error] : [service unregisterAndReturnError:&error];
    if (!ok) {
        sender.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
        [NSApp activate];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"로그인 항목을 바꾸지 못했습니다";
        alert.informativeText = error.localizedDescription ?: @"시스템 설정에서 로그인 항목을 허용해 주세요.";
        [alert runModal];
    }
}

typedef struct {
    uint8_t *pixels;
    int width;
    int height;
} RunnerBitmap;

static void runnerBitmapFree(RunnerBitmap *bitmap) {
    free(bitmap->pixels);
    bitmap->pixels = NULL;
    bitmap->width = 0;
    bitmap->height = 0;
}

static RunnerBitmap runnerBitmapMake(int width, int height) {
    RunnerBitmap bitmap = {NULL, 0, 0};
    if (width < 1 || height < 1) return bitmap;
    bitmap.pixels = calloc((size_t)width * (size_t)height, 4);
    if (!bitmap.pixels) return bitmap;
    bitmap.width = width;
    bitmap.height = height;
    return bitmap;
}

static RunnerBitmap runnerBitmapFromImage(CGImageRef image) {
    RunnerBitmap bitmap = runnerBitmapMake((int)CGImageGetWidth(image), (int)CGImageGetHeight(image));
    if (!bitmap.pixels) return bitmap;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(bitmap.pixels, bitmap.width, bitmap.height, 8, (size_t)bitmap.width * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextTranslateCTM(context, 0, bitmap.height);
    CGContextScaleCTM(context, 1, -1);
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, bitmap.width, bitmap.height), image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return bitmap;
}

static int runnerPixelOffset(const RunnerBitmap *bitmap, int x, int y) {
    return (y * bitmap->width + x) * 4;
}

static void runnerClearEdgeBackground(RunnerBitmap *bitmap) {
    int total = bitmap->width * bitmap->height;
    int transparent = 0;
    for (int index = 0; index < total; index++) {
        if (bitmap->pixels[index * 4 + 3] < 250) transparent++;
    }
    if (transparent > total / 20) return;
    int corners[4] = {0, bitmap->width - 1, (bitmap->height - 1) * bitmap->width, bitmap->height * bitmap->width - 1};
    int maxDistance = 0;
    for (int i = 0; i < 4; i++) {
        for (int j = i + 1; j < 4; j++) {
            const uint8_t *a = bitmap->pixels + corners[i] * 4;
            const uint8_t *b = bitmap->pixels + corners[j] * 4;
            int distance = abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2]);
            if (distance > maxDistance) maxDistance = distance;
        }
    }
    if (maxDistance > 48) return;
    int red = 0, green = 0, blue = 0;
    for (int i = 0; i < 4; i++) {
        const uint8_t *pixel = bitmap->pixels + corners[i] * 4;
        red += pixel[0];
        green += pixel[1];
        blue += pixel[2];
    }
    red /= 4;
    green /= 4;
    blue /= 4;
    uint8_t *seen = calloc((size_t)total, 1);
    int *queue = malloc(sizeof(int) * (size_t)total);
    if (!seen || !queue) {
        free(seen);
        free(queue);
        return;
    }
    int tail = 0;
    for (int y = 0; y < bitmap->height; y++) {
        for (int x = 0; x < bitmap->width; x++) {
            if (x != 0 && y != 0 && x != bitmap->width - 1 && y != bitmap->height - 1) continue;
            int index = y * bitmap->width + x;
            const uint8_t *pixel = bitmap->pixels + index * 4;
            int distance = abs(pixel[0] - red) + abs(pixel[1] - green) + abs(pixel[2] - blue);
            if (pixel[3] > 240 && distance <= 42 && !seen[index]) {
                seen[index] = 1;
                queue[tail++] = index;
            }
        }
    }
    for (int head = 0; head < tail; head++) {
        int index = queue[head];
        memset(bitmap->pixels + index * 4, 0, 4);
        int x = index % bitmap->width;
        int y = index / bitmap->width;
        int neighbors[4] = {
            x > 0 ? index - 1 : -1,
            x + 1 < bitmap->width ? index + 1 : -1,
            y > 0 ? index - bitmap->width : -1,
            y + 1 < bitmap->height ? index + bitmap->width : -1
        };
        for (int n = 0; n < 4; n++) {
            int next = neighbors[n];
            if (next < 0 || seen[next]) continue;
            const uint8_t *pixel = bitmap->pixels + next * 4;
            int distance = abs(pixel[0] - red) + abs(pixel[1] - green) + abs(pixel[2] - blue);
            if (pixel[3] > 240 && distance <= 42) {
                seen[next] = 1;
                queue[tail++] = next;
            }
        }
    }
    free(queue);
    free(seen);
}

static int runnerSpanCount(const RunnerBitmap *bitmap, BOOL columns, int minGap, int minSpan, int *starts, int *ends, int limit) {
    int length = columns ? bitmap->width : bitmap->height;
    int count = 0;
    int origin = -1;
    int gap = 0;
    for (int index = 0; index <= length; index++) {
        BOOL empty = YES;
        if (index < length) {
            int samples = columns ? bitmap->height : bitmap->width;
            for (int sample = 0; sample < samples; sample++) {
                int x = columns ? index : sample;
                int y = columns ? sample : index;
                if (bitmap->pixels[runnerPixelOffset(bitmap, x, y) + 3] > 16) {
                    empty = NO;
                    break;
                }
            }
        }
        if (empty) {
            if (index < length) gap++;
            continue;
        }
        if (origin >= 0 && gap >= minGap) {
            int end = index - gap;
            if (end - origin >= minSpan && count < limit) {
                starts[count] = origin;
                ends[count] = end;
                count++;
            }
            origin = index;
        } else if (origin < 0) {
            origin = index;
        }
        gap = 0;
    }
    if (origin >= 0 && count < limit) {
        int end = length - gap;
        if (end - origin >= minSpan) {
            starts[count] = origin;
            ends[count] = end;
            count++;
        }
    }
    return count;
}

static BOOL runnerContentBounds(const RunnerBitmap *bitmap, int left, int top, int width, int height, int *outX, int *outY, int *outW, int *outH) {
    int minX = width, minY = height, maxX = -1, maxY = -1;
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            if (bitmap->pixels[runnerPixelOffset(bitmap, left + x, top + y) + 3] <= 16) continue;
            if (x < minX) minX = x;
            if (y < minY) minY = y;
            if (x > maxX) maxX = x;
            if (y > maxY) maxY = y;
        }
    }
    if (maxX < 0) return NO;
    *outX = left + minX;
    *outY = top + minY;
    *outW = maxX - minX + 1;
    *outH = maxY - minY + 1;
    return YES;
}

static RunnerBitmap runnerScaleBitmap(const RunnerBitmap *source, int width, int height) {
    RunnerBitmap scaled = runnerBitmapMake(width, height);
    if (!scaled.pixels) return scaled;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef sourceContext = CGBitmapContextCreate(source->pixels, source->width, source->height, 8, (size_t)source->width * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef image = CGBitmapContextCreateImage(sourceContext);
    CGContextRef scaledContext = CGBitmapContextCreate(scaled.pixels, width, height, 8, (size_t)width * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextSetInterpolationQuality(scaledContext, kCGInterpolationHigh);
    CGContextTranslateCTM(scaledContext, 0, height);
    CGContextScaleCTM(scaledContext, 1, -1);
    CGContextDrawImage(scaledContext, CGRectMake(0, 0, width, height), image);
    CGImageRelease(image);
    CGContextRelease(scaledContext);
    CGContextRelease(sourceContext);
    CGColorSpaceRelease(space);
    return scaled;
}

static BOOL runnerWritePNG(const RunnerBitmap *bitmap, NSURL *url) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(bitmap->pixels, bitmap->width, bitmap->height, 8, (size_t)bitmap->width * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!context) {
        CGColorSpaceRelease(space);
        return NO;
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    BOOL ok = destination && image;
    if (ok) {
        CGImageDestinationAddImage(destination, image, NULL);
        ok = CGImageDestinationFinalize(destination);
    }
    if (destination) CFRelease(destination);
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return ok;
}

static BOOL runnerImageFile(NSURL *url) {
    NSString *extension = url.pathExtension.lowercaseString;
    return [@[@"png", @"jpg", @"jpeg", @"gif", @"tif", @"tiff", @"bmp", @"heic", @"webp"] containsObject:extension];
}

static RunnerBitmap runnerBitmapDecode(CGImageRef image) {
    int width = (int)CGImageGetWidth(image);
    int height = (int)CGImageGetHeight(image);
    RunnerBitmap bitmap = runnerBitmapMake(width, height);
    if (!bitmap.pixels) return bitmap;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(bitmap.pixels, width, height, 8, (size_t)width * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!context) {
        runnerBitmapFree(&bitmap);
        CGColorSpaceRelease(space);
        return bitmap;
    }
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return bitmap;
}

static BOOL runnerIsWhiteBackground(int red, int green, int blue) {
    int mx = MAX(red, MAX(green, blue));
    int mn = MIN(red, MIN(green, blue));
    return mx >= 246 && (mx - mn) <= 16;
}

static BOOL runnerIsBlackBackground(int red, int green, int blue, int alpha) {
    if (alpha < 8) return YES;
    int mx = MAX(red, MAX(green, blue));
    int mn = MIN(red, MIN(green, blue));
    return mx <= 22 && (mx - mn) <= 12;
}

static BOOL runnerHasBlackMatte(const RunnerBitmap *bitmap) {
    int total = bitmap->width * bitmap->height;
    uint8_t *background = calloc((size_t)total, 1);
    int *queue = malloc(sizeof(int) * (size_t)total);
    if (!background || !queue) {
        free(background);
        free(queue);
        return NO;
    }
    int tail = 0;
    for (int y = 0; y < bitmap->height; y++) {
        for (int x = 0; x < bitmap->width; x++) {
            if (x != 0 && y != 0 && x != bitmap->width - 1 && y != bitmap->height - 1) continue;
            int index = y * bitmap->width + x;
            const uint8_t *pixel = bitmap->pixels + index * 4;
            if (!runnerIsBlackBackground(pixel[0], pixel[1], pixel[2], pixel[3]) || background[index]) continue;
            background[index] = 1;
            queue[tail++] = index;
        }
    }
    for (int head = 0; head < tail; head++) {
        int index = queue[head];
        int x = index % bitmap->width;
        int nexts[4] = {
            x > 0 ? index - 1 : -1,
            x + 1 < bitmap->width ? index + 1 : -1,
            index >= bitmap->width ? index - bitmap->width : -1,
            index + bitmap->width < total ? index + bitmap->width : -1
        };
        for (int n = 0; n < 4; n++) {
            int next = nexts[n];
            if (next < 0 || background[next]) continue;
            const uint8_t *pixel = bitmap->pixels + next * 4;
            if (!runnerIsBlackBackground(pixel[0], pixel[1], pixel[2], pixel[3])) continue;
            background[next] = 1;
            queue[tail++] = next;
        }
    }
    int opaque = 0;
    int removed = 0;
    for (int index = 0; index < total; index++) {
        if (bitmap->pixels[index * 4 + 3] <= 20) continue;
        opaque++;
        if (background[index]) removed++;
    }
    free(queue);
    free(background);
    if (opaque < 100 || removed < 100) return NO;
    double fraction = (double)removed / (double)opaque;
    return fraction > 0.04 && fraction < 0.85;
}

static int runnerCornerMode(const RunnerBitmap *bitmap) {
    if (bitmap->width < 2 || bitmap->height < 2) return 0;
    int xs[4] = {0, bitmap->width - 1, 0, bitmap->width - 1};
    int ys[4] = {0, 0, bitmap->height - 1, bitmap->height - 1};
    int white = 0, black = 0, clear = 0;
    for (int index = 0; index < 4; index++) {
        const uint8_t *pixel = bitmap->pixels + runnerPixelOffset(bitmap, xs[index], ys[index]);
        if (pixel[3] < 8) {
            clear++;
            continue;
        }
        if (runnerIsWhiteBackground(pixel[0], pixel[1], pixel[2])) white++;
        if (runnerIsBlackBackground(pixel[0], pixel[1], pixel[2], pixel[3])) black++;
    }
    if (white >= 3) return 1;
    if (black >= 3) return 2;
    if (clear >= 3 && runnerHasBlackMatte(bitmap)) return 2;
    return 0;
}

static void runnerCutBackground(RunnerBitmap *bitmap, int mode) {
    if (mode == 0) return;
    int total = bitmap->width * bitmap->height;
    uint8_t *background = calloc((size_t)total, 1);
    int *queue = malloc(sizeof(int) * (size_t)total);
    if (!background || !queue) {
        free(background);
        free(queue);
        return;
    }
    int tail = 0;
    for (int y = 0; y < bitmap->height; y++) {
        for (int x = 0; x < bitmap->width; x++) {
            if (x != 0 && y != 0 && x != bitmap->width - 1 && y != bitmap->height - 1) continue;
            int index = y * bitmap->width + x;
            const uint8_t *pixel = bitmap->pixels + index * 4;
            BOOL hit = mode == 1
                ? (pixel[3] < 8 || runnerIsWhiteBackground(pixel[0], pixel[1], pixel[2]))
                : runnerIsBlackBackground(pixel[0], pixel[1], pixel[2], pixel[3]);
            if (!hit || background[index]) continue;
            background[index] = 1;
            queue[tail++] = index;
        }
    }
    for (int head = 0; head < tail; head++) {
        int index = queue[head];
        int x = index % bitmap->width;
        int nexts[4] = {
            x > 0 ? index - 1 : -1,
            x + 1 < bitmap->width ? index + 1 : -1,
            index >= bitmap->width ? index - bitmap->width : -1,
            index + bitmap->width < total ? index + bitmap->width : -1
        };
        for (int n = 0; n < 4; n++) {
            int next = nexts[n];
            if (next < 0 || background[next]) continue;
            const uint8_t *pixel = bitmap->pixels + next * 4;
            BOOL hit = mode == 1
                ? (pixel[3] < 8 || runnerIsWhiteBackground(pixel[0], pixel[1], pixel[2]))
                : runnerIsBlackBackground(pixel[0], pixel[1], pixel[2], pixel[3]);
            if (!hit) continue;
            background[next] = 1;
            queue[tail++] = next;
        }
    }
    for (int index = 0; index < total; index++) {
        uint8_t *pixel = bitmap->pixels + index * 4;
        if (background[index]) {
            pixel[0] = pixel[1] = pixel[2] = pixel[3] = 0;
            continue;
        }
        if (mode != 2) continue;
        int x = index % bitmap->width;
        int nexts[4] = {
            x > 0 ? index - 1 : -1,
            x + 1 < bitmap->width ? index + 1 : -1,
            index >= bitmap->width ? index - bitmap->width : -1,
            index + bitmap->width < total ? index + bitmap->width : -1
        };
        BOOL touches = NO;
        for (int n = 0; n < 4; n++) {
            if (nexts[n] >= 0 && background[nexts[n]]) touches = YES;
        }
        if (!touches) continue;
        int red = pixel[0], green = pixel[1], blue = pixel[2];
        int mx = MAX(red, MAX(green, blue));
        int mn = MIN(red, MIN(green, blue));
        if (mx <= 48 && mx - mn <= 18) {
            int alpha = MAX(0, MIN(255, (mx - 18) * 8));
            pixel[0] = (uint8_t)(red * alpha / 255);
            pixel[1] = (uint8_t)(green * alpha / 255);
            pixel[2] = (uint8_t)(blue * alpha / 255);
            pixel[3] = (uint8_t)alpha;
        }
    }
    free(queue);
    free(background);
}

static void runnerCentroid(const RunnerBitmap *bitmap, double *x, double *y) {
    long sumX = 0;
    long sumY = 0;
    long count = 0;
    int total = bitmap->width * bitmap->height;
    for (int index = 0; index < total; index++) {
        if (bitmap->pixels[index * 4 + 3] <= 20) continue;
        sumX += index % bitmap->width;
        sumY += index / bitmap->width;
        count++;
    }
    if (count == 0) {
        *x = 0;
        *y = 0;
        return;
    }
    *x = (double)sumX / (double)count;
    *y = (double)sumY / (double)count;
}

static double runnerGIFDelay(CGImageSourceRef source, size_t index) {
    CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(source, index, NULL);
    if (!props) return 0;
    NSDictionary *gif = ((__bridge NSDictionary *)props)[(id)kCGImagePropertyGIFDictionary];
    double delay = [gif[(id)kCGImagePropertyGIFUnclampedDelayTime] doubleValue];
    if (delay <= 0) delay = [gif[(id)kCGImagePropertyGIFDelayTime] doubleValue];
    CFRelease(props);
    return delay;
}

static NSDictionary *convertRunnerURLs(NSArray<NSURL *> *urls) {
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    for (NSURL *url in urls) {
        BOOL directory = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&directory]) continue;
        if (!directory) {
            if (runnerImageFile(url)) [files addObject:url];
            continue;
        }
        NSArray<NSURL *> *children = [NSFileManager.defaultManager contentsOfDirectoryAtURL:url includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
        for (NSURL *child in children) {
            if (runnerImageFile(child)) [files addObject:child];
        }
    }
    [files sortUsingComparator:^NSComparisonResult(NSURL *lhs, NSURL *rhs) {
        return [lhs.lastPathComponent localizedStandardCompare:rhs.lastPathComponent];
    }];
    if (files.count == 0) return @{@"error": @"이미지 파일을 고르세요."};
    if (files.count > 32) files = [[files subarrayWithRange:NSMakeRange(0, 32)] mutableCopy];

    NSMutableArray<NSValue *> *stored = [NSMutableArray array];
    double delaySum = 0;
    int delayCount = 0;
    int backgroundMode = -1;
    NSString *error = nil;
    double originX = 0;
    double originY = 0;
    double maxDrift2 = 0;
    int frameSpan = 0;
    for (NSURL *file in files) {
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)file, NULL);
        if (!source) {
            error = @"이미지를 열지 못했습니다.";
            break;
        }
        size_t count = files.count == 1 ? CGImageSourceGetCount(source) : 1;
        if (count > 32) count = 32;
        for (size_t index = 0; index < count && stored.count < 32; index++) {
            double delay = runnerGIFDelay(source, index);
            if (delay > 0) {
                delaySum += delay;
                delayCount++;
            }
            CGImageRef image = CGImageSourceCreateImageAtIndex(source, index, NULL);
            if (!image) continue;
            RunnerBitmap bitmap = runnerBitmapDecode(image);
            CGImageRelease(image);
            if (!bitmap.pixels) continue;
            if (backgroundMode < 0) backgroundMode = runnerCornerMode(&bitmap);
            runnerCutBackground(&bitmap, backgroundMode);
            double cx = 0;
            double cy = 0;
            runnerCentroid(&bitmap, &cx, &cy);
            if (stored.count == 0) {
                originX = cx;
                originY = cy;
                frameSpan = MIN(bitmap.width, bitmap.height);
            } else {
                double dx = cx - originX;
                double dy = cy - originY;
                double drift2 = dx * dx + dy * dy;
                if (drift2 > maxDrift2) maxDrift2 = drift2;
            }
            [stored addObject:[NSValue valueWithBytes:&bitmap objCType:@encode(RunnerBitmap)]];
        }
        CFRelease(source);
        if (error) break;
    }
    if (error || stored.count == 0) {
        for (NSValue *value in stored) {
            RunnerBitmap bitmap;
            [value getValue:&bitmap];
            runnerBitmapFree(&bitmap);
        }
        return @{@"error": error ?: @"그림에서 꺼낼 내용이 없습니다."};
    }

    double meanDelay = delayCount > 0 ? delaySum / delayCount : 0;
    double interval = 0;
    if (stored.count >= 2 && meanDelay > 0.02) {
        // The cat GIF stays in place and flickers at 0.06s, so it advances every 0.7s.
        // The running GIF's body travels, so it keeps the delay stored in the file.
        double limit = frameSpan * 0.045;
        BOOL heldStill = maxDrift2 < limit * limit;
        interval = (meanDelay <= 0.1 && heldStill) ? 0.7 : meanDelay;
    }

    NSString *token = [[[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] substringToIndex:8] lowercaseString];
    NSString *runnerID = [@"c-" stringByAppendingString:token];
    NSURL *directory = [runnersDirectory() URLByAppendingPathComponent:runnerID isDirectory:YES];
    NSError *writeError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&writeError]) {
        for (NSValue *value in stored) {
            RunnerBitmap bitmap;
            [value getValue:&bitmap];
            runnerBitmapFree(&bitmap);
        }
        return @{@"error": writeError.localizedDescription ?: @"이미지를 저장하지 못했습니다."};
    }
    for (NSUInteger index = 0; index < stored.count; index++) {
        RunnerBitmap bitmap;
        [stored[index] getValue:&bitmap];
        NSURL *url = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"%lu.png", (unsigned long)index]];
        if (!runnerWritePNG(&bitmap, url)) error = @"이미지를 저장하지 못했습니다.";
        runnerBitmapFree(&bitmap);
    }
    if (error) {
        [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
        return @{@"error": error};
    }
    NSString *title = nil;
    BOOL inputDirectory = NO;
    if (urls.count == 1) {
        [NSFileManager.defaultManager fileExistsAtPath:urls.firstObject.path isDirectory:&inputDirectory];
    }
    if (inputDirectory) {
        title = urls.firstObject.lastPathComponent;
    } else if (files.count > 1) {
        NSString *prefix = files.firstObject.URLByDeletingPathExtension.lastPathComponent;
        for (NSURL *file in files) {
            NSString *name = file.URLByDeletingPathExtension.lastPathComponent;
            while (prefix.length > 0 && ![name hasPrefix:prefix]) {
                prefix = [prefix substringToIndex:prefix.length - 1];
            }
        }
        NSCharacterSet *trimmable = [NSCharacterSet characterSetWithCharactersInString:@"-_ .0123456789"];
        while (prefix.length > 0 && [trimmable characterIsMember:[prefix characterAtIndex:prefix.length - 1]]) {
            prefix = [prefix substringToIndex:prefix.length - 1];
        }
        if (prefix.length >= 2) title = prefix;
    }
    if (title.length == 0) title = files.firstObject.URLByDeletingPathExtension.lastPathComponent;
    if (title.length == 0) title = @"가져온 이미지";
    if (title.length > 24) {
        NSRange range = [title rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, MIN(24, title.length))];
        title = [[title substringWithRange:range] stringByAppendingString:@"…"];
    }
    NSMutableDictionary *meta = [@{@"title": title, @"template": @NO, @"frames": @(stored.count)} mutableCopy];
    if (interval > 0) meta[@"interval"] = @(interval);
    NSData *metaData = [NSJSONSerialization dataWithJSONObject:meta options:0 error:nil];
    [metaData writeToURL:[directory URLByAppendingPathComponent:@"meta.json"] atomically:YES];
    return @{@"id": runnerID};
}

- (NSArray<NSImage *> *)framesForRunnerSpec:(NSDictionary *)spec {
    NSMutableArray<NSImage *> *frames = [NSMutableArray array];
    BOOL template = [spec[@"template"] boolValue];
    for (int index = 0; index < 32; index++) {
        NSString *path = nil;
        if (spec[@"directory"]) {
            path = [spec[@"directory"] stringByAppendingPathComponent:[NSString stringWithFormat:@"%d.png", index]];
            if (![NSFileManager.defaultManager fileExistsAtPath:path]) break;
        } else {
            NSString *name = [NSString stringWithFormat:@"%@-%d", spec[@"prefix"], index];
            path = [NSBundle.mainBundle pathForResource:name ofType:@"png"];
            if (!path) break;
        }
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
        if (!image || image.size.height < 1 || image.size.width < 1) break;
        CGFloat height = spec[@"directory"] ? 20 : 18;
        CGFloat width = image.size.width / image.size.height * height;
        CGFloat maxWidth = spec[@"directory"] ? 28 : 36;
        if (width > maxWidth) {
            height = maxWidth * image.size.height / image.size.width;
            width = maxWidth;
        }
        image.size = NSMakeSize(MAX(12, width), MAX(8, height));
        image.template = template;
        [frames addObject:image];
    }
    return frames;
}

- (void)applySelectedRunnerFrames {
    NSString *runnerID = selectedRunnerID();
    NSArray<NSImage *> *frames = self.runnerSets[runnerID];
    if (frames.count == 0) frames = self.runnerSets[@"character"];
    if (pref(@"flipRunner") && frames.count > 0) {
        NSMutableArray<NSImage *> *flipped = [NSMutableArray array];
        for (NSImage *image in frames) {
            NSImage *copy = horizontallyFlippedImage(image);
            if (copy) [flipped addObject:copy];
        }
        frames = flipped;
    }
    self.runnerFrames = frames ?: @[];
    if (self.runnerFrames.count > 0 && self.runnerFrame >= self.runnerFrames.count) self.runnerFrame = 0;
    self.statusGlyphSignature = nil;
}

- (void)loadRunner {
    NSMutableDictionary<NSString *, NSArray<NSImage *> *> *sets = [NSMutableDictionary dictionary];
    for (NSDictionary *spec in allRunnerSpecs()) {
        NSArray<NSImage *> *frames = [self framesForRunnerSpec:spec];
        if (frames.count > 0) sets[spec[@"id"]] = frames;
    }
    self.runnerSets = sets;
    [self applySelectedRunnerFrames];
}

- (void)showRunnerAlert:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"이미지를 넣지 못했습니다";
    alert.informativeText = message ?: @"다시 골라 주세요.";
    if (self.settingsWindow) [alert beginSheetModalForWindow:self.settingsWindow completionHandler:nil];
    else [alert runModal];
}

- (void)useRunnerID:(NSString *)runnerID {
    if (self.runnerSets[runnerID].count == 0) return;
    [NSUserDefaults.standardUserDefaults setObject:runnerID forKey:@"runnerID"];
    self.runnerFrame = 0;
    [self applySelectedRunnerFrames];
    [self applyStatusImage];
    self.previewView.image = self.runnerFrames.firstObject;
    [self updateRunnerSpeed];
    [self reloadRunnerGallery];
    [self updateSettingsWindow];
}

- (void)importRunnerURLs:(NSArray<NSURL *> *)urls {
    if (self.runnerImporting || urls.count == 0) return;
    self.runnerImporting = YES;
    self.importRunnerButton.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = convertRunnerURLs(urls);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.runnerImporting = NO;
            self.importRunnerButton.enabled = YES;
            NSString *error = result[@"error"];
            if (error.length) {
                [self showRunnerAlert:error];
                return;
            }
            [self loadRunner];
            [self useRunnerID:result[@"id"]];
        });
    });
}

- (void)importRunner:(id)sender {
    (void)sender;
    if (self.suppressLimitChange || !userInitiatedChange() || self.runnerImporting) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = YES;
    panel.allowedContentTypes = @[UTTypeImage];
    panel.message = @"GIF나 그림을 고르세요. 프레임을 유지한 채 가장자리 배경만 지우고 선택창에 넣습니다.";
    panel.prompt = @"넣기";
    [panel beginSheetModalForWindow:self.settingsWindow completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        [self importRunnerURLs:panel.URLs];
    }];
}

- (void)removeRunner:(id)sender {
    (void)sender;
    if (self.suppressLimitChange || !userInitiatedChange()) return;
    NSString *runnerID = selectedRunnerID();
    if (![runnerID hasPrefix:@"c-"]) return;
    NSString *root = runnersDirectory().path.stringByStandardizingPath;
    NSString *target = [[root stringByAppendingPathComponent:runnerID] stringByStandardizingPath];
    if (![target hasPrefix:[root stringByAppendingString:@"/"]]) return;
    NSString *title = @"이 이미지";
    for (NSDictionary *spec in allRunnerSpecs()) {
        if ([spec[@"id"] isEqualToString:runnerID]) title = spec[@"title"];
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"선택창에서 뺄까요?";
    alert.informativeText = [NSString stringWithFormat:@"%@ 이미지는 선택창에서 지워집니다.", title];
    [alert addButtonWithTitle:@"빼기"];
    [alert addButtonWithTitle:@"취소"];
    [alert beginSheetModalForWindow:self.settingsWindow completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        [NSFileManager.defaultManager removeItemAtPath:target error:nil];
        [NSUserDefaults.standardUserDefaults setObject:@"character" forKey:@"runnerID"];
        [self loadRunner];
        [self applySelectedRunnerFrames];
        [self applyStatusImage];
        self.previewView.image = self.runnerFrames.firstObject;
        [self updateRunnerSpeed];
        [self reloadRunnerGallery];
        [self updateSettingsWindow];
    }];
}

- (void)runnerChoiceChanged:(NSButton *)sender {
    if (self.suppressLimitChange || !userInitiatedChange()) return;
    NSString *runnerID = sender.identifier;
    if (self.runnerSets[runnerID].count == 0) return;
    if ([runnerID isEqualToString:selectedRunnerID()]) {
        [self updateSettingsWindow];
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:runnerID forKey:@"runnerID"];
    self.runnerFrame = 0;
    [self applySelectedRunnerFrames];
    [self applyStatusImage];
    self.previewView.image = self.runnerFrames.firstObject;
    [self updateRunnerSpeed];
    [self updateSettingsWindow];
}

- (NSTimeInterval)runnerFrameInterval {
    NSString *runnerID = selectedRunnerID();
    for (NSDictionary *spec in allRunnerSpecs()) {
        if (![spec[@"id"] isEqualToString:runnerID]) continue;
        double interval = [spec[@"interval"] doubleValue];
        if (interval > 0.02) return interval;
    }
    return 0.14 / [self runnerUnit];
}

- (void)updateRunnerSpeed {
    if (self.runnerFrames.count < 2) {
        [self.runnerTimer invalidate];
        self.runnerTimer = nil;
        return;
    }
    NSTimeInterval interval = [self runnerFrameInterval];
    if (self.runnerTimer && fabs(self.runnerInterval - interval) < 0.008) return;
    self.runnerInterval = interval;
    [self.runnerTimer invalidate];
    self.runnerTimer = [NSTimer timerWithTimeInterval:interval target:self selector:@selector(advanceRunner:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.runnerTimer forMode:NSRunLoopCommonModes];
}

- (void)advanceRunner:(NSTimer *)timer {
    (void)timer;
    if (self.runnerFrames.count == 0) return;
    self.runnerFrame = (self.runnerFrame + 1) % self.runnerFrames.count;
    self.previewView.image = self.runnerFrames[self.runnerFrame];
    [self applyStatusImage];
}

- (void)applyStatusImage {
    [self refreshStatusButton];
}

- (NSTextField *)label:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight color:(NSColor *)color {
    NSTextField *field = [NSTextField labelWithString:text];
    // labelWithString 은 제약 기반이라, 프레임으로 놓는 상태창에서 왼쪽 아래로 붙는다.
    field.translatesAutoresizingMaskIntoConstraints = YES;
    field.font = [NSFont systemFontOfSize:size weight:weight];
    field.textColor = color;
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    return field;
}

- (NSControl *)guard:(NSControl *)control {
    [self.guardedControls addObject:control];
    return control;
}

- (void)performWithoutControlActions:(void (^)(void))block {
    NSMutableArray *saved = [NSMutableArray array];
    for (NSControl *control in self.guardedControls) {
        [saved addObject:@{
            @"control": control,
            @"action": [NSValue valueWithPointer:control.action],
            @"target": control.target ?: NSNull.null
        }];
        control.action = NULL;
        control.target = nil;
    }
    block();
    for (NSDictionary *item in saved) {
        NSControl *control = item[@"control"];
        control.action = [item[@"action"] pointerValue];
        id target = item[@"target"];
        control.target = target == NSNull.null ? nil : target;
    }
}

- (NSScrollView *)newPage {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 680, 640)];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    FlippedClipView *clip = [[FlippedClipView alloc] initWithFrame:scroll.bounds];
    clip.drawsBackground = NO;
    scroll.contentView = clip;
    FlippedView *document = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, 680, 640)];
    scroll.documentView = document;
    return scroll;
}

- (CGFloat)addHeading:(NSString *)title subtitle:(NSString *)subtitle y:(CGFloat)y to:(NSView *)document {
    NSTextField *heading = [self label:title size:22 weight:NSFontWeightBold color:NSColor.labelColor];
    heading.frame = NSMakeRect(28, y, 600, 30);
    [document addSubview:heading];
    y += 34;
    if (subtitle.length) {
        NSTextField *detail = [self label:subtitle size:13 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
        detail.frame = NSMakeRect(28, y, 600, 36);
        detail.maximumNumberOfLines = 2;
        detail.cell.wraps = YES;
        detail.cell.scrollable = NO;
        [document addSubview:detail];
        y += 44;
    }
    return y;
}

- (void)finishPage:(NSScrollView *)page y:(CGFloat)y {
    FlippedView *document = page.documentView;
    document.frame = NSMakeRect(0, 0, 680, MAX(y + 28, 200));
}

- (NSView *)placeCardIn:(NSView *)document x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width height:(CGFloat)height caption:(NSString *)caption symbol:(NSString *)symbol valueKey:(NSString *)valueKey detailKey:(NSString *)detailKey graph:(NSView *)graph {
    CardView *card = [[CardView alloc] initWithFrame:NSMakeRect(x, y, width, height)];
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(16, 16, 16, 16)];
    icon.image = symbolImage(symbol, 13);
    icon.contentTintColor = NSColor.secondaryLabelColor;
    NSTextField *cap = [self label:caption size:12 weight:NSFontWeightMedium color:NSColor.secondaryLabelColor];
    cap.frame = NSMakeRect(36, 14, width - 52, 18);
    NSTextField *value = [self label:@"–" size:22 weight:NSFontWeightSemibold color:NSColor.labelColor];
    value.font = [NSFont monospacedDigitSystemFontOfSize:22 weight:NSFontWeightSemibold];
    value.frame = NSMakeRect(16, 40, width - (graph ? 156 : 32), 28);
    NSTextField *detail = [self label:@"" size:12 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    detail.frame = NSMakeRect(16, height - 32, width - 32, 18);
    [card addSubview:icon];
    [card addSubview:cap];
    [card addSubview:value];
    [card addSubview:detail];
    if (graph) {
        graph.frame = NSMakeRect(16, height - 40, width - 32, 26);
        [card addSubview:graph];
        detail.frame = NSMakeRect(16, height - 62, width - 32, 18);
    }
    [document addSubview:card];
    self.fields[valueKey] = value;
    self.fields[detailKey] = detail;
    return card;
}

- (NSScrollView *)buildDashboardPage {
    NSScrollView *page = [self newPage];
    FlippedView *document = page.documentView;
    CGFloat y = [self addHeading:@"대시보드" subtitle:@"지금 상태만 보여 줍니다. 값을 바꾸려면 왼쪽에서 기능을 고르세요." y:48 to:document];
    CardView *hero = [[CardView alloc] initWithFrame:NSMakeRect(28, y, 624, 148)];
    self.heroIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(24, 28, 36, 28)];
    self.heroIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
    NSTextField *percent = [self label:@"–%" size:48 weight:NSFontWeightSemibold color:NSColor.labelColor];
    percent.font = [NSFont monospacedDigitSystemFontOfSize:48 weight:NSFontWeightSemibold];
    percent.frame = NSMakeRect(70, 16, 230, 58);
    NSTextField *state = [self label:@"상태 확인 중" size:18 weight:NSFontWeightSemibold color:NSColor.labelColor];
    state.alignment = NSTextAlignmentRight;
    state.frame = NSMakeRect(280, 22, 320, 26);
    NSTextField *time = [self label:@"" size:13 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    time.alignment = NSTextAlignmentRight;
    time.frame = NSMakeRect(280, 50, 320, 20);
    self.dashMeter = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(24, 108, 576, 12)];
    self.dashMeter.indeterminate = NO;
    self.dashMeter.minValue = 0;
    self.dashMeter.maxValue = 100;
    self.dashMeter.style = NSProgressIndicatorStyleBar;
    for (NSView *view in @[self.heroIcon, percent, state, time, self.dashMeter]) [hero addSubview:view];
    [document addSubview:hero];
    self.fields[@"dash.percent"] = percent;
    self.fields[@"dash.state"] = state;
    self.fields[@"dash.time"] = time;
    y += 160;

    CGFloat cardW = 306;
    CGFloat gap = 12;
    CGFloat left = 28;
    CGFloat right = left + cardW + gap;
    CGFloat rowH = 112;
    CGFloat graphH = 136;
    [self placeCardIn:document x:left y:y width:cardW height:rowH caption:@"충전 한도" symbol:@"battery.100percent" valueKey:@"dash.limit.value" detailKey:@"dash.limit.detail" graph:nil];
    [self placeCardIn:document x:right y:y width:cardW height:rowH caption:@"범위 유지" symbol:@"arrow.left.and.right" valueKey:@"dash.sail.value" detailKey:@"dash.sail.detail" graph:nil];
    y += rowH + gap;
    [self placeCardIn:document x:left y:y width:cardW height:rowH caption:@"완충 · 보정" symbol:@"bolt.fill" valueKey:@"dash.mode.value" detailKey:@"dash.mode.detail" graph:nil];
    [self placeCardIn:document x:right y:y width:cardW height:rowH caption:@"성능" symbol:@"heart" valueKey:@"dash.health.value" detailKey:@"dash.health.detail" graph:nil];
    y += rowH + gap;
    [self placeCardIn:document x:left y:y width:cardW height:graphH caption:@"전력" symbol:@"bolt" valueKey:@"dash.power.value" detailKey:@"dash.power.detail" graph:nil];
    self.dashCPUGraph = [[LineGraphView alloc] initWithFrame:NSZeroRect];
    [self placeCardIn:document x:right y:y width:cardW height:graphH caption:@"CPU" symbol:@"cpu" valueKey:@"dash.cpu.value" detailKey:@"dash.cpu.detail" graph:self.dashCPUGraph];
    y += graphH + gap;
    self.dashMemoryGraph = [[LineGraphView alloc] initWithFrame:NSZeroRect];
    [self placeCardIn:document x:left y:y width:cardW height:graphH caption:@"메모리" symbol:@"memorychip" valueKey:@"dash.memory.value" detailKey:@"dash.memory.detail" graph:self.dashMemoryGraph];
    self.dashStorageGraph = [[BarGraphView alloc] initWithFrame:NSZeroRect];
    [self placeCardIn:document x:right y:y width:cardW height:graphH caption:@"저장공간" symbol:@"internaldrive" valueKey:@"dash.storage.value" detailKey:@"dash.storage.detail" graph:self.dashStorageGraph];
    y += graphH + gap;
    [self placeCardIn:document x:left y:y width:cardW height:rowH caption:@"네트워크" symbol:@"wifi" valueKey:@"dash.network.value" detailKey:@"dash.network.detail" graph:nil];
    [self placeCardIn:document x:right y:y width:cardW height:rowH caption:@"러너" symbol:@"figure.run" valueKey:@"dash.runner.value" detailKey:@"dash.runner.detail" graph:nil];
    y += rowH + 8;
    [self finishPage:page y:y];
    return page;
}

- (NSTextField *)noteIn:(NSView *)parent x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width {
    NSTextField *note = [self label:@"" size:12 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    note.frame = NSMakeRect(x, y, width, 34);
    note.maximumNumberOfLines = 2;
    note.cell.wraps = YES;
    note.cell.scrollable = NO;
    [parent addSubview:note];
    [self.noteFields addObject:note];
    return note;
}

- (NSScrollView *)buildChargePage {
    NSScrollView *page = [self newPage];
    FlippedView *document = page.documentView;
    CGFloat y = [self addHeading:@"충전 한도" subtitle:@"전원에 연결하면 고른 퍼센트에서 충전을 멈춥니다. 지금 잔량보다 낮추면 그 값까지 쓴 뒤 유지합니다." y:48 to:document];
    CardView *card = [[CardView alloc] initWithFrame:NSMakeRect(28, y, 624, 128)];
    self.limitValues = @[@80, @85, @90, @95, @100];
    self.limitControl = [NSSegmentedControl segmentedControlWithLabels:@[@"80%", @"85%", @"90%", @"95%", @"100%"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(limitChanged:)];
    self.limitControl.segmentStyle = NSSegmentStyleRounded;
    self.limitControl.frame = NSMakeRect(16, 20, 592, 32);
    [self guard:self.limitControl];
    [card addSubview:self.limitControl];
    [self noteIn:card x:16 y:68 width:592];
    [document addSubview:card];
    [self finishPage:page y:y + 148];
    return page;
}

- (NSScrollView *)buildTopUpPage {
    NSScrollView *page = [self newPage];
    FlippedView *document = page.documentView;
    CGFloat y = [self addHeading:@"한 번만 완충" subtitle:@"이번 한 번만 100%까지 충전하고, 도달하면 이전 충전 한도로 돌아갑니다." y:48 to:document];
    CardView *card = [[CardView alloc] initWithFrame:NSMakeRect(28, y, 624, 120)];
    self.topUpButton = [NSButton buttonWithTitle:@"한 번만 완충" target:self action:@selector(startTopUp:)];
    self.topUpButton.bezelStyle = NSBezelStyleRounded;
    self.topUpButton.frame = NSMakeRect(16, 20, 200, 32);
    [card addSubview:self.topUpButton];
    [self noteIn:card x:16 y:66 width:592];
    [document addSubview:card];
    [self finishPage:page y:y + 140];
    return page;
}

- (NSScrollView *)buildSailPage {
    NSScrollView *page = [self newPage];
    FlippedView *document = page.documentView;
    CGFloat y = [self addHeading:@"범위 유지" subtitle:@"전원에 연결된 동안 하한까지 배터리로 쓴 다음, 다시 상한까지 충전합니다." y:48 to:document];
    CardView *card = [[CardView alloc] initWithFrame:NSMakeRect(28, y, 624, 150)];
    self.sailCheckbox = [NSButton checkboxWithTitle:@"범위 유지 사용" target:self action:@selector(sailToggled:)];
    self.sailCheckbox.frame = NSMakeRect(16, 18, 220, 24);
    [self guard:self.sailCheckbox];
    NSTextField *lowerLabel = [self label:@"하한" size:12 weight:NSFontWeightMedium color:NSColor.secondaryLabelColor];
    lowerLabel.frame = NSMakeRect(16, 56, 40, 18);
    self.lowerPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(58, 52, 110, 28) pullsDown:NO];
    [self.lowerPopup addItemsWithTitles:@[@"80%", @"85%", @"90%"]];
    self.lowerPopup.target = self;
    self.lowerPopup.action = @selector(sailBoundsChanged:);
    [self guard:self.lowerPopup];
    NSTextField *upperLabel = [self label:@"상한" size:12 weight:NSFontWeightMedium color:NSColor.secondaryLabelColor];
    upperLabel.frame = NSMakeRect(186, 56, 40, 18);
    self.upperPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(228, 52, 110, 28) pullsDown:NO];
    [self.upperPopup addItemsWithTitles:@[@"85%", @"90%", @"95%", @"100%"]];
    self.upperPopup.target = self;
    self.upperPopup.action = @selector(sailBoundsChanged:);
    [self guard:self.upperPopup];
    for (NSView *view in @[self.sailCheckbox, lowerLabel, self.lowerPopup, upperLabel, self.upperPopup]) [card addSubview:view];
    [self noteIn:card x:16 y:98 width:592];
    [document addSubview:card];
    [self finishPage:page y:y + 170];
    return page;
}

- (NSScrollView *)buildCalibrationPage {
    NSScrollView *page = [self newPage];
    FlippedView *document = page.documentView;
    CGFloat y = [self addHeading:@"보정" subtitle:@"보정을 시작하면 직접 끝낼 때까지 충전 한도를 100%로 유지합니다." y:48 to:document];
    CardView *card = [[CardView alloc] initWithFrame:NSMakeRect(28, y, 624, 120)];
    self.calibrationButton = [NSButton buttonWithTitle:@"보정 시작" target:self action:@selector(startCalibration:)];
    self.calibrationButton.bezelStyle = NSBezelStyleRounded;
    self.calibrationButton.frame = NSMakeRect(16, 20, 200, 32);
    [card addSubview:self.calibrationButton];
    [self noteIn:card x:16 y:66 width:592];
    [document addSubview:card];
    [self finishPage:page y:y + 140];
    return page;
}

- (NSScrollView *)buildRunnerPage {
    NSScrollView *page = [self newPage];
    FlippedView *document = page.documentView;
    CGFloat y = [self addHeading:@"러너" subtitle:@"CPU가 바빠지면 메뉴 막대 캐릭터가 더 빨리 달립니다. 좌우 반전은 메뉴 막대와 미리보기에만 적용됩니다." y:48 to:document];
    CardView *card = [[CardView alloc] initWithFrame:NSMakeRect(28, y, 624, 214)];
    self.previewView = [[NSImageView alloc] initWithFrame:NSMakeRect(20, 20, 72, 72)];
    self.previewView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.previewView.image = self.runnerFrames.firstObject;
    self.speedLabel = [self label:@"지금 속도  1.0×" size:16 weight:NSFontWeightSemibold color:NSColor.labelColor];
    self.speedLabel.frame = NSMakeRect(112, 24, 360, 24);
    NSButton *slow = [NSButton checkboxWithTitle:@"바쁠 때 천천히 달리기" target:self action:@selector(metricFlagChanged:)];
    slow.identifier = @"slowWhenBusy";
    slow.frame = NSMakeRect(112, 56, 280, 24);
    [self guard:slow];
    self.metricChecks[@"slowWhenBusy"] = slow;
    NSButton *flip = [NSButton checkboxWithTitle:@"좌우 반전" target:self action:@selector(metricFlagChanged:)];
    flip.identifier = @"flipRunner";
    flip.frame = NSMakeRect(112, 84, 280, 24);
    [self guard:flip];
    self.metricChecks[@"flipRunner"] = flip;
    NSTextField *modeLabel = [self label:@"표시 방식" size:13 weight:NSFontWeightSemibold color:NSColor.labelColor];
    modeLabel.frame = NSMakeRect(16, 128, 120, 20);
    self.renderModeControl = [NSSegmentedControl segmentedControlWithLabels:@[@"흑백", @"색상"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(renderModeChanged:)];
    self.renderModeControl.frame = NSMakeRect(400, 122, 208, 28);
    [self guard:self.renderModeControl];
    NSTextField *hint = [self label:@"흑백은 메뉴 막대 색을 따르고, 색상은 그림 색을 그대로 둡니다. 넣은 이미지에서만 바꿀 수 있습니다." size:12 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    hint.frame = NSMakeRect(16, 164, 592, 36);
    hint.maximumNumberOfLines = 2;
    hint.cell.wraps = YES;
    hint.cell.scrollable = NO;
    for (NSView *view in @[self.previewView, self.speedLabel, slow, flip, modeLabel, self.renderModeControl, hint]) [card addSubview:view];
    [document addSubview:card];
    y += 226;
    self.runnerPage = page;
    self.runnerGalleryTop = y;
    [self reloadRunnerGallery];
    return page;
}

- (void)reloadRunnerGallery {
    if (!self.runnerPage) return;
    FlippedView *document = self.runnerPage.documentView;
    for (NSButton *button in self.runnerChoices.allValues) [self.guardedControls removeObject:button];
    for (NSView *view in document.subviews.copy) {
        if ([view.identifier isEqualToString:@"runnerGallery"]) [view removeFromSuperview];
    }
    NSArray<NSDictionary *> *available = [allRunnerSpecs() filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *spec, NSDictionary *bindings) {
        (void)bindings;
        return self.runnerSets[spec[@"id"]].count > 0;
    }]];
    NSInteger count = (NSInteger)available.count;
    NSInteger columns = count > 3 ? 4 : MAX(count, 1);
    NSInteger rows = count == 0 ? 0 : (count + columns - 1) / columns;
    CGFloat gap = 12;
    CGFloat buttonsHeight = rows == 0 ? 0 : rows * 116 + (rows - 1) * gap;
    CGFloat cardHeight = 44 + buttonsHeight + 52;
    RunnerDropView *gallery = [[RunnerDropView alloc] initWithFrame:NSMakeRect(28, self.runnerGalleryTop, 624, cardHeight)];
    gallery.identifier = @"runnerGallery";
    __weak BatteryApp *weakSelf = self;
    gallery.onDrop = ^(NSArray<NSURL *> *urls) {
        [weakSelf importRunnerURLs:urls];
    };
    NSTextField *galleryTitle = [self label:@"이미지" size:13 weight:NSFontWeightSemibold color:NSColor.labelColor];
    galleryTitle.frame = NSMakeRect(16, 14, 180, 18);
    self.importRunnerButton = [NSButton buttonWithTitle:@"이미지 넣기" target:self action:@selector(importRunner:)];
    self.importRunnerButton.bezelStyle = NSBezelStyleRounded;
    self.importRunnerButton.frame = NSMakeRect(480, 10, 128, 28);
    self.importRunnerButton.enabled = !self.runnerImporting;
    self.removeRunnerButton = [NSButton buttonWithTitle:@"빼기" target:self action:@selector(removeRunner:)];
    self.removeRunnerButton.bezelStyle = NSBezelStyleRounded;
    self.removeRunnerButton.frame = NSMakeRect(400, 10, 72, 28);
    self.removeRunnerButton.enabled = [selectedRunnerID() hasPrefix:@"c-"];
    [gallery addSubview:galleryTitle];
    [gallery addSubview:self.removeRunnerButton];
    [gallery addSubview:self.importRunnerButton];

    self.runnerChoices = [NSMutableDictionary dictionary];
    CGFloat buttonWidth = (592 - gap * (columns - 1)) / columns;
    for (NSInteger index = 0; index < count; index++) {
        NSDictionary *spec = available[index];
        NSImage *thumb = [self.runnerSets[spec[@"id"]].firstObject copy];
        CGFloat buttonX = 16 + (index % columns) * (buttonWidth + gap);
        CGFloat buttonY = 44 + (index / columns) * (116 + gap);
        RunnerOptionButton *button = [[RunnerOptionButton alloc] initWithFrame:NSMakeRect(buttonX, buttonY, buttonWidth, 116)];
        button.title = spec[@"title"];
        button.image = thumb;
        button.accessibilityLabel = spec[@"title"];
        button.identifier = spec[@"id"];
        button.target = self;
        button.action = @selector(runnerChoiceChanged:);
        [self guard:button];
        self.runnerChoices[spec[@"id"]] = button;
        [gallery addSubview:button];
    }
    NSTextField *galleryHint = [self label:@"GIF를 넣으면 프레임은 그대로 두고 가장자리 배경만 지웁니다. 표정이 빠르게 깜빡이면 천천히 넘깁니다." size:12 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    galleryHint.frame = NSMakeRect(16, 44 + buttonsHeight + 8, 592, 32);
    galleryHint.maximumNumberOfLines = 2;
    galleryHint.cell.wraps = YES;
    galleryHint.cell.scrollable = NO;
    [gallery addSubview:galleryHint];
    [document addSubview:gallery];
    [self finishPage:self.runnerPage y:self.runnerGalleryTop + cardHeight + 12];
}

- (NSButton *)metricCheck:(NSString *)title key:(NSString *)key frame:(NSRect)frame in:(NSView *)parent {
    NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(metricFlagChanged:)];
    box.identifier = key;
    box.frame = frame;
    [self guard:box];
    self.metricChecks[key] = box;
    [parent addSubview:box];
    return box;
}

- (void)renderModeChanged:(NSSegmentedControl *)sender {
    if (self.suppressLimitChange || !userInitiatedChange()) return;
    NSString *runnerID = selectedRunnerID();
    if (![runnerID hasPrefix:@"c-"]) return;
    NSURL *metaURL = [[runnersDirectory() URLByAppendingPathComponent:runnerID] URLByAppendingPathComponent:@"meta.json"];
    NSData *data = [NSData dataWithContentsOfURL:metaURL];
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    if (![parsed isKindOfClass:[NSMutableDictionary class]]) return;
    parsed[@"template"] = @(sender.selectedSegment == 0);
    NSData *output = [NSJSONSerialization dataWithJSONObject:parsed options:NSJSONWritingPrettyPrinted error:nil];
    if (![output writeToURL:metaURL atomically:YES]) return;
    [self loadRunner];
    [self applyStatusImage];
    self.previewView.image = self.runnerFrames.firstObject;
    [self reloadRunnerGallery];
    [self updateSettingsWindow];
}

- (NSDictionary *)customSourceWithID:(NSString *)ident {
    for (NSDictionary *source in customMetricSources()) {
        if ([source[@"id"] isEqualToString:ident]) return source;
    }
    return nil;
}

- (void)stopWatchingCustomSource:(NSString *)ident {
    dispatch_source_t watcher = self.customWatchers[ident];
    if (!watcher) return;
    [self.customWatchers removeObjectForKey:ident];
    dispatch_source_cancel(watcher);
}

- (void)noteCustomMetricsChanged {
    NSString *signature = [self customMetricsStructureSignature];
    if (![signature isEqualToString:self.customMetricsSignature]) {
        self.customMetricsSignature = signature;
        self.builtPopoverSignature = nil;
        [self reloadCustomMetricsSection];
        if (self.metricsSettingsPopover.isShown) [self rebuildMetricsSettingsPopover];
    }
    [self updateMetricsItem];
    [self updatePopover];
    [self updateSettingsWindow];
}

- (BOOL)rereadCustomSource:(NSString *)ident {
    NSDictionary *source = [self customSourceWithID:ident];
    if (!source) return NO;
    NSString *path = source[@"path"];
    NSError *error = nil;
    NSDictionary *attrs = path.length ? [NSFileManager.defaultManager attributesOfItemAtPath:path error:&error] : nil;
    unsigned long long size = [attrs fileSize];
    NSData *data = (!error && size > 0 && size <= 1024 * 1024) ? [NSData dataWithContentsOfFile:path options:0 error:&error] : nil;
    NSString *parseError = nil;
    NSDictionary *snapshot = data ? customMetricsSnapshot(data, &parseError) : nil;
    (void)parseError;
    BOOL failed = snapshot == nil;
    BOOL wasFailed = [self.customFailed containsObject:ident];
    NSDictionary *previous = self.customSnapshots[ident];
    if (snapshot) {
        self.customSnapshots[ident] = snapshot;
        [self.customFailed removeObject:ident];
    } else {
        [self.customFailed addObject:ident];
    }
    BOOL changed = failed != wasFailed || (snapshot && ![snapshot isEqual:previous]);
    if (changed) [self noteCustomMetricsChanged];
    return changed;
}

- (void)watchCustomSource:(NSDictionary *)source {
    NSString *ident = source[@"id"];
    NSString *path = source[@"path"];
    if (ident.length == 0 || path.length == 0 || self.customWatchers[ident]) return;
    int fd = open(path.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) return;
    dispatch_source_t watcher = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd, DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE, dispatch_get_main_queue());
    if (!watcher) {
        close(fd);
        return;
    }
    __weak BatteryApp *weakSelf = self;
    dispatch_source_set_event_handler(watcher, ^{
        BatteryApp *strongSelf = weakSelf;
        if (!strongSelf) return;
        unsigned long flags = dispatch_source_get_data(watcher);
        if (flags & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE)) {
            [strongSelf stopWatchingCustomSource:ident];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                BatteryApp *later = weakSelf;
                if (!later) return;
                [later rereadCustomSource:ident];
                NSDictionary *fresh = [later customSourceWithID:ident];
                if (fresh) [later watchCustomSource:fresh];
            });
            return;
        }
        [strongSelf rereadCustomSource:ident];
    });
    dispatch_source_set_cancel_handler(watcher, ^{ close(fd); });
    dispatch_resume(watcher);
    self.customWatchers[ident] = watcher;
}

- (void)startCustomMetrics {
    for (NSDictionary *source in customMetricSources()) {
        [self rereadCustomSource:source[@"id"]];
        [self watchCustomSource:source];
    }
}

- (void)refreshCustomMetrics {
    NSMutableSet *live = [NSMutableSet set];
    for (NSDictionary *source in customMetricSources()) {
        NSString *ident = source[@"id"];
        if (ident.length == 0) continue;
        [live addObject:ident];
        [self rereadCustomSource:ident];
        if (!self.customWatchers[ident]) [self watchCustomSource:source];
    }
    for (NSString *ident in self.customWatchers.allKeys) {
        if (![live containsObject:ident]) [self stopWatchingCustomSource:ident];
    }
}

- (NSString *)customMetricsStructureSignature {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *source in customMetricSources()) {
        NSString *ident = source[@"id"] ?: @"";
        NSDictionary *snap = self.customSnapshots[ident];
        NSArray *metrics = [snap[@"metrics"] isKindOfClass:[NSArray class]] ? snap[@"metrics"] : @[];
        NSMutableString *shape = [NSMutableString string];
        for (NSDictionary *metric in metrics) [shape appendString:metric[@"normalizedValue"] ? @"b" : @"t"];
        [parts addObject:[NSString stringWithFormat:@"%@:%@:%@:%d:%d:%@", ident, snap[@"title"] ?: @"", snap[@"symbol"] ?: @"", [self.customFailed containsObject:ident], [source[@"showInBar"] boolValue], shape]];
    }
    return [parts componentsJoinedByString:@"|"];
}

- (void)saveCustomSources:(NSArray *)sources {
    [NSUserDefaults.standardUserDefaults setObject:sources forKey:@"customMetricsSources"];
}

- (void)toggleMetricsSettings:(id)sender {
    NSView *anchor = [sender isKindOfClass:[NSView class]] ? sender : self.metricsItem.button;
    if (self.metricsSettingsPopover.isShown) {
        [self.metricsSettingsPopover performClose:nil];
        return;
    }
    if (self.popover.isShown) [self.popover performClose:nil];
    if (!self.metricsSettingsPopover) {
        self.metricsSettingsPopover = [[NSPopover alloc] init];
        self.metricsSettingsPopover.behavior = NSPopoverBehaviorTransient;
        self.metricsSettingsPopover.animates = YES;
    }
    [self rebuildMetricsSettingsPopover];
    [self.metricsSettingsPopover showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSRectEdgeMinY];
}

- (void)rebuildMetricsSettingsPopover {
    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, 320, 40)];
    self.metricsPopoverChecks = [NSMutableDictionary dictionary];
    NSTextField *title = [self label:@"지표 막대" size:13 weight:NSFontWeightSemibold color:NSColor.labelColor];
    title.frame = NSMakeRect(16, 12, 280, 18);
    [root addSubview:title];
    CGFloat y = 40;
    NSArray *rows = @[
        @[@"barCPU", @"CPU 사용량"],
        @[@"barMemory", @"메모리"],
        @[@"barStorage", @"저장공간"],
        @[@"barBattery", @"배터리"],
        @[@"barNetwork", @"네트워크"]
    ];
    for (NSArray *row in rows) {
        NSButton *box = [NSButton checkboxWithTitle:row[1] target:self action:@selector(metricFlagChanged:)];
        box.identifier = row[0];
        box.frame = NSMakeRect(16, y, 288, 22);
        box.state = pref(row[0]) ? NSControlStateValueOn : NSControlStateValueOff;
        [root addSubview:box];
        self.metricsPopoverChecks[row[0]] = box;
        y += 26;
    }
    NSArray *sources = customMetricSources();
    if (sources.count) {
        y += 6;
        NSTextField *customTitle = [self label:@"사용자 지표" size:12 weight:NSFontWeightSemibold color:NSColor.secondaryLabelColor];
        customTitle.frame = NSMakeRect(16, y, 288, 16);
        [root addSubview:customTitle];
        y += 22;
        for (NSDictionary *source in sources) {
            NSString *ident = source[@"id"] ?: @"";
            NSString *name = self.customSnapshots[ident][@"title"] ?: [source[@"path"] lastPathComponent] ?: @"사용자 지표";
            NSButton *box = [NSButton checkboxWithTitle:name target:self action:@selector(customBarToggled:)];
            box.identifier = ident;
            box.frame = NSMakeRect(16, y, 288, 22);
            box.state = [source[@"showInBar"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
            [root addSubview:box];
            self.metricsPopoverChecks[ident] = box;
            y += 26;
        }
    }
    root.frame = NSMakeRect(0, 0, 320, y + 12);
    NSViewController *controller = [[NSViewController alloc] initWithNibName:nil bundle:nil];
    controller.view = root;
    self.metricsSettingsPopover.contentViewController = controller;
    self.metricsSettingsPopover.contentSize = root.frame.size;
}

- (void)customBarToggled:(NSButton *)sender {
    if (self.suppressLimitChange || !userInitiatedChange()) return;
    NSString *ident = sender.identifier;
    if (ident.length == 0) return;
    NSMutableArray *sources = [NSMutableArray array];
    for (NSDictionary *source in customMetricSources()) {
        NSMutableDictionary *item = [source mutableCopy];
        if ([item[@"id"] isEqualToString:ident]) item[@"showInBar"] = @(sender.state == NSControlStateValueOn);
        [sources addObject:item];
    }
    [self saveCustomSources:sources];
    self.customMetricsSignature = nil;
    [self noteCustomMetricsChanged];
    [self updateSettingsWindow];
}

- (void)reloadCustomMetricsSection {
    if (!self.metricsPage) return;
    FlippedView *document = self.metricsPage.documentView;
    for (NSView *view in document.subviews.copy) {
        if ([view.identifier isEqualToString:@"customMetrics"]) [view removeFromSuperview];
    }
    self.customBarChecks = [NSMutableDictionary dictionary];
    self.customStatusLabels = [NSMutableDictionary dictionary];
    NSArray *sources = customMetricSources();
    CGFloat rowHeight = 72;
    CGFloat cardHeight = 96 + sources.count * rowHeight + (sources.count ? 8 : 0);
    CardView *card = [[CardView alloc] initWithFrame:NSMakeRect(28, self.customMetricsTop, 624, cardHeight)];
    card.identifier = @"customMetrics";
    NSTextField *heading = [self label:@"사용자 지표" size:13 weight:NSFontWeightSemibold color:NSColor.labelColor];
    heading.frame = NSMakeRect(16, 14, 280, 18);
    NSButton *add = [NSButton buttonWithTitle:@"소스 추가" target:self action:@selector(addCustomMetric:)];
    add.bezelStyle = NSBezelStyleRounded;
    add.frame = NSMakeRect(360, 8, 110, 28);
    NSButton *help = [NSButton buttonWithTitle:@"형식" target:self action:@selector(openCustomMetricHelp:)];
    help.bezelStyle = NSBezelStyleRounded;
    help.frame = NSMakeRect(478, 8, 130, 28);
    [card addSubview:heading];
    [card addSubview:add];
    [card addSubview:help];
    CGFloat y = 48;
    for (NSDictionary *source in sources) {
        NSString *ident = source[@"id"] ?: @"";
        NSDictionary *snap = self.customSnapshots[ident];
        BOOL failed = [self.customFailed containsObject:ident];
        NSString *name = snap[@"title"] ?: [source[@"path"] lastPathComponent] ?: @"사용자 지표";
        NSTextField *title = [self label:name size:13 weight:NSFontWeightSemibold color:NSColor.labelColor];
        title.frame = NSMakeRect(16, y, 360, 18);
        NSTextField *path = [self label:source[@"path"] ?: @"" size:11 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
        path.lineBreakMode = NSLineBreakByTruncatingMiddle;
        path.frame = NSMakeRect(16, y + 20, 360, 16);
        NSTextField *status = [self label:relativeUpdateText(snap[@"updated"], failed) size:11 weight:NSFontWeightRegular color:failed ? NSColor.systemRedColor : NSColor.secondaryLabelColor];
        status.frame = NSMakeRect(16, y + 38, 250, 16);
        self.customStatusLabels[ident] = status;
        NSButton *bar = [NSButton checkboxWithTitle:@"지표 막대" target:self action:@selector(customBarToggled:)];
        bar.identifier = ident;
        bar.frame = NSMakeRect(390, y + 8, 110, 22);
        bar.state = [source[@"showInBar"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        self.customBarChecks[ident] = bar;
        NSButton *remove = [NSButton buttonWithTitle:@"빼기" target:self action:@selector(removeCustomMetric:)];
        remove.identifier = ident;
        remove.bezelStyle = NSBezelStyleRounded;
        remove.frame = NSMakeRect(520, y + 6, 84, 26);
        for (NSView *view in @[title, path, status, bar, remove]) [card addSubview:view];
        y += rowHeight;
    }
    NSTextField *hint = [self label:@"JSON 파일이 바뀌면 메뉴 막대 대시보드 카드가 함께 바뀝니다. 파일 내용은 이 앱이 만들지 않습니다." size:12 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    hint.frame = NSMakeRect(16, cardHeight - 36, 592, 24);
    [card addSubview:hint];
    [document addSubview:card];
    [self finishPage:self.metricsPage y:self.customMetricsTop + cardHeight + 16];
}

- (void)addCustomMetric:(id)sender {
    (void)sender;
    if (self.suppressLimitChange || !userInitiatedChange()) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[UTTypeJSON];
    panel.message = @"지표 JSON 파일을 고르세요. title, metrics, lastUpdatedDate가 있어야 합니다.";
    panel.prompt = @"추가";
    [panel beginSheetModalForWindow:self.settingsWindow completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;
        [self importCustomMetricURL:panel.URL];
    }];
}

- (void)importCustomMetricURL:(NSURL *)url {
    NSString *path = url.path;
    if (path.length == 0) return;
    for (NSDictionary *source in customMetricSources()) {
        if ([source[@"path"] isEqualToString:path]) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"이미 추가한 파일입니다";
            alert.informativeText = path.lastPathComponent;
            if (self.settingsWindow.isVisible) [alert beginSheetModalForWindow:self.settingsWindow completionHandler:nil];
            else [alert runModal];
            return;
        }
    }
    NSData *data = [NSData dataWithContentsOfURL:url];
    NSString *parseError = nil;
    NSDictionary *snapshot = customMetricsSnapshot(data, &parseError);
    if (!snapshot) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"지표를 추가하지 못했습니다";
        alert.informativeText = parseError ?: @"JSON 형식을 확인해 주세요.";
        if (self.settingsWindow.isVisible) [alert beginSheetModalForWindow:self.settingsWindow completionHandler:nil];
        else [alert runModal];
        return;
    }
    NSData *bookmark = [url bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
    NSMutableDictionary *source = [@{
        @"id": NSUUID.UUID.UUIDString,
        @"path": path,
        @"showInBar": @NO,
        @"createdAt": NSDate.date
    } mutableCopy];
    if (bookmark) source[@"bookmark"] = bookmark;
    NSMutableArray *sources = [customMetricSources() mutableCopy];
    [sources addObject:source];
    [self saveCustomSources:sources];
    self.customSnapshots[source[@"id"]] = snapshot;
    [self.customFailed removeObject:source[@"id"]];
    [self watchCustomSource:source];
    self.customMetricsSignature = nil;
    [self noteCustomMetricsChanged];
    [self updateSettingsWindow];
}

- (void)removeCustomMetric:(NSButton *)sender {
    if (self.suppressLimitChange || !userInitiatedChange()) return;
    NSString *ident = sender.identifier;
    NSDictionary *source = [self customSourceWithID:ident];
    if (!source) return;
    NSString *name = self.customSnapshots[ident][@"title"] ?: [source[@"path"] lastPathComponent] ?: @"이 지표";
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"사용자 지표를 뺄까요?";
    alert.informativeText = [NSString stringWithFormat:@"%@ 카드는 대시보드에서 사라집니다. JSON 파일은 지우지 않습니다.", name];
    [alert addButtonWithTitle:@"빼기"];
    [alert addButtonWithTitle:@"취소"];
    [alert beginSheetModalForWindow:self.settingsWindow completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSMutableArray *sources = [NSMutableArray array];
        for (NSDictionary *item in customMetricSources()) {
            if (![item[@"id"] isEqualToString:ident]) [sources addObject:item];
        }
        [self saveCustomSources:sources];
        [self stopWatchingCustomSource:ident];
        [self.customSnapshots removeObjectForKey:ident];
        [self.customFailed removeObject:ident];
        self.customMetricsSignature = nil;
        self.builtPopoverSignature = nil;
        [self noteCustomMetricsChanged];
        [self updateSettingsWindow];
    }];
}

- (void)openCustomMetricHelp:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/runcat-dev/RunCatNeo/blob/main/docs/CustomMetricsSchema.md"]];
}

- (NSScrollView *)buildMetricsPage {
    NSScrollView *page = [self newPage];
    FlippedView *document = page.documentView;
    CGFloat y = [self addHeading:@"시스템 지표" subtitle:@"메뉴 막대를 눌렀을 때 보이는 대시보드와, 숫자만 보여주는 지표 막대를 고릅니다. CPU는 항상 표시됩니다. 지표 막대를 누르면 표시 항목을 고릅니다." y:48 to:document];
    CardView *interval = [[CardView alloc] initWithFrame:NSMakeRect(28, y, 624, 72)];
    NSTextField *intervalLabel = [self label:@"갱신 주기" size:13 weight:NSFontWeightSemibold color:NSColor.labelColor];
    intervalLabel.frame = NSMakeRect(16, 24, 120, 20);
    self.intervalPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(460, 20, 148, 28) pullsDown:NO];
    [self.intervalPopup addItemWithTitle:@"3초"];
    self.intervalPopup.lastItem.tag = 3;
    [self.intervalPopup addItemWithTitle:@"5초"];
    self.intervalPopup.lastItem.tag = 5;
    [self.intervalPopup addItemWithTitle:@"10초"];
    self.intervalPopup.lastItem.tag = 10;
    self.intervalPopup.target = self;
    self.intervalPopup.action = @selector(intervalChanged:);
    [self guard:self.intervalPopup];
    [interval addSubview:intervalLabel];
    [interval addSubview:self.intervalPopup];
    [document addSubview:interval];
    y += 84;

    CardView *dashboard = [[CardView alloc] initWithFrame:NSMakeRect(28, y, 624, 148)];
    NSTextField *dashTitle = [self label:@"대시보드에 표시" size:13 weight:NSFontWeightSemibold color:NSColor.labelColor];
    dashTitle.frame = NSMakeRect(16, 14, 240, 18);
    [dashboard addSubview:dashTitle];
    [self metricCheck:@"메모리" key:@"showMemory" frame:NSMakeRect(16, 42, 250, 22) in:dashboard];
    [self metricCheck:@"저장공간" key:@"showStorage" frame:NSMakeRect(280, 42, 250, 22) in:dashboard];
    [self metricCheck:@"배터리" key:@"showBattery" frame:NSMakeRect(16, 74, 250, 22) in:dashboard];
    [self metricCheck:@"네트워크" key:@"showNetwork" frame:NSMakeRect(280, 74, 250, 22) in:dashboard];
    [document addSubview:dashboard];
    y += 160;

    CardView *bar = [[CardView alloc] initWithFrame:NSMakeRect(28, y, 624, 176)];
    [self metricCheck:@"메뉴 막대에 지표 막대 보이기" key:@"showMetricsBar" frame:NSMakeRect(16, 16, 360, 22) in:bar];
    [self metricCheck:@"CPU" key:@"barCPU" frame:NSMakeRect(16, 52, 160, 22) in:bar];
    [self metricCheck:@"메모리" key:@"barMemory" frame:NSMakeRect(180, 52, 160, 22) in:bar];
    [self metricCheck:@"저장공간" key:@"barStorage" frame:NSMakeRect(360, 52, 180, 22) in:bar];
    [self metricCheck:@"배터리" key:@"barBattery" frame:NSMakeRect(16, 84, 160, 22) in:bar];
    [self metricCheck:@"네트워크" key:@"barNetwork" frame:NSMakeRect(180, 84, 180, 22) in:bar];
    NSTextField *barHint = [self label:@"지표 막대는 러너 왼쪽에 붙습니다. 항목을 모두 끄면 막대는 숨겨집니다." size:12 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    barHint.frame = NSMakeRect(16, 122, 580, 32);
    barHint.maximumNumberOfLines = 2;
    barHint.cell.wraps = YES;
    barHint.cell.scrollable = NO;
    [bar addSubview:barHint];
    [document addSubview:bar];
    y += 188;
    self.metricsPage = page;
    self.customMetricsTop = y;
    [self reloadCustomMetricsSection];
    return page;
}

- (NSScrollView *)buildShortcutPage {
    NSScrollView *page = [self newPage];
    FlippedView *document = page.documentView;
    CGFloat y = [self addHeading:@"단축키" subtitle:@"설정 단축키는 원하는 키로 바꿀 수 있습니다. 충전 한도 단축키는 고정이며, 어느 화면에서나 동작합니다." y:48 to:document];
    CardView *card = [[CardView alloc] initWithFrame:NSMakeRect(28, y, 624, 250)];
    NSTextField *openLabel = [self label:@"설정 열기" size:13 weight:NSFontWeightSemibold color:NSColor.labelColor];
    openLabel.frame = NSMakeRect(16, 18, 160, 20);
    self.shortcutButton = [NSButton buttonWithTitle:shortcutLabel(settingsKeyCode(), settingsMods()) target:self action:@selector(beginShortcutRecording:)];
    self.shortcutButton.bezelStyle = NSBezelStyleRounded;
    self.shortcutButton.frame = NSMakeRect(420, 14, 188, 30);
    NSTextField *limitHeading = [self label:@"충전 한도" size:13 weight:NSFontWeightSemibold color:NSColor.labelColor];
    limitHeading.frame = NSMakeRect(16, 62, 200, 20);
    NSArray *limits = @[@"⌃⌥1    80%", @"⌃⌥2    85%", @"⌃⌥3    90%", @"⌃⌥4    95%", @"⌃⌥5    100%"];
    for (NSUInteger index = 0; index < limits.count; index++) {
        NSTextField *row = [self label:limits[index] size:13 weight:NSFontWeightRegular color:NSColor.labelColor];
        row.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
        row.frame = NSMakeRect(16, 92 + (CGFloat)index * 24, 240, 20);
        [card addSubview:row];
    }
    [card addSubview:openLabel];
    [card addSubview:self.shortcutButton];
    [card addSubview:limitHeading];
    [document addSubview:card];
    [self finishPage:page y:y + 270];
    return page;
}

- (NSScrollView *)buildGeneralPage {
    NSScrollView *page = [self newPage];
    FlippedView *document = page.documentView;
    CGFloat y = [self addHeading:@"일반" subtitle:@"로그인할 때 메뉴 막대에 이 앱을 띄웁니다." y:48 to:document];
    CardView *card = [[CardView alloc] initWithFrame:NSMakeRect(28, y, 624, 72)];
    self.loginCheckbox = [NSButton checkboxWithTitle:@"로그인할 때 열기" target:self action:@selector(loginCheckboxChanged:)];
    self.loginCheckbox.frame = NSMakeRect(16, 24, 280, 24);
    [self guard:self.loginCheckbox];
    [card addSubview:self.loginCheckbox];
    [document addSubview:card];
    [self finishPage:page y:y + 92];
    return page;
}

- (void)buildSettingsWindow {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 960, 760)
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
    window.title = @"맥북 배터리 제어";
    window.delegate = self;
    window.titlebarAppearsTransparent = YES;
    window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
    window.toolbarStyle = NSWindowToolbarStyleUnified;
    window.releasedWhenClosed = NO;
    window.contentMinSize = NSMakeSize(860, 560);
    [window center];

    self.sidebar = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 210, 640)];
    self.sidebar.headerView = nil;
    self.sidebar.rowHeight = 28;
    self.sidebar.backgroundColor = NSColor.clearColor;
    self.sidebar.style = NSTableViewStyleSourceList;
    self.sidebar.floatsGroupRows = YES;
    self.sidebar.allowsEmptySelection = NO;
    self.sidebar.allowsMultipleSelection = NO;
    self.sidebar.focusRingType = NSFocusRingTypeNone;
    self.sidebar.intercellSpacing = NSMakeSize(0, 0);
    self.sidebar.dataSource = self;
    self.sidebar.delegate = self;
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    column.width = 210;
    column.resizingMask = NSTableColumnAutoresizingMask;
    [self.sidebar addTableColumn:column];
    NSScrollView *sideScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 210, 640)];
    sideScroll.documentView = self.sidebar;
    sideScroll.hasVerticalScroller = YES;
    sideScroll.autohidesScrollers = YES;
    sideScroll.drawsBackground = NO;
    sideScroll.borderType = NSNoBorder;

    self.settingsContent = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 700, 640)];
    NSViewController *sideController = [[NSViewController alloc] initWithNibName:nil bundle:nil];
    sideController.view = sideScroll;
    NSViewController *contentController = [[NSViewController alloc] initWithNibName:nil bundle:nil];
    contentController.view = self.settingsContent;
    NSSplitViewController *split = [[NSSplitViewController alloc] init];
    NSSplitViewItem *sideItem = [NSSplitViewItem sidebarWithViewController:sideController];
    sideItem.minimumThickness = 196;
    sideItem.maximumThickness = 240;
    sideItem.canCollapse = NO;
    NSSplitViewItem *contentItem = [NSSplitViewItem splitViewItemWithViewController:contentController];
    [split addSplitViewItem:sideItem];
    [split addSplitViewItem:contentItem];
    window.contentViewController = split;
    [window setContentSize:NSMakeSize(960, 740)];
    [window center];

    self.pages = @[
        [self buildDashboardPage],
        [self buildChargePage],
        [self buildTopUpPage],
        [self buildSailPage],
        [self buildCalibrationPage],
        [self buildRunnerPage],
        [self buildMetricsPage],
        [self buildShortcutPage],
        [self buildGeneralPage]
    ];
    self.settingsWindow = window;
    [self applyPageInsets];
    [self.sidebar reloadData];
    [self.sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
}

- (void)applyPageInsets {
    NSView *content = self.settingsWindow.contentView;
    CGFloat inset = 0;
    if (content && self.settingsWindow.titlebarAppearsTransparent) {
        NSRect layout = [content convertRect:self.settingsWindow.contentLayoutRect fromView:nil];
        inset = NSMaxY(content.bounds) - NSMaxY(layout);
        if (inset < 0 || inset > 80) inset = 0;
    }
    for (NSScrollView *page in self.pages) {
        page.automaticallyAdjustsContentInsets = NO;
        page.contentInsets = NSEdgeInsetsMake(inset, 0, 8, 0);
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)sidebarRows().count;
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row {
    (void)tableView;
    return sidebarRows()[row][@"group"] != nil;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    (void)tableView;
    return sidebarRows()[row][@"group"] == nil;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    (void)tableView;
    return sidebarRows()[row][@"group"] ? 22 : 28;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    (void)tableColumn;
    NSDictionary *model = sidebarRows()[row];
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"side" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 200, 28)];
        cell.identifier = @"side";
        NSImageView *imageView = [[NSImageView alloc] initWithFrame:NSMakeRect(8, 5, 18, 18)];
        imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
        NSTextField *textField = [[NSTextField alloc] initWithFrame:NSMakeRect(32, 4, 160, 18)];
        textField.editable = NO;
        textField.bezeled = NO;
        textField.drawsBackground = NO;
        textField.font = [NSFont systemFontOfSize:13];
        textField.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.imageView = imageView;
        cell.textField = textField;
        [cell addSubview:imageView];
        [cell addSubview:textField];
    }
    BOOL group = model[@"group"] != nil;
    cell.textField.stringValue = group ? model[@"group"] : model[@"title"];
    if (group) {
        cell.imageView.image = nil;
        cell.textField.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        cell.textField.textColor = NSColor.secondaryLabelColor;
        cell.textField.frame = NSMakeRect(10, 2, 180, 16);
    } else {
        cell.imageView.image = symbolImage(model[@"symbol"], 13);
        cell.imageView.contentTintColor = NSColor.secondaryLabelColor;
        cell.textField.font = [NSFont systemFontOfSize:13];
        cell.textField.textColor = NSColor.labelColor;
        cell.textField.frame = NSMakeRect(32, 5, 160, 18);
    }
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    NSInteger row = self.sidebar.selectedRow;
    if (row < 0 || row >= (NSInteger)sidebarRows().count) return;
    NSNumber *section = sidebarRows()[row][@"section"];
    if (!section) return;
    [self showSettingsSection:section.integerValue];
}

- (void)showSettingsSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.pages.count) return;
    [self.settingsContent.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    NSView *page = self.pages[section];
    page.frame = self.settingsContent.bounds;
    if (NSWidth(page.frame) < 200) page.frame = NSMakeRect(0, 0, 700, 640);
    page.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.settingsContent addSubview:page];
    if ([page isKindOfClass:[NSScrollView class]]) {
        NSScrollView *scroll = (NSScrollView *)page;
        [scroll.contentView scrollToPoint:NSZeroPoint];
        [scroll reflectScrolledClipView:scroll.contentView];
    }
}

- (NSString *)powerText {
    if (!self.status[@"powerWatts"]) return @"–";
    double watts = [self.status[@"powerWatts"] doubleValue];
    if (fabs(watts) < 0.05) return @"대기 0.0W";
    return [NSString stringWithFormat:@"%@ %.1fW", watts < 0 ? @"방전" : @"충전", fabs(watts)];
}

- (void)updateSettingsWindow {
    if (!self.settingsWindow) return;
    self.suppressLimitChange = YES;
    NSDictionary *status = self.status ?: @{};
    NSNumber *percent = status[@"percent"];
    self.fields[@"dash.percent"].stringValue = percent ? [NSString stringWithFormat:@"%@%%", percent] : @"–%";
    if (percent) {
        int value = percent.intValue;
        self.fields[@"dash.percent"].textColor = value < 20 ? NSColor.systemRedColor : (value < 50 ? NSColor.systemOrangeColor : NSColor.labelColor);
    }
    self.fields[@"dash.state"].stringValue = stateLabel(status);
    self.fields[@"dash.time"].stringValue = remainingLabel(status[@"timeRemaining"]) ?: ([status[@"source"] isEqualToString:@"ac"] ? @"전원 연결됨" : @"");
    self.dashMeter.doubleValue = percent.doubleValue;
    self.heroIcon.image = symbolImage(symbolName(status), 22);
    self.fields[@"dash.limit.value"].stringValue = limitText(status[@"charge"]);
    self.fields[@"dash.limit.detail"].stringValue = [status[@"charge"][@"enabled"] boolValue] ? @"전원에 연결하면 이 값에서 멈춥니다" : @"제한 없이 충전합니다";
    BOOL sailing = [NSUserDefaults.standardUserDefaults boolForKey:@"sailEnabled"];
    self.fields[@"dash.sail.value"].stringValue = sailing ? @"켜짐" : @"꺼짐";
    self.fields[@"dash.sail.detail"].stringValue = [NSString stringWithFormat:@"%d%% – %d%%", [self sailLower], [self sailUpper]];
    NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:@"batteryMode"] ?: @"none";
    if ([mode isEqualToString:@"topup"]) {
        self.fields[@"dash.mode.value"].stringValue = @"완충 중";
        self.fields[@"dash.mode.detail"].stringValue = @"100%가 되면 이전 한도로 돌아갑니다";
    } else if ([mode isEqualToString:@"calibration"]) {
        self.fields[@"dash.mode.value"].stringValue = @"보정 중";
        self.fields[@"dash.mode.detail"].stringValue = @"직접 끝낼 때까지 100%를 유지합니다";
    } else {
        self.fields[@"dash.mode.value"].stringValue = @"대기";
        self.fields[@"dash.mode.detail"].stringValue = @"한 번만 완충과 보정은 꺼져 있습니다";
    }
    self.fields[@"dash.health.value"].stringValue = status[@"healthPercent"] ? [NSString stringWithFormat:@"%@%%", status[@"healthPercent"]] : @"–";
    if (status[@"cycleCount"]) {
        self.fields[@"dash.health.detail"].stringValue = status[@"designCycles"]
            ? [NSString stringWithFormat:@"충전 %@ / %@회", status[@"cycleCount"], status[@"designCycles"]]
            : [NSString stringWithFormat:@"충전 %@회", status[@"cycleCount"]];
    } else {
        self.fields[@"dash.health.detail"].stringValue = @"충전 횟수 확인 중";
    }
    self.fields[@"dash.power.value"].stringValue = [self powerText];
    NSMutableArray *powerBits = [NSMutableArray array];
    if (status[@"voltage"]) [powerBits addObject:[NSString stringWithFormat:@"%.2fV", [status[@"voltage"] doubleValue]]];
    if (status[@"amperage"]) [powerBits addObject:[NSString stringWithFormat:@"%.2fA", [status[@"amperage"] doubleValue]]];
    if (status[@"temperature"]) [powerBits addObject:[NSString stringWithFormat:@"%.1f°C", [status[@"temperature"] doubleValue]]];
    self.fields[@"dash.power.detail"].stringValue = powerBits.count ? [powerBits componentsJoinedByString:@"  ·  "] : @"전력 확인 중";
    if (self.memoryTotal > 0) {
        self.fields[@"dash.memory.value"].stringValue = [NSString stringWithFormat:@"%.0f%%", self.memoryUsed / self.memoryTotal * 100.0];
        self.fields[@"dash.memory.detail"].stringValue = [NSString stringWithFormat:@"%@ / %@", byteText(self.memoryUsed, NSByteCountFormatterCountStyleMemory), byteText(self.memoryTotal, NSByteCountFormatterCountStyleMemory)];
    }
    if (self.storageTotal > 0) {
        self.fields[@"dash.storage.value"].stringValue = [NSString stringWithFormat:@"%.0f%%", self.storageUsed / self.storageTotal * 100.0];
        self.fields[@"dash.storage.detail"].stringValue = [NSString stringWithFormat:@"%@ / %@", byteText(self.storageUsed, NSByteCountFormatterCountStyleFile), byteText(self.storageTotal, NSByteCountFormatterCountStyleFile)];
    }
    self.fields[@"dash.network.value"].stringValue = self.netName ?: @"–";
    self.fields[@"dash.network.detail"].stringValue = self.hasNetworkSample
        ? [NSString stringWithFormat:@"↑ %@   ↓ %@", rateText(self.netUp), rateText(self.netDown)]
        : @"속도 계산 중";
    self.dashCPUGraph.values = self.cpuHistory;
    self.dashMemoryGraph.values = self.memoryHistory;
    self.dashStorageGraph.value = self.storageTotal > 0 ? self.storageUsed / self.storageTotal * 100.0 : 0;
    [self updateCPUReadouts];

    NSDictionary *charge = status[@"charge"];
    int current = activeChargeLimit(charge);
    NSUInteger index = [self.limitValues indexOfObject:@(current)];
    [self performWithoutControlActions:^{
        self.topUpButton.title = [mode isEqualToString:@"topup"] ? @"완충 취소" : @"한 번만 완충";
        self.topUpButton.action = [mode isEqualToString:@"topup"] ? @selector(endCalibration:) : @selector(startTopUp:);
        self.calibrationButton.title = [mode isEqualToString:@"calibration"] ? @"보정 끝내기" : @"보정 시작";
        self.calibrationButton.action = [mode isEqualToString:@"calibration"] ? @selector(endCalibration:) : @selector(startCalibration:);
        self.sailCheckbox.state = sailing ? NSControlStateValueOn : NSControlStateValueOff;
        [self.lowerPopup selectItemWithTitle:[NSString stringWithFormat:@"%d%%", [self sailLower]]];
        [self.upperPopup selectItemWithTitle:[NSString stringWithFormat:@"%d%%", [self sailUpper]]];
        self.limitControl.enabled = [charge[@"supported"] boolValue];
        if (index != NSNotFound && self.limitControl.selectedSegment != (NSInteger)index) {
            self.limitControl.selectedSegment = (NSInteger)index;
        }
        [self.intervalPopup selectItemWithTag:(NSInteger)[self metricsInterval]];
        self.loginCheckbox.state = [SMAppService mainAppService].status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        for (NSString *key in self.metricChecks) {
            self.metricChecks[key].state = pref(key) ? NSControlStateValueOn : NSControlStateValueOff;
        }
        for (NSString *key in self.metricsPopoverChecks) {
            if ([key hasPrefix:@"bar"]) self.metricsPopoverChecks[key].state = pref(key) ? NSControlStateValueOn : NSControlStateValueOff;
        }
        NSString *runnerID = selectedRunnerID();
        BOOL customRunner = [runnerID hasPrefix:@"c-"];
        self.renderModeControl.enabled = customRunner;
        BOOL template = YES;
        for (NSDictionary *spec in allRunnerSpecs()) {
            if ([spec[@"id"] isEqualToString:runnerID]) template = [spec[@"template"] boolValue];
        }
        self.renderModeControl.selectedSegment = template ? 0 : 1;
        for (NSString *ident in self.customBarChecks) {
            BOOL show = [[self customSourceWithID:ident][@"showInBar"] boolValue];
            self.customBarChecks[ident].state = show ? NSControlStateValueOn : NSControlStateValueOff;
            if (self.metricsPopoverChecks[ident]) self.metricsPopoverChecks[ident].state = show ? NSControlStateValueOn : NSControlStateValueOff;
        }
        for (NSString *ident in self.customStatusLabels) {
            BOOL failed = [self.customFailed containsObject:ident];
            self.customStatusLabels[ident].stringValue = relativeUpdateText(self.customSnapshots[ident][@"updated"], failed);
            self.customStatusLabels[ident].textColor = failed ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
        }
        for (NSString *key in self.runnerChoices) {
            self.runnerChoices[key].state = [key isEqualToString:runnerID] ? NSControlStateValueOn : NSControlStateValueOff;
        }
        self.removeRunnerButton.enabled = [runnerID hasPrefix:@"c-"];
        BOOL barOn = pref(@"showMetricsBar");
        for (NSString *key in @[@"barCPU", @"barMemory", @"barStorage", @"barBattery", @"barNetwork"]) {
            self.metricChecks[key].enabled = barOn;
        }
    }];
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            self.suppressLimitChange = NO;
        });
    });
    if ([charge[@"error"] isKindOfClass:[NSString class]]) {
        BOOL blank = YES;
        for (NSTextField *field in self.noteFields) {
            if (field.stringValue.length) blank = NO;
        }
        if (blank) [self showNote:charge[@"error"] error:YES];
    }
}

- (void)openSettings:(id)sender {
    (void)sender;
    if (self.popover.isShown) [self.popover performClose:nil];
    if (!self.settingsWindow) [self buildSettingsWindow];
    [self updateSettingsWindow];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activate];
    [self.settingsWindow makeKeyAndOrderFront:nil];
    [self applyPageInsets];
    NSView *page = self.settingsContent.subviews.firstObject;
    if (page) page.frame = self.settingsContent.bounds;
}

- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == self.settingsWindow) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }
}

- (void)windowDidResize:(NSNotification *)notification {
    if (notification.object != self.settingsWindow) return;
    [self applyPageInsets];
    NSView *page = self.settingsContent.subviews.firstObject;
    if (page) page.frame = self.settingsContent.bounds;
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
