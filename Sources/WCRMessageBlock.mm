#import "WCRMessageBlock.h"

#import "WCRCodePatch.h"
#import "WCRContactName.h"
#import "WCROriginalID.h"

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach-o/dyld.h>
#import <libkern/OSCacheControl.h>

#include <atomic>
#include <cstdint>
#include <cstring>
#include <string>
#include <sys/mman.h>

NSString *const kWCRMessageBlockEnabledDefaultsKey = @"WCRefineMacMessageBlockEnabled";
NSString *const kWCRMessageBlockSessionsDefaultsKey = @"WCRefineMacMessageBlockSessions";
NSString *const kWCRMessageBlockTypesDefaultsKey = @"WCRefineMacMessageBlockTypes";
NSString *const kWCRMessageBlockSessionTypesDefaultsKey = @"WCRefineMacMessageBlockSessionTypes";
NSString *const kWCRMessageBlockShowTipDefaultsKey = @"WCRefineMacMessageBlockShowTip";

NSString *const kWCRMessageBlockTypeText = @"text";
NSString *const kWCRMessageBlockTypeRefer = @"refer";
NSString *const kWCRMessageBlockTypeImage = @"image";
NSString *const kWCRMessageBlockTypeVoice = @"voice";
NSString *const kWCRMessageBlockTypeVideo = @"video";
NSString *const kWCRMessageBlockTypeEmoticon = @"emoticon";
NSString *const kWCRMessageBlockTypePat = @"pat";
NSString *const kWCRMessageBlockTypeFile = @"file";
NSString *const kWCRMessageBlockTypeContact = @"contact";
NSString *const kWCRMessageBlockTypeLocation = @"location";
NSString *const kWCRMessageBlockTypeChatRecord = @"chatrecord";
NSString *const kWCRMessageBlockTypeLink = @"link";
NSString *const kWCRMessageBlockTypeMusic = @"music";
NSString *const kWCRMessageBlockTypeRedPacket = @"redpacket";
NSString *const kWCRMessageBlockTypeTransfer = @"transfer";
NSString *const kWCRMessageBlockTypeOther = @"other";

namespace {

constexpr uint64_t kMessageTypeOffset = 0x0C;
constexpr uint64_t kMessageFromOffset = 0x18;
constexpr uint64_t kMessageToOffset = 0x30;
constexpr uint64_t kMessageContentOffset = 0x130;
// 解析器把源记录 +0x38 指向的字符串抄到这里。只在像「昵称: 摘要」时拿来显示。
constexpr uint64_t kMessagePushOffset = 0x160;
// 解析前的源记录。270390 的 0x45bf724：+0x14 是类型，
// +8 / +0x18 / +0x20 是持有者，字符串在持有者 +8。
constexpr uint64_t kSourceTypeOffset = 0x14;
constexpr uint64_t kSourceFromHolderOffset = 0x08;
constexpr uint64_t kSourceToHolderOffset = 0x18;
constexpr uint64_t kSourceContentHolderOffset = 0x20;
constexpr uint64_t kSourcePushOffset = 0x38;
constexpr uint64_t kHolderStringOffset = 0x08;
constexpr size_t kMaxContentBytes = 65536;
constexpr uint32_t kSystemTipType = 10000;
constexpr uint32_t kSystemCommandType = 10002;
constexpr size_t kMaxSessionIDs = 256;
constexpr size_t kMaxSessionBytes = 128;
constexpr size_t kEntryBytes = 16;
constexpr size_t kTrampolineBytes = 32;

using StringAssignFn = void (*)(void *destination, const void *source);

std::atomic_bool gInstalled(false);
uint8_t gSavedEntry[kEntryBytes] = {};
uint8_t *gEntry = nullptr;
void *gTrampoline = nullptr;
uintptr_t gTrampolineEntry = 0;
uint8_t gPrepareSaved[kEntryBytes] = {};
uint8_t *gPrepareEntry = nullptr;
void *gPrepareTrampoline = nullptr;
uintptr_t gPrepareTrampolineEntry = 0;
StringAssignFn gStringAssign = nullptr;

NSError *MessageBlockError(NSString *message) {
    return [NSError errorWithDomain:@"WCRefineMac.MessageBlock"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"消息屏蔽错误"}];
}

bool IsAddressRangeReadable(const void *address, size_t length) {
    if (!address || length == 0) return false;
    uintptr_t current = reinterpret_cast<uintptr_t>(address);
    uintptr_t end = current + length;
    if (end < current) return false;

    while (current < end) {
        mach_vm_address_t region = static_cast<mach_vm_address_t>(current);
        mach_vm_size_t regionSize = 0;
        vm_region_basic_info_data_64_t info = {};
        mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t objectName = MACH_PORT_NULL;
        kern_return_t result = mach_vm_region(mach_task_self(),
                                              &region,
                                              &regionSize,
                                              VM_REGION_BASIC_INFO_64,
                                              reinterpret_cast<vm_region_info_t>(&info),
                                              &infoCount,
                                              &objectName);
        if (objectName != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), objectName);
        if (result != KERN_SUCCESS || regionSize == 0 ||
            region > current || (info.protection & VM_PROT_READ) == 0) {
            return false;
        }
        uintptr_t next = static_cast<uintptr_t>(region + regionSize);
        if (next <= current) return false;
        current = next;
    }
    return true;
}

bool ReadLibcppStringLimited(const void *object, size_t offset, size_t maxBytes,
                             bool allowPrefix, std::string &out) {
    if (!object || maxBytes == 0) return false;
    const auto *slot = reinterpret_cast<const uint8_t *>(object) + offset;
    if (!IsAddressRangeReadable(slot, 24)) return false;

    const int8_t flag = static_cast<int8_t>(slot[23]);
    if (flag >= 0) {
        size_t length = static_cast<uint8_t>(flag) & 0x7F;
        if (length == 0 || length > 22) return false;
        if (length > maxBytes) {
            if (!allowPrefix) return false;
            length = maxBytes;
        }
        out.assign(reinterpret_cast<const char *>(slot), length);
        return true;
    }

    const char *data = nullptr;
    uint64_t rawLength = 0;
    memcpy(&data, slot, sizeof(data));
    memcpy(&rawLength, slot + 8, sizeof(rawLength));
    size_t length = static_cast<size_t>(rawLength & 0x7FFFFFFFFFFFFFFFULL);
    if (!data || length == 0) return false;
    if (length > maxBytes) {
        if (!allowPrefix) return false;
        length = maxBytes;
    }
    if (!IsAddressRangeReadable(data, length)) return false;
    out.assign(data, length);
    return true;
}

bool ReadLibcppStringAt(const void *object, size_t offset, std::string &out) {
    return ReadLibcppStringLimited(object, offset, kMaxSessionBytes, false, out);
}

bool ReadMessageType(const void *message, uint32_t *type) {
    if (!message || !type) return false;
    auto *slot = reinterpret_cast<const uint8_t *>(message) + kMessageTypeOffset;
    if (!IsAddressRangeReadable(slot, sizeof(*type))) return false;
    memcpy(type, slot, sizeof(*type));
    return true;
}

NSString *TrimmedString(id value) {
    if (![value isKindOfClass:[NSString class]]) return @"";
    return [(NSString *)value stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

bool ValidSessionID(NSString *value) {
    if (value.length == 0 || value.length > kMaxSessionBytes) return false;
    NSCharacterSet *bad = [NSCharacterSet controlCharacterSet];
    return [value rangeOfCharacterFromSet:bad].location == NSNotFound &&
           [value rangeOfCharacterFromSet:
               [NSCharacterSet whitespaceAndNewlineCharacterSet]].location == NSNotFound;
}

NSString *StringFromUTF8(const std::string &value) {
    if (value.empty()) return nil;
    return [[NSString alloc] initWithBytes:value.data()
                                    length:value.size()
                                  encoding:NSUTF8StringEncoding];
}

bool EndsWithChatroom(NSString *value) {
    return [value hasSuffix:@"@chatroom"] || [value hasSuffix:@"@im.chatroom"];
}

bool LooksLikeUserName(NSString *value) {
    NSString *text = TrimmedString(value);
    if (text.length < 4 || text.length > 128) return false;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-@"];
    if ([text rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return false;
    if ([text containsString:@"@"]) return EndsWithChatroom(text);
    return true;
}

bool HumanName(NSString *value) {
    NSString *text = TrimmedString(value);
    if (text.length == 0 || text.length > 32) return false;
    if ([text rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) {
        return false;
    }
    if ([text containsString:@"<"] || [text containsString:@">"] || [text containsString:@"@"]) {
        return false;
    }
    return !LooksLikeUserName(text);
}

NSString *FirstTagText(NSString *content, NSString *tag) {
    if (content.length == 0 || tag.length == 0) return nil;
    NSString *open = [NSString stringWithFormat:@"<%@>", tag];
    NSString *close = [NSString stringWithFormat:@"</%@>", tag];
    NSRange start = [content rangeOfString:open options:NSCaseInsensitiveSearch];
    if (start.location == NSNotFound || NSMaxRange(start) > content.length) return nil;
    NSRange rest = NSMakeRange(NSMaxRange(start), content.length - NSMaxRange(start));
    NSRange end = [content rangeOfString:close options:NSCaseInsensitiveSearch range:rest];
    if (end.location == NSNotFound || end.location < NSMaxRange(start)) return nil;
    if (end.location - NSMaxRange(start) > 128) return nil;
    NSString *inner = TrimmedString([content substringWithRange:
        NSMakeRange(NSMaxRange(start), end.location - NSMaxRange(start))]);
    if (inner.length >= 12 && [inner hasPrefix:@"<![CDATA["] && [inner hasSuffix:@"]]>"]) {
        inner = TrimmedString([inner substringWithRange:NSMakeRange(9, inner.length - 12)]);
    }
    return inner.length ? inner : nil;
}

NSString *FirstLineLabel(NSString *content) {
    if (content.length == 0) return nil;
    NSRange newline = [content rangeOfCharacterFromSet:
        [NSCharacterSet newlineCharacterSet]];
    NSString *line = newline.location == NSNotFound
        ? content
        : [content substringToIndex:newline.location];
    line = TrimmedString(line);
    BOOL ascii = [line hasSuffix:@":"];
    BOOL full = [line hasSuffix:@"："];
    if (line.length < 2 || (!ascii && !full)) return nil;
    line = TrimmedString([line substringToIndex:line.length - 1]);
    if (line.length == 0 || line.length > 128) return nil;
    return line;
}

NSString *NameBeforeColon(NSString *text) {
    if (text.length == 0 || text.length > 180 || [text containsString:@"<"]) return nil;
    NSRange ascii = [text rangeOfString:@":"];
    NSRange full = [text rangeOfString:@"："];
    NSRange mark = ascii;
    if (full.location != NSNotFound &&
        (mark.location == NSNotFound || full.location < mark.location)) {
        mark = full;
    }
    if (mark.location == NSNotFound || mark.location == 0) return nil;
    NSString *left = TrimmedString([text substringToIndex:mark.location]);
    return HumanName(left) ? left : nil;
}

bool IsPatContent(NSString *content) {
    if (content.length == 0) return false;
    NSString *low = content.lowercaseString;
    if ([low containsString:@"type=\"pat\""] || [low containsString:@"<pat>"] ||
        [low containsString:@"<pat "] || [low containsString:@"pattedusername"] ||
        [low containsString:@"patsuffix"] || [low containsString:@"<patmsg"]) {
        return true;
    }
    // 自己的灰字提示写成「的拍一拍」，不能再被当成拍一拍消息丢掉。
    return [content containsString:@"拍了拍"];
}

struct MessageParty {
    NSString *userName;
    NSString *seenName;
};

MessageParty IdentifySender(NSString *from, NSString *to, NSString *content, NSString *push) {
    MessageParty party{nil, nil};
    NSString *label = FirstLineLabel(content);
    if (LooksLikeUserName(label) && !EndsWithChatroom(label)) party.userName = label;
    else if (HumanName(label)) party.seenName = label;
    if (party.userName.length == 0) {
        NSString *xmlFrom = FirstTagText(content, @"fromusername");
        if (LooksLikeUserName(xmlFrom) && !EndsWithChatroom(xmlFrom)) party.userName = xmlFrom;
    }
    if (party.userName.length == 0 && from.length > 0 && !EndsWithChatroom(from)) {
        party.userName = from;
    }
    (void)to;
    if (party.seenName.length == 0) party.seenName = NameBeforeColon(push);
    if (party.seenName.length == 0) {
        NSString *card = FirstTagText(content, @"displayname");
        if (!HumanName(card)) card = FirstTagText(content, @"nickname");
        if (HumanName(card)) party.seenName = card;
    }
    if (party.seenName.length == 0) {
        NSRange patted = [content rangeOfString:@"拍了拍"];
        if (patted.location != NSNotFound && patted.location > 0 && patted.location <= 64) {
            NSString *left = TrimmedString([content substringToIndex:patted.location]);
            left = [left stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@"\"'“”「」"]];
            if (HumanName(left)) party.seenName = left;
        }
    }
    return party;
}

void RememberParty(NSString *session, MessageParty party, NSString *content) {
    if (party.userName.length > 0 && HumanName(party.seenName)) {
        // 群里见到的是群名片。私聊见到的是昵称。备注只留给选择器手填。
        if (EndsWithChatroom(session)) {
            WCRContactNameRemember(party.userName, nil, party.seenName, nil, nil);
        } else {
            WCRContactNameRemember(party.userName, nil, nil, party.seenName, nil);
        }
    }
    // 群名只信消息里写明的 chatroomname / topic。推送摘要不是群名。
    if (!EndsWithChatroom(session)) return;
    NSString *room = FirstTagText(content, @"chatroomname");
    if (!HumanName(room)) room = FirstTagText(content, @"topic");
    if (HumanName(room)) WCRContactNameRemember(session, nil, room, nil, nil);
}

bool SentBySelf(NSString *sender, NSString *selfUser) {
    return sender.length > 0 && selfUser.length > 0 && [sender isEqualToString:selfUser];
}

NSString *StringAt(const void *object, size_t offset, size_t maxBytes) {
    std::string bytes;
    if (!object || !ReadLibcppStringLimited(object, offset, maxBytes, true, bytes)) return nil;
    return StringFromUTF8(bytes);
}

NSString *SourcePushText(const void *source) {
    if (!IsAddressRangeReadable(static_cast<const uint8_t *>(source) + kSourcePushOffset,
                                sizeof(void *))) {
        return nil;
    }
    const void *text = nullptr;
    memcpy(&text, static_cast<const uint8_t *>(source) + kSourcePushOffset, sizeof(text));
    if (!text || !IsAddressRangeReadable(text, 24)) return nil;
    return StringAt(text, 0, 512);
}

/// 自己的拍一拍正文是「你拍了拍」。别人拍自己是「拍了拍你」，不能当成自己。
bool PatFromSelf(NSString *content, MessageParty party) {
    if (party.userName.length > 0) return false;
    return content.length > 0 && [content containsString:@"你拍了拍"];
}

/// 命中返回 YES，并写出提示要用的会话、发送者和类型。未命中也会记下见过的名字。
bool ShouldDropInbound(uint32_t type,
                       NSString *from,
                       NSString *to,
                       NSString *content,
                       NSString *push,
                       NSString **sessionOut,
                       MessageParty *partyOut,
                       NSString **typeKeyOut) {
    bool system = type == kSystemTipType || type == kSystemCommandType;
    if (system && !IsPatContent(content)) return false;

    MessageParty party = IdentifySender(from, to, content, push);
    NSString *selfUser = WCROriginalIDSelfWXID();
    if (SentBySelf(party.userName, selfUser) || PatFromSelf(content, party)) return false;

    NSString *session = WCRMessageBlockResolveSession(from, to, selfUser);
    RememberParty(session, party, content);
    if (session.length == 0 || !WCRMessageBlockIsSessionBlocked(session)) return false;

    NSString *typeKey = system
        ? kWCRMessageBlockTypePat
        : WCRMessageBlockTypeKeyForMessageType(type, content);
    if (typeKey.length == 0 || !WCRMessageBlockTypeIsSelectedForSession(session, typeKey)) {
        return false;
    }
    if (sessionOut) *sessionOut = session;
    if (partyOut) *partyOut = party;
    if (typeKeyOut) *typeKeyOut = typeKey;
    return true;
}

NSInteger InnerTypeValue(NSString *text) {
    NSString *work = TrimmedString(text);
    if (work.length >= 12 && [work hasPrefix:@"<![CDATA["] && [work hasSuffix:@"]]>"]) {
        work = TrimmedString([work substringWithRange:NSMakeRange(9, work.length - 12)]);
    }
    if (work.length == 0) return -1;
    NSInteger value = [work integerValue];
    return value > 0 ? value : -1;
}

NSInteger AppMsgAttributeType(NSString *content) {
    if (content.length < 8) return -1;
    NSRange app = [content rangeOfString:@"<appmsg" options:NSCaseInsensitiveSearch];
    if (app.location == NSNotFound) return -1;
    NSUInteger window = MIN((NSUInteger)240, content.length - app.location);
    NSRange gt = [content rangeOfString:@">" options:0 range:NSMakeRange(app.location, window)];
    if (gt.location == NSNotFound || gt.location < app.location) return -1;
    NSString *head = [content substringWithRange:NSMakeRange(app.location, gt.location - app.location)];
    NSString *low = head.lowercaseString;
    NSRange mark = [low rangeOfString:@"type=\""];
    if (mark.location == NSNotFound) mark = [low rangeOfString:@"type='"];
    if (mark.location == NSNotFound) return -1;
    NSUInteger index = NSMaxRange(mark);
    NSUInteger end = index;
    while (end < head.length) {
        unichar character = [head characterAtIndex:end];
        if (character < '0' || character > '9') break;
        end += 1;
    }
    if (end == index) return -1;
    return InnerTypeValue([head substringWithRange:NSMakeRange(index, end - index)]);
}

NSInteger FirstAppMsgInnerType(NSString *content) {
    if (content.length < 8) return -1;
    NSRange appMsg = [content rangeOfString:@"<appmsg" options:NSCaseInsensitiveSearch];
    NSString *slice = appMsg.location == NSNotFound ? content : [content substringFromIndex:appMsg.location];
    NSRange open = [slice rangeOfString:@"<type>" options:NSCaseInsensitiveSearch];
    NSRange close = [slice rangeOfString:@"</type>" options:NSCaseInsensitiveSearch];
    if (open.location != NSNotFound && close.location != NSNotFound &&
        close.location > open.location) {
        NSUInteger start = NSMaxRange(open);
        if (close.location >= start && close.location - start <= 64) {
            NSInteger tagged = InnerTypeValue([slice substringWithRange:
                NSMakeRange(start, close.location - start)]);
            if (tagged > 0) return tagged;
        }
    }
    return AppMsgAttributeType(content);
}

const void *HolderString(const void *source, uint64_t holderOffset) {
    if (!IsAddressRangeReadable(static_cast<const uint8_t *>(source) + holderOffset,
                                sizeof(void *))) {
        return nullptr;
    }
    const void *holder = nullptr;
    memcpy(&holder, static_cast<const uint8_t *>(source) + holderOffset, sizeof(holder));
    if (!holder || !IsAddressRangeReadable(static_cast<const uint8_t *>(holder) + kHolderStringOffset,
                                           sizeof(void *))) {
        return nullptr;
    }
    const void *text = nullptr;
    memcpy(&text, static_cast<const uint8_t *>(holder) + kHolderStringOffset, sizeof(text));
    if (!text || !IsAddressRangeReadable(text, 24)) return nullptr;
    return text;
}

void AppendCDATA(std::string *out, const std::string &text) {
    *out += "<![CDATA[";
    size_t start = 0;
    while (start < text.size()) {
        size_t marker = text.find("]]>", start);
        if (marker == std::string::npos) {
            out->append(text, start, std::string::npos);
            break;
        }
        out->append(text, start, marker - start);
        *out += "]]]]><![CDATA[>";
        start = marker + 3;
    }
    *out += "]]>";
}

std::string SystemTipXML(const std::string &plain, NSString *session) {
    std::string xml = "<sysmsg type=\"sysmsgtemplate\"><sysmsgtemplate>"
                      "<content_template type=\"tmpl_type_profile\">"
                      "<plain><![CDATA[]]></plain><template>";
    AppendCDATA(&xml, plain);
    xml += "</template><link_list></link_list>"
           "</content_template></sysmsgtemplate></sysmsg>";
    if (EndsWithChatroom(session) && session.length > 0) {
        std::string prefix = std::string(session.UTF8String ?: "") + ":\n";
        if (xml.compare(0, prefix.size(), prefix) != 0) xml = prefix + xml;
    }
    return xml;
}

bool WriteSourceType(void *source, uint32_t type) {
    auto *slot = static_cast<uint8_t *>(source) + kSourceTypeOffset;
    if (!IsAddressRangeReadable(slot, sizeof(type))) return false;
    memcpy(slot, &type, sizeof(type));
    return true;
}

}  // namespace

static NSString *CachedPersonName(NSString *userName) {
    if (userName.length == 0 || EndsWithChatroom(userName)) return nil;
    NSString *name = WCRContactNameDisplay(userName);
    if (name.length == 0 || [name isEqualToString:userName] || EndsWithChatroom(name)) return nil;
    return name;
}

static NSString *BlockTipText(NSString *sender, NSString *seenName, NSString *typeKey) {
    NSString *name = CachedPersonName(sender);
    if (name.length == 0 && HumanName(seenName)) name = TrimmedString(seenName);
    if (name.length == 0 && sender.length > 0 && !EndsWithChatroom(sender)) name = sender;
    if (name.length == 0) name = @"成员";
    NSString *typeTitle = WCRMessageBlockTitleForTypeKey(typeKey);
    if (typeTitle.length == 0) typeTitle = @"消息";
    return [NSString stringWithFormat:@"已屏蔽 %@ 的%@", name, typeTitle];
}

/// 解析前把源记录改成系统提示。失败时保持原样，过滤桩会丢掉这条消息。
static BOOL RewriteSourceAsSystemTip(void *source,
                                     NSString *sender,
                                     NSString *seenName,
                                     NSString *session,
                                     NSString *typeKey) {
    if (!gStringAssign) return NO;
    const void *content = HolderString(source, kSourceContentHolderOffset);
    if (!content) return NO;
    try {
        NSString *text = BlockTipText(sender, seenName, typeKey);
        const char *bytes = text.UTF8String;
        if (!bytes || bytes[0] == '\0') return NO;
        std::string xml = SystemTipXML(std::string(bytes), session);
        if (xml.empty()) return NO;
        gStringAssign(const_cast<void *>(content), &xml);
        return WriteSourceType(source, kSystemTipType);
    } catch (...) {
        return NO;
    }
}

extern "C" {

__attribute__((visibility("hidden"))) void *gWCRMessageBlockTrampoline = nullptr;

BOOL WCRMessageBlockShouldFilterMessageObject(const void *message) {
    @autoreleasepool {
        try {
            if (!message || !WCRMessageBlockEnabled()) return NO;

            uint32_t type = 0;
            if (!ReadMessageType(message, &type)) return NO;

            std::string fromBytes;
            std::string toBytes;
            if (!ReadLibcppStringAt(message, kMessageFromOffset, fromBytes) ||
                !ReadLibcppStringAt(message, kMessageToOffset, toBytes)) {
                return NO;
            }
            NSString *from = StringFromUTF8(fromBytes);
            NSString *to = StringFromUTF8(toBytes);
            bool system = type == kSystemTipType || type == kSystemCommandType;
            bool grouped = EndsWithChatroom(from) || EndsWithChatroom(to);
            NSString *content = nil;
            if (system || grouped || type == 49) {
                content = StringAt(message, kMessageContentOffset, kMaxContentBytes);
            }
            NSString *push = (system || grouped) ? StringAt(message, kMessagePushOffset, 512) : nil;
            // 10000/10002 里只有拍一拍进入屏蔽。改写成功的提示也是 10000，
            // 正文不含拍了拍，这里会放行。不能再改已经解析好的消息。
            return ShouldDropInbound(type, from, to, content, push, nullptr, nullptr, nullptr);
        } catch (...) {
            // 过滤判断失败时放行，不能把插件异常带进微信消息管线。
            return NO;
        }
    }
}

/// 裸桩：调用方把上下文放在 x0、消息对象放在 x1。
/// 270351 的调用点是 `mov x0, x26; add x1, sp, #0x210; bl`，
/// 返回值 bit0 为 1 时跳过写库。只检查 x0 会读到上下文，屏蔽永远不命中。
__attribute__((naked)) static void WCRMessageBlockStub(void) {
    __asm__ volatile(
        "stp x29, x30, [sp, #-48]!\n"
        "stp x0, x1, [sp, #16]\n"
        "mov x0, x1\n"
        "bl _WCRMessageBlockShouldFilterMessageObject\n"
        "cbnz w0, 1f\n"
        "ldp x0, x1, [sp, #16]\n"
        "ldp x29, x30, [sp], #48\n"
        "adrp x16, _gWCRMessageBlockTrampoline@PAGE\n"
        "ldr x16, [x16, _gWCRMessageBlockTrampoline@PAGEOFF]\n"
        "br x16\n"
        "1:\n"
        "mov w0, #1\n"
        "ldp x29, x30, [sp], #48\n"
        "ret\n"
    );
}

/// 解析器入口：x1 是源记录。改写必须发生在微信把类型和正文抄进消息之前。
__attribute__((naked)) static void WCRMessageBlockPrepareStub(void) {
    __asm__ volatile(
        "stp x29, x30, [sp, #-32]!\n"
        "stp x0, x1, [sp, #16]\n"
        "mov x0, x1\n"
        "bl _WCRMessageBlockPrepareSource\n"
        "ldp x0, x1, [sp, #16]\n"
        "ldp x29, x30, [sp], #32\n"
        "adrp x16, _gWCRMessageBlockPrepareTrampoline@PAGE\n"
        "ldr x16, [x16, _gWCRMessageBlockPrepareTrampoline@PAGEOFF]\n"
        "br x16\n"
    );
}

__attribute__((visibility("hidden"))) void *gWCRMessageBlockPrepareTrampoline = nullptr;

void WCRMessageBlockPrepareSource(void *source) {
    if (!source || !gStringAssign || !WCRMessageBlockEnabled()) return;
    @autoreleasepool {
        try {
            if (!WCRMessageBlockShowTip()) return;
            auto *base = static_cast<uint8_t *>(source);
            if (!IsAddressRangeReadable(base + kSourceTypeOffset, sizeof(uint32_t))) return;
            uint32_t type = 0;
            memcpy(&type, base + kSourceTypeOffset, sizeof(type));

            const void *fromSlot = HolderString(source, kSourceFromHolderOffset);
            const void *toSlot = HolderString(source, kSourceToHolderOffset);
            std::string fromBytes;
            std::string toBytes;
            if (!fromSlot || !toSlot ||
                !ReadLibcppStringAt(fromSlot, 0, fromBytes) ||
                !ReadLibcppStringAt(toSlot, 0, toBytes)) {
                return;
            }
            NSString *from = StringFromUTF8(fromBytes);
            NSString *to = StringFromUTF8(toBytes);
            bool system = type == kSystemTipType || type == kSystemCommandType;
            bool grouped = EndsWithChatroom(from) || EndsWithChatroom(to);
            NSString *content = nil;
            if (system || grouped || type == 49) {
                const void *contentSlot = HolderString(source, kSourceContentHolderOffset);
                if (contentSlot) content = StringAt(contentSlot, 0, kMaxContentBytes);
            }
            NSString *push = (system || grouped) ? SourcePushText(source) : nil;
            NSString *session = nil;
            MessageParty party{nil, nil};
            NSString *typeKey = nil;
            if (!ShouldDropInbound(type, from, to, content, push, &session, &party, &typeKey)) {
                return;
            }
            RewriteSourceAsSystemTip(source, party.userName, party.seenName, session, typeKey);
        } catch (...) {
        }
    }
}

}  // extern "C"

BOOL WCRMessageBlockEnabled(void) {
    id stored = [[NSUserDefaults standardUserDefaults]
        objectForKey:kWCRMessageBlockEnabledDefaultsKey];
    return stored ? [stored boolValue] : NO;
}

void WCRMessageBlockSetEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled
                                           forKey:kWCRMessageBlockEnabledDefaultsKey];
}

NSArray<NSString *> *WCRMessageBlockSessions(void) {
    id stored = [[NSUserDefaults standardUserDefaults]
        objectForKey:kWCRMessageBlockSessionsDefaultsKey];
    if (![stored isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id item in (NSArray *)stored) {
        NSString *value = TrimmedString(item);
        if (!ValidSessionID(value) || [seen containsObject:value]) continue;
        [seen addObject:value];
        [result addObject:value];
        if (result.count >= kMaxSessionIDs) break;
    }
    return result;
}

BOOL WCRMessageBlockIsSessionBlocked(NSString *session) {
    NSString *value = TrimmedString(session);
    if (!ValidSessionID(value)) return NO;
    return [WCRMessageBlockSessions() containsObject:value];
}

BOOL WCRMessageBlockSetSessionBlocked(NSString *session, BOOL blocked) {
    NSString *value = TrimmedString(session);
    if (!ValidSessionID(value)) return NO;

    NSMutableArray<NSString *> *rows = [WCRMessageBlockSessions() mutableCopy];
    NSUInteger index = [rows indexOfObject:value];
    if (blocked) {
        if (index != NSNotFound) return YES;
        if (rows.count >= kMaxSessionIDs) return NO;
        [rows addObject:value];
    } else {
        if (index == NSNotFound) {
            WCRMessageBlockSetCustomTypesForSession(value, nil);
            return YES;
        }
        [rows removeObjectAtIndex:index];
    }
    [[NSUserDefaults standardUserDefaults] setObject:rows
                                              forKey:kWCRMessageBlockSessionsDefaultsKey];
    if (!blocked) WCRMessageBlockSetCustomTypesForSession(value, nil);
    return YES;
}

void WCRMessageBlockClearSessions(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:kWCRMessageBlockSessionsDefaultsKey];
    [defaults removeObjectForKey:kWCRMessageBlockSessionTypesDefaultsKey];
}

BOOL WCRMessageBlockValidSessionID(NSString *session) {
    return ValidSessionID(TrimmedString(session));
}

static NSDictionary<NSString *, NSArray<NSString *> *> *SessionTypeMap(void);

BOOL WCRMessageBlockReplaceSessions(NSArray<NSString *> *sessions) {
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id item in sessions) {
        NSString *value = TrimmedString(item);
        if (!ValidSessionID(value) || [seen containsObject:value]) continue;
        if (rows.count >= kMaxSessionIDs) return NO;
        [seen addObject:value];
        [rows addObject:value];
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:rows forKey:kWCRMessageBlockSessionsDefaultsKey];
    NSMutableDictionary *types = [SessionTypeMap() mutableCopy] ?: [NSMutableDictionary dictionary];
    NSSet<NSString *> *alive = [NSSet setWithArray:rows];
    for (NSString *key in types.allKeys) {
        if (![alive containsObject:key]) [types removeObjectForKey:key];
    }
    if (types.count == 0) {
        [defaults removeObjectForKey:kWCRMessageBlockSessionTypesDefaultsKey];
    } else {
        [defaults setObject:types forKey:kWCRMessageBlockSessionTypesDefaultsKey];
    }
    return YES;
}

NSArray<NSString *> *WCRMessageBlockAllTypeKeys(void) {
    return @[
        kWCRMessageBlockTypeRedPacket,
        kWCRMessageBlockTypeTransfer,
        kWCRMessageBlockTypeText,
        kWCRMessageBlockTypeRefer,
        kWCRMessageBlockTypeImage,
        kWCRMessageBlockTypeVoice,
        kWCRMessageBlockTypeVideo,
        kWCRMessageBlockTypeEmoticon,
        kWCRMessageBlockTypePat,
        kWCRMessageBlockTypeFile,
        kWCRMessageBlockTypeContact,
        kWCRMessageBlockTypeLocation,
        kWCRMessageBlockTypeChatRecord,
        kWCRMessageBlockTypeLink,
        kWCRMessageBlockTypeMusic,
        kWCRMessageBlockTypeOther,
    ];
}

NSString *WCRMessageBlockTitleForTypeKey(NSString *typeKey) {
    NSString *key = TrimmedString(typeKey);
    static NSDictionary<NSString *, NSString *> *titles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        titles = @{
            kWCRMessageBlockTypeText: @"文本",
            kWCRMessageBlockTypeRefer: @"引用",
            kWCRMessageBlockTypeImage: @"图片",
            kWCRMessageBlockTypeVoice: @"语音",
            kWCRMessageBlockTypeVideo: @"视频",
            kWCRMessageBlockTypeEmoticon: @"表情",
            kWCRMessageBlockTypePat: @"拍一拍",
            kWCRMessageBlockTypeFile: @"文件",
            kWCRMessageBlockTypeContact: @"名片",
            kWCRMessageBlockTypeLocation: @"位置",
            kWCRMessageBlockTypeChatRecord: @"聊天记录",
            kWCRMessageBlockTypeLink: @"链接卡片",
            kWCRMessageBlockTypeMusic: @"音乐卡片",
            kWCRMessageBlockTypeRedPacket: @"红包",
            kWCRMessageBlockTypeTransfer: @"转账",
            kWCRMessageBlockTypeOther: @"其他",
        };
    });
    return titles[key] ?: key;
}

NSArray<NSString *> *WCRMessageBlockSelectedTypes(void) {
    id stored = [[NSUserDefaults standardUserDefaults]
        objectForKey:kWCRMessageBlockTypesDefaultsKey];
    if (![stored isKindOfClass:[NSArray class]]) return @[];
    NSSet<NSString *> *allowed = [NSSet setWithArray:WCRMessageBlockAllTypeKeys()];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (NSString *key in WCRMessageBlockAllTypeKeys()) {
        if ([allowed containsObject:key] && [(NSArray *)stored containsObject:key]) {
            [result addObject:key];
        }
    }
    if (result.count >= WCRMessageBlockAllTypeKeys().count) return @[];
    return result;
}

void WCRMessageBlockSetSelectedTypes(NSArray<NSString *> *types) {
    NSSet<NSString *> *wanted = [NSSet setWithArray:types ?: @[]];
    NSMutableArray<NSString *> *ordered = [NSMutableArray array];
    for (NSString *key in WCRMessageBlockAllTypeKeys()) {
        if ([wanted containsObject:key]) [ordered addObject:key];
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (ordered.count == 0 || ordered.count >= WCRMessageBlockAllTypeKeys().count) {
        [defaults removeObjectForKey:kWCRMessageBlockTypesDefaultsKey];
        return;
    }
    [defaults setObject:ordered forKey:kWCRMessageBlockTypesDefaultsKey];
}

NSString *WCRMessageBlockTypeSummary(void) {
    NSArray<NSString *> *selected = WCRMessageBlockSelectedTypes();
    NSArray<NSString *> *all = WCRMessageBlockAllTypeKeys();
    if (selected.count == 0 || selected.count >= all.count) return @"全部类型";
    if (selected.count > 3) {
        return [NSString stringWithFormat:@"已选 %lu 类", (unsigned long)selected.count];
    }
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSString *key in selected) {
        [titles addObject:WCRMessageBlockTitleForTypeKey(key)];
    }
    return [titles componentsJoinedByString:@"/"];
}

BOOL WCRMessageBlockTypeIsSelected(NSString *typeKey) {
    NSString *key = TrimmedString(typeKey);
    if (key.length == 0) return NO;
    NSArray<NSString *> *selected = WCRMessageBlockSelectedTypes();
    if (selected.count == 0) return YES;
    return [selected containsObject:key];
}

static NSArray<NSString *> *SanitizeTypeList(id stored) {
    if (![stored isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (NSString *key in WCRMessageBlockAllTypeKeys()) {
        if ([(NSArray *)stored containsObject:key]) [result addObject:key];
    }
    return result;
}

static NSDictionary<NSString *, NSArray<NSString *> *> *SessionTypeMap(void) {
    id stored = [[NSUserDefaults standardUserDefaults]
        objectForKey:kWCRMessageBlockSessionTypesDefaultsKey];
    if (![stored isKindOfClass:[NSDictionary class]]) return @{};
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *result = [NSMutableDictionary dictionary];
    [(NSDictionary *)stored enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        (void)stop;
        NSString *session = TrimmedString(key);
        if (!ValidSessionID(session)) return;
        NSArray<NSString *> *types = SanitizeTypeList(obj);
        if (!types) return;
        result[session] = types;
    }];
    return result;
}

static void WriteSessionTypeMap(NSDictionary<NSString *, NSArray<NSString *> *> *map) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (map.count == 0) {
        [defaults removeObjectForKey:kWCRMessageBlockSessionTypesDefaultsKey];
        return;
    }
    [defaults setObject:map forKey:kWCRMessageBlockSessionTypesDefaultsKey];
}

BOOL WCRMessageBlockSessionUsesCustomTypes(NSString *session) {
    NSString *value = TrimmedString(session);
    if (!ValidSessionID(value)) return NO;
    return SessionTypeMap()[value] != nil;
}

NSArray<NSString *> *WCRMessageBlockCustomTypesForSession(NSString *session) {
    NSString *value = TrimmedString(session);
    if (!ValidSessionID(value)) return nil;
    return SessionTypeMap()[value];
}

void WCRMessageBlockSetCustomTypesForSession(NSString *session, NSArray<NSString *> *types) {
    NSString *value = TrimmedString(session);
    if (!ValidSessionID(value)) return;
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *map =
        [SessionTypeMap() mutableCopy] ?: [NSMutableDictionary dictionary];
    if (!types) {
        [map removeObjectForKey:value];
    } else {
        map[value] = SanitizeTypeList(types) ?: @[];
    }
    WriteSessionTypeMap(map);
}

BOOL WCRMessageBlockTypeIsSelectedForSession(NSString *session, NSString *typeKey) {
    NSString *key = TrimmedString(typeKey);
    if (key.length == 0) return NO;
    if (WCRMessageBlockSessionUsesCustomTypes(session)) {
        return [WCRMessageBlockCustomTypesForSession(session) containsObject:key];
    }
    return WCRMessageBlockTypeIsSelected(key);
}

BOOL WCRMessageBlockShowTip(void) {
    id stored = [[NSUserDefaults standardUserDefaults]
        objectForKey:kWCRMessageBlockShowTipDefaultsKey];
    return stored ? [stored boolValue] : NO;
}

void WCRMessageBlockSetShowTip(BOOL show) {
    [[NSUserDefaults standardUserDefaults] setBool:show
                                           forKey:kWCRMessageBlockShowTipDefaultsKey];
}

NSString *WCRMessageBlockTypeKeyForMessageType(uint32_t messageType, NSString *content) {
    NSString *safe = [content isKindOfClass:[NSString class]] ? content : @"";
    switch (messageType) {
        case 1:
            return kWCRMessageBlockTypeText;
        case 3:
            return kWCRMessageBlockTypeImage;
        case 34:
            return kWCRMessageBlockTypeVoice;
        case 42:
            return kWCRMessageBlockTypeContact;
        case 43:
        case 50:
            return kWCRMessageBlockTypeVideo;
        case 47:
            return kWCRMessageBlockTypeEmoticon;
        case 48:
            return kWCRMessageBlockTypeLocation;
        case 76:
            return kWCRMessageBlockTypeMusic;
        case 2000:
        case 419430449:
            return kWCRMessageBlockTypeTransfer;
        case 2001:
        case 436207665:
        case 469762097:
            return kWCRMessageBlockTypeRedPacket;
        case 49:
            break;
        case 10000:
        case 10002:
            return nil;
        default:
            return kWCRMessageBlockTypeOther;
    }

    NSInteger inner = FirstAppMsgInnerType(safe);
    NSString *low = safe.lowercaseString;
    if (inner == 57 || [low containsString:@"<refermsg"]) return kWCRMessageBlockTypeRefer;
    if (inner == 19) return kWCRMessageBlockTypeChatRecord;
    if (inner == 76) return kWCRMessageBlockTypeMusic;
    if (inner == 2000) return kWCRMessageBlockTypeTransfer;
    if (inner == 2001) return kWCRMessageBlockTypeRedPacket;
    if ([low containsString:@"receivehongbao"] || [low containsString:@"<hongbao"] ||
        [low containsString:@"<wchongbao"] || [low containsString:@"nativehongbao"] ||
        [low containsString:@"hongbaoconfig"] ||
        [low containsString:@"c2cbizmessagehandler/hongbao"]) {
        return kWCRMessageBlockTypeRedPacket;
    }
    if ([low containsString:@"transfer_id"] || [low containsString:@"<transfer"] ||
        [low containsString:@"c2ctransfer"]) {
        return kWCRMessageBlockTypeTransfer;
    }
    if (inner == 40 || inner == 42) return kWCRMessageBlockTypeContact;
    if (inner == 43 || inner == 44 || inner == 45) return kWCRMessageBlockTypeVideo;
    if (inner == 6 || inner == 8 || inner == 74) return kWCRMessageBlockTypeFile;
    if (inner == 48) return kWCRMessageBlockTypeLocation;
    if (inner == 5 || inner == 33 || inner == 36 || inner == 51 || inner == 63) {
        return kWCRMessageBlockTypeLink;
    }
    return kWCRMessageBlockTypeOther;
}

NSString *WCRMessageBlockResolveSession(NSString *fromUser,
                                        NSString *toUser,
                                        NSString *selfUser) {
    NSString *from = TrimmedString(fromUser);
    NSString *to = TrimmedString(toUser);
    NSString *self = TrimmedString(selfUser);
    if (from.length == 0 && to.length == 0) return nil;

    // 自己发出的消息不参与屏蔽，避免从其他设备同步的回显被吞掉。
    if (self.length > 0 && [from isEqualToString:self]) return nil;

    if (EndsWithChatroom(from)) return from;
    if (EndsWithChatroom(to)) return to;

    if (self.length > 0) {
        if ([to isEqualToString:self]) return from.length > 0 ? from : nil;
        if ([from isEqualToString:self]) return nil;
    }
    return from.length > 0 ? from : to;
}

BOOL WCRMessageBlockSupportsProfile(const WCRPatchProfile *profile) {
    return profile && profile->messageFilterAddress != 0;
}

static BOOL InstallEntryHook(uint8_t *entry,
                             const uint8_t expected[kEntryBytes],
                             void *stub,
                             uint8_t saved[kEntryBytes],
                             uint8_t **entryOut,
                             void **trampolineOut,
                             uintptr_t *trampolineEntryOut,
                             void **publishedTrampoline,
                             NSString *mismatch,
                             NSError **error) {
    if (!IsAddressRangeReadable(entry, kEntryBytes) ||
        memcmp(entry, expected, kEntryBytes) != 0) {
        if (error) *error = MessageBlockError(mismatch);
        return NO;
    }
    if (!*trampolineOut || *trampolineEntryOut != reinterpret_cast<uintptr_t>(entry)) {
        void *trampoline = mmap(nullptr, kTrampolineBytes, PROT_READ | PROT_WRITE,
                                MAP_ANON | MAP_PRIVATE, -1, 0);
        if (trampoline == MAP_FAILED) {
            if (error) *error = MessageBlockError(@"无法分配消息屏蔽跳板");
            return NO;
        }
        uint8_t *bytes = static_cast<uint8_t *>(trampoline);
        memcpy(bytes, entry, kEntryBytes);
        const uint32_t tail[2] = {0x58000050u, 0xD61F0200u};  // ldr x16,#8; br x16
        memcpy(bytes + 16, tail, sizeof(tail));
        uint64_t resume = reinterpret_cast<uint64_t>(entry) + kEntryBytes;
        memcpy(bytes + 24, &resume, sizeof(resume));
        sys_icache_invalidate(bytes, kTrampolineBytes);
        if (mprotect(trampoline, kTrampolineBytes, PROT_READ | PROT_EXEC) != 0) {
            munmap(trampoline, kTrampolineBytes);
            if (error) *error = MessageBlockError(@"无法锁定消息屏蔽跳板");
            return NO;
        }
        *trampolineOut = trampoline;
        *trampolineEntryOut = reinterpret_cast<uintptr_t>(entry);
    }

    uint8_t patch[kEntryBytes] = {};
    const uint32_t head[2] = {0x58000051u, 0xD61F0220u};  // ldr x17,#8; br x17
    memcpy(patch, head, sizeof(head));
    uint64_t stubAddress = reinterpret_cast<uint64_t>(stub);
    memcpy(patch + 8, &stubAddress, sizeof(stubAddress));
    memcpy(saved, entry, kEntryBytes);
    *entryOut = entry;
    if (publishedTrampoline) *publishedTrampoline = *trampolineOut;
    if (!WCRPatchCodeBytes(entry, patch, sizeof(patch), error)) {
        *entryOut = nullptr;
        if (publishedTrampoline) *publishedTrampoline = nullptr;
        return NO;
    }
    return YES;
}

BOOL WCRMessageBlockInstall(const WCRPatchProfile *profile, NSError **error) {
    if (gInstalled.load()) return YES;
    if (!WCRMessageBlockSupportsProfile(profile)) {
        if (error) *error = MessageBlockError(
            @"当前微信构建尚未登记消息过滤入口，消息屏蔽保持关闭");
        return NO;
    }

    uintptr_t wechatSlide = 0;
    bool found = false;
    for (uint32_t index = 0; index < _dyld_image_count(); ++index) {
        const char *name = _dyld_get_image_name(index);
        if (name && strstr(name, "/wechat.dylib")) {
            wechatSlide = static_cast<uintptr_t>(_dyld_get_image_vmaddr_slide(index));
            found = true;
            break;
        }
    }
    if (!found) {
        if (error) *error = MessageBlockError(@"wechat.dylib 尚未加载");
        return NO;
    }

    if (profile->messagePrepareAddress != 0) {
        if (profile->messageStringAssignAddress == 0) {
            if (error) *error = MessageBlockError(
                @"当前微信构建缺字符串赋值入口，消息屏蔽保持关闭");
            return NO;
        }
        uint8_t expected[kEntryBytes] = {};
        for (size_t index = 0; index < 4; ++index) {
            memcpy(expected + index * sizeof(uint32_t),
                   &profile->messagePreparePrologue[index], sizeof(uint32_t));
        }
        auto *prepare = reinterpret_cast<uint8_t *>(wechatSlide + profile->messagePrepareAddress);
        gStringAssign = reinterpret_cast<StringAssignFn>(
            wechatSlide + profile->messageStringAssignAddress);
        if (!InstallEntryHook(prepare, expected,
                              reinterpret_cast<void *>(&WCRMessageBlockPrepareStub),
                              gPrepareSaved, &gPrepareEntry, &gPrepareTrampoline,
                              &gPrepareTrampolineEntry, &gWCRMessageBlockPrepareTrampoline,
                              @"消息解析入口字节不匹配，拒绝安装消息屏蔽 Hook",
                              error)) {
            gStringAssign = nullptr;
            return NO;
        }
    }

    uint8_t expected[kEntryBytes] = {};
    for (size_t index = 0; index < sizeof(profile->messageFilterPrologue) / sizeof(uint32_t); ++index) {
        memcpy(expected + index * sizeof(uint32_t),
               &profile->messageFilterPrologue[index], sizeof(uint32_t));
    }
    auto *entry = reinterpret_cast<uint8_t *>(wechatSlide + profile->messageFilterAddress);
    if (!InstallEntryHook(entry, expected,
                          reinterpret_cast<void *>(&WCRMessageBlockStub),
                          gSavedEntry, &gEntry, &gTrampoline, &gTrampolineEntry,
                          &gWCRMessageBlockTrampoline,
                          @"消息过滤入口字节不匹配，拒绝安装消息屏蔽 Hook",
                          error)) {
        if (gPrepareEntry) {
            WCRPatchCodeBytes(gPrepareEntry, gPrepareSaved, sizeof(gPrepareSaved), nullptr);
            gPrepareEntry = nullptr;
            gWCRMessageBlockPrepareTrampoline = nullptr;
        }
        gStringAssign = nullptr;
        return NO;
    }
    gInstalled.store(true);
    return YES;
}

BOOL WCRMessageBlockUninstall(NSError **error) {
    if (!gInstalled.load()) return YES;
    if (gPrepareEntry &&
        !WCRPatchCodeBytes(gPrepareEntry, gPrepareSaved, sizeof(gPrepareSaved), error)) {
        return NO;
    }
    if (gEntry && !WCRPatchCodeBytes(gEntry, gSavedEntry, sizeof(gSavedEntry), error)) {
        return NO;
    }
    gInstalled.store(false);
    gEntry = nullptr;
    gPrepareEntry = nullptr;
    gWCRMessageBlockTrampoline = nullptr;
    gWCRMessageBlockPrepareTrampoline = nullptr;
    gStringAssign = nullptr;
    return YES;
}

BOOL WCRMessageBlockIsInstalled(void) {
    return gInstalled.load();
}
