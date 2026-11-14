#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WCRPatchState) {
    WCRPatchStateUnavailable = 0,
    WCRPatchStatePristine,
    WCRPatchStateApplied,
    WCRPatchStateInvalidBytes,
};

typedef struct {
    const char *shortVersion;
    const char *buildVersion;
    const char *displayVersion;
    /// Full-file SHA-256 of Contents/Resources/wechat.dylib.
    /// Version strings alone are not sufficient to identify a build.
    const char *dylibSHA256;
    uint64_t patchAddress;
    uint8_t expectedBytes[4];
    uint8_t replacementBytes[4];

    /// Optional parseRevokeXML entry and message layout for recall-tip mode.
    /// Zero means this build only supports silent anti-revoke.
    uint64_t revokeParserAddress;
    uint32_t revokePrologue[4];
    uint64_t revokeNewMsgIdOffset;
    uint64_t revokeReplaceMsgOffset;

    /// Optional common-message finalizer geometry for capturing the original
    /// content before a later revoke event arrives.
    uint64_t messageFinalizerAddress;
    uint64_t messageFinalizerContinuation;
    uint32_t messageFinalizerPrologue[4];
    uint64_t messageServerIDOffset;
    uint64_t messageTypeOffset;
    uint64_t messageContentOffset;
    /// 0 = 本构建还没核实。这是 0x278 聊天消息的时间，不是撤回解析参数。
    /// 270135 构造函数 0x4cbb198：秒在 +0x114，同一时刻的毫秒在 +0x100。
    /// 捕获原消息时间用它们。解析对象把 revoketime 放在 +0x288，不能写这里。
    uint64_t messageCreateTimeSecOffset;
    uint64_t messageCreateTimeMsOffset;
    /// 0 = 只写 revokeReplaceMsgOffset。270135 带 <revoketime> 时，
    /// parseRevokeXML 把 <content> 写入 +0x1D0 后再赋给这两处
    /// （0x4d20524、0x4d20530）。灰字读的是这两份。
    uint64_t revokeDisplayCopyOffsetA;
    uint64_t revokeDisplayCopyOffsetB;

    /// Voice send pipeline. Still unregistered on every build: the bubble
    /// switch does not read these fields. Offsets stay zero until a
    /// prologue-checked send entry exists. Do not invent them.
    uint64_t voiceSendAddress;
    uint32_t voiceSendPrologue[4];
    uint64_t voiceDataOffset;
    uint64_t voiceDurationOffset;
    uint64_t voiceFormatOffset;

    /// Bubble-menu visibility gate for type 34. Zero means this build has no
    /// verified gate and the switch stays disabled. 270135: sub_4D3AE38.
    /// x0 is the menu view-model (menu+0x120); the wire type dword is at +8.
    /// Text type 1 returns 1. Voice type 34 falls through to return 0.
    /// The hook returns 1 only for type 34. This is not voiceSendAddress.
    uint64_t voiceMenuGateAddress;
    uint32_t voiceMenuGatePrologue[4];

    /// Optional text-message long-press menu builder for 消息复读.
    /// 270135: 0xcf46ac. 270351: 0xd31de8. Helper addresses live beside the
    /// profile and are selected by build. Zero means the switch stays off.
    uint64_t repeatMenuBuilderAddress;
    uint32_t repeatMenuBuilderPrologue[4];

    /// Optional avatar paint entry for 圆角头像. Zero means this build has no
    /// verified entry yet: the feature
    /// stays preference-only and the hook refuses to install. The entry is
    /// Shared XImage bitmap paint (270135: 0x1f3c2cc). The hook keeps the
    /// avatar percent on XAvatarImage, ContactHeadView and SNSAvatarHeadView
    /// only. It reads mode at widget+468 (2=circle) and radii at +472/+476.
    /// 100% forces mode 2; smaller percents use mode 1.
    uint64_t avatarShapeAddress;
    uint32_t avatarShapePrologue[4];

    /// ChatMasterView::OnSelectedSession(std::string) 发射桩。
    /// 270135: 0x1361b8。x0 是视图，x1 是用户名 std::string*。
    /// 前 3 条指令可搬走，第 4 条是 adrp，必须留在原地。其它构建为 0。
    uint64_t sessionSelectAddress;
    uint32_t sessionSelectPrologue[3];

    /// 新消息入库/刷新会话前的统一过滤函数：
    /// x0 = 消息管理器，x1 = 0x278 字节的消息对象。返回 1 表示丢弃本条消息。
    /// 不同构建未登记时保持 0，消息屏蔽拒绝安装，不猜地址。
    uint64_t messageFilterAddress;
    uint32_t messageFilterPrologue[4];

    /// 接收循环里填充那条 0x278 消息的解析器。270390: 0x45bf724。
    /// 唯一调用点是 0x45c1310；0x45c1300 只被接收循环 0x2dd361c 调用。
    /// x0 是还没填的消息，x1 是源记录。源 +0x14 的类型由 0x45c049c 写入消息 +0x0C。
    /// 源 +8 / +0x18 / +0x20 是 from / to / 正文的持有者，字符串在持有者 +8。
    /// 屏蔽提示在解析前改这里，让微信自己做成系统消息。0 表示还没核实。
    uint64_t messagePrepareAddress;
    uint32_t messagePreparePrologue[4];
    /// 微信自己的 libc++ string 赋值。270390: 0x6abcf78。0 表示不能改写正文。
    uint64_t messageStringAssignAddress;

    /// 朋友圈评论长按菜单构建函数。270351: 0x1bfd67c。270353: 0x1c00a88。270387: 0x1a6bfdc。270390: 0x1a66640。菜单在 x0 返回，
    /// 钩子先执行这 16 字节再追加「复读」。0 表示开关保持关闭。
    /// 不是聊天复读的 repeatMenuBuilderAddress。
    uint64_t commentMenuBuilderAddress;
    uint32_t commentMenuBuilderPrologue[4];

    /// 聊天多选上限。下面每一处都非 0 才支持，缺一处开关置灰。
    /// 控制器 / 提示窗口改的是初始化时的 mov #100。聊天视图往往在补丁之前
    /// 就已经建好，字段里仍是 100，所以还要改真正读取这个字段的指令。
    /// 提示条数、选择拒绝、范围累加、溢出判断都从 ldr 改成 mov #9999。
    /// 转发窗口从记录向量的 ldp 起，共 8 条。第 4 条是 b.lo，
    /// 条数达到 101 时写错误码 2（「选择的消息最多不超过100条」）。
    /// 「选择到这里」不读控制器字段，虚调用取出范围条数后直接 cmp #100，
    /// 大于等于就弹「最多选择100条」。窗口 6 条，最后一条 b.lt 改成无条件跳过。
    /// 0 表示这一构建还没核实，不能猜。
    uint64_t multiSelectControllerAddress;
    uint32_t multiSelectControllerWindow[4];
    uint64_t multiSelectTipAddress;
    uint32_t multiSelectTipWindow[4];
    uint64_t multiSelectForwardGateAddress;
    uint32_t multiSelectForwardGateWindow[8];
    uint64_t multiSelectTooltipAddress;
    uint32_t multiSelectTooltipWindow[4];
    uint64_t multiSelectCountGateAddress;
    uint32_t multiSelectCountGateWindow[4];
    uint64_t multiSelectRangeGateAddress;
    uint32_t multiSelectRangeGateWindow[4];
    uint64_t multiSelectOverflowGateAddress;
    uint32_t multiSelectOverflowGateWindow[4];
    uint64_t multiSelectReachGateAddress;
    uint32_t multiSelectReachGateWindow[6];

    /// 语音视图模型构造。270351: 0x78e98c。x0 是 ChatVoiceItemViewModel，
    /// 4 个参数，返回 x0。前 16 字节能搬走，但单独不唯一，所以核对 44 字节。
    /// 第 11 条是 bl，留在原地。0 表示这一构建还没核实。
    uint64_t voiceAutoTextSetStateAddress;
    uint32_t voiceAutoTextSetStateWindow[11];
    /// 官方「转文字」sub_7954DC。x0 是同一个视图模型，w1 必须是 1。
    /// 只核对 32 字节，不改这条。270351 第 8 条是 adrp。
    /// 270390 第 7 条是 adrp，第 8 条是 ldr。
    uint64_t voiceAutoTextOnClickAddress;
    uint32_t voiceAutoTextOnClickWindow[8];
    /// 旧的录音条开关。不再作为安装条件，保持 0。
    uint64_t voiceAutoTextFeatureCheckAddress;
    uint32_t voiceAutoTextFeatureCheckWindow[6];
    /// MessageData 对象首 qword 里的虚表。0 表示语音自动转文字仍用 270351 的
    /// 0xa002468。只在复制函数把这个地址写进对象时登记。
    uint64_t messageDataVtableAddress;
} WCRPatchProfile;

typedef struct {
    BOOL supported;
    BOOL alreadyPatched;
    WCRPatchProfile profile;
    NSString *shortVersion;
    NSString *buildVersion;
    NSString *wechatDylibPath;
    NSString *failureReason;
} WCRAppInspection;

/// Reads a WeChat.app without loading it.
/// Returns NO only for hard errors: missing Info.plist, not WeChat,
/// missing wechat.dylib, not arm64, or unreadable Mach-O.
/// Unknown CFBundleVersion and patch-byte mismatch set supported=NO
/// and failureReason, then return YES so the installer can still copy.
BOOL WCRInspectWeChatApp(NSString *appPath, WCRAppInspection *inspection, NSError **error);

/// Returns the version profile for the current WeChat process.
const WCRPatchProfile * _Nullable WCRCurrentProcessProfile(NSError **error);

/// 主副本 bundle id 是 com.tencent.xinWeChat。多开副本是
/// com.tencent.xinWeChat.WCRefineMulti<N>，插件必须同样放行。
/// selfTest 为真时另外接受 com.tencent.xinWeChat.WCRefineTest 前缀。
BOOL WCRHostBundleIdentifierAllowed(NSString *bundleIdentifier, BOOL selfTest);

/// Applies or restores the memory-only patch in the current WeChat process.
BOOL WCRApplyAntiRevokePatch(NSError **error);
BOOL WCRRestoreAntiRevokePatch(NSError **error);

/// Reports the real bytes currently present in the loaded wechat.dylib.
WCRPatchState WCRCurrentProcessPatchState(NSError **error);

/// Human-readable support list for the CLI and diagnostics.
NSArray<NSString *> *WCRSupportedBuildDescriptions(void);

NS_ASSUME_NONNULL_END
