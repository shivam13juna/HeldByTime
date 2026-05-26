#!/usr/bin/env bash
# build.sh — Task 11 (app.md §10 step 13). Assemble and sign the double-clickable
# EncryptedVault.app, GATED on the test harness.
#
# The cardinal rule (app.md §10 step 13, §11 "Required tests"): this script runs
# the §11 hard-gate tests FIRST via ./run_tests and refuses to assemble or sign
# the bundle if any are red. So any .app produced by this official path has passed
# them — a *process* gate enforcing "no real secrets until gates pass", not a
# crypto boundary (a hand-assembled bundle is outside this guarantee; that limit
# is the §11 "honest ceiling").
#
# Pipeline:
#   gate → build helper (arm64) → SIGN the nested helper (final, ad-hoc) → hash the
#   SIGNED helper and inject that SHA-256 into the app (so HelperRunner.preflight
#   stops failing closed) → compile the RELEASE app (no -D DEBUG) → assert no
#   dry-run surface in the shipped binary → write Info.plist (no CLI/URL/document
#   surface) → SIGN the bundle → verify (codesign --verify --deep --strict; the
#   embedded helper's hash still equals the compiled-in value; otool -L; file).
#
# Why the helper is signed BEFORE it is hashed: codesign rewrites the Mach-O
# signature bytes, so hashing an unsigned helper and then signing it would compile
# in a hash that never matches the shipped binary — the app would (safely) fail
# closed forever. We hash exactly the bytes the app will preflight at runtime.
#
# Output: build/dist/EncryptedVault.app  (build/ is gitignored — never committed).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="EncryptedVault"
BUNDLE_ID="com.shivam.encryptedvault"
VERSION="1.0"
BUILD_NUMBER="1"
MIN_MACOS="14.0"
DRYRUN_MARKER='VAULT_DRYRUN_SURFACE_V1'

ICON_SRC="$ROOT/assets/icon.png"   # tracked source; built into AppIcon.icns below

BUILD="$ROOT/build"
DIST="$BUILD/dist"
APP="$DIST/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"
HELPERS_DIR="$APP/Contents/Helpers"
RES_DIR="$APP/Contents/Resources"

say() { printf '\n== %s ==\n' "$*"; }
die() { printf '\nBUILD FAILED: %s\n' "$*" >&2; exit 1; }

# ---- 0. HARD GATE: tests must pass before we assemble or sign anything --------
say "Gate — ./run_tests (refusing to assemble/sign if red)"
if ! ./run_tests; then
  die "test harness is red — not assembling or signing the .app (app.md §10 step 13)"
fi

# ---- 1. Build the Go vaultseal helper (arm64, vendored, no cgo) ---------------
say "Build vaultseal helper (arm64)"
mkdir -p "$BUILD"
( cd helper && GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 \
    go build -mod=vendor -trimpath -ldflags="-s -w" \
      -o "$BUILD/vaultseal" ./cmd/vaultseal ) || die "helper build failed"
file "$BUILD/vaultseal" | grep -q 'arm64' || die "helper is not an arm64 binary"

# ---- 2. Lay out the bundle, embed the helper, and SIGN it (NESTED-FIRST) ------
# The nested helper is signed before the bundle: signing the bundle seals a
# manifest of its nested code, so the helper must already carry its signature.
# Ad-hoc (`-s -`): this machine has no Developer ID and the build is for local use
# (no notarization). Hardened runtime is enabled for hygiene.
say "Embed + sign the nested helper (ad-hoc)"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$HELPERS_DIR" "$RES_DIR"
cp "$BUILD/vaultseal" "$HELPERS_DIR/vaultseal"
chmod 755 "$HELPERS_DIR/vaultseal"
codesign --force --options runtime --timestamp=none -s - "$HELPERS_DIR/vaultseal" \
  || die "signing the nested helper failed"

# ---- 3. Hash the SIGNED helper and inject it into BundledHelper.swift ---------
# The committed value is empty (fail-closed). Rewrite it in place for this build,
# restore it afterward via a trap so the working tree returns to fail-closed.
say "Inject SIGNED helper SHA-256 into the app"
HELPER_SHA_HEX="$(shasum -a 256 "$HELPERS_DIR/vaultseal" | awk '{print $1}')"
[ "${#HELPER_SHA_HEX}" -eq 64 ] || die "unexpected helper digest length: $HELPER_SHA_HEX"
SWIFT_BYTES="$(printf '%s' "$HELPER_SHA_HEX" | sed -E 's/(..)/0x\1, /g; s/, $//')"

BH="Sources/VaultApp/BundledHelper.swift"
BH_BAK="$BUILD/BundledHelper.swift.orig"
cp "$BH" "$BH_BAK"
restore_bh() { [ -f "$BH_BAK" ] && cp "$BH_BAK" "$BH"; }
trap restore_bh EXIT
/usr/bin/sed -i '' -E \
  "s#static let sha256: \[UInt8\] = \[\]#static let sha256: [UInt8] = [$SWIFT_BYTES]#" "$BH"
grep -q '0x' "$BH" || die "hash injection into $BH did not take"
echo "  signed helper sha256 = $HELPER_SHA_HEX"

# ---- 4. Build the vendored Argon2id static lib (same recipe as run_tests) -----
say "Build Argon2id static lib"
ACFLAGS="-O3 -Ivendor/argon2/include -Ivendor/argon2/src -ISources/CArgon2/include"
ASRC="vendor/argon2/src/argon2.c vendor/argon2/src/core.c vendor/argon2/src/encoding.c \
      vendor/argon2/src/ref.c vendor/argon2/src/thread.c vendor/argon2/src/blake2/blake2b.c \
      Sources/CArgon2/shim.c"
mkdir -p "$BUILD/aobj"
for f in $ASRC; do
  clang $ACFLAGS -c "$f" -o "$BUILD/aobj/$(basename "${f%.c}").o" || die "Argon2 C build failed: $f"
done
ar rcs "$BUILD/libargon2.a" "$BUILD"/aobj/*.o || die "Argon2 ar failed"

# ---- 5. Compile the RELEASE app executable (-O, NO -D DEBUG) ------------------
say "Compile the app (release)"
swiftc -O -parse-as-library \
    Sources/Constants/Constants.swift Sources/VaultCore/*.swift \
    Sources/VaultApp/*.swift Sources/VaultApp/Views/*.swift \
    -I Sources/CArgon2/include -Xcc -Ivendor/argon2/include \
    -L "$BUILD" -largon2 \
    -o "$MACOS_DIR/$APP_NAME" || die "app compile failed"

# Compile is done — restore the committed fail-closed default now (trap is backup).
restore_bh
trap - EXIT
rm -f "$BH_BAK"

# ---- 6. No dry-run / CLI surface may leak into the shipped binary -------------
say "Release-surface check (no DEBUG dry-run in the shipped binary)"
if strings "$MACOS_DIR/$APP_NAME" | grep -q "$DRYRUN_MARKER"; then
  die "dry-run marker '$DRYRUN_MARKER' present in the release app binary (DEBUG leaked)"
fi

# ---- 7. Info.plist (no CLI/URL/document surface) + PkgInfo --------------------
say "Write Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "Info.plist is malformed"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Defence in depth: the bundle must declare NO URL scheme and NO document types
# (no hidden launch/URL surface, no recent-documents association — app.md §10 s13).
if /usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  die "Info.plist declares CFBundleURLTypes — the app must expose no URL surface"
fi
if /usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  die "Info.plist declares CFBundleDocumentTypes — the app must expose no document surface"
fi

# ---- 7b. App icon — build AppIcon.icns from the committed assets/icon.png ------
# Cosmetic only: an .icns in Resources + CFBundleIconFile in the plist. Generated
# BEFORE the bundle is signed (step 8) so codesign seals it. Adds no URL/document
# /CLI surface. Done in a temp .iconset (sips resizes, iconutil packs).
if [ -f "$ICON_SRC" ]; then
  say "Generate AppIcon.icns from $ICON_SRC"
  ICONSET="$BUILD/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for sz in 16 32 128 256 512; do
    sips -z "$sz" "$sz" "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null 2>&1 \
      || die "sips ${sz}x${sz} failed"
    sips -z "$((sz*2))" "$((sz*2))" "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1 \
      || die "sips ${sz}x${sz}@2x failed"
  done
  iconutil -c icns "$ICONSET" -o "$RES_DIR/AppIcon.icns" || die "iconutil failed"
  [ -f "$RES_DIR/AppIcon.icns" ] || die "AppIcon.icns not produced"
else
  say "No $ICON_SRC — building without a custom icon (plist still names AppIcon)"
fi

# ---- 8. Sign the bundle (outer seal; leaves the signed nested helper intact) --
say "Sign the app bundle (ad-hoc)"
codesign --force --options runtime --timestamp=none -s - "$APP" \
  || die "signing the app bundle failed"

# ---- 9. Verify ----------------------------------------------------------------
say "Verify"
codesign --verify --deep --strict --verbose=2 "$APP" || die "codesign --verify --deep --strict failed"
codesign --verify --strict "$HELPERS_DIR/vaultseal" || die "nested helper signature invalid"

# The compiled-in hash must equal the SHIPPED helper's hash, AFTER the bundle was
# signed (proves bundle signing did not mutate the nested helper, and that the app
# the user runs will actually accept the helper instead of failing closed).
EMBEDDED_SHA="$(shasum -a 256 "$HELPERS_DIR/vaultseal" | awk '{print $1}')"
[ "$EMBEDDED_SHA" = "$HELPER_SHA_HEX" ] \
  || die "embedded helper hash ($EMBEDDED_SHA) != compiled-in hash ($HELPER_SHA_HEX) — app would fail closed"
echo "  embedded == compiled-in: $EMBEDDED_SHA"

echo "-- otool -L (linked libraries; expect only system frameworks/dylibs) --"
otool -L "$MACOS_DIR/$APP_NAME"
# A locally-built static-Argon2 app must not pull in /usr/local or a stray @rpath
# dylib (would be an unsigned, user-writable code surface beside the signed app).
if otool -L "$MACOS_DIR/$APP_NAME" | tail -n +2 | grep -E '^[[:space:]]+(/usr/local/|@rpath/|@executable_path/)' ; then
  die "app links a non-system dylib (unexpected dependency surface)"
fi

echo "-- file --"
file "$MACOS_DIR/$APP_NAME"
file "$MACOS_DIR/$APP_NAME" | grep -q 'Mach-O 64-bit executable arm64' \
  || die "app binary is not an arm64 Mach-O executable"
file "$HELPERS_DIR/vaultseal" | grep -q 'Mach-O 64-bit executable arm64' \
  || die "helper is not an arm64 Mach-O executable"

say "OK — $APP"
echo "Double-click in Finder, or:  open \"$APP\""
