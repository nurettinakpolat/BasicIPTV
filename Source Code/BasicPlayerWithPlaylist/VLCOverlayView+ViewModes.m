#import "VLCOverlayView+ViewModes.h"
#import "VLCOverlayView_Private.h"
#import "VLCOverlayView+PlayerControls.h"
#import "VLCSubtitleSettings.h"
#import <objc/runtime.h>
#import "VLCOverlayView+Utilities.h"
#import <math.h>
#import "VLCSliderControl.h"
#import "VLCOverlayView+Globals.h"

@implementation VLCOverlayView (ViewModes)


#pragma mark - Stacked View Drawing

- (void)drawStackedView:(NSRect)rect {
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    CGFloat stackedViewX = catWidth + groupWidth;
    CGFloat stackedViewWidth = self.bounds.size.width - stackedViewX;
    CGFloat rowHeight = 400; // Reduced height for better fit - can show more movies
    
    // Draw background using theme colors
    NSRect stackedRect = NSMakeRect(stackedViewX, 0, stackedViewWidth, self.bounds.size.height);
    NSGradient *backgroundGradient = [[NSGradient alloc] initWithStartingColor:self.themeChannelStartColor ? self.themeChannelStartColor : [NSColor colorWithCalibratedRed:0.10 green:0.12 blue:0.16 alpha:0.7]
                                                                   endingColor:self.themeChannelEndColor ? self.themeChannelEndColor : [NSColor colorWithCalibratedRed:0.12 green:0.14 blue:0.18 alpha:0.7]];
    [backgroundGradient drawInRect:stackedRect angle:90];
    [backgroundGradient release];
    
    // Get current movies for the selected group
    NSArray *moviesInCurrentGroup = [self getChannelsForCurrentGroup];
    
    if (!moviesInCurrentGroup || moviesInCurrentGroup.count == 0) {
        // No movies to display
        NSString *message = @"No movies available in this group";
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        [style setAlignment:NSTextAlignmentCenter];
        
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:16],
            NSForegroundColorAttributeName: self.textColor,
            NSParagraphStyleAttributeName: style
        };
        
        NSRect messageRect = NSMakeRect(stackedViewX, self.bounds.size.height/2 - 10, stackedViewWidth, 20);
        [message drawInRect:messageRect withAttributes:attrs];
        [style release];
        return;
    }
    
    // Calculate total content height for scrolling
    CGFloat totalContentHeight = moviesInCurrentGroup.count * rowHeight;
    
    // Add extra space at bottom to ensure last item is fully visible when scrolled to the end
    totalContentHeight += rowHeight;
    
    // Update scroll limits to ensure last item is fully visible
    CGFloat maxScroll = MAX(0, totalContentHeight - stackedRect.size.height);
    CGFloat scrollPosition = MIN(channelScrollPosition, maxScroll); // Reuse channelScrollPosition for stacked view
    
    // Calculate minimum number of visible rows (at least 4)
    NSInteger minVisibleRows = 4;
    CGFloat requiredHeight = minVisibleRows * rowHeight;
    if (stackedRect.size.height < requiredHeight) {
        // If window is too small, adjust row height to fit at least 4 rows
        rowHeight = MAX(80, stackedRect.size.height / minVisibleRows); // Minimum 80px per row
        
        // Recalculate content height with adjusted row height for accurate scroll bar
        totalContentHeight = moviesInCurrentGroup.count * rowHeight;
        totalContentHeight += rowHeight; // Add extra space
        maxScroll = MAX(0, totalContentHeight - stackedRect.size.height);
        scrollPosition = MIN(channelScrollPosition, maxScroll);
    }
    
    // Draw each movie row
    for (NSInteger i = 0; i < moviesInCurrentGroup.count; i++) {
        VLCChannel *movie = [moviesInCurrentGroup objectAtIndex:i];
        
        // Calculate smooth position with correct scroll direction
        // Position movies from bottom to top, with proper scroll offset
        CGFloat movieYPosition = stackedRect.size.height - ((i + 1) * rowHeight) + scrollPosition;
        
        // Position the movie row
        NSRect itemRect = NSMakeRect(stackedViewX, 
                                     movieYPosition, 
                                     stackedViewWidth, 
                                     rowHeight);
        
        // Skip drawing if completely outside visible area
        if (itemRect.origin.y + itemRect.size.height < 0 || 
            itemRect.origin.y > stackedRect.size.height) {
            continue;
        }
        
        // Clip to visible area for smooth scrolling
        NSRect clippedRect = NSIntersectionRect(itemRect, stackedRect);
        if (NSIsEmptyRect(clippedRect)) {
            continue;
        }
        
        // ONLY load cached poster image for visible movies (after visibility check)
        if ([movie.category isEqualToString:@"MOVIES"] && !movie.cachedPosterImage) {
            [self loadCachedPosterImageForChannel:movie];
        }
        
        // Draw row background and selection state
        if (i == self.selectedChannelIndex) {
            // Selected movie - use exact same style as categories/groups
            NSBezierPath *selectionPath = [NSBezierPath bezierPathWithRoundedRect:
                                         NSInsetRect(clippedRect, 4, 2)
                                                                         xRadius:6
                                                                         yRadius:6];
            [[NSColor colorWithCalibratedRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.3] set];
            [selectionPath fill];
            
            // Add subtle highlight - exact same as categories/groups
            [[NSColor colorWithCalibratedRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.2] set];
            [selectionPath stroke];
        } else if (i == self.hoveredChannelIndex) {
            // Hovered movie - use exact same style as categories/groups
            NSBezierPath *hoverPath = [NSBezierPath bezierPathWithRoundedRect:
                                     NSInsetRect(clippedRect, 4, 2)
                                                                     xRadius:6
                                                                     yRadius:6];
            [[NSColor colorWithCalibratedRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.25] set];
            [hoverPath fill];
            
            // Add subtle highlight - exact same as categories/groups
            [[NSColor colorWithCalibratedRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.15] set];
            [hoverPath stroke];
        }
        
        // Draw border around each movie row
        [[NSColor colorWithCalibratedWhite:0.4 alpha:0.6] set];
        NSBezierPath *borderPath = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(clippedRect, 2, 2) xRadius:4 yRadius:4];
        [borderPath setLineWidth:1.0];
        [borderPath stroke];
        
        // Calculate layout dimensions using original itemRect for positioning
        // Movie poster aspect ratio is typically 2:3 (width:height)
        CGFloat posterHeight = rowHeight - 10; // Leave some padding
        CGFloat posterAspectRatio = 2.0 / 3.0; // Standard movie poster ratio
        CGFloat posterWidth = posterHeight * posterAspectRatio; // Calculate width to maintain aspect ratio
        CGFloat posterX = itemRect.origin.x + 10;
        CGFloat posterY = itemRect.origin.y + 5;
        
        CGFloat textAreaX = posterX + posterWidth + 15;
        CGFloat textAreaWidth = itemRect.size.width - posterWidth - 30;
        
        // Draw movie poster
        NSRect posterRect = NSMakeRect(posterX, posterY, posterWidth, posterHeight);
        
        // Only draw poster if it intersects with visible area
        if (NSIntersectsRect(posterRect, clippedRect)) {
            if (movie.cachedPosterImage) {
                // Draw the actual poster image
                [[NSColor colorWithCalibratedWhite:0.2 alpha:0.8] set];
                NSBezierPath *posterBg = [NSBezierPath bezierPathWithRoundedRect:posterRect xRadius:4 yRadius:4];
                [posterBg fill];
                
                NSRect imageRect = NSInsetRect(posterRect, 2, 2);
                [movie.cachedPosterImage drawInRect:imageRect 
                                           fromRect:NSZeroRect 
                                          operation:NSCompositeSourceOver 
                                           fraction:1.0 
                                    respectFlipped:YES 
                                             hints:nil];
            } else {
                // Draw placeholder
                [[NSColor colorWithCalibratedWhite:0.3 alpha:0.8] set];
                NSBezierPath *placeholderPath = [NSBezierPath bezierPathWithRoundedRect:posterRect xRadius:4 yRadius:4];
                [placeholderPath fill];
                
                // Draw "No Image" text
                NSMutableParagraphStyle *placeholderStyle = [[NSMutableParagraphStyle alloc] init];
                [placeholderStyle setAlignment:NSTextAlignmentCenter];
                
                NSDictionary *placeholderAttrs = @{
                    NSFontAttributeName: [NSFont systemFontOfSize:10],
                    NSForegroundColorAttributeName: [NSColor lightGrayColor],
                    NSParagraphStyleAttributeName: placeholderStyle
                };
                
                [@"No Image" drawInRect:posterRect withAttributes:placeholderAttrs];
                [placeholderStyle release];
                
                // Try to load the image if available and not already loading
                if (movie.logo && !objc_getAssociatedObject(movie, "imageLoadingInProgress")) {
                    [self loadImageAsynchronously:movie.logo forChannel:movie];
                }
            }
        }
        
        // Draw movie details in the text area
        CGFloat currentY = itemRect.origin.y + itemRect.size.height - 40;
        CGFloat lineHeight = 16;
        
        // Movie title (larger, bold)
        NSString *movieTitle = movie.name ? movie.name : @"Unknown Movie";
        NSMutableParagraphStyle *titleStyle = [[NSMutableParagraphStyle alloc] init];
        [titleStyle setAlignment:NSTextAlignmentLeft];
        [titleStyle setLineBreakMode:NSLineBreakByTruncatingTail];
        
        NSDictionary *titleAttrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:16],
            NSForegroundColorAttributeName: self.textColor,
            NSParagraphStyleAttributeName: titleStyle
        };
        
        NSRect titleRect = NSMakeRect(textAreaX, currentY, textAreaWidth, lineHeight + 2);
        // Only draw title if it's visible in the clipped area
        if (NSIntersectsRect(titleRect, clippedRect)) {
            [movieTitle drawInRect:titleRect withAttributes:titleAttrs];
        }
        [titleStyle release];
        currentY -= (lineHeight + 5);
        
        // Show movie info if loaded
        if (movie.hasLoadedMovieInfo) {
            // Year and Genre on same line
            NSMutableString *yearGenre = [NSMutableString string];
            if (movie.movieYear && movie.movieYear.length > 0) {
                [yearGenre appendString:movie.movieYear];
            }
            if (movie.movieGenre && movie.movieGenre.length > 0) {
                if (yearGenre.length > 0) [yearGenre appendString:@" • "];
                [yearGenre appendString:movie.movieGenre];
            }
            
            if (yearGenre.length > 0) {
                NSRect yearGenreRect = NSMakeRect(textAreaX, currentY, textAreaWidth, lineHeight);
                if (NSIntersectsRect(yearGenreRect, clippedRect)) {
                    [self drawCompactText:yearGenre inRect:yearGenreRect];
                }
                currentY -= lineHeight;
            }
            
            // Director
            if (movie.movieDirector && movie.movieDirector.length > 0) {
                NSString *directorText = [NSString stringWithFormat:@"Director: %@", movie.movieDirector];
                NSRect directorRect = NSMakeRect(textAreaX, currentY, textAreaWidth, lineHeight);
                if (NSIntersectsRect(directorRect, clippedRect)) {
                    [self drawCompactText:directorText inRect:directorRect];
                }
                currentY -= lineHeight;
            }
            
            // Rating and Duration on same line with stars
            NSMutableString *ratingDuration = [NSMutableString string];
            if (movie.movieRating && movie.movieRating.length > 0) {
                // Convert rating to stars (assuming rating is out of 10)
                NSString *stars = [self convertRatingToStars:movie.movieRating];
                [ratingDuration appendString:[NSString stringWithFormat:@"★ %@ %@", movie.movieRating, stars]];
            }
            if (movie.movieDuration && movie.movieDuration.length > 0) {
                if (ratingDuration.length > 0) [ratingDuration appendString:@" • "];
                [ratingDuration appendString:[NSString stringWithFormat:@"⏱ %@", movie.movieDuration]];
            }
            
            if (ratingDuration.length > 0) {
                NSRect ratingDurationRect = NSMakeRect(textAreaX, currentY, textAreaWidth, lineHeight);
                if (NSIntersectsRect(ratingDurationRect, clippedRect)) {
                    [self drawHighlightedText:ratingDuration inRect:ratingDurationRect];
                }
                currentY -= lineHeight;
            }
            
            // Short description if space allows - with improved styling
            if (movie.movieDescription && movie.movieDescription.length > 0 && currentY > itemRect.origin.y + 5) {
                NSString *shortDescription = movie.movieDescription;
                // Truncate description to fit in remaining space
                if (shortDescription.length > 150) {
                    shortDescription = [[shortDescription substringToIndex:147] stringByAppendingString:@"..."];
                }
                
                NSMutableParagraphStyle *descStyle = [[NSMutableParagraphStyle alloc] init];
                [descStyle setAlignment:NSTextAlignmentLeft];
                [descStyle setLineBreakMode:NSLineBreakByWordWrapping];
                [descStyle setLineSpacing:2.0]; // Add line spacing for better readability
                
                NSDictionary *descAttrs = @{
                    NSFontAttributeName: [NSFont systemFontOfSize:14],
                    NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.9 alpha:1.0], // Brighter text
                    NSParagraphStyleAttributeName: descStyle,
                    NSShadowAttributeName: ({
                        NSShadow *shadow = [[NSShadow alloc] init];
                        shadow.shadowColor = [NSColor colorWithCalibratedWhite:0.0 alpha:0.6];
                        shadow.shadowOffset = NSMakeSize(0, -1);
                        shadow.shadowBlurRadius = 1;
                        shadow;
                    })
                };
                
                NSRect descRect = NSMakeRect(textAreaX, itemRect.origin.y + 10, textAreaWidth, currentY - itemRect.origin.y - 15);
                if (NSIntersectsRect(descRect, clippedRect)) {
                    [shortDescription drawInRect:descRect withAttributes:descAttrs];
                }
                [descStyle release];
                [descAttrs[NSShadowAttributeName] release];
            }
        } else {
            // Movie info not loaded yet
            NSRect loadingRect = NSMakeRect(textAreaX, currentY, textAreaWidth, lineHeight);
            if (NSIntersectsRect(loadingRect, clippedRect)) {
                [self drawCompactText:@"Loading movie information..." 
                               inRect:loadingRect];
            }
            
            // Movie info loading is now handled by the preloading system
            // which uses accurate visibility detection and improved caching logic
        }
    }
    
    // Draw scroll indicator if content is scrollable
    if (totalContentHeight > stackedRect.size.height) {
        [self drawScrollBar:stackedRect contentHeight:totalContentHeight scrollPosition:scrollPosition];
    }
    
    // Draw navigation hint at bottom
    NSString *navigationHint = @"Use ↑↓ keys to browse movies, Press Enter to play";
    NSMutableParagraphStyle *hintStyle = [[NSMutableParagraphStyle alloc] init];
    [hintStyle setAlignment:NSTextAlignmentCenter];
    
    NSDictionary *hintAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: [NSColor darkGrayColor],
        NSParagraphStyleAttributeName: hintStyle
    };
    
    NSRect hintRect = NSMakeRect(stackedViewX, 5, stackedViewWidth, 15);
    [navigationHint drawInRect:hintRect withAttributes:hintAttrs];
    [hintStyle release];
}

- (void)drawSearchMovieResults:(NSRect)rect {
    if (!self.searchMovieResults || [self.searchMovieResults count] == 0) {
        return;
    }
    
    CGFloat rowHeight = 120; // Smaller rows for search results
    
    // Draw background using theme colors with proper alpha handling
    NSColor *searchBackgroundStartColor, *searchBackgroundEndColor;
    if (self.themeChannelStartColor && self.themeChannelEndColor) {
        // Use theme colors with proper alpha adjustment for search results
        CGFloat searchAlpha = self.themeAlpha * 0.9; // Slightly more opaque for search results
        searchBackgroundStartColor = [self.themeChannelStartColor colorWithAlphaComponent:searchAlpha];
        searchBackgroundEndColor = [self.themeChannelEndColor colorWithAlphaComponent:searchAlpha];
    } else {
        // Fallback colors consistent with theme system defaults
        searchBackgroundStartColor = [NSColor colorWithCalibratedRed:0.08 green:0.10 blue:0.14 alpha:0.9];
        searchBackgroundEndColor = [NSColor colorWithCalibratedRed:0.10 green:0.12 blue:0.16 alpha:0.8];
    }
    
    NSGradient *backgroundGradient = [[NSGradient alloc] initWithStartingColor:searchBackgroundStartColor
                                                                   endingColor:searchBackgroundEndColor];
    [backgroundGradient drawInRect:rect angle:90];
    [backgroundGradient release];

    /*
    // Draw section header
    NSString *headerText = [NSString stringWithFormat:@"Movies/Series Found (%lu)", (unsigned long)[self.searchMovieResults count]];
    NSMutableParagraphStyle *headerStyle = [[NSMutableParagraphStyle alloc] init];
    [headerStyle setAlignment:NSTextAlignmentLeft];
    
    NSDictionary *headerAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:14],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: headerStyle
    };
    
    NSRect headerRect = NSMakeRect(rect.origin.x + 10, rect.origin.y + rect.size.height - 25, rect.size.width - 20, 20);
    [headerText drawInRect:headerRect withAttributes:headerAttrs];
    [headerStyle release];
    */
    // Calculate scrollable content area
    NSRect contentRect = NSMakeRect(rect.origin.x, rect.origin.y, rect.size.width, rect.size.height - 30);
    CGFloat totalContentHeight = [self.searchMovieResults count] * rowHeight;
    
    // Use dedicated scroll position for movie results
    CGFloat maxScroll = MAX(0, totalContentHeight - contentRect.size.height);
    CGFloat scrollPosition = MIN(self.searchMovieScrollPosition, maxScroll);
    
    // Draw each movie result
    for (NSInteger i = 0; i < [self.searchMovieResults count]; i++) {
        VLCChannel *movie = [self.searchMovieResults objectAtIndex:i];
        
        // Calculate position with scroll offset
        CGFloat movieYPosition = contentRect.origin.y + contentRect.size.height - ((i + 1) * rowHeight) + scrollPosition;
        
        NSRect itemRect = NSMakeRect(contentRect.origin.x, movieYPosition, contentRect.size.width, rowHeight);
        
        // Skip drawing if completely outside visible area
        if (itemRect.origin.y + itemRect.size.height < contentRect.origin.y || 
            itemRect.origin.y > contentRect.origin.y + contentRect.size.height) {
            continue;
        }
        
        // Clip to visible area
        NSRect clippedRect = NSIntersectionRect(itemRect, contentRect);
        if (NSIsEmptyRect(clippedRect)) {
            continue;
        }
        
        // Draw row background using theme-appropriate colors
        NSColor *rowBackgroundColor;
        if (self.themeChannelStartColor) {
            // Use a lighter version of the theme color for individual rows
            CGFloat rowAlpha = self.themeAlpha * 0.6;
            rowBackgroundColor = [self.themeChannelStartColor colorWithAlphaComponent:rowAlpha];
        } else {
            // Fallback to default
            rowBackgroundColor = [NSColor colorWithCalibratedWhite:0.15 alpha:0.6];
        }
        [rowBackgroundColor set];
        NSRectFill(clippedRect);
        
        // Draw border using theme-appropriate colors
        NSColor *borderColor;
        if (self.themeChannelEndColor) {
            // Use theme end color with reduced alpha for borders
            CGFloat borderAlpha = self.themeAlpha * 0.4;
            borderColor = [self.themeChannelEndColor colorWithAlphaComponent:borderAlpha];
        } else {
            // Fallback to default
            borderColor = [NSColor colorWithCalibratedWhite:0.4 alpha:0.4];
        }
        [borderColor set];
        NSBezierPath *borderPath = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(clippedRect, 1, 1) xRadius:3 yRadius:3];
        [borderPath setLineWidth:0.5];
        [borderPath stroke];
        
        // Calculate layout dimensions
        CGFloat posterHeight = rowHeight - 10;
        CGFloat posterWidth = posterHeight * (2.0 / 3.0); // Movie poster aspect ratio
        CGFloat posterX = itemRect.origin.x + 8;
        CGFloat posterY = itemRect.origin.y + 5;
        
        CGFloat textAreaX = posterX + posterWidth + 10;
        CGFloat textAreaWidth = itemRect.size.width - posterWidth - 25;
        
        // Draw movie poster
        NSRect posterRect = NSMakeRect(posterX, posterY, posterWidth, posterHeight);
        
        if (NSIntersectsRect(posterRect, clippedRect)) {
            if (movie.cachedPosterImage) {
                // Use theme-appropriate background for poster area
                NSColor *posterBgColor;
                if (self.themeChannelStartColor) {
                    CGFloat posterBgAlpha = self.themeAlpha * 0.8;
                    posterBgColor = [self.themeChannelStartColor colorWithAlphaComponent:posterBgAlpha];
                } else {
                    posterBgColor = [NSColor colorWithCalibratedWhite:0.2 alpha:0.8];
                }
                [posterBgColor set];
                NSBezierPath *posterBg = [NSBezierPath bezierPathWithRoundedRect:posterRect xRadius:3 yRadius:3];
                [posterBg fill];
                
                NSRect imageRect = NSInsetRect(posterRect, 1, 1);
                [movie.cachedPosterImage drawInRect:imageRect 
                                           fromRect:NSZeroRect 
                                          operation:NSCompositeSourceOver 
                                           fraction:1.0 
                                    respectFlipped:YES 
                                             hints:nil];
            } else {
                // Draw placeholder with theme-appropriate color
                NSColor *placeholderColor;
                if (self.themeChannelStartColor) {
                    CGFloat placeholderAlpha = self.themeAlpha * 0.25;
                    placeholderColor = [self.themeChannelStartColor colorWithAlphaComponent:placeholderAlpha];
                } else {
                    placeholderColor = [NSColor colorWithCalibratedWhite:0.25 alpha:0.8];
                }
                [placeholderColor set];
                NSBezierPath *placeholderPath = [NSBezierPath bezierPathWithRoundedRect:posterRect xRadius:3 yRadius:3];
                [placeholderPath fill];
                
                // Load image if available
                if (movie.logo && !objc_getAssociatedObject(movie, "imageLoadingInProgress")) {
                    [self loadImageAsynchronously:movie.logo forChannel:movie];
                }
            }
        }
        
        // Draw movie information in text area
        CGFloat currentY = itemRect.origin.y + itemRect.size.height - 20;
        CGFloat lineHeight = 14;
        
        // Movie title
        NSString *movieTitle = movie.name ? movie.name : @"Unknown Movie";
        NSMutableParagraphStyle *titleStyle = [[NSMutableParagraphStyle alloc] init];
        [titleStyle setAlignment:NSTextAlignmentLeft];
        [titleStyle setLineBreakMode:NSLineBreakByTruncatingTail];
        
        NSDictionary *titleAttrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:13],
            NSForegroundColorAttributeName: self.textColor,
            NSParagraphStyleAttributeName: titleStyle
        };
        
        NSRect titleRect = NSMakeRect(textAreaX, currentY, textAreaWidth, lineHeight);
        if (NSIntersectsRect(titleRect, clippedRect)) {
            [movieTitle drawInRect:titleRect withAttributes:titleAttrs];
        }
        [titleStyle release];
        currentY -= (lineHeight + 2);
        
        // Group name (where it was found)
        if (movie.group && [movie.group length] > 0) {
            NSString *groupText = [NSString stringWithFormat:@"From: %@", movie.group];
            NSRect groupRect = NSMakeRect(textAreaX, currentY, textAreaWidth, lineHeight);
            if (NSIntersectsRect(groupRect, clippedRect)) {
                [self drawCompactText:groupText inRect:groupRect];
            }
            currentY -= lineHeight;
        }
        
        // Movie details if loaded
        if (movie.hasLoadedMovieInfo) {
            // Year and Genre
            NSMutableString *yearGenre = [NSMutableString string];
            if (movie.movieYear && movie.movieYear.length > 0) {
                [yearGenre appendString:movie.movieYear];
            }
            if (movie.movieGenre && movie.movieGenre.length > 0) {
                if (yearGenre.length > 0) [yearGenre appendString:@" • "];
                [yearGenre appendString:movie.movieGenre];
            }
            
            if (yearGenre.length > 0) {
                NSRect yearGenreRect = NSMakeRect(textAreaX, currentY, textAreaWidth, lineHeight);
                if (NSIntersectsRect(yearGenreRect, clippedRect)) {
                    [self drawCompactText:yearGenre inRect:yearGenreRect];
                }
                currentY -= lineHeight;
            }
            
            // Rating if available
            if (movie.movieRating && movie.movieRating.length > 0) {
                NSString *ratingText = [NSString stringWithFormat:@"★ %@", movie.movieRating];
                NSRect ratingRect = NSMakeRect(textAreaX, currentY, textAreaWidth, lineHeight);
                if (NSIntersectsRect(ratingRect, clippedRect)) {
                    [self drawHighlightedText:ratingText inRect:ratingRect];
                }
            }
        }
    }
    
    // Draw scroll indicator if content is scrollable
    if (totalContentHeight > contentRect.size.height) {
        [self drawScrollBar:contentRect contentHeight:totalContentHeight scrollPosition:scrollPosition];
    }
}

- (void)drawCompactText:(NSString *)text inRect:(NSRect)rect {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentLeft];
    [style setLineBreakMode:NSLineBreakByTruncatingTail];
    
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: [NSColor lightGrayColor],
        NSParagraphStyleAttributeName: style
    };
    
    [text drawInRect:rect withAttributes:attrs];
    [style release];
}

- (void)drawHighlightedText:(NSString *)text inRect:(NSRect)rect {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentLeft];
    [style setLineBreakMode:NSLineBreakByTruncatingTail];
    
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.9 alpha:1.0],
        NSParagraphStyleAttributeName: style
    };
    
    [text drawInRect:rect withAttributes:attrs];
    [style release];
}

- (NSString *)convertRatingToStars:(NSString *)rating {
    // Convert rating to stars (assuming rating is out of 10)
    CGFloat ratingValue = [rating floatValue];
    NSInteger starCount = (NSInteger)ratingValue; // Direct conversion for 10-star scale
    starCount = MAX(0, MIN(10, starCount)); // Clamp between 0 and 10
    
    NSMutableString *stars = [NSMutableString string];
    for (NSInteger i = 0; i < 10; i++) {
        if (i < starCount) {
            [stars appendString:@"★"];
        } else {
            [stars appendString:@"☆"];
        }
    }
    return stars;
}

#pragma mark - View Mode Preferences

- (void)saveViewModePreference {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:currentViewMode forKey:@"VLCOverlayViewMode"];
    [defaults synchronize];
    //NSLog(@"Saved view mode preference: %ld", (long)currentViewMode);
}

- (void)loadViewModePreference {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // Load saved view mode (default to 0 = Stacked)
    NSInteger savedViewMode = [defaults integerForKey:@"VLCOverlayViewMode"];
    
    // Validate the loaded value
    if (savedViewMode < 0 || savedViewMode > 2) {
        savedViewMode = 0; // Default to Stacked
    }
    
    currentViewMode = savedViewMode;
    
    // Apply the loaded view mode
    [self applyViewMode:currentViewMode];
    
    //NSLog(@"Loaded view mode preference: %ld", (long)currentViewMode);
}

- (void)applyViewMode:(NSInteger)viewMode {
    // Apply the view mode settings
    switch (viewMode) {
        case 0: // Stacked
            isGridViewActive = NO;
            isStackedViewActive = YES;
            break;
        case 1: // Grid
            isGridViewActive = YES;
            isStackedViewActive = NO;
            break;
        case 2: // List
            isGridViewActive = NO;
            isStackedViewActive = NO;
            break;
    }
    
    // Reset hover state and scroll position when changing view modes
    // CRITICAL FIX: Don't reset hover index if we're preserving state for EPG
    extern BOOL isPersistingHoverState;
    if (!isPersistingHoverState) {
        //NSLog(@"ViewModes: Resetting hover index from %ld to -1", (long)self.hoveredChannelIndex);
        self.hoveredChannelIndex = -1;
    } else {
        //NSLog(@"ViewModes: Preserving hover index %ld (EPG persistence mode)", (long)self.hoveredChannelIndex);
    }
    channelScrollPosition = 0;
    
    //NSLog(@"Applied view mode: %ld (Stacked: %@, Grid: %@)", (long)viewMode, 
    //      isStackedViewActive ? @"YES" : @"NO", 
    //      isGridViewActive ? @"YES" : @"NO");
}

// Memory management: Clear cached images for channels that are not currently visible
- (void)clearOffscreenCachedImages {
    NSArray *channelsInCurrentGroup = [self getChannelsForCurrentGroup];
    if (!channelsInCurrentGroup || channelsInCurrentGroup.count == 0) {
        return;
    }
    
    // Calculate visible range based on current view mode
    NSRange visibleRange = [self calculateVisibleChannelRange];
    
    NSInteger clearedCount = 0;
    NSInteger memoryBufferSize = 8; // Larger buffer - keep more items in memory
    
    // Clear images for channels well outside the visible range
    for (NSInteger i = 0; i < channelsInCurrentGroup.count; i++) {
        VLCChannel *channel = [channelsInCurrentGroup objectAtIndex:i];
        
        // Keep images for visible channels plus a larger buffer for smooth scrolling
        BOOL shouldKeepInMemory = (i >= visibleRange.location - memoryBufferSize) && 
                                 (i <= visibleRange.location + visibleRange.length + memoryBufferSize);
        
        if (!shouldKeepInMemory && channel.cachedPosterImage) {
            channel.cachedPosterImage = nil; // Release from memory (but keep on disk)
            clearedCount++;
        }
    }
    
    if (clearedCount > 0) {
        //NSLog(@"Cleared %ld cached images from memory (buffer: %ld items)", (long)clearedCount, (long)memoryBufferSize);
    }
}

// Preload content for channels that are about to become visible
- (void)preloadContentWithMargin {
    NSArray *channelsInCurrentGroup = [self getChannelsForCurrentGroup];
    if (!channelsInCurrentGroup || channelsInCurrentGroup.count == 0) {
        return;
    }
    
    // Calculate visible range based on current view mode
    NSRange visibleRange = [self calculateVisibleChannelRange];
    
    // Validate visible range
    if (visibleRange.location >= channelsInCurrentGroup.count || visibleRange.length == 0) {
        //NSLog(@"Invalid visible range for preloading");
        return;
    }
    
    // MODIFIED: Only process exactly visible items, no buffer margin to prevent bulk downloading
    NSInteger totalChannels = (NSInteger)channelsInCurrentGroup.count;
    NSInteger visibleStart = (NSInteger)visibleRange.location;
    NSInteger visibleEnd = visibleStart + (NSInteger)visibleRange.length - 1;
    
    // NO BUFFER: Only process exactly what's visible
    NSInteger startIndex = visibleStart;
    NSInteger endIndex = MIN(totalChannels - 1, visibleEnd);
    
    //NSLog(@"Processing ONLY visible movies (no buffer): indices %ld-%ld", (long)startIndex, (long)endIndex);
    
    // Process channels in the visible range only
    for (NSInteger i = startIndex; i <= endIndex; i++) {
        VLCChannel *channel = [channelsInCurrentGroup objectAtIndex:i];
        if (![channel.category isEqualToString:@"MOVIES"]) {
            continue;
        }
        
        // Only process if not already loaded and not already fetching
        if (!channel.hasLoadedMovieInfo && !channel.hasStartedFetchingMovieInfo) {
            // First try to load from cache
            BOOL loadedFromCache = [self loadMovieInfoFromCacheForChannel:channel];
            
            if (!loadedFromCache) {
                // Mark as started and fetch asynchronously
                channel.hasStartedFetchingMovieInfo = YES;
                
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [self fetchMovieInfoForChannelAsync:channel];
                });
                
                //NSLog(@"🔄 Started fetching movie info for visible item: %@", channel.name);
            } else {
                //NSLog(@"📋 Loaded movie info from cache for visible item: %@", channel.name);
            }
        }
    }
}

// Enhanced method to manage memory and preload
- (void)optimizeMemoryAndPreload {
    // First clear offscreen cached images to free memory
    [self clearOffscreenCachedImages];
    
    // Then preload content that's about to become visible
    [self preloadContentWithMargin];
    
    // Also validate movie info for currently visible items
    [self validateMovieInfoForVisibleItems];
    
    // Clean up any incomplete cached movie info files (run occasionally)
    static NSTimeInterval lastCleanupTime = 0;
    NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
    
    // Clean up once every hour to avoid performance impact
    if (currentTime - lastCleanupTime > 3600) {
        [self cleanupIncompleteMovieInfoCache];
        lastCleanupTime = currentTime;
    }
}

// Add method to clean up incomplete cached movie info
- (void)cleanupIncompleteMovieInfoCache {
    NSString *appSupportDir = [self applicationSupportDirectory];
    NSString *movieInfoCacheDir = [appSupportDir stringByAppendingPathComponent:@"MovieInfo"];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:movieInfoCacheDir]) {
        return; // No cache directory exists
    }
    
    NSError *error = nil;
    NSArray *cacheFiles = [fileManager contentsOfDirectoryAtPath:movieInfoCacheDir error:&error];
    if (error || !cacheFiles) {
        return;
    }
    
    NSInteger cleanedCount = 0;
    
    for (NSString *filename in cacheFiles) {
        if (![filename hasSuffix:@".plist"]) continue;
        
        NSString *cacheFilePath = [movieInfoCacheDir stringByAppendingPathComponent:filename];
        NSDictionary *movieInfo = [NSDictionary dictionaryWithContentsOfFile:cacheFilePath];
        
        if (movieInfo) {
            NSString *cachedDescription = [movieInfo objectForKey:@"description"];
            NSString *cachedYear = [movieInfo objectForKey:@"year"];
            NSString *cachedGenre = [movieInfo objectForKey:@"genre"];
            NSString *cachedDirector = [movieInfo objectForKey:@"director"];
            NSString *cachedRating = [movieInfo objectForKey:@"rating"];
            
            // Check if this cached data is incomplete
            BOOL hasUsefulDescription = (cachedDescription && [cachedDescription length] > 10);
            BOOL hasUsefulMetadata = ((cachedYear && [cachedYear length] > 0) || 
                                     (cachedGenre && [cachedGenre length] > 0) || 
                                     (cachedDirector && [cachedDirector length] > 0) || 
                                     (cachedRating && [cachedRating length] > 0));
            
            if (!hasUsefulDescription && !hasUsefulMetadata) {
                // Remove incomplete cache file
                [fileManager removeItemAtPath:cacheFilePath error:nil];
                cleanedCount++;
            }
        }
    }
    
    if (cleanedCount > 0) {
        //NSLog(@"🧹 Cleaned up %ld incomplete movie info cache files", (long)cleanedCount);
    }
}



// Calculate the range of currently visible channels based on view mode
- (NSRange)calculateVisibleChannelRange {
    NSArray *channelsInCurrentGroup = [self getChannelsForCurrentGroup];
    if (!channelsInCurrentGroup || channelsInCurrentGroup.count == 0) {
        return NSMakeRange(0, 0);
    }
    
    // Check current view mode
    if (isGridViewActive && ((self.selectedCategoryIndex == CATEGORY_MOVIES) || 
                           (self.selectedCategoryIndex == CATEGORY_FAVORITES && [self currentGroupContainsMovieChannels]))) {
        // Grid view calculation - improved to match actual visible items
        CGFloat catWidth = 200;
        CGFloat groupWidth = 250;
        CGFloat gridX = catWidth + groupWidth;
        CGFloat gridWidth = self.bounds.size.width - gridX;
        CGFloat itemPadding = 10;
        CGFloat itemWidth = MIN(180, (gridWidth / 2) - (itemPadding * 2));
        CGFloat itemHeight = itemWidth * 1.5;
        CGFloat contentHeight = self.bounds.size.height - 40; // Account for header
        
        NSInteger maxColumns = MAX(1, (NSInteger)((gridWidth - itemPadding) / (itemWidth + itemPadding)));
        
        // Calculate scroll offset like in drawGridView
        CGFloat totalGridHeight = ((NSInteger)ceilf((float)channelsInCurrentGroup.count / (float)maxColumns)) * (itemHeight + itemPadding) + itemPadding + itemHeight;
        CGFloat maxScroll = MAX(0, totalGridHeight - contentHeight);
        CGFloat scrollOffset = MAX(0, MIN(channelScrollPosition, maxScroll));
        
        // Calculate which items are actually visible using the same positioning logic as drawing
        NSMutableIndexSet *visibleIndices = [NSMutableIndexSet indexSet];
        
        for (NSInteger i = 0; i < channelsInCurrentGroup.count; i++) {
            NSInteger row = i / maxColumns;
            NSInteger col = i % maxColumns;
            
            // Calculate position using exact same formula as drawGridView
            CGFloat totalGridItemWidth = maxColumns * (itemWidth + itemPadding) + itemPadding;
            CGFloat leftMargin = gridX + (gridWidth - totalGridItemWidth) / 2;
            
            CGFloat x = leftMargin + itemPadding + col * (itemWidth + itemPadding);
            CGFloat y = self.bounds.size.height - 60 - itemHeight - (row * (itemHeight + itemPadding)) + scrollOffset;
            
            // Check if item intersects with visible area (same logic as drawing skip check)
            if (!(y + itemHeight < 0 || y > self.bounds.size.height)) {
                [visibleIndices addIndex:i];
            }
        }
        
        // Convert to NSRange - find the contiguous range or use first and last indices
        if (visibleIndices.count == 0) {
            return NSMakeRange(0, 0);
        }
        
        NSUInteger firstIndex = [visibleIndices firstIndex];
        NSUInteger lastIndex = [visibleIndices lastIndex];
        NSUInteger length = lastIndex - firstIndex + 1;
        
        return NSMakeRange(firstIndex, length);
        
    } else if (isStackedViewActive && ((self.selectedCategoryIndex == CATEGORY_MOVIES) || 
                                     (self.selectedCategoryIndex == CATEGORY_FAVORITES && [self currentGroupContainsMovieChannels]))) {
        // Stacked view calculation - use EXACT same logic as drawStackedView and scroll calculations
        CGFloat catWidth = 200;
        CGFloat groupWidth = 250;
        CGFloat stackedViewX = catWidth + groupWidth;
        CGFloat stackedViewWidth = self.bounds.size.width - stackedViewX;
        NSRect stackedRect = NSMakeRect(stackedViewX, 0, stackedViewWidth, self.bounds.size.height);
        
        CGFloat rowHeight = 400; // Start with base row height
        
        // Account for potential rowHeight adjustment (matches drawStackedView logic)
        NSInteger minVisibleRows = 4;
        CGFloat requiredHeight = minVisibleRows * rowHeight;
        if (stackedRect.size.height < requiredHeight) {
            // Adjust row height if window is too small (matches drawStackedView)
            rowHeight = MAX(80, stackedRect.size.height / minVisibleRows);
        }
        
        // Calculate total content height for proper scroll position
        CGFloat totalContentHeight = channelsInCurrentGroup.count * rowHeight;
        totalContentHeight += rowHeight; // Add extra space
        CGFloat maxScroll = MAX(0, totalContentHeight - stackedRect.size.height);
        CGFloat scrollPosition = MIN(channelScrollPosition, maxScroll);
        
        // Calculate which items are visible using the same positioning logic as drawing
        NSMutableIndexSet *visibleIndices = [NSMutableIndexSet indexSet];
        
        for (NSInteger i = 0; i < channelsInCurrentGroup.count; i++) {
            // Calculate item position using exact same formula as drawStackedView
            CGFloat movieYPosition = stackedRect.size.height - ((i + 1) * rowHeight) + scrollPosition;
            NSRect itemRect = NSMakeRect(stackedViewX, movieYPosition, stackedViewWidth, rowHeight);
            
            // Check if item intersects with visible area (same logic as drawing)
            if (!(itemRect.origin.y + itemRect.size.height < 0 || 
                  itemRect.origin.y > stackedRect.size.height)) {
                [visibleIndices addIndex:i];
            }
        }
        
        // Convert to NSRange - find the contiguous range or use first and last indices
        if (visibleIndices.count == 0) {
            return NSMakeRange(0, 0);
        }
        
        NSUInteger firstIndex = [visibleIndices firstIndex];
        NSUInteger lastIndex = [visibleIndices lastIndex];
        NSUInteger length = lastIndex - firstIndex + 1;
        
        return NSMakeRange(firstIndex, length);
        
    } else {
        // Regular list view calculation
        CGFloat rowHeight = 40;
        NSInteger visibleCount = (NSInteger)(self.bounds.size.height / rowHeight) + 2;
        NSInteger startIndex = (NSInteger)(channelScrollPosition / rowHeight);
        
        startIndex = MAX(0, MIN(startIndex, (NSInteger)channelsInCurrentGroup.count - 1));
        visibleCount = MIN(visibleCount, (NSInteger)channelsInCurrentGroup.count - startIndex);
        
        return NSMakeRange(startIndex, visibleCount);
    }
}

@end 
