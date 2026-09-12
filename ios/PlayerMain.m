//
//  PlayerMain.m
//  RenPy Box
//
//  player_main is the SDL main function handed to SDL_UIKitRunApp() by
//  main.c. It boots the SwiftUI library (hosted in SDL's UIKit window).
//

#import <Foundation/Foundation.h>

// Import the generated Swift module header so we can talk to Swift directly.
#import "RenPyBox-Swift.h"

extern int launcher_main(int argc, char **argv);

int player_main(int argc, char **argv) {
    @autoreleasepool {
        // After a game quits, launcher_main returns and Swift re-presents the
        // library itself - nothing else to do here.
        [RenPyBoxGameLauncher startApp];
    }
    return 0;
}