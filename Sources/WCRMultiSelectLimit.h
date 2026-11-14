#import <Foundation/Foundation.h>

#import "WCRPatchProfiles.h"

NS_ASSUME_NONNULL_BEGIN

/// 三处地址都登记了才返回 YES。缺任一处时菜单置灰，不猜地址。
BOOL WCRMultiSelectLimitSupportsProfile(const WCRPatchProfile *profile);

/// 把多选上限从 100 提到 9999，并放开转发条数校验。
/// 序言窗口不对、构建未登记或 wechat.dylib 还没加载时不写内存。
BOOL WCRMultiSelectLimitInstall(const WCRPatchProfile *profile, NSError **error);

/// 把三处指令恢复成进入前的字节。
BOOL WCRMultiSelectLimitUninstall(NSError **error);

BOOL WCRMultiSelectLimitIsInstalled(void);

NS_ASSUME_NONNULL_END
