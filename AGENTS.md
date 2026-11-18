# AGENTS.md — Notch Ping

Guidelines and architectural invariants for contributors and coding agents working in this repository.

## Overview

Notch Ping is a native, dependency-free macOS indicator (`macOS 14+`, `Swift 6`) that surfaces background coding-agent sessions (**Codex**, **Claude Code**, and **Antigravity**) when they are actively working, blocked on user input/approval, finished, or failed.

## Core Invariants

1. **Zero external dependencies & zero network:**
   - Use only `SwiftUI`, `AppKit`, `Foundation`, `CryptoKit`, and `Darwin` in Swift targets, and the Python 3 standard library in `scripts/`.
   - Never add network requests, telemetry, analytics, auto-updaters, usage dashboards, or chat views.
   - Maintain `0.0%` CPU and zero repeating timers when idle (no active/unread sessions).

2. **Notch & Menu-Bar UI Geometry:**
   - Never widen the physical MacBook notch or draw black wings over neighboring menu-bar items.
   - Render the supplied 16-point Lucide Bot mark (`ThirdParty/Lucide/bot.svg`, ISC notice bundled in app resources) beside the notch, revealing a fixed 336-point session card vertically below the menu bar on hover (`35 ms` open / `60 ms` close).
   - Hovering must never steal keyboard focus (`nonactivatingPanel`) or block adjacent menu-bar items. Respect macOS **Reduce Motion** with restrained static equivalents.

3. **Observer-Only Hook Contract & Privacy:**
   - Hooks must observe only — never approve permissions, block tool execution, rewrite arguments, or inject prompts/context (`{}` on stdout, or Antigravity's neutral policy-delegating `{"decision":"allow"}` on `PreToolUse`).
   - Never open `transcript_path`, agent databases, or credentials. Forward only stripped session metadata over the user-private `0600` Unix datagram socket (`~/Library/Application Support/NotchPing/events.sock`).
   - Always back up user hook/configuration files before targeted edits and preserve unrelated hooks and notification commands (including Codex `notify` and third-party hook namespaces).
   - Do not add shell startup modifications, login items, or launch services unless explicitly requested.

4. **Strict Live vs. Demo Isolation:**
   - Normal launch runs live. Explicit `--demo` mode is isolated from `events.sock` and `OriginStore`.
   - Never attach to or resume real user agent sessions for automated testing.

## Verification

Before finishing changes, run:

```sh
swift test
python3 scripts/test_hooks.py
./scripts/build.sh
codesign --verify --deep --strict "dist/Notch Ping.app"
```
