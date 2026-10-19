#Requires AutoHotkey v2.0
#SingleInstance Off

; DevWS window helper.
;
;   focus-hwnd <hwnd>            restore if minimized and activate
;
; HWND-based so a dynamic top-level title never matters.
;
; This helper retains exactly one production mode: window focus. Existence,
; process-name, restore/move, rectangle capture and the exact-title locator
; lookup all moved to the in-process Win32 layer (devws-window-ops.ps1).
; Close/reset keeps its own reset-window.ahk helper.

if A_Args.Length < 2
    ExitApp 2

mode := A_Args[1]

if (mode = "focus-hwnd") {
    if !hwnd := WinExist("ahk_id " Integer(A_Args[2]))
        ExitApp 1

    try {
        ; Restore only if minimized. Do not alter maximized/normal geometry.
        if (WinGetMinMax("ahk_id " hwnd) = -1)
            WinRestore "ahk_id " hwnd

        WinActivate "ahk_id " hwnd
        ExitApp 0
    }
    catch {
        ExitApp 1
    }
}

ExitApp 2
