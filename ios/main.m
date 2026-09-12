//
//  main.m
//  RenPy Box
//
//  PLAIN UIKit boot. The app starts as an ordinary iPhone app (native SwiftUI
//  library) with no SDL engine involved at launch. When the user picks a game,
//  Swift calls the renios engine entry `launcher_main` on a background thread,
//  which boots Ren'Py in-process and renders into its own window.
//

#import <UIKit/UIKit.h>

void SDL_SetMainReady(void);

int main(int argc, char **argv) {
    SDL_SetMainReady();
    return UIApplicationMain(argc, argv, nil, @"RPBAppDelegate");
}