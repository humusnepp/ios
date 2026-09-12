#!/usr/bin/env bash
#
# End-to-end build of the RenPy Box IPA (unsigned).
#
# Pipeline:
#   1. Download Ren'Py 8.5.3 SDK + renios DLC  (cached under ./build)
#   2. Create a headless Xcode project via the launcher's `ios_create` command,
#      which populates `base/` (renpy engine + python stdlib + entry main.py).
#   3. Post-process: patch base/main.py (per-game language support), keep the
#      engine, drop the placeholder game payload.
#   4. Generate the real Xcode project with XcodeGen around the renios
#      prototype sources + our SwiftUI shell.
#   5. Build for device with signing disabled and package an unsigned IPA.
#
# Requires: macOS (Xcode), bash, xcodegen, 7z (p7zip), curl, sips.
# Runs entirely headless - no Apple IDs, no signing.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
RENPY_VERSION="${RENPY_VERSION:-8.5.3}"
SDK_URL="https://www.renpy.org/dl/${RENPY_VERSION}/renpy-${RENPY_VERSION}-sdk.7z.exe"
RENIOS_URL="https://www.renpy.org/dl/${RENPY_VERSION}/renpy-${RENPY_VERSION}-renios.zip"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${ROOT}/build"
DIST="${BUILD}/dist"

SDK_7Z="${BUILD}/renpy-${RENPY_VERSION}-sdk.7z.exe"
RENIOS_ZIP="${BUILD}/renpy-${RENPY_VERSION}-renios.zip"
SDK="${BUILD}/sdk"
RENIOS="${BUILD}/renios"
PLACEHOLDER="${BUILD}/placeholder-project"
IOSOUT="${BUILD}/iosout"         # launcher-generated Xcode project
STAGE="${BUILD}/xcode"           # XcodeGen staging dir

APPNAME="RenPyBox"
BUNDLE_ID="com.renpybox.app"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Fetch assets
# ---------------------------------------------------------------------------
mkdir -p "${BUILD}" "${DIST}"
cd "${BUILD}"

if [ ! -f "${SDK}/renpy.sh" ]; then
  log "Fetching Ren'Py SDK (${RENPY_VERSION})..."
  test -f "${SDK_7Z}" || curl -fL --retry 3 -o "${SDK_7Z}" "${SDK_URL}"
  rm -rf "${SDK}"
  7z x -y "${SDK_7Z}" >/dev/null
  mv renpy-${RENPY_VERSION}-sdk "${SDK}"
fi

if [ ! -d "${RENIOS}/buildlib" ]; then
  log "Fetching renios (${RENPY_VERSION})..."
  test -f "${RENIOS_ZIP}" || curl -fL --retry 3 -o "${RENIOS_ZIP}" "${RENIOS_URL}"
  mkdir -p "${RENIOS}"
  unzip -q -o "${RENIOS_ZIP}" -d "${RENIOS}"
fi

# The launcher looks for renios inside the SDK directory (hash.txt checked).
log "Installing renios into SDK directory..."
rm -rf "${SDK}/renios"
cp -R "${RENIOS}/renios" "${SDK}/renios"

# ---------------------------------------------------------------------------
# 2. Create the Xcode project with the launcher, populate base/
# ---------------------------------------------------------------------------
if [ ! -d "${IOSOUT}" ]; then
  log "Creating placeholder project from SDK sample (the_question)..."
  rm -rf "${PLACEHOLDER}"
  cp -R "${SDK}/the_question" "${PLACEHOLDER}"

  # ios_populate regenerates the app icon from <project>/ios-icon.png.
  # The sample ships gui images, so synthesize one from its main menu art.
  if [ ! -f "${PLACEHOLDER}/ios-icon.png" ]; then
    MENU_IMG="$(find "${PLACEHOLDER}/game" -iname 'main_menu.png' | head -n1)"
    if [ -z "${MENU_IMG}" ]; then
      MENU_IMG="$(find "${PLACEHOLDER}/game" -iname '*.png' | head -n1)"
    fi
    if [ -n "${MENU_IMG}" ]; then
      cp "${MENU_IMG}" "${PLACEHOLDER}/ios-icon.png"
      sips --resampleWidth 1024 "${PLACEHOLDER}/ios-icon.png" >/dev/null 2>&1 || true
      sips --setProperty format png "${PLACEHOLDER}/ios-icon.png" >/dev/null 2>&1 || true
    else
      warn "No sample image found to synthesize ios-icon.png; ios_create may fail."
    fi
  fi

  log "Running launcher ios_create (headless)..."
  rm -rf "${IOSOUT}"
  (
    cd "${SDK}"
    if bash renpy.sh launcher ios_create "${PLACEHOLDER}" "${IOSOUT}" \
        > "${BUILD}/ios_create.log" 2>&1; then
      :
    else
      # Fallback: invoke the SDK python directly against the launcher.
      PY=""
      for cand in \
          "${SDK}/lib/py3-mac-`uname -m`/renpython" \
          "${SDK}/lib/py3-mac-universal2/renpython" \
          "${SDK}/lib/py3-mac-x86_64/renpython"; do
        if [ -x "${cand}" ]; then PY="${cand}"; break; fi
      done
      if [ -n "${PY}" ]; then
        "${PY}" launcher ios_create "${PLACEHOLDER}" "${IOSOUT}" \
          >> "${BUILD}/ios_create.log" 2>&1
      else
        cat "${BUILD}/ios_create.log"
        warn "renpy.sh launcher failed and no fallback python binary found."
        exit 1
      fi
    fi
  )
  log "ios_create done."
fi

BASE_SRC="${IOSOUT}/base"
test -d "${BASE_SRC}" || { echo "base/ missing in ${IOSOUT}"; exit 1; }

# ---------------------------------------------------------------------------
# 3. Post-process base/ (engine + stdlib, no baked-in game)
# ---------------------------------------------------------------------------
log "Preparing app base/ ..."
rm -rf "${STAGE}"
mkdir -p "${STAGE}/base"

# Keep engine + stdlib; drop the placeholder game payload (games live under
# Documents/stories/<Game> and are chosen from the native library).
rsync -a --exclude 'game/' --exclude '__pycache__' "${BASE_SRC}/" "${STAGE}/base/"

# Patch base/main.py: per-game launch config written by the app.
LANG_PATCH=$(cat <<'PY'
# --- RenPy Box: per-game launch config ---
import os as _rpb_os
_rpb_dir = _rpb_os.environ.get("RENPYBOX_GAME_DIR")
if _rpb_dir:
    _rpb_lang = _rpb_os.path.join(_rpb_dir, ".renpybox.lang")
    if _rpb_os.path.exists(_rpb_lang):
        try:
            import renpy as _rpb_renpy
            _txt = open(_rpb_lang, "r").read().strip()
            if _txt:
                _rpb_renpy.config.language = _txt
        except Exception:
            pass

PY
)

MAIN_PY="${STAGE}/base/main.py"
if [ -f "${MAIN_PY}" ]; then
  printf '%s' "${LANG_PATCH}" | cat - "${MAIN_PY}" > "${MAIN_PY}.new"
  mv "${MAIN_PY}.new" "${MAIN_PY}"
else
  warn "base/main.py missing - expected at ${MAIN_PY}"
fi

log "Staging engine files..."
mkdir -p "${STAGE}/prebuilt" "${STAGE}/Frameworks" "${STAGE}/engine"
cp -R "${IOSOUT}/prebuilt/release" "${STAGE}/prebuilt"
cp -R "${IOSOUT}/Frameworks"/* "${STAGE}/Frameworks/"
for f in "Launch Screen.storyboard" Media.xcassets LaunchImage-background.png \
         LaunchImage-foreground.png Log.m IAPHelper.m VideoPlayer.m; do
  cp -R "${IOSOUT}/${f}" "${STAGE}/engine/" 2>/dev/null || warn "missing engine file: ${f}"
done

# ---------------------------------------------------------------------------
# 4. Stage our app sources + generate Xcode project with XcodeGen
# ---------------------------------------------------------------------------
log "Staging app sources..."
cp -R "${ROOT}/ios/RenPyBox" "${STAGE}/RenPyBox"
cp "${ROOT}/ios/main.m"            "${STAGE}/main.m"
cp "${ROOT}/ios/RPBAppDelegate.m"  "${STAGE}/RPBAppDelegate.m"
cp "${ROOT}/ios/Info.plist"        "${STAGE}/Info.plist"
sed "s|__BUNDLE_ID__|${BUNDLE_ID}|" "${ROOT}/ios/project.yml" > "${STAGE}/project.yml"

log "Bundling test game (SDK sample the_question)..."
if [ -d "${SDK}/the_question" ]; then
  cp -R "${SDK}/the_question" "${STAGE}/TestGame"
else
  warn "SDK sample the_question not found; skipping test-game bundling"
fi

log "Generating Xcode project..."
cd "${STAGE}"
xcodegen generate

# ---------------------------------------------------------------------------
# 5. Build (unsigned) + package IPA
# ---------------------------------------------------------------------------
log "Building (no code signing)..."
rm -rf "${STAGE}/dd"
xcodebuild \
  -project RenPyBox.xcodeproj \
  -scheme RenPyBox \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "${STAGE}/dd" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP="${STAGE}/dd/Build/Products/Release-iphoneos/RenPyBox.app"
test -d "${APP}" || { echo "RenPyBox.app not found"; exit 1; }

log "Packaging IPA..."
rm -rf "${BUILD}/payload" "${DIST}/RenPyBox.ipa"
mkdir -p "${BUILD}/payload/Payload"
cp -R "${APP}" "${BUILD}/payload/Payload/RenPyBox.app"
(
  cd "${BUILD}/payload"
  zip -qry9 -r "${DIST}/RenPyBox.ipa" Payload/RenPyBox.app
)

log "Done: ${DIST}/RenPyBox.ipa"
ls -lh "${DIST}/RenPyBox.ipa"