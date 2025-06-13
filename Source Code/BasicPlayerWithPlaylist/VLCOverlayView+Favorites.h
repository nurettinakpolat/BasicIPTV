#if TARGET_OS_OSX
#import "VLCOverlayView.h"
@class NSMenuItem;
#endif

#if TARGET_OS_IOS || TARGET_OS_TV
#import "VLCUIOverlayView.h"
#endif

@class VLCChannel;

#if TARGET_OS_OSX
@interface VLCOverlayView (Favorites)
#else
@interface VLCUIOverlayView (Favorites)
#endif

// Add/remove favorites
- (void)addChannelToFavorites:(VLCChannel *)channel;
- (void)removeChannelFromFavorites:(VLCChannel *)channel;
- (void)addGroupToFavorites:(NSString *)groupName;
- (void)removeGroupFromFavorites:(NSString *)groupName;

// Check favorites status
- (BOOL)isChannelInFavorites:(VLCChannel *)channel;
- (BOOL)isGroupInFavorites:(NSString *)groupName;

#if TARGET_OS_OSX
// Menu actions
- (void)addChannelToFavoritesAction:(NSMenuItem *)sender;
- (void)removeChannelFromFavoritesAction:(NSMenuItem *)sender;
- (void)addGroupToFavoritesAction:(NSMenuItem *)sender;
- (void)removeGroupFromFavoritesAction:(NSMenuItem *)sender;
#endif

- (void)updateFavoritesWithEPGData;

#if TARGET_OS_IOS || TARGET_OS_TV
// iOS/tvOS specific context menu
- (void)showContextMenuForChannel:(VLCChannel *)channel atPoint:(CGPoint)point;
- (void)showContextMenuForGroup:(NSString *)groupName atPoint:(CGPoint)point;
#endif

@end 