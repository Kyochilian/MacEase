# AGENTS.md

## Project identity

MacEase is an unofficial third-party NetEase Cloud Music client for macOS.
MacEase is a native macOS application built with Apple technologies.
Cross-platform or non-native technologies require explicit justification.

## Current phase

The design phase is complete. See `init.md` for the full research findings, confirmed
decisions with rationale, architecture draft, roadmap, and risk register.

## Confirmed decisions

- Public open-source product (MIT), distributed via GitHub Releases with Developer ID
signing, notarization, and Sparkle 2. Never submitted to the Mac App Store.
- NetEase-only client. No multi-source provider abstraction, but all API calls stay
inside the `NeteaseKit` SPM module.
- Native Swift implementation of weapi/eapi. No Node.js gateway, no bundled sidecar.
- Login via WKWebView loading the official NetEase login page, then extracting cookies.
- Deployment target macOS 15. SwiftUI first, AppKit as an escape hatch.
- AVPlayer with a temporary-directory cache. GRDB for persistence.

## Research tools

MCP-first is mandatory for WebSearch and WebFetch.
Use native web tools only when the corresponding MCP tool is unavailable or fails.

## Mirrors (CN)

GitHub read operations must use mirrors first:
ghfast.top → gh-proxy.com → ghproxy.net → github.com.
Always push directly to GitHub.

## Python

Always use uv venv. Activate with `source .venv/bin/activate.fish`, then run/pip.
