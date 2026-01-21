# Refactor requirements contract

This document captures the externally supplied constraints for the ADB transport refactor. These are not derived from the current repository state and must be preserved as a contract for future work.

## Execution model

* Controller remains AHK v1.
* ADB is used only for:
  * `exec-out screencap -p` (image source)
  * `shell input tap` (input injection)
* Tesseract is used for OCR; AHK orchestrates timers, parsing, logic, logging, notifications, heartbeats.

## Transport & capture

* Capture source is only: `adb exec-out screencap -p > captures\ld.png`.
* Input is only: `adb shell input tap X Y`.
* Absolutely no:
  * Desktop/window capture (GDI/DWM/Gdip_BitmapFromScreen)
  * Windows input (mouse move, SendInput, ControlClick)

## Coordinate semantics

* All coordinates (tap points, ROIs, probe pixels) are evaluated in ADB screenshot space.
* Percent-based values are percent of full ADB screenshot width/height.
* Y-from-bottom semantics remain Y-from-bottom, but relative to the full device frame.

## Preflight (fail-closed)

* Verify `adb.exe` exists at `C:\LDPllayer\LDPlayer9\adb.exe`.
* Verify Tesseract exists.
* ADB device selection:
  * If `adbDeviceId` is set, use it.
  * If not set and 1 device exists, use it.
  * If not set and >1 device exists, fail-closed with a clear error.
* Query and cache `wm size` resolution.
* If any preflight fails:
  * Log + visible error
  * Do not start timers
  * Heartbeat must not start

## Timers

* Main click timer: randomized interval (unchanged).
* State tick timer: unchanged cadence.
* Heartbeat timer: every 2–5 minutes, independent of click/state.
* All timers start only after successful preflight.

## Heartbeat / dead man’s switch

* Heartbeat is sent to Healthchecks-style endpoint (HTTP GET via curl).
* Heartbeat failures (network hiccups) are log-only and do not stop the script.
* On fail-closed stop: all timers including heartbeat stop, so external watcher alerts.
* External watcher must be cloud-hosted so alerts work even if PC is off/asleep.

## Click cycle (unchanged logic)

* On scheduled click:
  * Take ADB screenshot to `ld.png` (once per cycle).
  * Compute click coordinates from percent config + jitter.
  * ADB tap.
  * Preserve hold-time behavior.
* If ADB tap fails: fail-closed.

## OCR pipeline

* OCR operates on crops from `ld.png`.
* Numeric gems OCR and text modal OCR preserved.
* Missing `ld.png` or ROI image file: fail-closed.
* OCR read failures (no text): log and continue (unless current behavior treats it as fatal).

## Detection + recovery

* Death: strict RGB probe + OCR modal detection; unchanged semantics.
* Recovery: ADB taps only; unchanged sequencing including offset retries.
* Freeze: CRC32 over screenshot pixels; unchanged debounce/alert semantics.

## Logging

* `Logs/gem_clicker.log` structured events including heartbeat send attempts and fail-closed reason.
* CSV output for gems unchanged.

## Acceptance criteria

* Works with monitor off: `ld.png` updates and automation continues.
* No Windows input occurs (mouse remains untouched).
* Killing script triggers external alert within configured window.
* Removing/renaming `adb.exe` triggers fail-closed and external alert.
