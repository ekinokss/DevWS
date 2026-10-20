#Requires AutoHotkey v2.0
#SingleInstance Force

; Alt + Shift + T -> warm DevWS coordinator launch (local IPC)
!+t::DevWSLaunchWorkspace()

; --- DevWS Stage 1 warm coordinator client (managed; do not edit) ---------
global DevWSCoordinatorPipe := "DevWS.Coordinator.v1"
global DevWSCoordinatorScript := EnvGet("LOCALAPPDATA") "\DevWS\app\coordinator.ps1"
global DevWSAppScript := EnvGet("LOCALAPPDATA") '\DevWS\app\ws.ps1'

DevWSLaunchWorkspace() {
    if (DevWSCoordinatorRequest())
        return

    ; Bounded recovery: start the coordinator once, retry briefly, then fall
    ; back to the exact hidden launch behavior (slow but semantically equal).
    DevWSCoordinatorStart()
    deadline := A_TickCount + 6000

    while (A_TickCount < deadline) {
        Sleep 150

        if (DevWSCoordinatorRequest())
            return
    }

    Run('pwsh.exe -NoLogo -NoProfile -WindowStyle Hidden -File "' DevWSAppScript '" launch', , "Hide")
}

DevWSCoordinatorStart() {
    if (!FileExist(DevWSCoordinatorScript))
        return false

    try
        Run('pwsh.exe -NoLogo -NoProfile -WindowStyle Hidden -File "' DevWSCoordinatorScript '"', , "Hide")
    catch
        return false

    return true
}

DevWSCoordinatorProbe() {
    h := DllCall("CreateFile", "Str", "\\.\pipe\" DevWSCoordinatorPipe, "UInt", 0xC0000000, "UInt", 3, "Ptr", 0, "UInt", 3, "UInt", 0, "Ptr", 0, "Ptr")

    if (h = -1 || h = 0)
        return false

    DllCall("CloseHandle", "Ptr", h)
    return true
}

DevWSCoordinatorRequest() {
    request := '{"version":1,"command":"launch"}' . "`n"
    size := StrPut(request, "UTF-8")
    buf := Buffer(size, 0)
    StrPut(request, buf, "UTF-8")

    h := DllCall("CreateFile", "Str", "\\.\pipe\" DevWSCoordinatorPipe, "UInt", 0xC0000000, "UInt", 3, "Ptr", 0, "UInt", 3, "UInt", 0, "Ptr", 0, "Ptr")

    if (h = -1 || h = 0)
        return false

    written := 0
    ok := DllCall("WriteFile", "Ptr", h, "Ptr", buf, "UInt", size - 1, "UInt*", &written, "Ptr", 0)
    ack := ""

    if (ok) {
        deadline := A_TickCount + 5000
        avail := 0

        while (A_TickCount < deadline) {
            if (!DllCall("PeekNamedPipe", "Ptr", h, "Ptr", 0, "UInt", 0, "Ptr", 0, "UInt*", &avail, "Ptr", 0))
                break

            if (avail)
                break

            Sleep 5
        }

        if (avail) {
            rbuf := Buffer(4096, 0)
            read := 0

            if (DllCall("ReadFile", "Ptr", h, "Ptr", rbuf, "UInt", rbuf.Size, "UInt*", &read, "Ptr", 0) && read > 0)
                ack := StrGet(rbuf, read, "UTF-8")
        }
    }

    DllCall("CloseHandle", "Ptr", h)
    return ack != "" && InStr(ack, '"ok":true')
}

; Ensure the warm coordinator is running once at login (idempotent; hidden).
if (!DevWSCoordinatorProbe())
    DevWSCoordinatorStart()

; Additional set launch hotkeys (generated derived state; safe to be absent)
#Include "*i %LOCALAPPDATA%\DevWS\state\hotkeys\bindings.ahk"
