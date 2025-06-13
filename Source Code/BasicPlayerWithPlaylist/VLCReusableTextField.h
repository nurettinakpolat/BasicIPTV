#import "PlatformBridge.h"

@protocol VLCReusableTextFieldDelegate <NSObject>
@optional
- (void)textFieldDidChange:(NSString *)newValue forIdentifier:(NSString *)identifier;
- (void)textFieldDidEndEditing:(NSString *)finalValue forIdentifier:(NSString *)identifier;
- (void)textFieldDidBeginEditing:(NSString *)identifier;
@end

#if TARGET_OS_OSX
@interface VLCReusableTextField : NSTextField
#else
@interface VLCReusableTextField : UITextField
#endif

@property (nonatomic, assign) id<VLCReusableTextFieldDelegate> textFieldDelegate;
@property (nonatomic, retain) NSString *identifier;
@property (nonatomic, assign) BOOL isActive;

- (instancetype)initWithFrame:(PlatformRect)frame identifier:(NSString *)identifier;
- (void)setPlaceholderText:(NSString *)placeholder;
- (void)setTextValue:(NSString *)text;
- (void)activateField;
- (void)deactivateField;

// Copy/Paste support
- (void)copy:(id)sender;
- (void)cut:(id)sender;
- (void)paste:(id)sender;
- (void)selectAll:(id)sender;

@end 
