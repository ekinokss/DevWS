# DevWS app dispatch.
#
# Match kinds:   exe | processPathContains
# Launch kinds:  exe | appId
#
# Exact window resolution for the Phase 8 lifecycle lives in
# devws-app-window.ps1 (generic top-level window enumeration, bounded ownership
# classification, ambiguity-safe selection). This library keeps the configured
# launch command semantics and the single controlled launch invocation.

function ConvertTo-DevWSWindowsArgument {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value -eq "") {
        return '""'
    }

    if ($Value -match '[\s"]') {
        $escaped = $Value -replace '(\\*)"', '$1$1\"'
        return '"' + $escaped + '"'
    }

    return $Value
}

function Get-DevWSAppMatchSummary {
    param(
        [Parameter(Mandatory)]
        $App
    )

    return "match=$($App.match.kind) '$($App.match.value)'"
}

function Get-DevWSAppLaunchSummary {
    param(
        [Parameter(Mandatory)]
        $App
    )

    $suffix = ""

    if (@($App.launch.args).Count -gt 0) {
        $suffix = " " + (@($App.launch.args) -join " ")
    }

    return "launch=$($App.launch.kind) '$($App.launch.value)'$suffix"
}

function Get-DevWSAppLaunchCommandLine {
    param(
        [Parameter(Mandatory)]
        $App
    )

    $kind = [string]$App.launch.kind
    $value = [string]$App.launch.value
    $arguments = @($App.launch.args)

    switch ($kind) {
        "exe" {
            # Always quote the executable path, matching v1 behavior.
            $parts = @('"' + ($value -replace '"', '\"') + '"')

            foreach ($argument in $arguments) {
                $parts += ConvertTo-DevWSWindowsArgument ([string]$argument)
            }

            return ($parts -join " ")
        }

        "appId" {
            if ($arguments.Count -gt 0) {
                throw "App '$($App.id)': launch.kind 'appId' does not support launch args. Remove launch.args for this app, or use an executable (launch.kind 'exe') definition when arguments are required."
            }

            return "explorer.exe `"shell:AppsFolder\$value`""
        }

        default {
            throw "App '$($App.id)': unsupported launch.kind '$kind' (supported: exe, appId)."
        }
    }
}

function Invoke-DevWSAppLaunchCommand {
    param(
        [Parameter(Mandatory)]
        $App
    )

    # One controlled launch invocation. Get-DevWSAppLaunchCommandLine validates
    # the definition first, so unsupported kinds and appId arguments fail
    # before any process starts. Exact-window acquisition is the caller's job.
    $null = Get-DevWSAppLaunchCommandLine -App $App

    if ([string]$App.launch.kind -eq "appId") {
        Start-Process `
            -FilePath "explorer.exe" `
            -ArgumentList ('"shell:AppsFolder\{0}"' -f [string]$App.launch.value) | Out-Null

        return
    }

    $value     = [string]$App.launch.value
    $arguments = @($App.launch.args)

    if ($arguments.Count -eq 0) {
        Start-Process -FilePath $value | Out-Null
        return
    }

    $argumentString = (@($arguments | ForEach-Object { ConvertTo-DevWSWindowsArgument ([string]$_) }) -join " ")
    Start-Process -FilePath $value -ArgumentList $argumentString | Out-Null
}
