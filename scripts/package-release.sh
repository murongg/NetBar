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
  -h, --help            Show this help.

Artifacts:
  NetBar-macos-<arch>.dmg
  NetBar-macos-<arch>.dmg.sha256
  NetBar-macos-<arch>.tar.gz
  NetBar-macos-<arch>.tar.gz.sha256
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

SKIP_BUILD=0
OUTPUT_DIR="dist"

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
command -v hdiutil >/dev/null || die "hdiutil is required to build a DMG"
command -v shasum >/dev/null || die "shasum is required"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "${REPO_ROOT}"

[[ -n "${OUTPUT_DIR}" && "${OUTPUT_DIR}" != "/" ]] || die "refusing to use unsafe output directory: ${OUTPUT_DIR}"

APP_NAME="NetBar"
BUNDLE_ID="com.murongg.NetBar"
EXECUTABLE_PATH=".build/release/${APP_NAME}"
VERSION="$(sed -nE 's/.*static let current = AppVersion\("([^"]+)"\)!.*/\1/p' Sources/NetBarCore/AppUpdate.swift | head -n 1)"
[[ -n "${VERSION}" ]] || die "could not read AppVersion.current from Sources/NetBarCore/AppUpdate.swift"

if [[ "${SKIP_BUILD}" != "1" ]]; then
  swift build -c release
fi

[[ -x "${EXECUTABLE_PATH}" ]] || die "missing release executable at ${EXECUTABLE_PATH}"

ARCH="$(uname -m)"
ASSET_NAME="${APP_NAME}-macos-${ARCH}"
DIST_DIR="${OUTPUT_DIR}"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
TARBALL_PATH="${DIST_DIR}/${ASSET_NAME}.tar.gz"
DMG_PATH="${DIST_DIR}/${ASSET_NAME}.dmg"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/netbar-package.XXXXXX")"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

rm -rf "${DIST_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${EXECUTABLE_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

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

echo "Packaged release artifacts:"
echo "  ${TARBALL_PATH}"
echo "  ${TARBALL_PATH}.sha256"
echo "  ${DMG_PATH}"
echo "  ${DMG_PATH}.sha256"
