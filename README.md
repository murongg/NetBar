# NetBar

[![CI](https://github.com/murongg/NetBar/actions/workflows/ci.yml/badge.svg)](https://github.com/murongg/NetBar/actions/workflows/ci.yml)
[![Release](https://github.com/murongg/NetBar/actions/workflows/release.yml/badge.svg)](https://github.com/murongg/NetBar/actions/workflows/release.yml)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![AppKit](https://img.shields.io/badge/UI-AppKit-147EFB)](https://developer.apple.com/documentation/appkit)

NetBar is a lightweight macOS menu bar traffic monitor for seeing which apps are using bandwidth, how much they upload and download, and whether traffic is going through the system proxy or a direct connection.

## Features

- Menu-bar-only experience with no Dock icon.
- Live upload and download rates in the menu bar, arranged for compact scanning.
- Native AppKit popover dashboard with a focused dark, glassy interface.
- Per-app traffic ranking with app icons, total usage, download usage, upload usage, and visual share bars.
- Time range switching for Hour, Today, Week, and Month statistics.
- Traffic route breakdown for Proxy, Direct, Local, and Unknown usage.
- Best-effort proxy detection based on the current system HTTP, HTTPS, and SOCKS proxy ports.
- Current app version shown inside the popover.
- In-app updates powered by Sparkle, using signed GitHub Release appcasts.
- Daily sharded traffic history for fast startup even after long-term use.
- Automatic retention cleanup for older traffic shards.
- Permission-friendly sampling through macOS `nettop`, with no Network Extension or System Extension required.
