#include "AppDelegate.h"
#include "GeneratedPluginRegistrant.h"
#include "FlutterDownloaderPlugin.h"

@implementation AppDelegate

void registerPlugins(NSObject<FlutterPluginRegistry>* registry) {
    if (![registry hasPlugin:@"FlutterDownloaderPlugin"]) {
        [FlutterDownloaderPlugin registerWithRegistrar:[registry registrarForPlugin:@"FlutterDownloaderPlugin"]];
    }
}

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  // The plugin tests register the plugin themselves, so they control its first registration.
  if (NSProcessInfo.processInfo.environment[@"XCTestConfigurationFilePath"] == nil) {
    [GeneratedPluginRegistrant registerWithRegistry:self];
  }
  [FlutterDownloaderPlugin setPluginRegistrantCallback:registerPlugins];
  // Override point for customization after application launch.
  return [super application:application didFinishLaunchingWithOptions:launchOptions];
}

@end
