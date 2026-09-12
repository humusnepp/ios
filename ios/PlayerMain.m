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
        // First milestone drawn on screen BEFORE any Swift code runs, proving
        // the SDL -> player_main -> Swift bridge is alive.
        [RenPyBoxBoot mark:@"player_main entered"];
        [RenPyBoxGameLauncher startApp];
    }
    return 0;
}