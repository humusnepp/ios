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
# 3. Patch the generated project's base/main.py (per-game launch config stays
#    future-proof; harmless when a single game is baked in)
# ---------------------------------------------------------------------------
BASE_SRC="${IOSOUT}/base"
test -d "${BASE_SRC}" || { echo "base/ missing in ${IOSOUT}"; exit 1; }

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

MAIN_PY="${BASE_SRC}/main.py"
if [ -f "${MAIN_PY}" ]; then
  printf '%s' "${LANG_PATCH}" | cat - "${MAIN_PY}" > "${MAIN_PY}.new"
  mv "${MAIN_PY}.new" "${MAIN_PY}"
else
  warn "base/main.py missing - expected at ${MAIN_PY}"
fi

# ---------------------------------------------------------------------------
# 4. Build the renios-generated reference project (NO hand-rolled linking).
#    This is the exact pipeline renios ships with: the sample game (baked in
#    by ios_create) plays as soon as the app boots.
# ---------------------------------------------------------------------------
PROJ="$(find "${IOSOUT}" -maxdepth 3 -name '*.xcodeproj' | head -n 1)"
test -n "${PROJ}" || { echo "No .xcodeproj in ${IOSOUT}"; exit 1; }
log "Using generated project: ${PROJ}"

TARGET="$(xcodebuild -list -project "${PROJ}" 2>/dev/null | awk '/Targets:/{f=1;next} /Build Configurations:/{f=0} f && NF{print $1; exit}')"
test -n "${TARGET}" || { echo "No target found in ${PROJ}"; exit 1; }
log "Build target: ${TARGET}"

log "Building unsigned IPA (reference renios project)..."
rm -rf "${BUILD}/dd"
xcodebuild \
  -project "${PROJ}" \
  -target "${TARGET}" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "${BUILD}/dd" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP="$(find "${BUILD}/dd/Build/Products/Release-iphoneos" -maxdepth 1 -name '*.app' | head -n 1)"
test -d "${APP}" || { echo "'${APP}' not found"; exit 1; }
log "Built app: ${APP}"

# ---------------------------------------------------------------------------
# 5. Package IPA
# ---------------------------------------------------------------------------
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