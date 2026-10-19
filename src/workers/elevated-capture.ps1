$ErrorActionPreference = "Stop"

# Public Security hardening: installed workers resolve libraries ONLY from the
# administrator-protected privileged root next to them
# (<privileged root>\workers -> <privileged root>\lib). Repository execution
# resolves <repo>\src\lib. There is no fallback to user-writable install
# copies.
$LibDir = Join-Path (Split-Path -Parent $PSScriptRoot) "lib"

if (-not (Test-Path -LiteralPath (Join-Path $LibDir "devws-paths.ps1") -PathType Leaf)) {
    throw "DevWS runtime libraries were not found at '$LibDir'. Installed workers require the administrator-protected privileged root next to them; run install.ps1."
}

. (Join-Path $LibDir "devws-paths.ps1")
Assert-DevWSWorkerLibraryRoot -LibDir $LibDir
. (Join-Path $LibDir "devws-config.ps1")
. (Join-Path $LibDir "devws-bindings.ps1")
. (Join-Path $LibDir "devws-ahk.ps1")
. (Join-Path $LibDir "devws-native.ps1")
. (Join-Path $LibDir "devws-window-ops.ps1")
. (Join-Path $LibDir "devws-uia.ps1")
. (Join-Path $LibDir "devws-state.ps1")
. (Join-Path $LibDir "devws-identity.ps1")
. (Join-Path $LibDir "devws-locator.ps1")
. (Join-Path $LibDir "devws-worker-protocol.ps1")
. (Join-Path $LibDir "devws-terminal-operations.ps1")

# One-shot authenticated pipe transport (Public Security Phase 2-D): exactly
# one connection, one request, ACCEPTED before the protected claim creation,
# FINAL with the outcome (including the publication identity), then exit.
# There are no request/result files.
$location = Resolve-DevWSConfigLocation -StartPath $PSScriptRoot
$kind = "capture"

$server = New-DevWSWorkerPipeServer -Kind $kind

try {
    if (-not (Wait-DevWSWorkerPipeConnection -Server $server -TimeoutSeconds 60)) {
        exit 0
    }

    $request = Read-DevWSWorkerPipeRequest -Server $server -Kind $kind -TimeoutSeconds 20

    if (-not $request.Ok) {
        [void](Send-DevWSWorkerError -Server $server -Kind $kind -RequestId ([string]$request.RequestId) -Error ([string]$request.Error))
        exit 0
    }

    $requestId = [string]$request.RequestId
    $payload = $request.Payload

    # ---- pre-accept validation (any failure: explicit rejection, no side
    # effects) ---------------------------------------------------------------
    if (-not (Test-DevWSProperty -Object $payload -Name "setId") -or [string]::IsNullOrWhiteSpace([string]$payload.setId)) {
        [void](Send-DevWSWorkerError -Server $server -Kind $kind -RequestId $requestId -Error "Capture request is missing the required 'setId'.")
        exit 0
    }

    $config = $null
    $target = $null
    $state = $null
    $terminals = $null

    try {
        $config = Get-DevWSConfig -Location $location
        $target = Resolve-DevWSLifecycleTarget -Config $config -SetId ([string]$payload.setId)
        $state = Read-DevWSRuntimeState
        $terminals = @(Get-DevWSWindows -Config $config -Type terminal -EnabledOnly -Set $target.Set)
    }
    catch {
        [void](Send-DevWSWorkerError -Server $server -Kind $kind -RequestId $requestId -Error $_.Exception.Message)
        exit 0
    }

    # Phase 2-B protected publication: the request id (validated as a canonical
    # lowercase GUID by the transport frame contract - the scheduled capture
    # worker claims ONLY canonical lowercase GUID operation ids) becomes the
    # claim's operation id. ACCEPTED precedes claim creation.
    [void](Send-DevWSWorkerAccepted -Server $server -Kind $kind -RequestId $requestId)

    try {
        $claim = New-DevWSProtectedCaptureClaim -OperationId $requestId

        try {
            $publication = [guid]::NewGuid().ToString()
            Set-DevWSProtectedPublicationIdentity -ClaimPath $claim.ClaimPath -Publication $publication

            # Thin transport shell: the shared terminal-operations core owns the policy.
            $null = Invoke-DevWSTerminalCaptureOperation -SetId $target.SetId -Terminals $terminals -State $state -ClaimPath $claim.ClaimPath

            [void](Send-DevWSWorkerFinal -Server $server -Kind $kind -RequestId $requestId -Ok $true -Message "OK" -Data @{ publication = $publication })
        }
        finally {
            $claim.Scope.Dispose()
        }
    }
    catch {
        [void](Send-DevWSWorkerFinal -Server $server -Kind $kind -RequestId $requestId -Ok $false -Message $_.Exception.Message)
        throw
    }
}
finally {
    # Ensure the caller consumed the buffered response (or that its handle is gone)
    # before the one-shot pipe instance is destroyed.
    Wait-DevWSWorkerFrameDelivery -Server $server
    $server.Dispose()
}
