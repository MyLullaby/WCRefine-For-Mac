#import <Foundation/Foundation.h>

#import "WCRPatchProfiles.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const kWCRMessageBlockEnabledDefaultsKey;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockSessionsDefaultsKey;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockTypesDefaultsKey;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockSessionTypesDefaultsKey;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockShowTipDefaultsKey;

FOUNDATION_EXPORT NSString *const kWCRMessageBlockTypeText;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockTypeRefer;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockTypeImage;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockTypeVoice;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockTypeVideo;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockTypeEmoticon;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockTypePat;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockTypeFile;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockTypeContact;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockTypeLocation;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockTypeChatRecord;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockTypeLink;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockTypeMusic;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockTypeRedPacket;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockTypeTransfer;
FOUNDATION_EXPORT NSString *const kWCRMessageBlockTypeOther;

/// 消息屏蔽：在微信把收到的消息写入本地库、刷新会话列表和发通知之前，
/// 对命中的联系人或群返回「需要过滤」。配置按会话 ID 保存，只影响别人发来的
/// 消息；当前账号自己发出的消息不会进入过滤。
BOOL WCRMessageBlockSupportsProfile(const WCRPatchProfile * _Nullable profile);
BOOL WCRMessageBlockInstall(const WCRPatchProfile *profile, NSError **error);
BOOL WCRMessageBlockUninstall(NSError **error);
BOOL WCRMessageBlockIsInstalled(void);

BOOL WCRMessageBlockEnabled(void);
void WCRMessageBlockSetEnabled(BOOL enabled);

/// 已屏蔽的会话 ID，去重并保持用户添加顺序。
NSArray<NSString *> *WCRMessageBlockSessions(void);
BOOL WCRMessageBlockIsSessionBlocked(NSString *session);
BOOL WCRMessageBlockValidSessionID(NSString * _Nullable session);
/// 返回 NO 表示会话 ID 为空、格式无效，或达到上限。
BOOL WCRMessageBlockSetSessionBlocked(NSString *session, BOOL blocked);
/// 用这份名单替换已屏蔽会话。非法 ID 会跳过；有效项超过 256 个时不写并返回 NO。
BOOL WCRMessageBlockReplaceSessions(NSArray<NSString *> * _Nullable sessions);
void WCRMessageBlockClearSessions(void);

/// 与手机版相同的类型顺序。未保存任何类型时表示全部类型。
NSArray<NSString *> *WCRMessageBlockAllTypeKeys(void);
NSString *WCRMessageBlockTitleForTypeKey(NSString * _Nullable typeKey);
NSString *WCRMessageBlockTypeSummary(void);
NSArray<NSString *> *WCRMessageBlockSelectedTypes(void);
void WCRMessageBlockSetSelectedTypes(NSArray<NSString *> * _Nullable types);
BOOL WCRMessageBlockTypeIsSelected(NSString * _Nullable typeKey);

/// 这个会话有没有单独指定类型。没有时跟随全局「屏蔽类型」。
BOOL WCRMessageBlockSessionUsesCustomTypes(NSString * _Nullable session);
/// 单独指定的类型。没有单独指定时返回 nil。空数组表示这个会话一种都不挡。
NSArray<NSString *> * _Nullable WCRMessageBlockCustomTypesForSession(NSString * _Nullable session);
/// types 为 nil 时取消单独指定，改回跟随全局。空数组表示一种都不挡。
void WCRMessageBlockSetCustomTypesForSession(NSString *session,
                                             NSArray<NSString *> * _Nullable types);
/// 单独指定优先。没有单独指定时用全局类型；全局为空表示全部类型。
BOOL WCRMessageBlockTypeIsSelectedForSession(NSString * _Nullable session,
                                             NSString * _Nullable typeKey);

/// 命中后是否在会话里留下一条系统提示。默认关闭，关闭时直接丢弃、不留痕迹。
BOOL WCRMessageBlockShowTip(void);
void WCRMessageBlockSetShowTip(BOOL show);

/// 10000/10002 返回 nil，调用方应放行。无法识别的业务消息归入「其他」。
NSString * _Nullable WCRMessageBlockTypeKeyForMessageType(uint32_t messageType,
                                                         NSString * _Nullable content);

/// 根据消息对象上的 fromUsr / toUsr 解析会话。自己发出的消息返回 nil。
NSString * _Nullable WCRMessageBlockResolveSession(NSString * _Nullable fromUser,
                                                   NSString * _Nullable toUser,
                                                   NSString * _Nullable selfUser);

/// 从最近会话和已经见过的联系人里多选要屏蔽的人或群，也可以手填用户名。
/// 不读取微信数据库。
void WCRMessageBlockPresentPicker(void);

/// 过滤桩只读已经解析好的消息。屏蔽提示改的是解析前的源记录，不改半成品消息。
#ifdef __cplusplus
extern "C" {
#endif
BOOL WCRMessageBlockShouldFilterMessageObject(const void * _Nullable message);
void WCRMessageBlockPrepareSource(void * _Nullable source);
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
