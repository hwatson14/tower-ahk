# Architecture (as-is)

## Status

This document describes the current architecture implemented in `src/gem_clicker.ahk` (canonical v8.7j code). It is derived from the script as written, without refactors or inferred behavior.

## High-level flow

The script is an AutoHotkey automation loop that targets an LDPlayer window. When enabled, it schedules periodic clicks inside the game client, performs OCR to read gem counts, logs results to CSV, and runs recovery checks for death/return-to-game states. It also detects “freeze” conditions by comparing client CRCs and sends ntfy notifications with screenshots.

Key runtime flow:
1. **Initialization**: Start GDI+, set directories, clear old captures, and initialize global state. `Gdip_Startup` is required and failure exits. Capture/log directories are created if missing and older capture files are deleted at startup. 【F:src/gem_clicker.ahk†L49-L94】
2. **Toggle ON (F6)**: Locks a target window (LDPlayer), starts click scheduling, countdown tooltip, and periodic recovery state checks. **Toggle OFF** stops timers and resets detection state. 【F:src/gem_clicker.ahk†L100-L147】
3. **Click cycle**: `DoClick` computes a content-relative click target, jitters it, performs a control click, runs OCR, logs CSV, probes death banner colors, and runs freeze detection. It then schedules the next click. 【F:src/gem_clicker.ahk†L197-L321】
4. **Recovery tick**: `StateTick` (every 60s when enabled) checks for a death modal or return-to-game overlay using OCR and clicks the appropriate targets if detected. 【F:src/gem_clicker.ahk†L323-L344】
5. **Exit**: On exit, GDI+ shuts down. 【F:src/gem_clicker.ahk†L701-L706】

## Components

### Configuration
The script defines configuration blocks for click timing, OCR ROI, recovery OCR/clicking, death detection color probes, logging paths, and ntfy topic. These are plain globals at the top of the script. 【F:src/gem_clicker.ahk†L11-L77】

### Window targeting & coordinate mapping
- **LDPlayer resolution**: `ResolveLdplayerHwnd` selects an LDPlayer window, preferring the largest client area with “LDPlayer” in its title. `EnsureValidHwnd` confirms/refreshes the handle. 【F:src/gem_clicker.ahk†L368-L390】
- **Client sizing**: `GetClientSize` retrieves client bounds. 【F:src/gem_clicker.ahk†L348-L366】
- **Header detection**: `DetectHeaderH` scans the top of the client to find a low-texture header height, used to define the content region. 【F:src/gem_clicker.ahk†L575-L632】
- **Content mapping**: `ContentPointFromBottomPct` converts percent-based coordinates (x, y from bottom of content) to client coordinates, with header-aware offsetting. This is used for clicking and ROI placement. 【F:src/gem_clicker.ahk†L634-L652】

### Click loop
- **Scheduling**: `ScheduleNextClick` randomizes delay between `minIntervalMs` and `maxIntervalMs` and uses a one-shot timer to call `DoClick`. 【F:src/gem_clicker.ahk†L179-L187】
- **Countdown tooltip**: `ShowCountdown` updates a tooltip with time until next click and last OCR/death message. 【F:src/gem_clicker.ahk†L189-L217】
- **Click execution**: `DoClick` computes a target in content space, applies jitter, performs `ControlClick` down/up with a randomized hold time, and then runs OCR/logging and detection checks. 【F:src/gem_clicker.ahk†L219-L321】

### OCR pipeline
- **Gem OCR**: `ReadGemsTesseractPct` captures a ROI within the content region, writes debug images (`last_raw.png`, `gem_clean.png`), runs Tesseract with numeric-only settings, and parses digits. Returns `-1` on failure and sets `ocrOK`. 【F:src/gem_clicker.ahk†L434-L497】
- **Generic OCR**: `OCR_TextPct` performs header-aware OCR over a specified ROI, while `OCR_TextClientPct` uses full-client coordinates (from bottom of full client). Both use Tesseract and return normalized text. 【F:src/gem_clicker.ahk†L655-L720】

### Logging
- **CSV logging**: `GemCsvLog` appends to a daily CSV file and includes timestamp, window title, x/y click coordinates, gem count, and OCR status. If the file is new, it writes the header and displays a tooltip. 【F:src/gem_clicker.ahk†L503-L548】

### Death detection & recovery
- **Banner color probe**: `ProbeBannerStrictRGB` samples a small pixel patch at a header-adjusted coordinate and compares against a strict color palette. If the probe fails after a click, it captures a screenshot and notifies via ntfy. 【F:src/gem_clicker.ahk†L400-L432】【F:src/gem_clicker.ahk†L273-L292】
- **Death modal detection**: `IsDeathModal` OCRs a saved ROI image and checks for “GAME” and “STAT,” pruning old debug images. 【F:src/gem_clicker.ahk†L742-L766】
- **Return-to-game detection**: `IsReturnToGame` OCRs a ROI and looks for “TAP” and “RETURN.” 【F:src/gem_clicker.ahk†L721-L740】
- **Recovery actions**: `RecoverReturnToGame` and `RecoverDeath` issue content-relative clicks with a brief focus-tap before retrying a death modal if needed. 【F:src/gem_clicker.ahk†L769-L804】

### Freeze detection
After each click, `CaptureClientCRC` computes a CRC32 for the full client image. If two consecutive CRCs match and the debounce window has elapsed, `AlertFreeze` sends a freeze notification with a screenshot and updates tooltip messaging. 【F:src/gem_clicker.ahk†L293-L314】【F:src/gem_clicker.ahk†L556-L573】

### Notifications
- **ntfy integration**: `SendNtfy` posts messages or image attachments to `https://ntfy.sh/<topic>` using curl, with optional deletion of the image after sending. This is used for death and freeze alerts and a manual screenshot test. 【F:src/gem_clicker.ahk†L533-L554】
- **Hotkey-triggered tests**: `^F8` and `^F9` capture diagnostics (ntfy screenshot test and probe snapshot). 【F:src/gem_clicker.ahk†L160-L183】

## External dependencies
- **GDI+**: `Gdip_All` library (via `#Include <Gdip_All>`) is required for screenshot capture and pixel access. 【F:src/gem_clicker.ahk†L1-L5】
- **Tesseract**: OCR relies on `tesseract.exe` at `C:\Program Files\Tesseract-OCR\tesseract.exe`. 【F:src/gem_clicker.ahk†L23-L28】
- **curl.exe**: Used by ntfy notifications. 【F:src/gem_clicker.ahk†L533-L553】

## Data & artifacts
- **Capture files**: Screenshots and OCR images are stored in `captures/` (e.g., `last_raw.png`, `death_*.png`, `freeze_*.png`, `death_check_*.png`). Old probe and test images are deleted on startup; death-check images are pruned to a maximum of 60. 【F:src/gem_clicker.ahk†L49-L74】【F:src/gem_clicker.ahk†L742-L758】
- **CSV logs**: Daily logs are stored under `Logs/` with the name `gem_log_<YYYY-MM-DD>.csv`. 【F:src/gem_clicker.ahk†L503-L523】

## Hotkeys & timers (runtime controls)
- **F6**: Toggle click loop and recovery timers; shows tooltip countdown. 【F:src/gem_clicker.ahk†L100-L147】
- **F7**: Lock the current active window as the target. 【F:src/gem_clicker.ahk†L149-L156】
- **F8/F9**: Recovery tests for return-to-game and death modal, respectively. 【F:src/gem_clicker.ahk†L158-L182】
- **Ctrl+F8/Ctrl+F9**: Manual screenshot test to ntfy and a banner probe snapshot. 【F:src/gem_clicker.ahk†L184-L216】
- **Esc**: Exit app (shutdown GDI+). 【F:src/gem_clicker.ahk†L217-L221】【F:src/gem_clicker.ahk†L701-L706】
- **Timers**: `DoClick` is scheduled via a randomized one-shot timer, `ShowCountdown` runs every 60 seconds, and `StateTick` runs every 60 seconds when auto-recovery is enabled. 【F:src/gem_clicker.ahk†L179-L187】【F:src/gem_clicker.ahk†L120-L131】

## Preservation requirements for refactor
- Click timing distribution must remain unchanged
- Header-aware content mapping must be preserved
- OCR ROI semantics must be identical
- Freeze detection debounce semantics must remain unchanged
