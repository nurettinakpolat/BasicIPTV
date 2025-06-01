#import "VLCOverlayView.h"

@class VLCChannel;

@interface VLCOverlayView (Favorites)

// Add/remove favorites
- (void)addChannelToFavorites:(VLCChannel *)channel;
- (void)removeChannelFromFavorites:(VLCChannel *)channel;
- (void)addGroupToFavorites:(NSString *)groupName;
- (void)removeGroupFromFavorites:(NSString *)groupName;

// Check favorites status
- (BOOL)isChannelInFavorites:(VLCChannel *)channel;
- (BOOL)isGroupInFavorites:(NSString *)groupName;

// Menu actions
- (void)addChannelToFavoritesAction:(NSMenuItem *)sender;
- (void)removeChannelFromFavoritesAction:(NSMenuItem *)sender;
- (void)addGroupToFavoritesAction:(NSMenuItem *)sender;
- (void)removeGroupFromFavoritesAction:(NSMenuItem *)sender;

@end 