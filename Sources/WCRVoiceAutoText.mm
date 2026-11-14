#import "WCRVoiceAutoText.h"

#import "WCRCodePatch.h"
#import "WCROriginalID.h"

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach-o/dyld.h>
#import <libkern/OSCacheControl.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>
#include <sys/mman.h>

// 270351 收到的语音走 ChatVoiceItemViewModel 构造函数 0x78e98c。
// x0 是视图模型，4 个参数，返回 x0。返回后 MessageData 嵌在 +0x130，不是指针。
// 270351 虚表 0xa002468。其它构建用 profile 里的 messageDataVtableAddress。
// 类型 +8，发送者 +0x10，接收者 +0x28，真正发送者 +0x40，服务器 id +0x90。
// 官方「转文字」是 sub_7954DC(视图模型, 1)。菜单用 +0x100 的最低位决定传 0 还是 1，
// 但 operator new 不会把这一位清零，所以这里不读它，固定传 1。
// 读不到消息时，私聊或群聊任一打开就转。读不到自己的 wxid 时不拦截。
// 录音条 SetState 0x93ce38 不是收到语音的路径，不要再钩。

NSString *const kWCRVoiceAutoTextPrivateEnabledKey = @"WCRefineMacVoiceAutoTextPrivateEnabled";
NSString *const kWCRVoiceAutoTextGroupEnabledKey = @"WCRefineMacVoiceAutoTextGroupEnabled";
NSString *const kWCRVoiceAutoTextIgnoreSelfEnabledKey = @"WCRefineMacVoiceAutoTextIgnoreSelfEnabled";

namespace {

constexpr size_t kPatchBytes = 16;
constexpr size_t kTrampolineBytes = 32;
constexpr uint64_t kMessageDataVtableOffset = 0xA002468;
constexpr uint64_t kMessageDataTypeOffset = 0x8;
constexpr uint64_t kMessageDataFromOffset = 0x10;
constexpr uint64_t kMessageDataToOffset = 0x28;
constexpr uint64_t kMessageDataRealSenderOffset = 0x40;
constexpr uint64_t kMessageDataServerIDOffset = 0x90;
constexpr uint64_t kViewModelMessageOffset = 0x130;
constexpr uintptr_t kPointerMask = 0x0000FFFFFFFFFFFFULL;
constexpr uint32_t kVoiceWireType = 34;
constexpr int kSeenCap = 256;
constexpr int kCallLogCap = 80;

std::atomic_bool gInstalled(false);
uint8_t gSavedEntry[kPatchBytes] = {};
uint8_t *gEntry = nullptr;
void *gTrampoline = nullptr;
uintptr_t gTrampolineEntry = 0;

using CtorFn = void *(*)(void *, uint64_t, uint64_t, uint64_t);
using TranscribeFn = int64_t (*)(void *, int);
CtorFn gOriginal = nullptr;
TranscribeFn gTranscribe = nullptr;
uintptr_t gMessageDataVtable = 0;

std::mutex gSeenMutex;
struct SeenVoice {
    uint64_t serverID = 0;
    void *viewModel = nullptr;
};
std::vector<SeenVoice> gSeen;
thread_local int gDepth = 0;

NSError *VoiceAutoError(NSString *message) {
    return [NSError errorWithDomain:@"WCRefineMac.VoiceAutoText"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"语音自动转文字错误"}];
}

bool PrefOn(NSString *key) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return stored ? [stored boolValue] : NO;
}

// 临时诊断：沙盒里 Data/tmp/wcr-voice-auto.log。确认收到语音会进这里之后再删。
void VoiceLog(const char *step, const void *bubble, uint32_t state, uint64_t mode,
              uint64_t progress, const char *detail) {
    @autoreleasepool {
        static NSString *path;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp"];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
            path = [dir stringByAppendingPathComponent:@"wcr-voice-auto.log"];
            [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        });
        if (path.length == 0) return;
        NSString *line = [NSString stringWithFormat:@"%@ %s bubble=%p state=%u mode=%llu prog=%llu %s\n",
                                                    [NSDate date], step ?: "?", bubble, state,
                                                    (unsigned long long)mode,
                                                    (unsigned long long)progress, detail ?: ""];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (data.length == 0) return;
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) {
            [data writeToFile:path atomically:NO];
            return;
        }
        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
        } @catch (__unused NSException *exception) {
        }
        [handle closeFile];
    }
}

const char *Tail(const std::string &value, char *out, size_t outSize) {
    if (!out || outSize == 0) return "";
    size_t n = value.size() > 8 ? 8 : value.size();
    size_t start = value.size() - n;
    if (n >= outSize) n = outSize - 1;
    memcpy(out, value.data() + start, n);
    out[n] = 0;
    return out;
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

bool ReadBytes(const void *object, uint64_t offset, void *out, size_t size) {
    if (!object || !out || size == 0) return false;
    const auto *slot = reinterpret_cast<const uint8_t *>(object) + offset;
    if (!IsAddressRangeReadable(slot, size)) return false;
    memcpy(out, slot, size);
    return true;
}

bool ReadU32(const void *object, uint64_t offset, uint32_t *out) {
    return ReadBytes(object, offset, out, sizeof(*out));
}

bool ReadU64(const void *object, uint64_t offset, uint64_t *out) {
    return ReadBytes(object, offset, out, sizeof(*out));
}

bool ReadLibcppString(const void *object, uint64_t offset, std::string &out) {
    const auto *slot = reinterpret_cast<const uint8_t *>(object) + offset;
    if (!IsAddressRangeReadable(slot, 24)) return false;
    const int8_t flag = static_cast<int8_t>(slot[23]);
    if (flag >= 0) {
        size_t length = static_cast<uint8_t>(flag) & 0x7F;
        if (length > 22) return false;
        out.assign(reinterpret_cast<const char *>(slot), length);
        return true;
    }
    const char *data = nullptr;
    uint64_t rawLength = 0;
    memcpy(&data, slot, sizeof(data));
    memcpy(&rawLength, slot + 8, sizeof(rawLength));
    size_t length = static_cast<size_t>(rawLength & 0x7FFFFFFFFFFFFFFFULL);
    if (!data || length == 0 || length > 8192 || !IsAddressRangeReadable(data, length)) {
        return false;
    }
    out.assign(data, length);
    return true;
}

bool IsID(const std::string &value) {
    if (value.empty() || value.size() > 128) return false;
    for (unsigned char c : value) {
        if (!(isalnum(c) || c == '_' || c == '-' || c == '@' || c == '.')) return false;
    }
    return true;
}

bool EndsWith(const std::string &value, const char *suffix) {
    size_t n = strlen(suffix);
    return value.size() >= n && value.compare(value.size() - n, n, suffix) == 0;
}

bool IsGroupID(const std::string &value) {
    return EndsWith(value, "@chatroom") || EndsWith(value, "@im.chatroom");
}

bool FindWeChatSlide(uintptr_t *slide) {
    for (uint32_t index = 0; index < _dyld_image_count(); ++index) {
        const char *name = _dyld_get_image_name(index);
        if (name && strstr(name, "/wechat.dylib")) {
            *slide = static_cast<uintptr_t>(_dyld_get_image_vmaddr_slide(index));
            return true;
        }
    }
    return false;
}

bool WindowMatches(const void *address, const uint32_t *words, size_t count) {
    size_t bytes = count * sizeof(uint32_t);
    if (!IsAddressRangeReadable(address, bytes)) return false;
    uint8_t expected[64] = {};
    if (bytes > sizeof(expected)) return false;
    for (size_t index = 0; index < count; ++index) {
        memcpy(expected + index * sizeof(uint32_t), &words[index], sizeof(uint32_t));
    }
    return memcmp(address, expected, bytes) == 0;
}

struct VoiceMessage {
    std::string from;
    std::string to;
    std::string realSender;
    uint64_t serverID = 0;
};

// MessageData：虚表 0xa002468，类型 dword 在 +8，发送者是 +0x10 的 libc++ 字符串。
bool MessageDataMatches(const void *object, VoiceMessage *out) {
    if (!object || gMessageDataVtable == 0 || !IsAddressRangeReadable(object, 0x98)) return false;
    uint64_t vtable = 0;
    if (!ReadU64(object, 0, &vtable)) return false;
    if ((vtable & kPointerMask) != (gMessageDataVtable & kPointerMask)) return false;
    uint32_t type = 0;
    if (!ReadU32(object, kMessageDataTypeOffset, &type) || type != kVoiceWireType) return false;
    std::string from;
    std::string to;
    if (!ReadLibcppString(object, kMessageDataFromOffset, from) || !IsID(from)) return false;
    if (!ReadLibcppString(object, kMessageDataToOffset, to) || !IsID(to)) return false;
    std::string realSender;
    if (ReadLibcppString(object, kMessageDataRealSenderOffset, realSender) && IsID(realSender)) {
        out->realSender = std::move(realSender);
    }
    uint64_t serverID = 0;
    ReadU64(object, kMessageDataServerIDOffset, &serverID);
    out->from = std::move(from);
    out->to = std::move(to);
    out->serverID = serverID;
    return true;
}

bool ShouldTranscribe(const VoiceMessage &message) {
    bool group = IsGroupID(message.from) || IsGroupID(message.to);
    if (group) {
        if (!PrefOn(kWCRVoiceAutoTextGroupEnabledKey)) return false;
    } else if (!PrefOn(kWCRVoiceAutoTextPrivateEnabledKey)) {
        return false;
    }
    if (!PrefOn(kWCRVoiceAutoTextIgnoreSelfEnabledKey)) return true;

    NSString *selfID = WCROriginalIDSelfWXID();
    // 还不知道自己的 wxid 时，没法证明这条是自己发的，不能因此跳过。
    if (selfID.length == 0) return true;
    std::string self(selfID.UTF8String ?: "");
    if (self.empty()) return true;
    // 群里自己发的，from 可能是群 id，真正的发送者在 +0x40。
    return message.from != self && message.realSender != self;
}

// 同一条语音滚出再滚回来会新建视图模型。服务器 id 相同就不再转一次。
// id 为 0 时只能记住这次的对象指针。
bool Claim(uint64_t serverID, void *viewModel) {
    std::lock_guard<std::mutex> lock(gSeenMutex);
    for (const SeenVoice &item : gSeen) {
        if (serverID != 0) {
            if (item.serverID == serverID) return false;
        } else if (item.viewModel == viewModel) {
            return false;
        }
    }
    if (static_cast<int>(gSeen.size()) >= kSeenCap) gSeen.erase(gSeen.begin());
    SeenVoice item;
    item.serverID = serverID;
    item.viewModel = serverID == 0 ? viewModel : nullptr;
    gSeen.push_back(item);
    return true;
}

void TranscribeViewModel(void *viewModel) {
    if (!viewModel || !gTranscribe || !gInstalled.load()) return;
    if (gDepth > 0) {
        static int reentryLogs = 0;
        if (reentryLogs < 8) {
            reentryLogs += 1;
            VoiceLog("skip", viewModel, 0, 0, 0, "reentry");
        }
        return;
    }
    if (!PrefOn(kWCRVoiceAutoTextPrivateEnabledKey) &&
        !PrefOn(kWCRVoiceAutoTextGroupEnabledKey)) {
        return;
    }

    VoiceMessage message;
    const auto *embedded = reinterpret_cast<const uint8_t *>(viewModel) + kViewModelMessageOffset;
    bool matched = MessageDataMatches(embedded, &message);
    if (matched && !ShouldTranscribe(message)) {
        static int ignoreLogs = 0;
        if (ignoreLogs < 24) {
            ignoreLogs += 1;
            char fromTail[16];
            char realTail[16];
            char detail[128];
            snprintf(detail, sizeof(detail), "ignore-self from=…%s real=…%s server=%llu",
                     Tail(message.from, fromTail, sizeof(fromTail)),
                     Tail(message.realSender, realTail, sizeof(realTail)),
                     (unsigned long long)message.serverID);
            VoiceLog("skip", viewModel, 1, message.serverID, 0, detail);
        }
        return;
    }

    uint64_t serverID = matched ? message.serverID : 0;
    if (!Claim(serverID, viewModel)) {
        static int seenLogs = 0;
        if (seenLogs < 24) {
            seenLogs += 1;
            char detail[64];
            snprintf(detail, sizeof(detail), "seen server=%llu", (unsigned long long)serverID);
            VoiceLog("skip", viewModel, matched ? 1 : 0, serverID, 0, detail);
        }
        return;
    }

    static int callLogs = 0;
    bool logThis = callLogs < kCallLogCap;
    if (logThis) callLogs += 1;
    if (logThis) {
        char detail[160];
        if (matched) {
            char fromTail[16];
            snprintf(detail, sizeof(detail), "call matched=1 from=…%s server=%llu",
                     Tail(message.from, fromTail, sizeof(fromTail)),
                     (unsigned long long)message.serverID);
        } else {
            snprintf(detail, sizeof(detail), "call matched=0");
        }
        VoiceLog("call", viewModel, matched ? 1 : 0, serverID, 1, detail);
    }

    TranscribeFn fn = gTranscribe;
    gDepth += 1;
    int64_t result = 0;
    bool threw = false;
    try {
        @try {
            result = fn(viewModel, 1);
        } @catch (__unused NSException *exception) {
            threw = true;
        }
    } catch (...) {
        threw = true;
    }
    gDepth -= 1;

    if (!logThis) return;
    if (threw) {
        VoiceLog("throw", viewModel, matched ? 1 : 0, serverID, 0, "transcribe");
        return;
    }
    char afterDetail[64];
    snprintf(afterDetail, sizeof(afterDetail), "called result=%lld", (long long)result);
    VoiceLog("called", viewModel, matched ? 1 : 0, serverID, 1, afterDetail);
}

extern "C" void WCRVoiceAutoTextNoteInstalled(void) {
    VoiceLog("install", nullptr, 0, 0, 0, "hook-on");
}

extern "C" void *WCRVoiceAutoTextViewModelHook(void *viewModel, uint64_t a2, uint64_t a3,
                                               uint64_t a4) {
    static std::atomic_bool logged{false};
    if (!logged.exchange(true)) {
        VoiceLog("hook", viewModel, 0, 0, 0, "first-view-model");
    }
    void *result = gOriginal ? gOriginal(viewModel, a2, a3, a4) : viewModel;
    if (result) {
        try {
            @try {
                TranscribeViewModel(result);
            } @catch (__unused NSException *exception) {
                VoiceLog("throw", result, 0, 0, 0, "objc");
            }
        } catch (...) {
            VoiceLog("throw", result, 0, 0, 0, "c++");
        }
    }
    return result;
}

}  // namespace

BOOL WCRVoiceAutoTextSupportsProfile(const WCRPatchProfile *profile) {
    return profile &&
           profile->voiceAutoTextSetStateAddress != 0 &&
           profile->voiceAutoTextOnClickAddress != 0;
}

BOOL WCRVoiceAutoTextInstall(const WCRPatchProfile *profile, NSError **error) {
    if (gInstalled.load()) return YES;
    if (!WCRVoiceAutoTextSupportsProfile(profile)) {
        if (error) *error = VoiceAutoError(@"当前微信构建尚未登记语音自动转文字入口");
        return NO;
    }

    uintptr_t slide = 0;
    if (!FindWeChatSlide(&slide)) {
        if (error) *error = VoiceAutoError(@"wechat.dylib 尚未加载");
        return NO;
    }

    auto *entry = reinterpret_cast<uint8_t *>(slide + profile->voiceAutoTextSetStateAddress);
    auto *transcribe = reinterpret_cast<uint8_t *>(slide + profile->voiceAutoTextOnClickAddress);
    if (!WindowMatches(entry, profile->voiceAutoTextSetStateWindow, 11) ||
        !WindowMatches(transcribe, profile->voiceAutoTextOnClickWindow, 8)) {
        if (error) *error = VoiceAutoError(@"语音自动转文字入口字节不匹配，拒绝安装");
        return NO;
    }

    if (!gTrampoline || gTrampolineEntry != reinterpret_cast<uintptr_t>(entry)) {
        void *trampoline = mmap(nullptr, kTrampolineBytes, PROT_READ | PROT_WRITE,
                                MAP_ANON | MAP_PRIVATE, -1, 0);
        if (trampoline == MAP_FAILED) {
            if (error) *error = VoiceAutoError(@"无法分配语音自动转文字跳板");
            return NO;
        }
        uint8_t *bytes = static_cast<uint8_t *>(trampoline);
        memcpy(bytes, entry, kPatchBytes);
        const uint32_t tail[2] = {0x58000050u, 0xD61F0200u};  // ldr x16, #8; br x16
        memcpy(bytes + kPatchBytes, tail, sizeof(tail));
        uint64_t resume = reinterpret_cast<uint64_t>(entry) + kPatchBytes;
        memcpy(bytes + 24, &resume, sizeof(resume));
        sys_icache_invalidate(bytes, kTrampolineBytes);
        if (mprotect(trampoline, kTrampolineBytes, PROT_READ | PROT_EXEC) != 0) {
            munmap(trampoline, kTrampolineBytes);
            if (error) *error = VoiceAutoError(@"无法锁定语音自动转文字跳板");
            return NO;
        }
        gTrampoline = trampoline;
        gTrampolineEntry = reinterpret_cast<uintptr_t>(entry);
    }

    uint8_t patch[kPatchBytes] = {};
    const uint32_t head[2] = {0x58000051u, 0xD61F0220u};  // ldr x17, #8; br x17
    memcpy(patch, head, sizeof(head));
    uint64_t stub = reinterpret_cast<uint64_t>(&WCRVoiceAutoTextViewModelHook);
    memcpy(patch + 8, &stub, sizeof(stub));

    memcpy(gSavedEntry, entry, sizeof(gSavedEntry));
    gEntry = entry;
    gOriginal = reinterpret_cast<CtorFn>(gTrampoline);
    gTranscribe = reinterpret_cast<TranscribeFn>(transcribe);
    uint64_t vtableOffset = profile->messageDataVtableAddress != 0
        ? profile->messageDataVtableAddress
        : kMessageDataVtableOffset;
    gMessageDataVtable = slide + vtableOffset;
    if (!WCRPatchCodeBytes(entry, patch, sizeof(patch), error)) {
        gEntry = nullptr;
        gOriginal = nullptr;
        gTranscribe = nullptr;
        gMessageDataVtable = 0;
        return NO;
    }
    gInstalled.store(true);
    WCRVoiceAutoTextNoteInstalled();
    return YES;
}

BOOL WCRVoiceAutoTextUninstall(NSError **error) {
    if (!gInstalled.load()) return YES;
    if (gEntry && !WCRPatchCodeBytes(gEntry, gSavedEntry, sizeof(gSavedEntry), error)) {
        return NO;
    }
    gInstalled.store(false);
    gEntry = nullptr;
    gOriginal = nullptr;
    gTranscribe = nullptr;
    gMessageDataVtable = 0;
    std::lock_guard<std::mutex> lock(gSeenMutex);
    gSeen.clear();
    return YES;
}

BOOL WCRVoiceAutoTextIsInstalled(void) {
    return gInstalled.load();
}
