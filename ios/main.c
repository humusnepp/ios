#include <stdio.h>

/*
 * RenPy Box entry point (mirrors the renios prototype's main.c).
 *
 * The app is an SDL-UIKit application: SDL_UIKitRunApp() launches the normal
 * UIKit app lifecycle and then calls our `player_main` on the main thread.
 * Instead of booting Ren'Py immediately, `player_main` shows the SwiftUI
 * library. When the user picks a game, Swift calls `launcher_main` (from
 * librenpython.a) which runs /base/main.py with the game dir as basedir.
 */

int player_main(int argc, char **argv);
int SDL_UIKitRunApp(int, char **, int (*)(int, char**));

int main(int argc, char **argv) {
    return SDL_UIKitRunApp(argc, argv, player_main);
}