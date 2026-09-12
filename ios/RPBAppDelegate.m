//
//  RPBAppDelegate.m
//  RenPy Box
//
//  Standard UIKit app delegate: creates the single window whose root is the
//  SwiftUI library. The engine (SDL/Ren'Py) is only started later, on demand,
//  so the library UI is guaranteed to appear.
//

#import <UIKit/UIKit.h>
#import "RenPyBox-Swift.h"

@interface RPBAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation RPBAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    [RenPyBoxBoot mark:@"RPBAppDelegate didFinishLaunching"];

    UIViewController *library = [RenPyBoxGameLauncher libraryRootController];
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    window.rootViewController = library;
    self.window = window;
    [window makeKeyAndVisible];

    [RenPyBoxBoot mark:@"library attached as window root"];
    return YES;
}

@end