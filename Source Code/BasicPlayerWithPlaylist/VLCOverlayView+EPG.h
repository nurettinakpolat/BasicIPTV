#import "VLCOverlayView.h"

@interface VLCOverlayView (EPG) <NSXMLParserDelegate>

// EPG loading
- (void)loadEpgData;
- (void)loadEpgDataWithRetryCount:(NSInteger)retryCount;
- (BOOL)loadEpgDataFromCache;
- (BOOL)loadEpgDataFromCacheWithoutChecks;
- (void)loadEpgFromCacheOnly;
- (void)loadEpgDataAtStartup;
- (BOOL)loadEpgDataFromCacheWithoutAgeCheck;
- (void)handleEpgLoadingTimeout;
- (void)handleDownloadError:(NSError *)error retryCount:(NSInteger)retryCount;
- (void)handleDownloadComplete;

// EPG data processing
- (void)matchEpgWithChannels;
- (void)saveEpgDataToCache;

// XML parser delegate methods
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName 
  namespaceURI:(NSString *)namespaceURI 
 qualifiedName:(NSString *)qName 
    attributes:(NSDictionary *)attributeDict;
    
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string;

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName 
  namespaceURI:(NSString *)namespaceURI 
 qualifiedName:(NSString *)qName;
 
- (void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError;

@end 