/*
 * RenPy Box entry point - PLAIN UIKit boot.
 *
 * The app starts as an ordinary iPhone app (native SwiftUI library). No SDL
 * engine is involved at launch - that's what produces the guaranteed-visible
 * Apple GUI. When the user picks a game, Swift calls `launcher_main` (the
 * renios engine entry, provided by librenpython.a) on a background thread,
 * which boots Ren'Py in-process and renders into its own window.
 */

void SDL_SetMainReady(void);

int main(int argc, char **argv) {
    SDL_SetMainReady();
    return UIApplicationMain(argc, argv, NULL, "RPBAppDelegate");
}