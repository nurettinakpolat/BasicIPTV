#import "VLCOverlayView.h"
#import "VLCChannel.h"

@interface VLCOverlayView (Search)

// Search methods
- (void)performSearch:(NSString *)searchText;
- (void)performDelayedSearch:(NSTimer *)timer;
- (BOOL)channel:(VLCChannel *)channel matchesSearchText:(NSString *)searchText;

// Selection persistence methods
- (void)saveLastSelectedIndices;
- (void)loadAndRestoreLastSelectedIndices;
- (NSArray *)getGroupsForCategoryIndex:(NSInteger)categoryIndex;

// Smart search selection methods
- (void)saveOriginalLocationForSearchedChannel:(VLCChannel *)channel;
- (void)selectSearchAndRememberOriginalLocation:(VLCChannel *)channel;
- (void)restoreOriginalLocationOfSearchedChannel;

@end 