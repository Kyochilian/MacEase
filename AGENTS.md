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
- Apple Silicon (arm64) only. No Intel or Universal builds.
- AVPlayer with a temporary-directory cache. GRDB for persistence.
- Feature scope and batch order are recorded in `docs/roadmap-features.md`
  (2026-08-13): playback basics → library read/write → discovery → heartbeat mode.
  Discovery data is prefetched once at launch; refreshes are user-triggered only,
  still no auto-retry and no background polling.

## UI style

- Strictly follow the macOS Sequoia 15 system visual style and Apple/macOS design
  aesthetics. Do not introduce Liquid Glass for now.
- Use system components, materials, typography, and semantic colors; avoid custom
  chrome that diverges from native macOS appearance.

## Implementation constraints

- Keep implementations minimal, concise, and efficient.
- Add only correctness and security checks supported by current evidence. Do not add
  speculative fallbacks, redundant compatibility layers, or "just in case" branches.
- Before implementing a complex feature (new endpoint, playback state machine,
  system integration), first consult `docs/reference-implementations.md`: it maps
  each feature to vetted open-source implementations (file-level paths, verified
  endpoint parameters, known quirks, and license red lines). Deep-read the
  referenced source via MCP fetch before writing code. Never copy code from
  GPL/unlicensed repos; MIT borrowings go into THIRD_PARTY_NOTICES.md.

## Research tools

MCP-first is mandatory for WebSearch and WebFetch.
Use native web tools only when the corresponding MCP tool is unavailable or fails.

## Mirrors (CN)

GitHub read operations must use mirrors first:
ghfast.top → gh-proxy.com → ghproxy.net → github.com.
Always push directly to GitHub.
When pushing, do not add any AI as a collaborator: do not invite AI
accounts to the repository, and do not include `Co-authored-by` trailers
for Cursor, Claude, or any other AI agent.

## Python

Always use uv venv. Activate with `source .venv/bin/activate.fish`, then run/pip.
