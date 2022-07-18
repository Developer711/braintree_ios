#import "BTAnalyticsService.h"
#import "BTAnalyticsMetadata.h"
#import "BTAPIClient_Internal.h"
#import "BTHTTP.h"

// Objective-C Module Imports
#if __has_include(<Braintree/BraintreeCore.h>)
#import <Braintree/BTClientToken.h>
#import <Braintree/BTConfiguration.h>
#else
#import <BraintreeCore/BTClientToken.h>
#import <BraintreeCore/BTConfiguration.h>
#endif

#import <UIKit/UIKit.h>

// Swift Module Imports
#if __has_include(<Braintree/Braintree-Swift.h>) // Cocoapods-generated Swift Header
#import <Braintree/Braintree-Swift.h>

#elif SWIFT_PACKAGE                              // SPM
/* Use @import for SPM support
 * See https://forums.swift.org/t/using-a-swift-package-in-a-mixed-swift-and-objective-c-project/27348
 */
@import BraintreeCoreSwift;

#elif __has_include("Braintree-Swift.h")         // CocoaPods for ReactNative
/* Use quoted style when importing Swift headers for ReactNative support
 * See https://github.com/braintree/braintree_ios/issues/671
 */
#import "Braintree-Swift.h"

#else // Carthage or Local Builds
#import <BraintreeCoreSwift/BraintreeCoreSwift-Swift.h>
#endif

#pragma mark - BTAnalyticsEvent

/// Encapsulates a single analytics event
@interface BTAnalyticsEvent : NSObject

@property (nonatomic, copy) NSString *kind;

@property (nonatomic, assign) uint64_t timestamp;

+ (nonnull instancetype)event:(nonnull NSString *)eventKind withTimestamp:(uint64_t)timestamp;

/// Event serialized to JSON
- (nonnull NSDictionary *)json;

@end

@implementation BTAnalyticsEvent

+ (instancetype)event:(NSString *)eventKind withTimestamp:(uint64_t)timestamp {
    BTAnalyticsEvent *event = [[BTAnalyticsEvent alloc] init];
    event.kind = eventKind;
    event.timestamp = timestamp;
    return event;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@ at %llu", self.kind, (uint64_t)self.timestamp];
}

- (NSDictionary *)json {
    return @{
        @"kind": self.kind,
        @"timestamp": @(self.timestamp)
    };
}

@end

#pragma mark - BTAnalyticsSession

/// Encapsulates analytics events for a given session
@interface BTAnalyticsSession : NSObject

@property (nonatomic, copy, nonnull) NSString *sessionID;

@property (nonatomic, copy, nonnull) NSString *source;

@property (nonatomic, copy, nonnull) NSString *integration;

@property (nonatomic, strong, nonnull) NSMutableArray <BTAnalyticsEvent *> *events;

/// Dictionary of analytics metadata from `BTAnalyticsMetadata`
@property (nonatomic, strong, nonnull) NSDictionary *metadataParameters;

+ (nonnull instancetype)sessionWithID:(nonnull NSString *)sessionID
                               source:(nonnull NSString *)source
                          integration:(nonnull NSString *)integration;

@end

@implementation BTAnalyticsSession

- (instancetype)init {
    if (self = [super init]) {
        _events = [NSMutableArray array];
        _metadataParameters = [BTAnalyticsMetadata metadata];
    }
    return self;
}

+ (instancetype)sessionWithID:(NSString *)sessionID
                       source:(NSString *)source
                  integration:(NSString *)integration
{
    if (!sessionID || !source || !integration) {
        return nil;
    }
    
    BTAnalyticsSession *session = [[BTAnalyticsSession alloc] init];
    session.sessionID = sessionID;
    session.source = source;
    session.integration = integration;
    return session;
}

@end

#pragma mark - BTAnalyticsService

@interface BTAnalyticsService ()

/// Dictionary of analytics sessions, keyed by session ID. The analytics service requires that batched events
/// are sent from only one session. In practice, BTAPIClient.metadata.sessionID should never change, so this
/// is defensive.
@property (nonatomic, strong) NSMutableDictionary <NSString *, BTAnalyticsSession *> *analyticsSessions;

/// A serial dispatch queue that synchronizes access to `analyticsSessions`
@property (nonatomic, strong) dispatch_queue_t sessionsQueue;

@end

@implementation BTAnalyticsService

NSString * const BTAnalyticsServiceErrorDomain = @"com.braintreepayments.BTAnalyticsServiceErrorDomain";

- (instancetype)initWithAPIClient:(BTAPIClient *)apiClient {
    if (self = [super init]) {
        _analyticsSessions = [NSMutableDictionary dictionary];
        _sessionsQueue = dispatch_queue_create("com.braintreepayments.BTAnalyticsService", DISPATCH_QUEUE_SERIAL);
        _apiClient = apiClient;
        _flushThreshold = 1;
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Public methods

- (void)sendAnalyticsEvent:(NSString *)eventKind {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self enqueueEvent:eventKind];
        [self checkFlushThreshold];
    });
}

- (void)sendAnalyticsEvent:(NSString *)eventKind completion:(__unused void(^)(NSError *error))completionBlock {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self enqueueEvent:eventKind];
        [self flush:completionBlock];
    });
}

- (void)flush:(void (^)(NSError *))completionBlock {
    [self.apiClient fetchOrReturnRemoteConfiguration:^(BTConfiguration *configuration, NSError *error) {
        if (error) {
            NSLog(@"%@ Failed to send analytics event. Remote configuration fetch failed. %@", [BTLogLevelDescription stringFor:BTLogLevelWarning],  error.localizedDescription);
            if (completionBlock) completionBlock(error);
            return;
        }
        
        NSURL *analyticsURL = [configuration.json[@"analytics"][@"url"] asURL];
        if (!analyticsURL) {
            NSLog(@"%@ Skipping sending analytics event - analytics is disabled in remote configuration", [BTLogLevelDescription stringFor:BTLogLevelDebug]);
            NSError *error = [NSError errorWithDomain:BTAnalyticsServiceErrorDomain code:BTAnalyticsServiceErrorTypeMissingAnalyticsURL userInfo:@{ NSLocalizedDescriptionKey : @"Analytics is disabled in remote configuration" }];
            if (completionBlock) completionBlock(error);
            return;
        }
        
        if (!self.http) {
            if (self.apiClient.clientToken) {
                self.http = [[BTHTTP alloc] initWithBaseURL:analyticsURL authorizationFingerprint:self.apiClient.clientToken.authorizationFingerprint];
            } else if (self.apiClient.tokenizationKey) {
                self.http = [[BTHTTP alloc] initWithBaseURL:analyticsURL tokenizationKey:self.apiClient.tokenizationKey];
            }
            if (!self.http) {
                NSError *error = [NSError errorWithDomain:BTAnalyticsServiceErrorDomain code:BTAnalyticsServiceErrorTypeInvalidAPIClient userInfo:@{ NSLocalizedDescriptionKey : @"API client must have client token or tokenization key" }];
                NSLog(@"%@ %@", [BTLogLevelDescription stringFor:BTLogLevelWarning], error.localizedDescription);
                if (completionBlock) completionBlock(error);
                return;
            }
        }
        // A special value passed in by unit tests to prevent BTHTTP from actually posting
        if ([self.http.baseURL isEqual:[NSURL URLWithString:@"test://do-not-send.url"]]) {
            if (completionBlock) completionBlock(nil);
            return;
        }
        
        dispatch_async(self.sessionsQueue, ^{
            if (self.analyticsSessions.count == 0) {
                if (completionBlock) completionBlock(nil);
                return;
            }

            BOOL willPostAnalyticsEvent = NO;

            for (NSString *sessionID in self.analyticsSessions.allKeys) {
                BTAnalyticsSession *session = self.analyticsSessions[sessionID];
                if (session.events.count == 0) {
                    continue;
                }

                willPostAnalyticsEvent = YES;

                NSMutableDictionary *metadataParameters = [NSMutableDictionary dictionary];
                [metadataParameters addEntriesFromDictionary:session.metadataParameters];
                metadataParameters[@"sessionId"] = session.sessionID;
                metadataParameters[@"integrationType"] = session.integration;
                metadataParameters[@"source"] = session.source;
                
                NSMutableDictionary *postParameters = [NSMutableDictionary dictionary];
                if (session.events) {
                    // Map array of BTAnalyticsEvent to JSON
                    postParameters[@"analytics"] = [session.events valueForKey:@"json"];
                }
                postParameters[@"_meta"] = metadataParameters;
                if (self.apiClient.clientToken.authorizationFingerprint) {
                    postParameters[@"authorization_fingerprint"] = self.apiClient.clientToken.authorizationFingerprint;
                }
                if (self.apiClient.tokenizationKey) {
                    postParameters[@"tokenization_key"] = self.apiClient.tokenizationKey;
                }

                [session.events removeAllObjects];

                [self.http POST:@"/" parameters:postParameters completion:^(__unused BTJSON *body, __unused NSHTTPURLResponse *response, NSError *error) {
                    if (error != nil) {
                        NSLog(@"%@ Failed to flush analytics events: %@", [BTLogLevelDescription stringFor:BTLogLevelWarning],  error.localizedDescription);
                    }
                    if (completionBlock) completionBlock(error);
                }];
            }

            if (!willPostAnalyticsEvent && completionBlock) {
                completionBlock(nil);
            }
        });
    }];
}

#pragma mark - Helpers

- (void)enqueueEvent:(NSString *)eventKind {
    uint64_t timestampInMilliseconds = ([[NSDate date] timeIntervalSince1970] * 1000);
    BTAnalyticsEvent *event = [BTAnalyticsEvent event:eventKind withTimestamp:timestampInMilliseconds];

    BTAnalyticsSession *session = [BTAnalyticsSession sessionWithID:self.apiClient.metadata.sessionID
                                                             source:self.apiClient.metadata.sourceString
                                                        integration:self.apiClient.metadata.integrationString];
    if (!session) {
        NSLog(@"%@ Missing analytics session metadata - will not send event  %@", [BTLogLevelDescription stringFor:BTLogLevelWarning],  event.kind);
        return;
    }

    dispatch_async(self.sessionsQueue, ^{
        if (!self.analyticsSessions[session.sessionID]) {
            self.analyticsSessions[session.sessionID] = session;
        }

        [self.analyticsSessions[session.sessionID].events addObject:event];
    });
}

- (void)checkFlushThreshold {
    __block NSUInteger eventCount = 0;

    dispatch_sync(self.sessionsQueue, ^{
        for (BTAnalyticsSession *analyticsSession in self.analyticsSessions.allValues) {
            eventCount += analyticsSession.events.count;
        }
    });

    if (eventCount >= self.flushThreshold) {
        [self flush:nil];
    }
}

@end
