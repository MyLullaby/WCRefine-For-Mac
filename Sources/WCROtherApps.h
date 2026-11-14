#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 微信「其他应用」只列出能接收一个 zip 的系统共享扩展。
/// 这些应用自己没有这种扩展，所以不会出现。WorkBuddy 官方已经带了入口，不再重复添加。
/// 勾选后由 WCRefineShare 在本机生成对应入口，转发时把微信打好的压缩包交给那个应用。
typedef struct {
    __unsafe_unretained NSString *identifier;
    __unsafe_unretained NSString *title;
    __unsafe_unretained NSString *bundleIdentifier;
    /// 系统里显示的应用名。和菜单标题不一样时，提示里用这个名字。
    __unsafe_unretained NSString *applicationName;
} WCROtherAppSpec;

const WCROtherAppSpec *WCROtherAppSpecs(NSUInteger *count);
const WCROtherAppSpec *_Nullable WCROtherAppSpecForIdentifier(NSString *_Nullable identifier);

/// Resolves the app by bundle identifier, then by its standard /Applications name.
/// The latter covers builds whose Mac bundle id differs from the public listing.
NSURL *_Nullable WCROtherAppApplicationURL(const WCROtherAppSpec *spec);

BOOL WCROtherAppIsInstalled(const WCROtherAppSpec *spec);
BOOL WCROtherAppEnabled(const WCROtherAppSpec *spec);
void WCROtherAppSetEnabled(const WCROtherAppSpec *spec, BOOL enabled);

/// 扩展宿主已在登录项数据库里。没装时勾选无法把入口登记进系统。
BOOL WCROtherAppsHostInstalled(void);

NSString *WCROtherAppTooltip(const WCROtherAppSpec *spec);

/// 选择有变化时让宿主重新登记入口。宿主没装好时返回 NO。
BOOL WCROtherAppsRequestSyncIfSelectionChanged(NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
