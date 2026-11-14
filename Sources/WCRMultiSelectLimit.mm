#import "WCRMultiSelectLimit.h"

#import "WCRCodePatch.h"

#import <atomic>
#import <cstring>
#import <mach-o/dyld.h>

namespace {

// movz w8, #100 / movz w8, #9999。9999 = 0x270F，编码 0x52800000 | (imm16 << 5) | 8。
constexpr uint32_t kMovLimit100 = 0x52800C88u;
constexpr uint32_t kMovLimit9999 = 0x5284E1E8u;
// 0x49dab28 的 b.lo #+12。改成无条件 b 后仍落到体积检查，不再写错误码 2。
// 101 条记录是 1616 字节，cmp 立即数装不下 9999*16，所以直接跳过条数判断。
constexpr uint32_t kCountBranch = 0x54000063u;
constexpr uint32_t kCountBranchBypass = 0x14000003u;
constexpr uint32_t kLdrControllerLimit = 0xB9403A68u;  // ldr w8, [x19, #0x38]
constexpr uint32_t kLdrTooltipCount = 0xB9420268u;     // ldr w8, [x19, #0x200]
// 0x9459e0 的 b.lt #+0x94。改成无条件 b 后走到允许分支，不再弹「最多选择100条」。
// 270390 的位移不同。安装时按窗口里的 b.cond 自己算无条件跳转，条件仍必须是 lt / lo。
constexpr uint32_t kReachBranch = 0x540004ABu;
constexpr uint32_t kReachBranchBypass = 0x14000025u;
static_assert((kCountBranch & 0xFF000010u) == 0x54000000u && (kCountBranch & 0xFu) == 0x3u, "转发条数必须是 b.lo");
static_assert((0x14000000u | ((kCountBranch >> 5) & 0x7FFFFu)) == kCountBranchBypass, "270351 转发绕过字节变了");
static_assert((kReachBranch & 0xFF000010u) == 0x54000000u && (kReachBranch & 0xFu) == 0xBu, "选择到这里必须是 b.lt");
static_assert((0x14000000u | ((kReachBranch >> 5) & 0x7FFFFu)) == kReachBranchBypass, "270351 选择到这里绕过字节变了");
constexpr size_t kGatePatchIndex = 3;
constexpr size_t kReachPatchIndex = 5;
constexpr int kSiteCount = 8;

std::atomic_bool gInstalled(false);

struct SavedWord {
    uint8_t *address;
    uint32_t original;
};

SavedWord gSaved[kSiteCount];

NSError *WCRMultiSelectError(NSString *message) {
    return [NSError errorWithDomain:@"WCRefineMac.MultiSelectLimit"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"多选突破错误"}];
}

bool WCRFindWeChatSlide(uintptr_t *slide) {
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "/wechat.dylib")) {
            *slide = static_cast<uintptr_t>(_dyld_get_image_vmaddr_slide(i));
            return true;
        }
    }
    return false;
}

struct Site {
    uint64_t address;
    const uint32_t *window;
    size_t count;
    size_t patchIndex;
    uint32_t expected;
    uint32_t replacement;
    const char *name;
};

NSString *WCRHexBytes(const uint8_t *bytes, size_t length) {
    NSMutableString *text = [NSMutableString string];
    for (size_t i = 0; i < length; ++i) [text appendFormat:@"%02x", bytes[i]];
    return text;
}

}  // namespace

BOOL WCRMultiSelectLimitSupportsProfile(const WCRPatchProfile *profile) {
    return profile &&
           profile->multiSelectControllerAddress != 0 &&
           profile->multiSelectTipAddress != 0 &&
           profile->multiSelectForwardGateAddress != 0 &&
           profile->multiSelectTooltipAddress != 0 &&
           profile->multiSelectCountGateAddress != 0 &&
           profile->multiSelectRangeGateAddress != 0 &&
           profile->multiSelectOverflowGateAddress != 0 &&
           profile->multiSelectReachGateAddress != 0;
}

BOOL WCRMultiSelectLimitInstall(const WCRPatchProfile *profile, NSError **error) {
    if (gInstalled.load()) return YES;
    if (!WCRMultiSelectLimitSupportsProfile(profile)) {
        if (error) *error = WCRMultiSelectError(@"当前微信构建尚未登记多选突破");
        return NO;
    }

    uintptr_t slide = 0;
    if (!WCRFindWeChatSlide(&slide)) {
        if (error) *error = WCRMultiSelectError(@"wechat.dylib 尚未加载");
        return NO;
    }

    const Site sites[kSiteCount] = {
        {profile->multiSelectControllerAddress, profile->multiSelectControllerWindow,
         4, 0, kMovLimit100, kMovLimit9999, "多选上限"},
        {profile->multiSelectTipAddress, profile->multiSelectTipWindow,
         4, 0, kMovLimit100, kMovLimit9999, "多选提示"},
        {profile->multiSelectForwardGateAddress, profile->multiSelectForwardGateWindow,
         8, kGatePatchIndex, kCountBranch, kCountBranchBypass, "转发条数"},
        // 下面四处读的是对象里已经写下的 100。聊天视图经常比补丁更早建好。
        {profile->multiSelectTooltipAddress, profile->multiSelectTooltipWindow,
         4, 0, kLdrTooltipCount, kMovLimit9999, "多选提示条数"},
        {profile->multiSelectCountGateAddress, profile->multiSelectCountGateWindow,
         4, 0, kLdrControllerLimit, kMovLimit9999, "多选条数拒绝"},
        {profile->multiSelectRangeGateAddress, profile->multiSelectRangeGateWindow,
         4, 0, kLdrControllerLimit, kMovLimit9999, "多选范围累加"},
        {profile->multiSelectOverflowGateAddress, profile->multiSelectOverflowGateWindow,
         4, 0, kLdrControllerLimit, kMovLimit9999, "多选溢出判断"},
        {profile->multiSelectReachGateAddress, profile->multiSelectReachGateWindow,
         6, kReachPatchIndex, kReachBranch, kReachBranchBypass, "选择到这里"},
    };

    uint8_t *entries[kSiteCount] = {};
    uint32_t replacements[kSiteCount] = {};
    uint32_t originals[kSiteCount] = {};
    for (int i = 0; i < kSiteCount; ++i) {
        const Site &site = sites[i];
        uint8_t *entry = reinterpret_cast<uint8_t *>(slide + site.address);
        const size_t length = site.count * sizeof(uint32_t);
        const uint32_t original = site.window[site.patchIndex];
        const bool forwardGate = site.address == profile->multiSelectForwardGateAddress;
        const bool reachGate = site.address == profile->multiSelectReachGateAddress;
        bool wordOK = original == site.expected;
        uint32_t replacement = site.replacement;
        if (forwardGate || reachGate) {
            const uint32_t cond = original & 0xFu;
            const uint32_t imm19 = (original >> 5) & 0x7FFFFu;
            const uint32_t want = reachGate ? 0xBu : 0x3u;
            wordOK = (original & 0xFF000010u) == 0x54000000u && cond == want;
            replacement = 0x14000000u | imm19;
        }
        if (memcmp(entry, site.window, length) != 0 || !wordOK) {
            if (error) {
                *error = WCRMultiSelectError([NSString stringWithFormat:
                    @"%s入口字节不匹配（当前 %@）",
                    site.name, WCRHexBytes(entry, length)]);
            }
            return NO;
        }
        entries[i] = entry + site.patchIndex * sizeof(uint32_t);
        replacements[i] = replacement;
        originals[i] = original;
    }

    SavedWord applied[kSiteCount];
    int appliedCount = 0;
    for (int i = 0; i < kSiteCount; ++i) {
        NSError *patchError = nil;
        if (!WCRPatchCodeBytes(entries[i], &replacements[i], sizeof(uint32_t), &patchError)) {
            for (int j = appliedCount - 1; j >= 0; --j) {
                WCRPatchCodeBytes(applied[j].address, &applied[j].original, sizeof(uint32_t), nullptr);
            }
            if (error) *error = patchError;
            return NO;
        }
        applied[appliedCount++] = {entries[i], originals[i]};
    }

    for (int i = 0; i < kSiteCount; ++i) gSaved[i] = applied[i];
    gInstalled.store(true);
    return YES;
}

BOOL WCRMultiSelectLimitUninstall(NSError **error) {
    if (!gInstalled.load()) return YES;
    for (const SavedWord &site : gSaved) {
        NSError *patchError = nil;
        if (!WCRPatchCodeBytes(site.address, &site.original, sizeof(site.original), &patchError)) {
            if (error) *error = patchError;
            return NO;
        }
    }
    gInstalled.store(false);
    return YES;
}

BOOL WCRMultiSelectLimitIsInstalled(void) {
    return gInstalled.load();
}
