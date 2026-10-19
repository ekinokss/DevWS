#Requires AutoHotkey v2.0
#SingleInstance Off

; DevWS reset helper.
;
;   close-hwnd <hwnd>   activate the window and close it using the proven
;                       close-all flow (Alt+F4, then confirm the dialog).
;
; HWND-based so a dynamic top-level title never matters.

if A_Args.Length < 2
    ExitApp 2

mode := A_Args[1]

if (mode = "close-hwnd") {
    hwnd := Integer(A_Args[2])

    if !WinExist("ahk_id " hwnd)
        ExitApp 0

    WinActivate "ahk_id " hwnd

    if !WinWaitActive("ahk_id " hwnd, , 2)
        ExitApp 2

    ; Close the entire Windows Terminal window.
    Send "!{F4}"

    ; If there was only one tab, the window may close immediately.
    Sleep 300

    if !WinExist("ahk_id " hwnd)
        ExitApp 0

    ; Multi-tab Windows Terminal shows:
    ; "Do you want to close all tabs?"
    ; "Close all" is the default focused button.
    Send "{Enter}"

    if WinWaitClose("ahk_id " hwnd, , 3)
        ExitApp 0

    ExitApp 3
}

ExitApp 2
