#import "VLCOverlayView.h"
#import "VLCReusableTextField.h"
#import "VLCClickableLabel.h"

#if TARGET_OS_OSX

@interface VLCOverlayView (TextFields) <VLCReusableTextFieldDelegate, VLCClickableLabelDelegate>

// Text field handling
- (void)loadFromUrlButtonClicked;
- (void)updateEpgButtonClicked;
- (void)calculateCursorPositionForTextField:(BOOL)isM3uField withPoint:(NSPoint)point;
- (NSString *)generateEpgUrlFromM3uUrl:(NSString *)m3uUrl;

// Movie helper methods
- (NSString *)fileExtensionFromUrl:(NSString *)urlString;

// Cache directory methods
- (NSString *)postersCacheDirectory;

@end

#endif // TARGET_OS_OSX 