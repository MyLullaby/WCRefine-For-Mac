#import <AppKit/AppKit.h>
#import <pwd.h>

/// 微信「其他应用」要求共享扩展是一个视图控制器。视图只有 1 点，请求在拷完文件后立刻结束。
@interface WCRShareViewController : NSViewController
- (void)wcr_loadZipFromProvider:(NSItemProvider *)provider
                          types:(NSArray<NSString *> *)types
                        atIndex:(NSUInteger)typeIndex
                     useFileRep:(BOOL)useFileRep
                           name:(NSString *)name
                          batch:(NSString *)batch
                           home:(NSString *)home
                          names:(NSMutableArray<NSString *> *)names
                           lock:(NSLock *)lock
                      loadError:(NSError * __strong *)loadError
                          group:(dispatch_group_t)group;
@end

@implementation WCRShareViewController {
    BOOL _started;
}

- (void)loadView {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)];
    view.alphaValue = 0;
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self wcr_receive:self.extensionContext];
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    [self wcr_receive:context];
}

static NSString *WCRShareRealHome(void) {
    struct passwd *entry = getpwuid(getuid());
    if (entry && entry->pw_dir) {
        NSString *home = [NSString stringWithUTF8String:entry->pw_dir];
        if (home.length > 0) return home;
    }
    return nil;
}

static NSString *WCRShareSafeName(NSString *suggested, NSUInteger index) {
    NSString *name = suggested.lastPathComponent;
    if (name.length == 0 || ![name.pathExtension.lowercaseString isEqualToString:@"zip"]) {
        name = index == 0 ? @"聊天记录.zip" : [NSString stringWithFormat:@"文件-%lu.zip", (unsigned long)index + 1];
    }
    name = [name stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    name = [name stringByReplacingOccurrencesOfString:@":" withString:@"-"];
    if ([name isEqualToString:@"."] || [name isEqualToString:@".."] || [name hasPrefix:@"."]) {
        name = [@"file-" stringByAppendingString:name];
    }
    return name;
}

static void WCRShareAppexLog(NSString *home, NSString *message) {
    if (home.length == 0 || message.length == 0) return;
    NSString *path = [home stringByAppendingPathComponent:@"Library/Application Support/WCRefine/share.log"];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

/// 微信这个附件用 loadItem 给出真正的 zip 数据。loadFileRepresentation 经常是一个空文件。
static BOOL WCRShareBytesAreZip(NSData *data) {
    if (data.length < 30) return NO;
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    return bytes[0] == 'P' && bytes[1] == 'K' && bytes[2] == 3 && bytes[3] == 4;
}

static NSData *WCRShareReadFile(NSURL *url) {
    if (![url isFileURL]) return nil;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] init];
    __block NSData *data = nil;
    NSError *coordError = nil;
    [coordinator coordinateReadingItemAtURL:url
                                    options:NSFileCoordinatorReadingWithoutChanges
                                      error:&coordError
                                 byAccessor:^(NSURL *newURL) {
        data = [NSData dataWithContentsOfURL:newURL options:0 error:nil];
    }];
    if (scoped) [url stopAccessingSecurityScopedResource];
    (void)coordError;
    return data;
}

static NSData *WCRShareMaterialize(id item) {
    if ([item isKindOfClass:[NSData class]]) return item;
    if ([item isKindOfClass:[NSURL class]]) return WCRShareReadFile(item);
    if ([item isKindOfClass:[NSString class]] && [(NSString *)item hasPrefix:@"/"]) {
        return WCRShareReadFile([NSURL fileURLWithPath:item]);
    }
    return nil;
}

- (void)wcr_loadZipFromProvider:(NSItemProvider *)provider
                          types:(NSArray<NSString *> *)types
                        atIndex:(NSUInteger)typeIndex
                     useFileRep:(BOOL)useFileRep
                           name:(NSString *)name
                          batch:(NSString *)batch
                           home:(NSString *)home
                          names:(NSMutableArray<NSString *> *)names
                           lock:(NSLock *)lock
                      loadError:(NSError * __strong *)loadError
                          group:(dispatch_group_t)group {
    if (typeIndex >= types.count) {
        if (!useFileRep) {
            [self wcr_loadZipFromProvider:provider
                                    types:types
                                  atIndex:0
                               useFileRep:YES
                                     name:name
                                    batch:batch
                                     home:home
                                    names:names
                                     lock:lock
                                loadError:loadError
                                    group:group];
            return;
        }
        [lock lock];
        if (loadError && !*loadError) {
            *loadError = [NSError errorWithDomain:@"com.wcrefine.mac.other-apps"
                                              code:5
                                          userInfo:@{NSLocalizedDescriptionKey : @"微信给出的聊天记录是空的，没有转发。"}];
        }
        [lock unlock];
        WCRShareAppexLog(home, @"zip empty");
        dispatch_group_leave(group);
        return;
    }
    NSString *type = types[typeIndex];
    if (![provider hasItemConformingToTypeIdentifier:type]) {
        [self wcr_loadZipFromProvider:provider
                                types:types
                              atIndex:typeIndex + 1
                           useFileRep:useFileRep
                                 name:name
                                batch:batch
                                 home:home
                                names:names
                                 lock:lock
                            loadError:loadError
                                group:group];
        return;
    }
    void (^finish)(NSData *, NSError *) = ^(NSData *data, NSError *error) {
        if (WCRShareBytesAreZip(data)) {
            NSString *destination = [batch stringByAppendingPathComponent:name];
            NSError *writeError = nil;
            BOOL wrote = [data writeToFile:destination options:NSDataWritingAtomic error:&writeError];
            [lock lock];
            if (wrote) [names addObject:name];
            else if (loadError && !*loadError) *loadError = writeError;
            [lock unlock];
            WCRShareAppexLog(home, [NSString stringWithFormat:@"zip bytes=%lu type=%@ saved=%d",
                (unsigned long)data.length, type, wrote ? 1 : 0]);
            dispatch_group_leave(group);
            return;
        }
        if (error) {
            [lock lock];
            if (loadError && !*loadError) *loadError = error;
            [lock unlock];
        }
        [self wcr_loadZipFromProvider:provider
                                types:types
                              atIndex:typeIndex + 1
                           useFileRep:useFileRep
                                 name:name
                                batch:batch
                                 home:home
                                names:names
                                 lock:lock
                            loadError:loadError
                                group:group];
    };
    if (!useFileRep) {
        [provider loadItemForTypeIdentifier:type options:nil completionHandler:^(id<NSSecureCoding> item, NSError *error) {
            finish(WCRShareMaterialize(item), error);
        }];
        return;
    }
    [provider loadFileRepresentationForTypeIdentifier:type completionHandler:^(NSURL *url, NSError *error) {
        finish(url ? WCRShareReadFile(url) : nil, error);
    }];
}

- (void)wcr_receive:(NSExtensionContext *)context {
    if (_started || !context) return;
    _started = YES;
    NSString *bundleIdentifier = [NSBundle.mainBundle objectForInfoDictionaryKey:@"WCRTargetBundleIdentifier"];
    NSString *displayName = [NSBundle.mainBundle objectForInfoDictionaryKey:@"WCRTargetDisplayName"];
    if (bundleIdentifier.length == 0 || displayName.length == 0) {
        [context cancelRequestWithError:[NSError errorWithDomain:@"com.wcrefine.mac.other-apps"
                                                              code:2
                                                          userInfo:@{NSLocalizedDescriptionKey : @"这个入口没有写明要交给哪个应用。"}]];
        return;
    }
    NSString *home = WCRShareRealHome();
    if (home.length == 0) {
        [context cancelRequestWithError:[NSError errorWithDomain:@"com.wcrefine.mac.other-apps"
                                                              code:3
                                                          userInfo:@{NSLocalizedDescriptionKey : @"找不到用户目录，没法保存转发的文件。"}]];
        return;
    }
    NSString *relay = [home stringByAppendingPathComponent:@"Library/Application Support/WCRefine/Relay"];
    NSString *batch = [relay stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:batch
                                   withIntermediateDirectories:YES
                                                    attributes:@{NSFilePosixPermissions : @0755}
                                                         error:&directoryError]) {
        [context cancelRequestWithError:directoryError];
        return;
    }

    NSMutableArray<NSItemProvider *> *providers = [NSMutableArray array];
    for (id item in context.inputItems) {
        if (![item isKindOfClass:[NSExtensionItem class]]) continue;
        for (NSItemProvider *provider in ((NSExtensionItem *)item).attachments) {
            if ([provider isKindOfClass:[NSItemProvider class]]) [providers addObject:provider];
        }
    }
    if (providers.count == 0) {
        [[NSFileManager defaultManager] removeItemAtPath:batch error:nil];
        [context cancelRequestWithError:[NSError errorWithDomain:@"com.wcrefine.mac.other-apps"
                                                              code:4
                                                          userInfo:@{NSLocalizedDescriptionKey : @"微信没有把文件交给这个入口。"}]];
        return;
    }

    dispatch_group_t group = dispatch_group_create();
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSLock *lock = [[NSLock alloc] init];
    __block NSError *loadError = nil;
    [providers enumerateObjectsUsingBlock:^(NSItemProvider *provider, NSUInteger index, BOOL *stop) {
        (void)stop;
        NSArray<NSString *> *types = @[@"public.zip-archive", @"com.pkware.zip-archive"];
        BOOL conforms = NO;
        for (NSString *type in types) {
            if ([provider hasItemConformingToTypeIdentifier:type]) conforms = YES;
        }
        if (!conforms) return;
        NSString *name = WCRShareSafeName(provider.suggestedName, index);
        dispatch_group_enter(group);
        [self wcr_loadZipFromProvider:provider
                                types:types
                              atIndex:0
                           useFileRep:NO
                                 name:name
                                batch:batch
                                 home:home
                                names:names
                                 lock:lock
                            loadError:&loadError
                                group:group];
    }];

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (names.count == 0) {
            [[NSFileManager defaultManager] removeItemAtPath:batch error:nil];
            [context cancelRequestWithError:loadError ?: [NSError errorWithDomain:@"com.wcrefine.mac.other-apps"
                                                                               code:6
                                                                           userInfo:@{NSLocalizedDescriptionKey : @"没有保存到转发的文件。"}]];
            return;
        }
        NSDictionary *intent = @{
            @"bundleIdentifier" : bundleIdentifier,
            @"displayName" : displayName,
            @"files" : names,
        };
        NSURL *intentURL = [NSURL fileURLWithPath:[batch stringByAppendingPathComponent:@"intent.json"]];
        NSData *data = [NSJSONSerialization dataWithJSONObject:intent options:0 error:nil];
        if (![data writeToURL:intentURL atomically:YES]) {
            [[NSFileManager defaultManager] removeItemAtPath:batch error:nil];
            [context cancelRequestWithError:[NSError errorWithDomain:@"com.wcrefine.mac.other-apps"
                                                                  code:7
                                                              userInfo:@{NSLocalizedDescriptionKey : @"没能记下要交给哪个应用。"}]];
            return;
        }
        NSURL *deliver = [NSURL URLWithString:@"wcrefine-share://deliver"];
        if (deliver) [[NSWorkspace sharedWorkspace] openURL:deliver];
        [context completeRequestReturningItems:@[] completionHandler:nil];
    });
}

@end
