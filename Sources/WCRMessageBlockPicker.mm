#import "WCRMessageBlock.h"

#import "WCRConfigStore.h"
#import "WCRContactName.h"
#import "WCROriginalID.h"

#import <AppKit/AppKit.h>

static NSString *Trimmed(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return @"";
    return [value stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

static BOOL IsGroupID(NSString *userName) {
    return [userName hasSuffix:@"@chatroom"] || [userName hasSuffix:@"@im.chatroom"];
}

static void AddPickerRow(NSMutableArray<NSMutableDictionary<NSString *, id> *> *rows,
                         NSMutableSet<NSString *> *seen,
                         NSString *userName,
                         NSSet<NSString *> *blocked) {
    NSString *who = Trimmed(userName);
    if (!WCRMessageBlockValidSessionID(who) || [seen containsObject:who]) return;
    NSString *title = WCRContactNameDisplay(who);
    if (title.length == 0) title = who;
    [rows addObject:[@{
        @"userName": who,
        @"title": title,
        @"kind": IsGroupID(who) ? @"群" : @"联系人",
        @"blocked": @([blocked containsObject:who]),
    } mutableCopy]];
    [seen addObject:who];
}

@interface WCRMessageBlockPickerController : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTableView *table;
@property(nonatomic, strong) NSSearchField *searchField;
@property(nonatomic, strong) NSTextField *addField;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary<NSString *, id> *> *rows;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary<NSString *, id> *> *visible;
@end

@implementation WCRMessageBlockPickerController

- (void)present {
    if (!self.window) [self build];
    NSMutableArray<NSMutableDictionary<NSString *, id> *> *rows = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSSet<NSString *> *blocked = [NSSet setWithArray:WCRMessageBlockSessions()];
    for (NSString *session in WCRMessageBlockSessions()) {
        AddPickerRow(rows, seen, session, blocked);
    }
    for (NSDictionary<NSString *, NSString *> *session in WCROriginalIDRecentSessions()) {
        AddPickerRow(rows, seen, session[@"value"], blocked);
    }
    for (NSDictionary<NSString *, NSString *> *record in WCRContactNameRecords()) {
        AddPickerRow(rows, seen, record[@"userName"], blocked);
    }
    self.rows = rows;
    self.searchField.stringValue = @"";
    self.addField.stringValue = @"";
    [self applyFilter];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)build {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 640, 520)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"选择屏蔽的联系人或群";
    window.releasedWhenClosed = NO;
    window.level = NSFloatingWindowLevel;
    self.window = window;

    NSTextField *hint = [NSTextField labelWithString:
        @"勾选要屏蔽的人或群，取消勾选再点完成就会去掉这个人。每个人挡哪些类型，在「已屏蔽会话」里单独选；不单独选就跟随「屏蔽类型」。"];
    hint.frame = NSMakeRect(20, 460, 600, 44);
    hint.font = [NSFont systemFontOfSize:12];
    hint.maximumNumberOfLines = 3;

    self.searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(20, 424, 600, 28)];
    self.searchField.placeholderString = @"搜索名称或用户名";
    self.searchField.delegate = self;
    self.searchField.target = self;
    self.searchField.action = @selector(searchChanged:);

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 148, 600, 268)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    NSTableView *table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    NSTableColumn *check = [[NSTableColumn alloc] initWithIdentifier:@"blocked"];
    check.title = @"屏蔽";
    check.width = 48;
    NSButtonCell *checkCell = [[NSButtonCell alloc] init];
    checkCell.buttonType = NSButtonTypeSwitch;
    checkCell.title = @"";
    check.dataCell = checkCell;
    [table addTableColumn:check];
    NSTableColumn *name = [[NSTableColumn alloc] initWithIdentifier:@"title"];
    name.title = @"名称";
    name.width = 180;
    [table addTableColumn:name];
    NSTableColumn *kind = [[NSTableColumn alloc] initWithIdentifier:@"kind"];
    kind.title = @"类型";
    kind.width = 64;
    [table addTableColumn:kind];
    NSTableColumn *who = [[NSTableColumn alloc] initWithIdentifier:@"userName"];
    who.title = @"用户名";
    who.width = 260;
    [table addTableColumn:who];
    table.dataSource = self;
    table.delegate = self;
    table.headerView = [[NSTableHeaderView alloc] init];
    scroll.documentView = table;
    self.table = table;

    self.addField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 108, 430, 24)];
    self.addField.placeholderString = @"手填用户名，例如 wxid_xxx 或 123456@chatroom";
    NSButton *add = [NSButton buttonWithTitle:@"加入名单" target:self action:@selector(addUser:)];
    add.frame = NSMakeRect(462, 104, 158, 30);

    NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancel:)];
    cancel.frame = NSMakeRect(430, 20, 88, 32);
    NSButton *done = [NSButton buttonWithTitle:@"完成" target:self action:@selector(commit:)];
    done.frame = NSMakeRect(528, 20, 92, 32);
    done.keyEquivalent = @"\r";

    for (NSView *view in @[hint, self.searchField, scroll, self.addField, add, cancel, done]) {
        [window.contentView addSubview:view];
    }
}

- (void)applyFilter {
    NSString *query = Trimmed(self.searchField.stringValue).lowercaseString;
    self.visible = [NSMutableArray array];
    for (NSMutableDictionary<NSString *, id> *row in self.rows) {
        if (query.length == 0) {
            [self.visible addObject:row];
            continue;
        }
        NSString *title = [row[@"title"] lowercaseString] ?: @"";
        NSString *who = [row[@"userName"] lowercaseString] ?: @"";
        if ([title containsString:query] || [who containsString:query]) {
            [self.visible addObject:row];
        }
    }
    [self.table reloadData];
}

- (void)searchChanged:(id)sender {
    (void)sender;
    [self applyFilter];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == self.searchField) [self applyFilter];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)self.visible.count;
}

- (id)tableView:(NSTableView *)tableView
objectValueForTableColumn:(NSTableColumn *)column
            row:(NSInteger)row {
    (void)tableView;
    if (row < 0 || row >= (NSInteger)self.visible.count) return nil;
    return self.visible[(NSUInteger)row][column.identifier];
}

- (void)tableView:(NSTableView *)tableView
   setObjectValue:(id)object
   forTableColumn:(NSTableColumn *)column
              row:(NSInteger)row {
    (void)tableView;
    if (row < 0 || row >= (NSInteger)self.visible.count) return;
    if (![column.identifier isEqualToString:@"blocked"]) return;
    self.visible[(NSUInteger)row][@"blocked"] = @([object boolValue]);
}

- (BOOL)tableView:(NSTableView *)tableView
shouldEditTableColumn:(NSTableColumn *)column
              row:(NSInteger)row {
    (void)tableView;
    (void)row;
    return [column.identifier isEqualToString:@"blocked"];
}

- (void)addUser:(id)sender {
    (void)sender;
    NSString *who = Trimmed(self.addField.stringValue);
    if (!WCRMessageBlockValidSessionID(who)) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"用户名无效";
        alert.informativeText = @"需要不含空格的用户名或群 ID，最长 128 个字符。";
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    for (NSMutableDictionary *row in self.rows) {
        if ([row[@"userName"] isEqualToString:who]) {
            row[@"blocked"] = @YES;
            self.addField.stringValue = @"";
            [self applyFilter];
            return;
        }
    }
    NSString *title = WCRContactNameDisplay(who);
    if (title.length == 0) title = who;
    [self.rows insertObject:[@{
        @"userName": who,
        @"title": title,
        @"kind": IsGroupID(who) ? @"群" : @"联系人",
        @"blocked": @YES,
    } mutableCopy] atIndex:0];
    self.addField.stringValue = @"";
    [self applyFilter];
}

- (void)cancel:(id)sender {
    (void)sender;
    [self.window orderOut:nil];
}

- (void)commit:(id)sender {
    (void)sender;
    NSMutableArray<NSString *> *chosen = [NSMutableArray array];
    for (NSDictionary *row in self.rows) {
        if (![row[@"blocked"] boolValue]) continue;
        NSString *who = row[@"userName"];
        if (!WCRMessageBlockValidSessionID(who) || [chosen containsObject:who]) continue;
        [chosen addObject:who];
    }
    if (chosen.count > 256) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"最多屏蔽 256 个会话";
        alert.informativeText = @"先去掉多出来的勾选，再点完成。";
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    if (!WCRMessageBlockReplaceSessions(chosen)) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"无法保存屏蔽名单";
        alert.informativeText = @"名单没有写入。请减少勾选后再试。";
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    WCRConfigStoreBumpRevision();
    [self.window orderOut:nil];
}

@end

static WCRMessageBlockPickerController *gMessageBlockPicker;

void WCRMessageBlockPresentPicker(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gMessageBlockPicker) {
            gMessageBlockPicker = [[WCRMessageBlockPickerController alloc] init];
        }
        [gMessageBlockPicker present];
    });
}
