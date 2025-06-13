#import "PlatformBridge.h"

@protocol VLCClickableLabelDelegate <NSObject>
@optional
- (void)clickableLabelWasClicked:(NSString *)identifier withText:(NSString *)text;
@end

#if TARGET_OS_OSX
@interface VLCClickableLabel : NSView
#else
@interface VLCClickableLabel : UIView
#endif

@property (nonatomic, assign) id<VLCClickableLabelDelegate> delegate;
@property (nonatomic, retain) NSString *identifier;
@property (nonatomic, retain) NSString *text;
@property (nonatomic, retain) NSString *placeholderText;
@property (nonatomic, assign) BOOL isHovered;

- (instancetype)initWithFrame:(PlatformRect)frame identifier:(NSString *)identifier;
- (void)setText:(NSString *)text;
- (void)setPlaceholderText:(NSString *)placeholder;

@end 
