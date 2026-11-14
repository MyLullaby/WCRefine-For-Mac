#import "WCROtherApps.h"

#import <AppKit/AppKit.h>

NSString *const WCROtherAppsErrorDomain = @"com.wcrefine.mac.other-apps";
static NSString *const kWCROtherAppsHostBundleIdentifier = @"com.wcrefine.mac.sharehost";
static NSString *const kWCROtherAppsSyncURL = @"wcrefine-share://sync";
static NSString *gWCROtherAppsLastSignature = nil;

static const WCROtherAppSpec kWCROtherAppSpecs[] = {
    {@"codex", @"Codex", @"com.openai.codex", @"ChatGPT"},
    {@"grok-bot", @"Grok Bot", @"com.anysphere.sand", @"Grok Bot"},
    {@"kimi", @"Kimi", @"com.moonshot.kimichat", @"Kimi"},
    {@"amp", @"Amp", @"com.ampcode.amp.macos", @"Amp"},
    {@"muse", @"Muse", @"com.facebook.hatch", @"Muse"},
    {@"qoder", @"Qoder", @"com.qoder.app", @"Qoder"},
    {@"qoder-cn", @"Qoder CN", @"com.qodercn.app", @"Qoder CN"},
    {@"zcode", @"ZCode", @"dev.zcode.app", @"ZCode"},
    // WorkBuddy 官方共享扩展已经出现在微信「其他应用」里，这里不再登记。
    {@"workbuddy-ai", @"WorkBuddy AI", @"com.workbuddy.workbuddy-ai", @"WorkBuddy AI"},
    {@"doubao-work", @"豆包工作", @"com.bot.neotix.doubao", @"豆包"},
};

const WCROtherAppSpec *WCROtherAppSpecs(NSUInteger *count) {
    if (count) *count = sizeof(kWCROtherAppSpecs) / sizeof(kWCROtherAppSpecs[0]);
    return kWCROtherAppSpecs;
}

const WCROtherAppSpec *WCROtherAppSpecForIdentifier(NSString *identifier) {
    if (identifier.length == 0) return NULL;
    NSUInteger count = 0;
    const WCROtherAppSpec *specs = WCROtherAppSpecs(&count);
    for (NSUInteger index = 0; index < count; ++index) {
        if ([specs[index].identifier isEqualToString:identifier]) return &specs[index];
    }
    return NULL;
}

/// 插件跑在微信沙盒里。NSHomeDirectory 就是容器的 Data 目录，宿主从外面读这份文件。
static NSURL *WCROtherAppsSelectionURL(void) {
    NSString *directory = [NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Application Support/WCRefine"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"other-apps.plist"]];
}

static NSMutableDictionary<NSString *, id> *WCROtherAppsSelection(void) {
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfURL:WCROtherAppsSelectionURL()];
    NSMutableDictionary<NSString *, id> *selection = [stored isKindOfClass:[NSDictionary class]]
        ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    // 早期「Qoder」这一行实际指向 Qoder CN。拆成两行后，原来的勾选继续交给 Qoder CN。
    BOOL migrated = NO;
    if (selection[@"qoder-cn"] == nil && [selection[@"qoder"] boolValue]) {
        selection[@"qoder-cn"] = @YES;
        selection[@"qoder"] = @NO;
        migrated = YES;
    }
    // 官方入口已经会打开 WorkBuddy。去掉这一行后，旧勾选不再参与登记。
    if (selection[@"workbuddy"] != nil) {
        [selection removeObjectForKey:@"workbuddy"];
        migrated = YES;
    }
    if (migrated) {
        [selection writeToURL:WCROtherAppsSelectionURL() atomically:YES];
    }
    return selection;
}

NSURL *WCROtherAppApplicationURL(const WCROtherAppSpec *spec) {
    if (!spec) return nil;
    NSURL *applicationURL = [[NSWorkspace sharedWorkspace]
        URLForApplicationWithBundleIdentifier:spec->bundleIdentifier];
    if (applicationURL) return applicationURL;

    // Muse 的 Mac 客户端和 App Store 版本可能使用不同 bundle id；按标准安装名兜底。
    NSString *fileName = [spec->applicationName stringByAppendingPathExtension:@"app"];
    if (fileName.length == 0) return nil;
    NSURL *candidate = [NSURL fileURLWithPath:
        [@"/Applications" stringByAppendingPathComponent:fileName]];
    return [[NSBundle bundleWithURL:candidate] bundleIdentifier] ? candidate : nil;
}

BOOL WCROtherAppIsInstalled(const WCROtherAppSpec *spec) {
    return WCROtherAppApplicationURL(spec) != nil;
}

BOOL WCROtherAppEnabled(const WCROtherAppSpec *spec) {
    if (!spec) return NO;
    return [WCROtherAppsSelection()[spec->identifier] boolValue];
}

void WCROtherAppSetEnabled(const WCROtherAppSpec *spec, BOOL enabled) {
    if (!spec) return;
    NSMutableDictionary<NSString *, id> *selection = WCROtherAppsSelection();
    selection[spec->identifier] = @(enabled);
    [selection writeToURL:WCROtherAppsSelectionURL() atomically:YES];
}

BOOL WCROtherAppsHostInstalled(void) {
    return [[NSWorkspace sharedWorkspace]
               URLForApplicationWithBundleIdentifier:kWCROtherAppsHostBundleIdentifier] != nil;
}

static NSString *WCROtherAppsSelectionSignature(void) {
    NSMutableString *signature = [NSMutableString string];
    NSUInteger count = 0;
    const WCROtherAppSpec *specs = WCROtherAppSpecs(&count);
    for (NSUInteger index = 0; index < count; ++index) {
        [signature appendFormat:@"%@=%d/%d;",
            specs[index].identifier,
            WCROtherAppEnabled(&specs[index]) ? 1 : 0,
            WCROtherAppIsInstalled(&specs[index]) ? 1 : 0];
    }
    [signature appendFormat:@"host=%d", WCROtherAppsHostInstalled() ? 1 : 0];
    return signature;
}

static NSString *WCROtherAppsStatusMessage(void) {
    NSURL *url = [[WCROtherAppsSelectionURL() URLByDeletingLastPathComponent]
        URLByAppendingPathComponent:@"share-status.plist"];
    NSDictionary *status = [NSDictionary dictionaryWithContentsOfURL:url];
    NSString *message = [status[@"message"] isKindOfClass:[NSString class]] ? status[@"message"] : nil;
    return message.length ? message : nil;
}

NSString *WCROtherAppTooltip(const WCROtherAppSpec *spec) {
    if (!spec) return @"";
    if (!WCROtherAppIsInstalled(spec)) {
        return [NSString stringWithFormat:@"这台 Mac 上没有找到「%@」。装好后再勾选。",
            spec->applicationName];
    }
    if (!WCROtherAppsHostInstalled()) {
        return @"其他应用扩展还没安装。请重新覆盖安装 WCRefine。";
    }
    NSString *status = WCROtherAppsStatusMessage();
    NSString *base = [NSString stringWithFormat:
        @"勾选后出现在微信「其他应用」里。转发聊天记录时，压缩包会交给%@。",
        spec->title];
    if ([spec->title isEqualToString:spec->applicationName]) return status.length
        ? [NSString stringWithFormat:@"%@\n%@", base, status] : base;
    base = [NSString stringWithFormat:
        @"勾选后出现在微信「其他应用」里。转发聊天记录时，压缩包会交给%@（%@）。",
        spec->title, spec->applicationName];
    return status.length ? [NSString stringWithFormat:@"%@\n%@", base, status] : base;
}

static NSError *WCROtherAppsError(NSString *message) {
    return [NSError errorWithDomain:WCROtherAppsErrorDomain
                                code:1
                            userInfo:@{NSLocalizedDescriptionKey : message ?: @""}];
}

BOOL WCROtherAppsRequestSyncIfSelectionChanged(NSError **error) {
    NSString *signature = WCROtherAppsSelectionSignature();
    if ([signature isEqualToString:gWCROtherAppsLastSignature]) {
        if (error) *error = nil;
        return YES;
    }
    gWCROtherAppsLastSignature = signature;
    if (!WCROtherAppsHostInstalled()) {
        if (error) *error = WCROtherAppsError(@"其他应用扩展还没安装。请重新覆盖安装 WCRefine。");
        return NO;
    }
    NSMutableArray<NSString *> *enabled = [NSMutableArray array];
    NSUInteger count = 0;
    const WCROtherAppSpec *specs = WCROtherAppSpecs(&count);
    for (NSUInteger index = 0; index < count; ++index) {
        if (WCROtherAppEnabled(&specs[index])) [enabled addObject:specs[index].identifier];
    }
    NSString *encoded = [[enabled componentsJoinedByString:@","]
        stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *absolute = [NSString stringWithFormat:@"%@?on=%@", kWCROtherAppsSyncURL, encoded ?: @""];
    NSURL *url = [NSURL URLWithString:absolute];
    if (!url) {
        if (error) *error = WCROtherAppsError(@"无法打开其他应用扩展。");
        return NO;
    }
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = NO;
    configuration.addsToRecentItems = NO;
    [[NSWorkspace sharedWorkspace] openURL:url
                             configuration:configuration
                         completionHandler:^(NSRunningApplication *application, NSError *openError) {
        (void)application;
        (void)openError;
    }];
    if (error) *error = nil;
    return YES;
}
