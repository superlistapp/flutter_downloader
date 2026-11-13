#import <Flutter/Flutter.h>
#import <XCTest/XCTest.h>
#import <flutter_downloader/FlutterDownloaderPlugin.h>
#import <objc/runtime.h>

@interface FlutterDownloaderPlugin (Testing)
- (instancetype)init:(NSObject<FlutterPluginRegistrar> *)registrar;
- (NSURLSession *)currentSession;
+ (void)setSessionWaitTimeout:(NSTimeInterval)timeout;
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

// Spins the main run loop until `condition` holds or `timeout` passes.
- (BOOL)waitUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    return condition();
}

- (void)call:(FlutterDownloaderPlugin *)plugin method:(NSString *)method arguments:(id)arguments result:(FlutterResult)result {
    [plugin handleMethodCall:[FlutterMethodCall methodCallWithMethodName:method arguments:arguments] result:result];
}

// Waits for the background session through a task method, which runs once it exists.
- (void)waitForSession:(FlutterDownloaderPlugin *)plugin {
    __block BOOL answered = NO;
    [self call:plugin method:@"cancelAll" arguments:nil result:^(id value) { answered = YES; }];
    XCTAssertTrue([self waitUntil:^BOOL { return answered; } timeout:kSessionCreationDelay * 3]);
}

- (NSNumber *)storedStatusOf:(NSString *)taskId plugin:(FlutterDownloaderPlugin *)plugin {
    __block NSNumber *status = nil;
    [self call:plugin method:@"loadTasks" arguments:nil result:^(NSArray<NSDictionary *> *tasks) {
        for (NSDictionary *task in tasks) {
            if ([task[@"task_id"] isEqualToString:taskId]) status = task[@"status"];
        }
    }];
    return status;
}

- (NSDictionary *)enqueueArguments:(NSString *)fileName {
    // Not routable: the task stays running until it is canceled.
    return @{@"url": [@"http://10.255.255.1/" stringByAppendingString:fileName], @"saved_dir": NSTemporaryDirectory(),
             @"file_name": fileName, @"headers": @"", @"show_notification": @NO, @"open_file_from_notification": @NO};
}

// Registers the plugin as GeneratedPluginRegistrant does on an engine.
- (FlutterDownloaderPlugin *)registerOnNewEngine {
    NSString *name = [NSString stringWithFormat:@"test-engine-%lu", (unsigned long)engines.count];
    FlutterEngine *engine = [[FlutterEngine alloc] initWithName:name project:nil allowHeadlessExecution:YES];
    XCTAssertTrue([engine runWithEntrypoint:@"idleEngineMain"]);
    [engines addObject:engine];
    return [[FlutterDownloaderPlugin alloc] init:[engine registrarForPlugin:@"FlutterDownloaderPlugin"]];
}

// Runs first (tests run in name order) so that it makes the first registration in
// the process: the session is still being created when the calls arrive.
- (void)testCallsDuringSessionCreationWaitInOrderWithoutBlockingTheMainThread {
    FlutterDownloaderPlugin *plugin = [self registerOnNewEngine];
    [self registerOnNewEngine];

    NSMutableArray<NSString *> *answers = [NSMutableArray array];
    NSMutableDictionary<NSString *, id> *values = [NSMutableDictionary dictionary];
    __block BOOL answeredOffMain = NO;
    __block NSString *firstTaskId = nil, *secondTaskId = nil;
    FlutterResult (^record)(NSString *) = ^FlutterResult(NSString *label) {
        return ^(id value) {
            answeredOffMain |= !NSThread.isMainThread;
            [answers addObject:label];
            if (value != nil) values[label] = value;
        };
    };

    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    [self call:plugin method:@"enqueue" arguments:[self enqueueArguments:@"first.bin"] result:^(id value) {
        firstTaskId = value;
        record(@"enqueue first")(value);
    }];
    [self call:plugin method:@"cancelAll" arguments:nil result:record(@"cancelAll")];
    [self call:plugin method:@"enqueue" arguments:[self enqueueArguments:@"second.bin"] result:^(id value) {
        secondTaskId = value;
        record(@"enqueue second")(value);
        // What Dart does once enqueue answers: cancel the new task right away.
        [self call:plugin method:@"cancel" arguments:@{@"task_id": value} result:record(@"cancel second")];
    }];
    [self call:plugin method:@"loadTasks" arguments:nil result:record(@"loadTasks")];
    NSDictionary *unknown = @{@"task_id": @"unknown", @"should_delete_content": @NO};
    for (NSString *method in @[@"pause", @"remove", @"retry", @"resume", @"cancel", @"open"]) {
        [self call:plugin method:method arguments:unknown result:record(method)];
    }
    XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 0.2, @"a call waited for the session");
    XCTAssertEqual(answers.count, 0u, @"answered before the session existed: %@", answers);

    NSArray *expected = @[@"enqueue first", @"cancelAll", @"enqueue second", @"cancel second", @"loadTasks",
                          @"pause", @"remove", @"retry", @"resume", @"cancel", @"open"];
    XCTAssertTrue([self waitUntil:^BOOL { return answers.count >= expected.count; } timeout:kSessionCreationDelay * 3]);
    [self waitUntil:^BOOL { return NO; } timeout:0.5];
    XCTAssertEqualObjects(answers, expected);
    XCTAssertFalse(answeredOffMain);

    // cancelAll ran after the first enqueue, and the cancel after the second one.
    XCTAssertTrue([self waitUntil:^BOOL {
        return [[self storedStatusOf:firstTaskId plugin:plugin] intValue] == 5 &&
               [[self storedStatusOf:secondTaskId plugin:plugin] intValue] == 5;
    } timeout:10], @"first %@, second %@", [self storedStatusOf:firstTaskId plugin:plugin],
                  [self storedStatusOf:secondTaskId plugin:plugin]);
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

    [self waitForSession:plugins.lastObject];
    NSURLSession *session = [plugins.lastObject currentSession];
    XCTAssertTrue([session.configuration.identifier hasSuffix:kBackgroundSessionSuffix]);
    XCTAssertFalse(backgroundSessionCreatedOnMainThread);
}

- (void)testRegisteringOnMoreEnginesKeepsTheSessionAndItsDelegate {
    FlutterDownloaderPlugin *plugin = [self registerOnNewEngine];
    [self registerOnNewEngine];
    [self waitForSession:plugin];
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

- (void)testSuccessfulQueuedCallIsNotAnsweredAgainAfterItsDeadline {
    FlutterDownloaderPlugin *plugin = [self registerOnNewEngine];
    [self registerOnNewEngine];
    __block BOOL ready = NO;
    [self call:plugin method:@"cancelAll" arguments:nil result:^(id value) { ready = YES; }];
    // Earlier tests may still have registrations on the serial creation queue.
    XCTAssertTrue([self waitUntil:^BOOL { return ready; } timeout:kSessionCreationDelay * 6]);

    [FlutterDownloaderPlugin setSessionWaitTimeout:3];
    [self registerOnNewEngine];
    __block int answers = 0;
    __block int errors = 0;
    [self call:plugin method:@"loadTasks" arguments:nil result:^(id value) {
        answers++;
        errors += [value isKindOfClass:FlutterError.class] ? 1 : 0;
    }];
    XCTAssertEqual(answers, 0);
    XCTAssertTrue([self waitUntil:^BOOL { return answers > 0; } timeout:6]);
    XCTAssertEqual(errors, 0);
    // The timeout must remain harmless after the ready callback clears the queue.
    [self waitUntil:^BOOL { return NO; } timeout:3.5];
    XCTAssertEqual(answers, 1);
    XCTAssertEqual(errors, 0);
    [FlutterDownloaderPlugin setSessionWaitTimeout:15];
}

- (void)testTaskCallsWaitingTooLongForTheSessionFailAndLaterCallsStillRun {
    [FlutterDownloaderPlugin setSessionWaitTimeout:0.5];
    FlutterDownloaderPlugin *plugin = [self registerOnNewEngine];
    // Registered after the headless runner exists, so this one creates a session.
    [self registerOnNewEngine];

    NSString *lateFile = [NSUUID.UUID.UUIDString stringByAppendingString:@"-late.bin"];
    __block int lateAnswers = 0;
    __block id lateAnswer = nil;
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    [self call:plugin method:@"enqueue" arguments:[self enqueueArguments:lateFile] result:^(id value) {
        lateAnswers++;
        lateAnswer = value;
    }];
    XCTAssertTrue([self waitUntil:^BOOL { return lateAnswers > 0; } timeout:kSessionCreationDelay]);
    XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, kSessionCreationDelay, @"answered only with the session");
    XCTAssertTrue([lateAnswer isKindOfClass:FlutterError.class], @"%@", lateAnswer);
    XCTAssertEqualObjects([(FlutterError *)lateAnswer code], @"session_unavailable");

    [FlutterDownloaderPlugin setSessionWaitTimeout:15];
    __block id taskId = nil;
    [self call:plugin method:@"enqueue" arguments:[self enqueueArguments:@"after-timeout.bin"] result:^(id value) {
        taskId = value;
    }];
    XCTAssertTrue([self waitUntil:^BOOL { return taskId != nil; } timeout:kSessionCreationDelay * 5]);
    XCTAssertTrue([taskId isKindOfClass:NSString.class], @"%@", taskId);
    [self waitUntil:^BOOL { return NO; } timeout:0.5];
    XCTAssertEqual(lateAnswers, 1, @"the timed-out call also ran");

    __block NSArray<NSDictionary *> *tasks = nil;
    [self call:plugin method:@"loadTasks" arguments:nil result:^(NSArray<NSDictionary *> *value) { tasks = value; }];
    XCTAssertTrue([self waitUntil:^BOOL { return tasks != nil; } timeout:2]);
    for (NSDictionary *task in tasks) {
        XCTAssertNotEqualObjects(task[@"file_name"], lateFile);
    }
    [self call:plugin method:@"cancel" arguments:@{@"task_id": taskId} result:^(id value) {}];
    XCTAssertTrue([self waitUntil:^BOOL { return [[self storedStatusOf:taskId plugin:plugin] intValue] == 5; }
                          timeout:10], @"status %@", [self storedStatusOf:taskId plugin:plugin]);
}

@end
