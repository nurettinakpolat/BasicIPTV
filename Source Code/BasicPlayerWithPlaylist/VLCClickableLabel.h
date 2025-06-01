#import <Cocoa/Cocoa.h>

@protocol VLCClickableLabelDelegate <NSObject>
@optional
- (void)clickableLabelWasClicked:(NSString *)identifier withText:(NSString *)text;
@end

@interface VLCClickableLabel : NSView

@property (nonatomic, assign) id<VLCClickableLabelDelegate> delegate;
@property (nonatomic, retain) NSString *identifier;
@property (nonatomic, retain) NSString *text;
@property (nonatomic, retain) NSString *placeholderText;
@property (nonatomic, assign) BOOL isHovered;

- (instancetype)initWithFrame:(NSRect)frame identifier:(NSString *)identifier;
- (void)setText:(NSString *)text;
- (void)setPlaceholderText:(NSString *)placeholder;

@end 