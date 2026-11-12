#import <Flutter/Flutter.h>
#import <XCTest/XCTest.h>
#import <flutter_downloader/FlutterDownloaderPlugin.h>
#import <objc/runtime.h>

@interface FlutterDownloaderPlugin (Testing)
- (instancetype)init:(NSObject<FlutterPluginRegistrar> *)registrar;
- (NSURLSession *)currentSession;
@end

static NSString *const kBackgroundSessionSuffix = @".download.background.session";
static const NSTimeInterval kSessionCreationDelay = 2;

static IMP originalSessionWithConfiguration;
static BOOL backgroundSessionCreatedOnMainThread = NO;

// Stands in for a slow nsurlsessiond: creating a background session waits for its reply.
static NSURLSession *slowSessionWithConfiguration(id self, SEL _cmd, NSURLSessionConfiguration *configuration,
                                                  id<NSURLSessionDelegate> delegate, NSOperationQueue *queue) {
    if ([configuration.identifier hasSuffix:kBackgroundSessionSuffix]) {
        @synchronized (NSURLSession.class) {
            backgroundSessionCreatedOnMainThread |= NSThread.isMainThread;
        }
        [NSThread sleepForTimeInterval:kSessionCreationDelay];
    }
    return ((NSURLSession * (*)(id, SEL, id, id, id))originalSessionWithConfiguration)(
        self, _cmd, configuration, delegate, queue);
}

@interface FlutterDownloaderPluginTests : XCTestCase
@end

@implementation FlutterDownloaderPluginTests

static NSMutableArray<FlutterEngine *> *engines;

+ (void)setUp {
    [super setUp];
    engines = [NSMutableArray array];
    Method method = class_getClassMethod(NSURLSession.class, @selector(sessionWithConfiguration:delegate:delegateQueue:));
    originalSessionWithConfiguration = method_setImplementation(method, (IMP)slowSessionWithConfiguration);
}

+ (void)tearDown {
    Method method = class_getClassMethod(NSURLSession.class, @selector(sessionWithConfiguration:delegate:delegateQueue:));
    method_setImplementation(method, originalSessionWithConfiguration);
    [super tearDown];
}

// Registers the plugin as GeneratedPluginRegistrant does on an engine.
- (FlutterDownloaderPlugin *)registerOnNewEngine {
    NSString *name = [NSString stringWithFormat:@"test-engine-%lu", (unsigned long)engines.count];
    FlutterEngine *engine = [[FlutterEngine alloc] initWithName:name project:nil allowHeadlessExecution:YES];
    XCTAssertTrue([engine runWithEntrypoint:@"idleEngineMain"]);
    [engines addObject:engine];
    return [[FlutterDownloaderPlugin alloc] init:[engine registrarForPlugin:@"FlutterDownloaderPlugin"]];
}

- (void)testRegisteringDoesNotWaitForTheBackgroundSessionOnTheMainThread {
    XCTAssertTrue(NSThread.isMainThread);

    // The first plugin instance creates the headless runner; the next is the one
    // startBackgroundIsolate registers on it, which owns the background session.
    NSMutableArray<FlutterDownloaderPlugin *> *plugins = [NSMutableArray array];
    for (int i = 0; i < 2; i++) {
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        [plugins addObject:[self registerOnNewEngine]];
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, kSessionCreationDelay / 4,
                          @"registration %d waited for the background session", i);
    }

    NSURLSession *session = [plugins.lastObject currentSession];
    XCTAssertTrue([session.configuration.identifier hasSuffix:kBackgroundSessionSuffix]);
    XCTAssertFalse(backgroundSessionCreatedOnMainThread);
}

- (void)testRegisteringOnMoreEnginesKeepsTheSessionAndItsDelegate {
    FlutterDownloaderPlugin *plugin = [self registerOnNewEngine];
    [self registerOnNewEngine];
    NSURLSession *session = [plugin currentSession];
    XCTAssertNotNil(session);
    id<NSURLSessionDelegate> delegate = session.delegate;

    // Other engines (e.g. flutter_local_notifications' background isolate) run
    // GeneratedPluginRegistrant, which registers this plugin again.
    [self registerOnNewEngine];
    [self registerOnNewEngine];
    XCTAssertEqual([plugin currentSession], session);
    XCTAssertEqual(session.delegate, delegate);

    for (FlutterEngine *engine in engines) {
        [engine destroyContext];
    }
    [engines removeAllObjects];
    XCTAssertEqual([plugin currentSession], session);
    XCTAssertEqual(session.delegate, delegate);
}

@end
