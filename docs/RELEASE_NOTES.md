# Notch Ping v0.2.0

A small, dependency-free native macOS notch indicator for **Codex**, **Claude Code**, and **Antigravity (`agy`)** sessions that are working, waiting for input, finished, or failed.

## Highlights

- **Discrete Native Notch Indicator:** Places a 16-point Lucide Bot icon beside the MacBook notch without widening the notch, drawing menu-bar wings, or stealing keyboard focus. Invisible (`0.0%` CPU, zero timers) when idle.
- **Distinct Per-State Motion & Cues:**
  - **Working (Blue):** GPU-driven orbiting progress arc around the Bot (also visible alongside green/amber attention states when parallel sessions are still running).
  - **Needs you (Amber):** Arrival wave and outward-radiating beacon for permission prompts and clarifying questions, settling to a crisp amber pip once checked.
  - **Finished (Green):** Celebratory bloom and calm breathing glow until glanced at.
  - **Command failed (Red):** Crisp horizontal error shake and alert flash.
  - **Reduced Motion:** Automatically replaces continuous animations with distinct static indicators.
- **Branch & Elapsed-Time Context:** Dropdown rows display repository name, git branch or worktree (read locally from `.git/HEAD` with `O_NOFOLLOW | O_NONBLOCK`), and relative run/wait duration (`Claude Code · feat/auth · 2m`) instead of raw session hashes.
- **Click-to-Open & Auto-Clear `Finished`:** Clicking a session activates its originating app (`cmux`, `Terminal`, `iTerm`, `Warp`, `Codex Desktop`, `Claude Desktop`, or `Antigravity`), collapses the card, and automatically clears `Finished` notifications while keeping `Working`, `Needs you`, and `Command failed` entries pinned. Unknown-origin sessions offer a one-click **Open in…** picker remembered across restarts.
- **Lifecycle Resilience:** Handles out-of-order async hook deliveries (`SessionStart`/`UserPromptSubmit` and `PostToolUse`/`Stop`), traverses macOS `/usr/bin/login` ancestry for `Terminal` and `iTerm2`, and automatically clears orphaned active CLI turns if their host process exits unexpectedly.

## Privacy & Security

- **100% Local & Dependency-Free:** Native `SwiftUI`/`AppKit` app and `notch-relay` helper with zero third-party frameworks, network calls, or telemetry.
- **Observer-Only Hooks:** Emits `{}` (and Antigravity's neutral policy-delegating `{"decision":"allow"}` on `PreToolUse`). Never reads transcripts, prompts, tool arguments, or credentials.
- **Hardened IPC & Storage:** Uses a user-only `0600` Unix datagram socket inside a `0700` Application Support directory, non-following descriptor checks on untrusted repository `.git` metadata, and timestamped `0600` configuration backups before hook installation.

## Quick Start

```sh
./scripts/build.sh
python3 scripts/hooks.py install
python3 scripts/codex_hook_setup.py --trust
open "dist/Notch Ping.app"
```

Standalone isolated demo:

```sh
open "dist/Notch Ping.app" --args --demo
```

Uninstall hooks and relay:

```sh
python3 scripts/hooks.py uninstall
```

## Validation & Known Limits

- **Automated checks:** 44 Swift tests, 11 Python hook installer tests, release app packaging, and strict deep code-signature verification pass.
- **License:** MIT (`LICENSE`), with the bundled Lucide Bot asset under ISC (`ThirdParty/Lucide/LICENSE`).
- **Known limits:** Plain Codex CLI sessions hosted behind its shared daemon (and detached `tmux` sessions) do not expose terminal ancestry automatically and prompt once for **Open in…**. Closing a terminal after a session is already `Finished` may not emit `SessionEnd` on all providers; clicking through or dismissing clears the entry. The bundle is ad-hoc signed for local builds.
