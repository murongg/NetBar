#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/package-release.sh [options]

Builds NetBar.app and packages release artifacts into dist/.

Options:
  --skip-build          Reuse the existing .build/release/NetBar executable.
  --output-dir <path>   Write artifacts to this directory. Defaults to dist.
  --appcast-download-url-prefix <url>
                        Generate dist/appcast.xml for Sparkle updates using
                        SPARKLE_PRIVATE_KEY and this release asset URL prefix.
  -h, --help            Show this help.

Artifacts:
  NetBar-macos-<arch>.dmg
  NetBar-macos-<arch>.dmg.sha256
  NetBar-macos-<arch>.tar.gz
  NetBar-macos-<arch>.tar.gz.sha256
  appcast.xml when --appcast-download-url-prefix is provided
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

SKIP_BUILD=0
OUTPUT_DIR="dist"
APPCAST_DOWNLOAD_URL_PREFIX=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a path"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --appcast-download-url-prefix)
      [[ $# -ge 2 ]] || die "--appcast-download-url-prefix requires a URL"
      APPCAST_DOWNLOAD_URL_PREFIX="$2"
      shift 2
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      die "unexpected argument: $1"
      ;;
  esac
done

command -v git >/dev/null || die "git is required"
command -v swift >/dev/null || die "swift is required"
command -v ditto >/dev/null || die "ditto is required"
command -v hdiutil >/dev/null || die "hdiutil is required to build a DMG"
command -v iconutil >/dev/null || die "iconutil is required to build the app icon"
command -v install_name_tool >/dev/null || die "install_name_tool is required"
command -v shasum >/dev/null || die "shasum is required"
command -v sips >/dev/null || die "sips is required to build the app icon"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "${REPO_ROOT}"

[[ -n "${OUTPUT_DIR}" && "${OUTPUT_DIR}" != "/" ]] || die "refusing to use unsafe output directory: ${OUTPUT_DIR}"

APP_NAME="NetBar"
BUNDLE_ID="com.murongg.NetBar"
EXECUTABLE_PATH=".build/release/${APP_NAME}"
ICON_SOURCE_PATH="Resources/NetBarIcon.png"
BUILD_PRODUCTS_DIR="$(dirname "${EXECUTABLE_PATH}")"
SPARKLE_FRAMEWORK_PATH="${BUILD_PRODUCTS_DIR}/Sparkle.framework"
SPARKLE_BIN_DIR=".build/artifacts/sparkle/Sparkle/bin"
VERSION="$(sed -nE 's/.*static let current = AppVersion\("([^"]+)"\)!.*/\1/p' Sources/NetBarCore/AppUpdate.swift | head -n 1)"
[[ -n "${VERSION}" ]] || die "could not read AppVersion.current from Sources/NetBarCore/AppUpdate.swift"

if [[ "${SKIP_BUILD}" != "1" ]]; then
  swift build -c release
fi

[[ -x "${EXECUTABLE_PATH}" ]] || die "missing release executable at ${EXECUTABLE_PATH}"
[[ -f "${ICON_SOURCE_PATH}" ]] || die "missing app icon source at ${ICON_SOURCE_PATH}"
[[ -d "${SPARKLE_FRAMEWORK_PATH}" ]] || die "missing Sparkle framework at ${SPARKLE_FRAMEWORK_PATH}; run swift build -c release first"

ARCH="$(uname -m)"
ASSET_NAME="${APP_NAME}-macos-${ARCH}"
DIST_DIR="${OUTPUT_DIR}"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
TARBALL_PATH="${DIST_DIR}/${ASSET_NAME}.tar.gz"
DMG_PATH="${DIST_DIR}/${ASSET_NAME}.dmg"
APPCAST_PATH="${DIST_DIR}/appcast.xml"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/netbar-package.XXXXXX")"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

rm -rf "${DIST_DIR}"
mkdir -p "${MACOS_DIR}" "${FRAMEWORKS_DIR}" "${RESOURCES_DIR}"

cp "${EXECUTABLE_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"
ditto "${SPARKLE_FRAMEWORK_PATH}" "${FRAMEWORKS_DIR}/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS_DIR}/${APP_NAME}"

ICONSET_DIR="${WORK_DIR}/${APP_NAME}.iconset"
mkdir -p "${ICONSET_DIR}"
sips -z 16 16 "${ICON_SOURCE_PATH}" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
sips -z 32 32 "${ICON_SOURCE_PATH}" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "${ICON_SOURCE_PATH}" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
sips -z 64 64 "${ICON_SOURCE_PATH}" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "${ICON_SOURCE_PATH}" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
sips -z 256 256 "${ICON_SOURCE_PATH}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "${ICON_SOURCE_PATH}" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
sips -z 512 512 "${ICON_SOURCE_PATH}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "${ICON_SOURCE_PATH}" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
sips -z 1024 1024 "${ICON_SOURCE_PATH}" --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null
iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/${APP_NAME}.icns"

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleIconFile</key>
  <string>${APP_NAME}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUFeedURL</key>
  <string>https://github.com/murongg/NetBar/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>4gATT3v06UxBra63em2BlXbqfJ3kgf8TkBlpzoANcsQ=</string>
  <key>SURequireSignedFeed</key>
  <true/>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
</dict>
</plist>
EOF

if command -v codesign >/dev/null; then
  codesign --force --deep --sign - "${APP_BUNDLE}" >/dev/null
fi

tar -czf "${TARBALL_PATH}" -C "${DIST_DIR}" "${APP_NAME}.app"

DMG_ROOT="${WORK_DIR}/dmg-root"
mkdir -p "${DMG_ROOT}"
cp -R "${APP_BUNDLE}" "${DMG_ROOT}/"
ln -s /Applications "${DMG_ROOT}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_ROOT}" -ov -format UDZO "${DMG_PATH}" >/dev/null

checksum() {
  local artifact="$1"
  (
    cd "$(dirname "${artifact}")"
    shasum -a 256 "$(basename "${artifact}")" > "$(basename "${artifact}").sha256"
  )
}

checksum "${TARBALL_PATH}"
checksum "${DMG_PATH}"

if [[ -n "${APPCAST_DOWNLOAD_URL_PREFIX}" ]]; then
  [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]] || die "SPARKLE_PRIVATE_KEY is required to generate a Sparkle appcast"
  [[ -x "${SPARKLE_BIN_DIR}/generate_appcast" ]] || die "missing Sparkle generate_appcast tool at ${SPARKLE_BIN_DIR}/generate_appcast"

  APPCAST_WORK_DIR="${WORK_DIR}/appcast"
  mkdir -p "${APPCAST_WORK_DIR}"
  cp "${DMG_PATH}" "${APPCAST_WORK_DIR}/"
  cat > "${APPCAST_WORK_DIR}/${ASSET_NAME}.md" <<EOF
# NetBar ${VERSION}

See the GitHub release for the full changelog.
EOF

  printf '%s' "${SPARKLE_PRIVATE_KEY}" | "${SPARKLE_BIN_DIR}/generate_appcast" \
    --ed-key-file - \
    --download-url-prefix "${APPCAST_DOWNLOAD_URL_PREFIX%/}/" \
    --link "https://github.com/murongg/NetBar" \
    --embed-release-notes \
    --maximum-versions 1 \
    -o "${APPCAST_PATH}" \
    "${APPCAST_WORK_DIR}" >/dev/null
fi

echo "Packaged release artifacts:"
echo "  ${TARBALL_PATH}"
echo "  ${TARBALL_PATH}.sha256"
echo "  ${DMG_PATH}"
echo "  ${DMG_PATH}.sha256"
if [[ -f "${APPCAST_PATH}" ]]; then
  echo "  ${APPCAST_PATH}"
fi
