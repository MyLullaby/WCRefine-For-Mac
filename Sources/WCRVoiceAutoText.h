#import <Foundation/Foundation.h>

#import "WCRPatchProfiles.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const kWCRVoiceAutoTextPrivateEnabledKey;
FOUNDATION_EXPORT NSString *const kWCRVoiceAutoTextGroupEnabledKey;
FOUNDATION_EXPORT NSString *const kWCRVoiceAutoTextIgnoreSelfEnabledKey;

/// 270351 气泡进入可转文字状态后，走微信自己的「转文字」。
/// 地址或字节对不上时保持关闭，不猜入口。
BOOL WCRVoiceAutoTextSupportsProfile(const WCRPatchProfile * _Nullable profile);

BOOL WCRVoiceAutoTextInstall(const WCRPatchProfile *profile, NSError **error);
BOOL WCRVoiceAutoTextUninstall(NSError **error);
BOOL WCRVoiceAutoTextIsInstalled(void);

NS_ASSUME_NONNULL_END
