#import <Foundation/Foundation.h>
#import <objc/message.h>

static id client(void) {
    static id instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *bundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/PowerUI.framework"];
        NSError *error = nil;
        if (![bundle loadAndReturnError:&error]) {
            fprintf(stderr, "PowerUI load failed: %s\n", [[error description] UTF8String]);
            return;
        }
        Class cls = NSClassFromString(@"PowerUISmartChargeClient");
        instance = ((id (*)(id, SEL, id))objc_msgSend)(
            [cls alloc], @selector(initWithClientName:), @"맥북 배터리 제어");
    });
    return instance;
}

static NSString *errorText(NSError *error) {
    if (!error) return nil;
    NSString *text = [error localizedDescription];
    return text.length ? text : [error description];
}

static NSDictionary *status(NSString **failure) {
    id charge = client();
    if (!charge) {
        if (failure) *failure = @"배터리 충전 제어 기능을 불러오지 못했습니다.";
        return nil;
    }

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
        for (id value in (NSArray *)available) {
            [limits addObject:@([value integerValue])];
        }
    }

    NSError *firstError = limitError ?: enabledError ?: availableError;
    return @{
        @"supported": @(supported),
        @"enabled": @(enabled != 0),
        @"limit": @(limit),
        @"available": limits,
        @"error": errorText(firstError) ?: [NSNull null]
    };
}

static BOOL setLimit(unsigned char limit, NSString **failure) {
    id charge = client();
    if (!charge) {
        if (failure) *failure = @"배터리 충전 제어 기능을 불러오지 못했습니다.";
        return NO;
    }

    NSError *__autoreleasing setError = nil;
    BOOL setOK = ((BOOL (*)(id, SEL, unsigned char, NSError *__autoreleasing *))objc_msgSend)(
        charge, @selector(setMCLLimit:error:), limit, &setError);
    if (!setOK) {
        if (failure) *failure = errorText(setError) ?: @"충전 한도를 바꾸지 못했습니다.";
        return NO;
    }

    NSError *__autoreleasing modeError = nil;
    SEL mode = limit >= 100 ? @selector(disableMCL:) : @selector(enableMCL:);
    BOOL modeOK = ((BOOL (*)(id, SEL, NSError *__autoreleasing *))objc_msgSend)(
        charge, mode, &modeError);
    if (!modeOK) {
        if (failure) *failure = errorText(modeError) ?: @"충전 한도 적용 상태를 바꾸지 못했습니다.";
        return NO;
    }
    return YES;
}

static void printJSON(id object) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    if (!data) {
        fprintf(stderr, "%s\n", [[error description] UTF8String]);
        exit(1);
    }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *command = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"status";
        NSString *failure = nil;

        if ([command isEqualToString:@"set"]) {
            if (argc < 3) {
                printJSON(@{@"ok": @NO, @"error": @"충전 한도 숫자가 필요합니다."});
                return 1;
            }
            int requested = atoi(argv[2]);
            if (requested < 1 || requested > 100) {
                printJSON(@{@"ok": @NO, @"error": @"충전 한도는 1에서 100 사이여야 합니다."});
                return 1;
            }
            BOOL ok = setLimit((unsigned char)requested, &failure);
            NSDictionary *current = status(NULL);
            NSMutableDictionary *result = current ? [current mutableCopy] : [NSMutableDictionary dictionary];
            result[@"ok"] = @(ok);
            if (!ok) result[@"error"] = failure ?: @"충전 한도를 바꾸지 못했습니다.";
            printJSON(result);
            return ok ? 0 : 1;
        }

        NSDictionary *current = status(&failure);
        if (!current) {
            printJSON(@{@"ok": @NO, @"error": failure ?: @"상태를 읽지 못했습니다."});
            return 1;
        }
        printJSON(current);
        return 0;
    }
}
