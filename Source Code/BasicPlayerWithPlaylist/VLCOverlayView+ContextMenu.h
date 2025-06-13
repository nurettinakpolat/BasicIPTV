#import "VLCOverlayView.h"
#import "VLCChannel.h"
#import "VLCProgram.h"

#if TARGET_OS_OSX

@interface VLCOverlayView (ContextMenu)

// Context menu methods
- (void)showContextMenuForChannel:(VLCChannel *)channel atPoint:(NSPoint)point;
- (void)showContextMenuForGroup:(NSString *)group atPoint:(NSPoint)point;
- (BOOL)handleEpgProgramRightClick:(NSPoint)point withEvent:(NSEvent *)event;
- (void)showContextMenuForProgram:(VLCProgram *)program channel:(VLCChannel *)channel atPoint:(NSPoint)point withEvent:(NSEvent *)event;
- (void)playCatchUpFromMenu:(NSMenuItem *)sender;
- (void)playChannelFromEpgMenu:(NSMenuItem *)sender;
- (NSInteger)findChannelIndexForChannel:(VLCChannel *)targetChannel;

// Timeshift methods
- (void)showTimeshiftOptionsForChannel:(NSMenuItem *)sender;
- (void)playTimeshiftFromMenu:(NSMenuItem *)sender;

// Scroll bar methods
- (void)fadeScrollBars:(NSTimer *)timer;

@end

#endif // TARGET_OS_OSX 