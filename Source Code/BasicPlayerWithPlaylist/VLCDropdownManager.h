#import <Cocoa/Cocoa.h>

@class VLCDropdownManager;

// Dropdown item data structure
@interface VLCDropdownItem : NSObject
@property (nonatomic, retain) id value;
@property (nonatomic, retain) NSString *displayText;
@property (nonatomic, assign) BOOL isSelected;
@property (nonatomic, assign) BOOL isHovered;

+ (instancetype)itemWithValue:(id)value displayText:(NSString *)text;
+ (instancetype)itemWithValue:(id)value displayText:(NSString *)text selected:(BOOL)selected;
@end

// Dropdown configuration and state
@interface VLCDropdown : NSObject
@property (nonatomic, retain) NSString *identifier;
@property (nonatomic, assign) NSRect frame;
@property (nonatomic, retain) NSMutableArray *items; // Array of VLCDropdownItem
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, assign) NSInteger hoveredIndex;
@property (nonatomic, assign) BOOL isOpen;
@property (nonatomic, assign) BOOL autoCloseOnMouseLeave;
@property (nonatomic, assign) CGFloat optionHeight;
@property (nonatomic, assign) NSInteger maxVisibleOptions;

// Styling
@property (nonatomic, retain) NSColor *backgroundColor;
@property (nonatomic, retain) NSColor *borderColor;
@property (nonatomic, retain) NSColor *selectedColor;
@property (nonatomic, retain) NSColor *hoveredColor;
@property (nonatomic, retain) NSColor *textColor;
@property (nonatomic, retain) NSFont *font;

// Scrolling support
@property (nonatomic, assign) NSInteger scrollOffset; // Index of first visible item

// Callbacks
@property (nonatomic, copy) void (^onSelectionChanged)(VLCDropdown *dropdown, VLCDropdownItem *selectedItem, NSInteger index);
@property (nonatomic, copy) void (^onHoverChanged)(VLCDropdown *dropdown, VLCDropdownItem *hoveredItem, NSInteger index);
@property (nonatomic, copy) void (^onClosed)(VLCDropdown *dropdown);

+ (instancetype)dropdownWithIdentifier:(NSString *)identifier frame:(NSRect)frame;
- (void)addItem:(VLCDropdownItem *)item;
- (void)addItemWithValue:(id)value displayText:(NSString *)text;
- (void)removeAllItems;
- (VLCDropdownItem *)itemAtIndex:(NSInteger)index;
- (NSRect)expandedFrame;

// Scrolling methods
- (void)scrollUp;
- (void)scrollDown;
- (void)scrollToItem:(NSInteger)itemIndex;
- (NSInteger)maxScrollOffset;
@end

// Main dropdown manager
@interface VLCDropdownManager : NSObject

@property (nonatomic, assign) NSView *parentView;
@property (nonatomic, retain) NSMutableDictionary *activeDropdowns;
@property (nonatomic, assign) NSPoint lastMousePosition;
@property (nonatomic, retain) NSTimer *mouseTrackingTimer;

+ (instancetype)sharedManager;
- (instancetype)initWithParentView:(NSView *)parentView;

// Dropdown Management
- (VLCDropdown *)createDropdownWithIdentifier:(NSString *)identifier frame:(NSRect)frame;
- (void)showDropdown:(NSString *)identifier;
- (void)hideDropdown:(NSString *)identifier;
- (void)hideAllDropdowns;
- (VLCDropdown *)dropdownWithIdentifier:(NSString *)identifier;

// Rendering
- (void)drawAllDropdowns:(NSRect)dirtyRect;

// Event handling
- (BOOL)handleMouseDown:(NSEvent *)event;
- (BOOL)handleMouseMoved:(NSEvent *)event;
- (void)handleMouseExited:(NSEvent *)event;
- (BOOL)handleScrollWheel:(NSEvent *)event;

// Utility methods
- (VLCDropdown *)dropdownAtPoint:(NSPoint)point;
- (BOOL)isPointInAnyDropdown:(NSPoint)point;

@end 
