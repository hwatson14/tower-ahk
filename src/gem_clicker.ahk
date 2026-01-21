#NoEnv
#SingleInstance Force
#Include <Gdip_All>
try DllCall("User32\SetProcessDPIAware")

SendMode Input

gemSym := Chr(0x1F48E) ; 💎 (avoid file-encoding issues)

CoordMode, Mouse, Window
SetBatchLines, 20

; ---------- CONFIG ----------
; Click timing + humanization
targetXPct       := 10
targetYBottomPct := 53          ; percent from bottom of CONTENT (client minus header)
jitter           := 8
minIntervalMs    := 660000
maxIntervalMs    := 700000
minHoldMs        := 60
maxHoldMs        := 150

; OCR
tesseractPath := "C:\Program Files\Tesseract-OCR\tesseract.exe"
leftPct      := 7.5
roiTopBottomPct := 86
widthPct     := 12.0
heightPct    := 3.5
tessPSM      := 7

; Recovery (Return to game / Retry on death)
scriptVersion := "v8.7i"
autoRecovery := true
stateTickMs  := 60000

; OCR ROIs for recovery (percent of client; Y from bottom OF CONTENT)
returnRoiLeftPct    := 5
returnRoiYBottomPct := 12
returnRoiWidthPct   := 90
returnRoiHeightPct  := 12
returnRoiPSM        := 6

deathRoiLeftPct     := 18
deathRoiYBottomPct  := 92
deathRoiWidthPct    := 64
deathRoiHeightPct   := 32
deathRoiPSM         := 6

; Click targets for recovery (percent; Y from bottom OF CONTENT)
returnClickXPct       := 50
returnClickYBottomPct := 7

deathFocusClickXPct       := 50
deathFocusClickYBottomPct := 5
deathRetryClickXPct       := 25
deathRetryClickYBottomPct := 30
deathHoldMs              := 90

; Files
gemLogDir  := A_ScriptDir "\Logs"
captureDir := A_ScriptDir "\captures"
adbExePath := "C:\LDPllayer\LDPlayer9\adb.exe"
adbLogPath := gemLogDir "\gem_clicker.log"

; Death probe (strict RGB); Y from bottom (of CONTENT)
bannerProbeX           := 5
bannerProbeYBottomPct  := 37
probeHalf              := 3

; Known banner colours (RRGGBB) — unchanged palette, tiny tolerance
colRed    := 0xCF3F59
colBlue   := 0x199EC9
colYellow := 0xDDB812
colGreen  := 0x60D64C
colTol    := 3

; Tooltip "death" note
lastDeathMsg   := ""
lastDeathUntil := 0
deathNoteMs    := 180000

; NTFY
ntfyTopic := "ahk-script-9q2mwd6j4"

; ---------- INIT ----------
if !pToken := Gdip_Startup() {
    MsgBox, 16, Error, Failed to start GDI+.
    ExitApp
}
EnsureDir(captureDir), EnsureDir(gemLogDir)

; Cleanup: stop file accumulation
Loop, Files, % captureDir "\probe_*.png"
    FileDelete, %A_LoopFileFullPath%
Loop, Files, % captureDir "\ntfy_test_*.png"
    FileDelete, %A_LoopFileFullPath%
; Optionally prune any old deaths too
Loop, Files, % captureDir "\death_*.png"
    FileDelete, %A_LoopFileFullPath%
; delete old gem_*.png as before (if any pattern still used)
Loop, Files, % captureDir "\gem_*.png"
    FileDelete, %A_LoopFileFullPath%

Toggle := false
nextClickTime := 0
lockedHwnd := 0
lastGems := ""
lastReturnOCR := ""
lastDeathOCR := ""
adbDeviceId := ""
adbWmWidth := 0
adbWmHeight := 0

; -------- Freeze detection state --------
lastScreenCRC := ""
freezeDebounceMs := 120000
lastFreezeAt := 0

; =========================
; HOTKEYS
; =========================
F6::
    Toggle := !Toggle
    if (Toggle) {
        lockedHwnd := ResolveLdplayerHwnd() ; lock window once
        WinGetTitle, activeTitle, ahk_id %lockedHwnd%
        ToolTip, Human-like tester ON`nTarget Window:`n%activeTitle%`n(F6 toggles off | Esc exits)
        Gosub, DoClick
        Gosub, ScheduleNextClick
        SetTimer, ShowCountdown, 60000
        Gosub, ShowCountdown
        if (autoRecovery) {
            SetTimer, StateTick, %stateTickMs%
            Gosub, StateTick
        }
    } else {
        SetTimer, DoClick, Off
        SetTimer, ShowCountdown, Off
        SetTimer, StateTick, Off
        ToolTip
        lastDeathMsg := "", lastDeathUntil := 0
        lockedHwnd := 0
        ; reset freeze detection state
        lastScreenCRC := ""
        lastFreezeAt := 0
    }
return

; Lock active window (use after clicking inside LDPlayer)
F7::
    lockedHwnd := WinActive("A")
    WinGetTitle, t, ahk_id %lockedHwnd%
    TrayTip, Lock, % "Locked window: " t, 2
return

; Test: click Return-to-game overlay (requires OCR detect)
F8::
    hwnd := EnsureValidHwnd(lockedHwnd)
    if (!hwnd)
        hwnd := ResolveLdplayerHwnd()
    if (!hwnd) {
        TrayTip, ReturnTest, no hwnd, 2
        return
    }
    if (IsReturnToGame(hwnd)) {
        RecoverReturnToGame(hwnd)
        TrayTip, ReturnTest, clicked, 2
    } else {
        TrayTip, ReturnTest, % "not detected: " SubStr(lastReturnOCR,1,60), 3
    }
return

; Test: click Retry on GAME STATS screen (requires OCR detect)
F9::
    hwnd := EnsureValidHwnd(lockedHwnd)
    if (!hwnd)
        hwnd := ResolveLdplayerHwnd()
    if (!hwnd) {
        TrayTip, RetryTest, no hwnd, 2
        return
    }
    if (IsDeathModal(hwnd)) {
        RecoverDeath(hwnd)
        TrayTip, RetryTest, clicked, 2
    } else {
        TrayTip, RetryTest, % "not detected: " SubStr(lastDeathOCR,1,60), 3
    }
return

; Debug probe snapshot (uses lockedHwnd if present) [Ctrl+F9]
^F9::
    hwnd := EnsureValidHwnd(lockedHwnd)
    ok := ProbeBannerStrictRGB(hwnd, bannerProbeX, bannerProbeYBottomPct, probeHalf, rgbHex)
    TrayTip, Probe, % "match=" ok " | " rgbHex, 5
    if GetClientSize(cw, ch, hwnd) {
        VarSetCapacity(pt, 8, 0), NumPut(0, pt, 0, "Int"), NumPut(0, pt, 4, "Int")
        DllCall("ClientToScreen", "ptr", hwnd, "ptr", &pt)
        ; visualize around computed client point
        ; Use header-aware Y
        h := DetectHeaderH(hwnd, cw, ch), contentH := ch - h
        yFromBottomC := Clamp(Round(contentH * (bannerProbeYBottomPct / 100.0)), 0, contentH-1)
        yClient := h + (contentH - yFromBottomC)
        sx := NumGet(pt, 0, "Int") + Clamp(bannerProbeX, 0, cw-1)
        sy := NumGet(pt, 4, "Int") + yClient
        rect := (sx-7) "|" (sy-7) "|" 15 "|" 15
        p := Gdip_BitmapFromScreen(rect)
        if (p) {
            Gdip_SaveBitmapToFile(p, captureDir "\probe_" A_Now ".png")
            Gdip_DisposeImage(p)
        }
    }
return

; Debug: ADB preflight + screencap/tap [Ctrl+F10]
^F10::
    if (!Adb_Preflight()) {
        TrayTip, ADB, preflight failed (see gem_clicker.log), 3
        return
    }
    shot := captureDir "\adb_test_" A_Now ".png"
    if (Adb_Screencap(shot)) {
        Adb_Tap(adbWmWidth // 2, adbWmHeight // 2)
        TrayTip, ADB, % "screencap OK: " shot, 3
    } else {
        TrayTip, ADB, screencap failed (see gem_clicker.log), 3
    }
return

; Screenshot via ntfy (uses lockedHwnd if present) [Ctrl+F8]
^F8::
    hwnd := EnsureValidHwnd(lockedHwnd)
    shot := captureDir "\ntfy_test_" A_Now ".png"
    if (CaptureClientToFile(hwnd, shot)) {
        ok := SendNtfy("AHK screenshot test", shot, "camera")
        MsgBox, 64, ntfy, % "Image push: " (ok ? "OK" : "FAILED")
    } else {
        MsgBox, 16, ntfy, Capture failed.
    }
return

Esc::ExitApp

; =========================
; CORE
; =========================
ScheduleNextClick:
    Random, delay, %minIntervalMs%, %maxIntervalMs%
    nextClickTime := A_TickCount + delay
    SetTimer, DoClick, -%delay%
return

ShowCountdown:
    if (!Toggle) {
        SetTimer, ShowCountdown, Off
        ToolTip
        return
    }
    msLeft := nextClickTime - A_TickCount
    if (msLeft < 0)
        msLeft := 0
    minutesLeft := Round(msLeft / 60000.0, 1)

    msg := "Next: " minutesLeft " mins. " gemSym lastGems
    if (A_TickCount < lastDeathUntil && lastDeathMsg != "")
        msg .= "`n" lastDeathMsg

    ToolTip, %msg%
return

DoClick:
    hwnd := EnsureValidHwnd(lockedHwnd)
    if (!hwnd) {
        if (Toggle)
            Gosub, ScheduleNextClick
        return
    }
    if !GetClientSize(cw, ch, hwnd) {
        if (Toggle)
            Gosub, ScheduleNextClick
        return
    }

    ; Compute click target inside CONTENT (client minus header)
    if !ContentPointFromBottomPct(hwnd, targetXPct, targetYBottomPct, baseX, baseY) {
        if (Toggle)
            Gosub, ScheduleNextClick
        return
    }

    ; jitter, clamped to content vertically
    h := DetectHeaderH(hwnd, cw, ch), contentH := ch - h
    minX := Max(baseX - jitter, 0),              maxX := Min(baseX + jitter, cw-1)
    minY := Max(baseY - jitter, h),              maxY := Min(baseY + jitter, h + contentH - 1)

    Random, rx, %minX%, %maxX%
    Random, ry, %minY%, %maxY%
    Random, holdTime, %minHoldMs%, %maxHoldMs%

    ; Safe click inside hwnd even if focus moves (no activation)
    ToolTip, Clicking at`nX: %rx% Y: %ry%
    Sleep, 120
    ; Down/Up with NA to avoid activation
    ControlClick, x%rx% y%ry%, ahk_id %hwnd%, , Left, 1, NA Down
    Sleep, %holdTime%
    ControlClick, x%rx% y%ry%, ahk_id %hwnd%, , Left, 1, NA Up

    ; OCR & log
    Sleep, 800
    gems := ReadGemsTesseractPct(hwnd, ocrOK)
    lastGems := (ocrOK ? gems : "[OCR-FAIL]")
    Gosub, ShowCountdown
    GemCsvLog(gems, rx, ry, hwnd, ocrOK)

    ; Death detection (strict colors, Y from bottom of CONTENT)
    ok := ProbeBannerStrictRGB(hwnd, bannerProbeX, bannerProbeYBottomPct, probeHalf, rgbHex)
    if (!ok) {
        FormatTime, ts,, yyyy-MM-dd HH:mm:ss
        shot := captureDir "\death_" A_Now ".png"
        CaptureClientToFile(hwnd, shot)
        SendNtfy("Death @ " ts " | " rgbHex, shot, "skull,warning")
        lastDeathMsg   := "☠ Death @ " ts " | " rgbHex
        lastDeathUntil := A_TickCount + deathNoteMs
        Gosub, ShowCountdown
    }

    ; -------- Freeze detection: screen unchanged since previous click --------
    crcOK := CaptureClientCRC(hwnd, currCRC)  ; no save on normal path
    if (crcOK) {
        now := A_TickCount
        if (lastScreenCRC != "" && currCRC = lastScreenCRC && (now - lastFreezeAt > freezeDebounceMs)) {
            lastFreezeAt := now
            AlertFreeze(hwnd, rgbHex)  ; ntfy with screenshot
            lastDeathMsg   := "🧊 No change after click @ " A_Hour ":" A_Min
            lastDeathUntil := A_TickCount + deathNoteMs
            Gosub, ShowCountdown
        }
        lastScreenCRC := currCRC
    }

    if (Toggle)
        Gosub, ScheduleNextClick
return

; =========================
; RECOVERY STATE TICK
; =========================
StateTick:
    if (!Toggle)
        return
    hwnd := EnsureValidHwnd(lockedHwnd)
    if (!hwnd)
        hwnd := ResolveLdplayerHwnd()
    if (!hwnd)
        return
    if (IsDeathModal(hwnd)) {
        RecoverDeath(hwnd)
        return
    }
    if (IsReturnToGame(hwnd)) {
        RecoverReturnToGame(hwnd)
        return
    }
return

; =========================
; HELPERS
; =========================
EnsureDir(path) {
    if !FileExist(path)
        FileCreateDir, %path%
}

; Keep only the newest N files matching a pattern (filenames must sort chronologically)
PrunePattern(dir, pattern, keepN) {
    list := ""
    Loop, Files, % dir "\" pattern
        list .= A_LoopFileName "`n"
    Sort, list
    count := 0
    Loop, Parse, list, `n, `r
        if (A_LoopField != "")
            count++
    if (count <= keepN)
        return
    toDel := count - keepN
    i := 0
    Loop, Parse, list, `n, `r
    {
        fn := A_LoopField
        if (fn = "")
            continue
        i++
        if (i <= toDel)
            FileDelete, % dir "\" fn
    }
}

Clamp(v, lo, hi) {
    return (v < lo) ? lo : (v > hi ? hi : v)
}

GetClientSize(ByRef outW, ByRef outH, hwnd := "") {
    if (hwnd = "")
        WinGet, hwnd, ID, A
    VarSetCapacity(RECT, 16, 0)
    if DllCall("GetClientRect", "ptr", hwnd, "ptr", &RECT) {
        outW := NumGet(RECT, 8, "Int")
        outH := NumGet(RECT, 12, "Int")
        return true
    }
    outW := 0, outH := 0
    return false
}

; ---- Window resolution/locking ----
ResolveLdplayerHwnd() {
    ; Try common patterns by title/class; fall back to largest client area with "LDPlayer" in title
    WinGet, ids, List,,, Program Manager
    bestHwnd := 0, bestArea := 0
    Loop, %ids% {
        this := ids%A_Index%
        WinGetTitle, ttl, ahk_id %this%
        if (InStr(ttl, "LDPlayer")) {
            if GetClientSize(w, h, this) {
                area := w*h
                if (area > bestArea) {
                    bestArea := area, bestHwnd := this
                }
            }
        }
    }
    return bestHwnd
}

EnsureValidHwnd(ByRef locked) {
    if (locked && WinExist("ahk_id " locked))
        return locked
    locked := ResolveLdplayerHwnd()
    return locked
}

; ---- Color proximity ----
RGB_Close(col, target, tol := 3) {
    r := (col >> 16) & 0xFF, g := (col >> 8) & 0xFF, b := col & 0xFF
    rt := (target >> 16) & 0xFF, gt := (target >> 8) & 0xFF, bt := target & 0xFF
    return (Abs(r-rt) <= tol) && (Abs(g-gt) <= tol) && (Abs(b-bt) <= tol)
}

; Sample a tiny patch and test center pixel against strict RGB palette
; yBottomPct = percent from bottom of CONTENT
ProbeBannerStrictRGB(hwnd, xClient, yBottomPct, probeHalf, ByRef outRgbHex := "") {
    global colRed, colBlue, colYellow, colGreen, colTol
    outRgbHex := "RGB=?"

    if !GetClientSize(cw, ch, hwnd)
        return false

    ; header-aware Y (content = client minus header)
    h := DetectHeaderH(hwnd, cw, ch), contentH := ch - h
    xClient := Clamp(xClient, 0, cw-1)
    yFromBottomC := Clamp(Round(contentH * (yBottomPct / 100.0)), 0, contentH-1)
    yClient := h + (contentH - yFromBottomC)

    VarSetCapacity(pt, 8, 0)
    NumPut(0, pt, 0, "Int"), NumPut(0, pt, 4, "Int")
    DllCall("ClientToScreen", "ptr", hwnd, "ptr", &pt)
    sx := NumGet(pt, 0, "Int") + xClient
    sy := NumGet(pt, 4, "Int") + yClient

    capX := sx - probeHalf
    capY := sy - probeHalf
    capW := 2*probeHalf + 1
    capH := 2*probeHalf + 1
    rect := capX "|" capY "|" capW "|" capH
    pBmp := Gdip_BitmapFromScreen(rect)
    if !pBmp
        return false

    ARGB := Gdip_GetPixel(pBmp, probeHalf, probeHalf)  ; 0xAARRGGBB
    Gdip_DisposeImage(pBmp)

    r := (ARGB >> 16) & 0xFF
    g := (ARGB >>  8) & 0xFF
    b :=  ARGB        & 0xFF
    rgb := (r<<16) | (g<<8) | b
    outRgbHex := "RGB=0x" Format("{:06X}", rgb) " ±" colTol

    if ( RGB_Close(rgb, colGreen,  colTol) )
        return true
    if ( RGB_Close(rgb, colBlue,   colTol) )
        return true
    if ( RGB_Close(rgb, colRed,    colTol) )
        return true
    if ( RGB_Close(rgb, colYellow, colTol) )
        return true

    return false
}

; ---------- OCR (ROI in % of client; Y from bottom OF CONTENT) ----------
; Returns gems (>=0) and sets ocrOK := true; returns -1 and ocrOK := false on failure.
ReadGemsTesseractPct(hwnd, ByRef ocrOK) {
    global leftPct, roiTopBottomPct, widthPct, heightPct, tesseractPath, tessPSM, captureDir
    ocrOK := false
    if !FileExist(tesseractPath)
        return -1

    if (!hwnd)
        return -1
    if !GetClientSize(cw, ch, hwnd)
        return -1

    VarSetCapacity(pt, 8, 0), NumPut(0, pt, 0, "Int"), NumPut(0, pt, 4, "Int")
    DllCall("ClientToScreen", "ptr", hwnd, "ptr", &pt)
    winX := NumGet(pt, 0, "Int"), winY := NumGet(pt, 4, "Int")

    ; header-aware ROI
    h := DetectHeaderH(hwnd, cw, ch), contentH := ch - h

    sxClient := Round(cw * (leftPct / 100.0))
    yFromBottomC := Round(contentH * (roiTopBottomPct / 100.0))
    syClient := h + (contentH - yFromBottomC)
    swClient := Round(cw * (widthPct  / 100.0))
    shClient := Round(contentH * (heightPct / 100.0))

    rect := (winX + sxClient) "|" (winY + syClient) "|" swClient "|" shClient
    pRaw := Gdip_BitmapFromScreen(rect)
    if (!pRaw)
        return -1

    Gdip_SaveBitmapToFile(pRaw, captureDir "\last_raw.png")
    Gdip_SaveBitmapToFile(pRaw, captureDir "\gem_clean.png")
    tmpPath := A_Temp "\gem_roi.bmp"
    Gdip_SaveBitmapToFile(pRaw, tmpPath)
    Gdip_DisposeImage(pRaw)

    cmd := """" tesseractPath """ """ tmpPath """ stdout -l eng --oem 1 --psm " tessPSM
        . " -c tessedit_char_whitelist=0123456789"
        . " -c user_defined_dpi=300"
        . " -c classify_bln_numeric_mode=1"
    sh := ComObjCreate("WScript.Shell")
    exec := sh.Exec(cmd)
    raw := exec.StdOut.ReadAll()
    ; NOTE: leaving tmpPath on disk for debugging
    ; FileDelete, %tmpPath%

    text := RegExReplace(raw, "[^\d]")
    if (text = "") {
        FileCopy, % captureDir "\last_raw.png", % captureDir "\last_gem_failed.png", 1
        return -1
    }
    ocrOK := true
    return (text + 0)
}

; ---------- CSV ----------
GemCsvPath() {
    global gemLogDir
    EnsureDir(gemLogDir)
    FormatTime, dstr, , yyyy-MM-dd
    return gemLogDir "\gem_log_" dstr ".csv"
}

GemCsvLog(gems, x, y, hwnd, ocrOK := true) {
    file := GemCsvPath()
    WinGetTitle, title, ahk_id %hwnd%
    StringReplace, title, title, `,, , All

    if !FileExist(file) {
        FileAppend, % "timestamp,window_title,x,y,gems,ocr_ok`r`n", %file%, UTF-8
        ToolTip, Gems logging to:`n%file%
        SetTimer, HideToolTip, -1800
    }

    FormatTime, ts, , yyyy-MM-dd HH:mm:ss
    ; For -1 (OCR fail), write empty gems but mark ocr_ok=FALSE
    if (gems = -1) {
        line := ts "," title "," x "," y "," "" "," "FALSE" "`r`n"
    } else {
        line := ts "," title "," x "," y "," gems "," (ocrOK ? "TRUE" : "FALSE") "`r`n"
    }
    FileAppend, %line%, %file%
}

HideToolTip:
    ToolTip
return

; ---------- Capture client to PNG ----------
CaptureClientToFile(hwnd, path) {
    if !GetClientSize(cw, ch, hwnd)
        return false
    VarSetCapacity(pt, 8, 0), NumPut(0, pt, 0, "Int"), NumPut(0, pt, 4, "Int")
    DllCall("ClientToScreen", "ptr", hwnd, "ptr", &pt)
    sx := NumGet(pt, 0, "Int"), sy := NumGet(pt, 4, "Int")
    rect := sx "|" sy "|" cw "|" ch
    p := Gdip_BitmapFromScreen(rect)
    if !p
        return false
    Gdip_SaveBitmapToFile(p, path)
    Gdip_DisposeImage(p)
    return true
}

; ---------- ADB backend scaffolding ----------
Adb_Preflight() {
    global adbWmWidth, adbWmHeight
    exe := Adb_ResolveExe()
    if (!exe) {
        Adb_Log("adb.exe not found")
        return false
    }
    if (!Adb_SelectDevice()) {
        Adb_Log("no adb devices detected")
        return false
    }
    out := ""
    if (Adb_RunWait(Adb_Command("shell wm size"), out) != 0) {
        Adb_Log("wm size failed")
        return false
    }
    if (RegExMatch(out, "(\d+)x(\d+)", m)) {
        adbWmWidth := m1
        adbWmHeight := m2
        return true
    }
    Adb_Log("wm size parse failed: " StrReplace(out, "`r`n", " "))
    return false
}

Adb_Screencap(outPath) {
    if (!outPath)
        return false
    cmd := Adb_Command("exec-out screencap -p") " > """ outPath """"
    Adb_RunWait(cmd)
    return FileExist(outPath)
}

Adb_Tap(x, y) {
    return (Adb_RunWait(Adb_Command("shell input tap " x " " y)) = 0)
}

Adb_HasDevice() {
    devices := Adb_GetDevices()
    return (devices.MaxIndex() ? true : false)
}

Adb_SelectDevice() {
    global adbDeviceId
    devices := Adb_GetDevices()
    if (!devices.MaxIndex())
        return false
    if (adbDeviceId != "")
        return true
    if (devices.MaxIndex() > 1) {
        Adb_Log("multiple devices detected; set adbDeviceId to select one")
        return false
    }
    adbDeviceId := devices[1]
    return true
}

Adb_GetDevices() {
    devices := []
    out := ""
    if (Adb_RunWait(Adb_RawCommand("devices"), out) != 0)
        return devices
    Loop, Parse, out, `n, `r {
        line := Trim(A_LoopField)
        if (line = "" || InStr(line, "List of devices attached"))
            continue
        if (RegExMatch(line, "O)^(\S+)\s+device$", m))
            devices.Push(m1)
    }
    return devices
}

Adb_Command(args) {
    global adbDeviceId
    exe := Adb_ResolveExe()
    deviceArg := (adbDeviceId != "") ? " -s """ adbDeviceId """" : ""
    return """" exe """" deviceArg " " args
}

Adb_RawCommand(args) {
    exe := Adb_ResolveExe()
    return """" exe """ " args
}

Adb_ResolveExe() {
    global adbExePath
    if (FileExist(adbExePath))
        return adbExePath
    scriptExe := A_ScriptDir "\adb.exe"
    if (FileExist(scriptExe))
        return scriptExe
    return ""
}

Adb_RunWait(cmd, ByRef out := "") {
    out := ""
    tmp := A_Temp "\adb_out_" A_TickCount ".txt"
    RunWait, % """" ComSpec """ /C " cmd " > """ tmp """",, Hide
    if FileExist(tmp) {
        FileRead, out, %tmp%
        FileDelete, %tmp%
    }
    return ErrorLevel
}

Adb_Log(msg) {
    global adbLogPath
    FormatTime, ts, , yyyy-MM-dd HH:mm:ss
    FileAppend, % ts " | " msg "`r`n", %adbLogPath%, UTF-8
}

; ---------- ntfy (with optional post-send cleanup) ----------
SendNtfy(msg, imagePath := "", tags := "", priority := "high", title := "AHK Alert", deleteAfter := true) {
    global ntfyTopic
    if (!ntfyTopic)
        return false

    url   := "https://ntfy.sh/" ntfyTopic
    msg   := StrReplace(msg,   """", "'")
    title := StrReplace(title, """", "'")

    hdr := " -H ""Title: " title """ -H ""Priority: " priority """"
    if (tags != "")
        hdr .= " -H ""Tags: " tags """"

    if (imagePath != "" && FileExist(imagePath)) {
        SplitPath, imagePath, fname
        hdr .= " -H ""Filename: " fname """"
        cmd := "curl.exe -s" hdr " -T """ imagePath """ " url
    } else {
        cmd := "curl.exe -s" hdr " -d """ msg """ " url
    }

    RunWait, % """" ComSpec """ /C " cmd,, Hide
    ok := (ErrorLevel = 0)

    if (ok && deleteAfter && imagePath != "" && FileExist(imagePath)) {
        Loop, 5 {
            FileDelete, %imagePath%
            if !FileExist(imagePath)
                break
            Sleep, 100
        }
    }
    return ok
}

; ---------- Freeze alert + CRC capture ----------
AlertFreeze(hwnd, rgbHex := "") {
    global captureDir
    FormatTime, ts,, yyyy-MM-dd HH:mm:ss
    shot := captureDir "\freeze_" A_Now ".png"
    CaptureClientToFile(hwnd, shot)
    SendNtfy("No visual change after click @ " ts (rgbHex ? " | " rgbHex : ""), shot, "snowflake,warning")
}

; Capture client and compute CRC32 over raw pixels (no extra copy). Optional save.
CaptureClientCRC(hwnd, ByRef outCRC, savePath := "") {
    outCRC := ""
    if !GetClientSize(cw, ch, hwnd)
        return false

    VarSetCapacity(pt, 8, 0), NumPut(0, pt, 0, "Int"), NumPut(0, pt, 4, "Int")
    DllCall("ClientToScreen", "ptr", hwnd, "ptr", &pt)
    sx := NumGet(pt, 0, "Int"), sy := NumGet(pt, 4, "Int")

    rect := sx "|" sy "|" cw "|" ch
    p := Gdip_BitmapFromScreen(rect)
    if !p
        return false

    ; PixelFormat32bppARGB = 0x26200A, LockMode=3 (read-only).
    BitmapData := 0
    status := Gdip_LockBits(p, 0, 0, cw, ch, stride, scan0, 0x26200A, 3, BitmapData)
    if (status != 0 || !scan0) {
        Gdip_DisposeImage(p)
        return false
    }

    size := Abs(stride) * ch
    crc := DllCall("ntdll\RtlComputeCrc32", "uint", 0, "ptr", scan0, "uint", size, "uint")

    ; two-argument unlock per your Gdip_All
    Gdip_UnlockBits(p, BitmapData)

    if (savePath != "")
        Gdip_SaveBitmapToFile(p, savePath)

    Gdip_DisposeImage(p)
    outCRC := Format("{:08X}", crc)
    return true
}

; ---------- Header detection + mapping ----------
; Detect a low-texture header from the top of the client.
DetectHeaderH(hwnd, cw, ch, maxScan:=240, samples:=24, sadThresh:=1800, busyRun:=3) {
    VarSetCapacity(pt, 8, 0), NumPut(0, pt, 0, "Int"), NumPut(0, pt, 4, "Int")
    DllCall("ClientToScreen", "ptr", hwnd, "ptr", &pt)
    sx := NumGet(pt, 0, "Int"), sy := NumGet(pt, 4, "Int")
    scanH := (maxScan < ch) ? maxScan : ch
    p := Gdip_BitmapFromScreen(sx "|" sy "|" cw "|" scanH)
    if !p
        return 0

    stride := scan0 := 0, bd := 0
    if (Gdip_LockBits(p, 0, 0, cw, scanH, stride, scan0, 0x26200A, 3, bd) != 0 || !scan0) {
        Gdip_DisposeImage(p)
        return 0
    }

    leftMargin := Max(8, cw//50), rightMargin := Max(8, cw//50)
    stepX := (samples>1) ? Floor((cw-leftMargin-rightMargin)/(samples-1)) : cw
    hdrH := 0, busyStreak := 0

    Loop, %scanH% {
        y := A_Index-1, row := scan0 + y*stride
        sad := 0, prevY := -1
        Loop, %samples% {
            x := leftMargin + (A_Index-1)*stepX
            if (x >= cw) x := cw-1
            a := NumGet(row + (x<<2), "UInt")
            r := (a>>16)&0xFF, g := (a>>8)&0xFF, b := a&0xFF
            y8 := ( (54*r + 183*g + 19*b) // 256 )
            if (A_Index>1) {
                d := y8 - prevY
                if (d<0) d := -d
                sad += d
            }
            prevY := y8
        }
        if (sad < sadThresh) {
            hdrH++, busyStreak := 0
        } else {
            busyStreak++
            if (busyStreak >= busyRun)
                break
        }
    }

    Gdip_UnlockBits(p, bd), Gdip_DisposeImage(p)
    return hdrH
}

; Map (xPct, yBottomPct) → client coords using header-only content strip.
ContentPointFromBottomPct(hwnd, xPct, yBottomPct, ByRef outX, ByRef outY) {
    if !GetClientSize(cw, ch, hwnd)
        return false
    static lastHeader := 0
    h := DetectHeaderH(hwnd, cw, ch)
    if (Abs(h - lastHeader) <= 2) h := lastHeader  ; debounce tiny jitter
    if (h < 0) h := 0
    if (h >= ch) h := 0
    lastHeader := h

    contentH := ch - h
    x := Round(cw * (xPct / 100.0))
    y := h + (contentH - Round(contentH * (yBottomPct / 100.0)))
    outX := Clamp(x, 0, cw-1)
    outY := Clamp(y, h, h + contentH - 1)
    return true
}


; ---------- OCR TEXT (generic) ----------
OCR_TextPct(hwnd, _leftPct, _yBottomPct, _widthPct, _heightPct, _psm, ByRef ok) {
    global tesseractPath, captureDir
    ok := false
    if !FileExist(tesseractPath)
        return ""
    if (!hwnd)
        return ""
    if !GetClientSize(cw, ch, hwnd)
        return ""

    VarSetCapacity(pt, 8, 0), NumPut(0, pt, 0, "Int"), NumPut(0, pt, 4, "Int")
    DllCall("ClientToScreen", "ptr", hwnd, "ptr", &pt)
    winX := NumGet(pt, 0, "Int"), winY := NumGet(pt, 4, "Int")

    h := DetectHeaderH(hwnd, cw, ch), contentH := ch - h
    sxClient := Round(cw * (_leftPct / 100.0))
    yFromBottomC := Round(contentH * (_yBottomPct / 100.0))
    syClient := h + (contentH - yFromBottomC)
    swClient := Round(cw * (_widthPct / 100.0))
    shClient := Round(contentH * (_heightPct / 100.0))

    rect := (winX + sxClient) "|" (winY + syClient) "|" swClient "|" shClient
    pRaw := Gdip_BitmapFromScreen(rect)
    if (!pRaw)
        return ""

    EnsureDir(captureDir)
    tmpPath := (savePath != "" ? savePath : captureDir "\ocr_tmp.png")
    Gdip_SaveBitmapToFile(pRaw, tmpPath)
    Gdip_DisposeImage(pRaw)

    cmd := """" tesseractPath """ """ tmpPath """ stdout -l eng --oem 1 --psm " _psm
        . " -c user_defined_dpi=300"
    sh := ComObjCreate("WScript.Shell")
    exec := sh.Exec(cmd)
    raw := exec.StdOut.ReadAll()
    ; NOTE: leaving tmpPath on disk for debugging
    ; FileDelete, %tmpPath%

    raw := RegExReplace(raw, "[\r\n]+", " ")
    raw := RegExReplace(raw, "\s+", " ")
    raw := Trim(raw)
    ok := true
    return raw
}


; OCR over full client (ignores header detection). Y is measured from bottom of the FULL client.
OCR_TextClientPct(hwnd, _leftPct, _yBottomPct, _widthPct, _heightPct, _psm, ByRef ok, savePath := "") {
    global tesseractPath, captureDir
    ok := false
    if !FileExist(tesseractPath)
        return ""
    if (!hwnd)
        return ""
    if !GetClientSize(cw, ch, hwnd)
        return ""

    VarSetCapacity(pt, 8, 0), NumPut(0, pt, 0, "Int"), NumPut(0, pt, 4, "Int")
    DllCall("ClientToScreen", "ptr", hwnd, "ptr", &pt)
    winX := NumGet(pt, 0, "Int"), winY := NumGet(pt, 4, "Int")

    sxClient := Round(cw * (_leftPct / 100.0))
    yFromBottom := Round(ch * (_yBottomPct / 100.0))
    syClient := ch - yFromBottom
    swClient := Round(cw * (_widthPct / 100.0))
    shClient := Round(ch * (_heightPct / 100.0))

    rect := (winX + sxClient) "|" (winY + syClient) "|" swClient "|" shClient
    pRaw := Gdip_BitmapFromScreen(rect)
    if (!pRaw)
        return ""

    EnsureDir(captureDir)
    tmpPath := (savePath != "" ? savePath : captureDir "\ocr_tmp.png")
    Gdip_SaveBitmapToFile(pRaw, tmpPath)
    Gdip_DisposeImage(pRaw)

    cmd := """" tesseractPath """ """ tmpPath """ stdout -l eng --oem 1 --psm " _psm
        . " -c user_defined_dpi=300"
    sh := ComObjCreate("WScript.Shell")
    exec := sh.Exec(cmd)
    raw := exec.StdOut.ReadAll()
    ; NOTE: leaving tmpPath on disk for debugging
    ; FileDelete, %tmpPath%

    raw := RegExReplace(raw, "[\r\n]+", " ")
    raw := RegExReplace(raw, "\s+", " ")
    raw := Trim(raw)
    ok := true
    return raw
}


IsReturnToGame(hwnd) {
    global returnRoiLeftPct, returnRoiYBottomPct, returnRoiWidthPct, returnRoiHeightPct, returnRoiPSM
    txt := OCR_TextClientPct(hwnd, returnRoiLeftPct, returnRoiYBottomPct, returnRoiWidthPct, returnRoiHeightPct, returnRoiPSM, ok)
    global lastReturnOCR
    lastReturnOCR := txt
    if (!ok)
        return false
    StringUpper, t, txt
    return InStr(t, "TAP") && InStr(t, "RETURN")
}

IsDeathModal(hwnd) {
    global deathRoiLeftPct, deathRoiYBottomPct, deathRoiWidthPct, deathRoiHeightPct, deathRoiPSM
    global captureDir, lastDeathOCR

    ; Save a dedicated ROI image on every check (for debugging)
    EnsureDir(captureDir)
    ts := A_Now A_MSec
    imgPath := captureDir "\death_check_" ts ".png"

    txt := OCR_TextClientPct(hwnd, deathRoiLeftPct, deathRoiYBottomPct, deathRoiWidthPct, deathRoiHeightPct, deathRoiPSM, ok, imgPath)
    lastDeathOCR := txt

    ; prevent unbounded growth (keep newest 60)
    PrunePattern(captureDir, "death_check_*.png", 60)

    if (!ok)
        return false
    StringUpper, t, txt
    return InStr(t, "GAME") && InStr(t, "STAT")
}


RecoverReturnToGame(hwnd) {
    global returnClickXPct, returnClickYBottomPct, deathHoldMs
    ClickContentPct(hwnd, returnClickXPct, returnClickYBottomPct, deathHoldMs)
}

RecoverDeath(hwnd) {
    global deathFocusClickXPct, deathFocusClickYBottomPct, deathRetryClickXPct, deathRetryClickYBottomPct, deathHoldMs

    ; 1) focus tap to ensure the modal accepts input
    ClickContentPct(hwnd, deathFocusClickXPct, deathFocusClickYBottomPct, deathHoldMs)
    Sleep, 250

    ; 2) primary retry click
    ClickContentPct(hwnd, deathRetryClickXPct, deathRetryClickYBottomPct, deathHoldMs)
    Sleep, 450

    ; 3) if still on death modal, re-try inside the same button (small Y offsets to avoid edge hits)
    if (IsDeathModal(hwnd)) {
        ClickContentPct(hwnd, deathRetryClickXPct, deathRetryClickYBottomPct + 2, deathHoldMs)
        Sleep, 350
    }
    if (IsDeathModal(hwnd)) {
        ClickContentPct(hwnd, deathRetryClickXPct, deathRetryClickYBottomPct - 2, deathHoldMs)
    }
}


ClickContentPct(hwnd, xPct, yBottomPct, holdMs := 80) {
    if !ContentPointFromBottomPct(hwnd, xPct, yBottomPct, cx, cy)
        return false
    ControlClick, x%cx% y%cy%, ahk_id %hwnd%, , Left, 1, NA Down
    Sleep, %holdMs%
    ControlClick, x%cx% y%cy%, ahk_id %hwnd%, , Left, 1, NA Up
    return true
}
; ---------- CLEANUP ----------
OnExit, __exit
return
__exit:
Gdip_Shutdown(pToken)
ExitApp
