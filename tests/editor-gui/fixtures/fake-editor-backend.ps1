$ErrorActionPreference = 'Stop'

$scenarioPath = $env:DEVWS_TEST_SCENARIO
if ([string]::IsNullOrWhiteSpace($scenarioPath) -or -not (Test-Path -LiteralPath $scenarioPath -PathType Leaf)) {
    throw 'DEVWS_TEST_SCENARIO is required for the fake editor backend.'
}

function Read-Scenario {
    return (Get-Content -LiteralPath $scenarioPath -Raw | ConvertFrom-Json -Depth 40)
}

function Write-Envelope {
    param($Request, $Result, $Warnings, $ErrorObject)

    $envelope = [ordered]@{
        protocol = 'devws-editor/1'
        id       = $Request.id
        ok       = ($null -eq $ErrorObject)
        op       = $Request.op
        result   = $Result
        warnings = @($Warnings)
        error    = $ErrorObject
    }

    [Console]::Out.WriteLine(($envelope | ConvertTo-Json -Compress -Depth 40))
    [Console]::Out.Flush()
}

function New-ProtocolError {
    param([string]$Code, [string]$Message)

    return [ordered]@{
        code      = $Code
        message   = $Message
        retryable = $false
        details   = [ordered]@{ source = 'fake-editor-backend' }
    }
}

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) {
        break
    }

    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }

    $request = $line | ConvertFrom-Json -Depth 40
    $scenario = Read-Scenario
    $op = [string]$request.op

    if ($op -eq 'hello') {
        Write-Envelope -Request $request -Result $scenario.hello -Warnings @() -ErrorObject $null
        continue
    }

    if ($op -eq 'inspect' -and $scenario.mode -in @('timeout-once', 'malformed-once', 'exit-once')) {
        $marker = [string]$scenario.marker
        if ([string]::IsNullOrWhiteSpace($marker)) {
            throw 'mode requires a marker path'
        }

        if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
            New-Item -ItemType File -Path $marker -Force | Out-Null

            switch ([string]$scenario.mode) {
                'timeout-once' { Start-Sleep -Seconds 5; continue }
                'malformed-once' {
                    [Console]::Out.WriteLine('{bad json')
                    [Console]::Out.Flush()
                    continue
                }
                'exit-once' { exit 7 }
            }
        }
    }

    switch ($op) {
        'inspect' {
            if ($null -ne $scenario.inspectError) {
                Write-Envelope -Request $request -Result $null -Warnings @() -ErrorObject $scenario.inspectError
            }
            else {
                Write-Envelope -Request $request -Result $scenario.inspect -Warnings @() -ErrorObject $null
            }
        }
        'read-config' {
            if ($null -ne $scenario.readConfigError) {
                Write-Envelope -Request $request -Result $null -Warnings @() -ErrorObject $scenario.readConfigError
            }
            else {
                Write-Envelope -Request $request -Result $scenario.readConfig -Warnings @() -ErrorObject $null
            }
        }
        'project' {
            $setId = [string]$request.params.setId
            if ([string]::IsNullOrWhiteSpace($setId)) {
                $setId = [string]$scenario.defaultSet
            }

            $projection = $null
            $property = $scenario.projects.PSObject.Properties[$setId]
            if ($null -ne $property) {
                $projection = $property.Value
            }
            if ($null -eq $projection) {
                Write-Envelope -Request $request -Result $null -Warnings @() -ErrorObject (New-ProtocolError -Code 'set-not-found' -Message "Unknown set '$setId'.")
            }
            else {
                Write-Envelope -Request $request -Result $projection -Warnings $scenario.warnings -ErrorObject $null
            }
        }
        'validate' {
            if ($null -ne $scenario.validateError) {
                Write-Envelope -Request $request -Result $null -Warnings @() -ErrorObject $scenario.validateError
            }
            elseif ($null -ne $scenario.validate) {
                Write-Envelope -Request $request -Result $scenario.validate -Warnings @() -ErrorObject $null
            }
            else {
                Write-Envelope -Request $request -Result ([ordered]@{ valid = $true; saveEligible = $false; errors = @() }) -Warnings @() -ErrorObject $null
            }
        }
        'preview' {
            if ($null -ne $scenario.previewError) {
                Write-Envelope -Request $request -Result $null -Warnings @() -ErrorObject $scenario.previewError
            }
            elseif ($null -ne $scenario.preview) {
                $previewWarnings = if ($null -ne $scenario.PSObject.Properties['previewWarnings']) {
                    @($scenario.previewWarnings)
                } else {
                    @()
                }
                Write-Envelope -Request $request -Result $scenario.preview -Warnings $previewWarnings -ErrorObject $null
            }
            else {
                Write-Envelope -Request $request -Result $null -Warnings @() -ErrorObject (New-ProtocolError -Code 'backend-internal' -Message 'No fake preview result configured.')
            }
        }
        'convert' {
            if ($null -ne $scenario.convertError) {
                Write-Envelope -Request $request -Result $null -Warnings @() -ErrorObject $scenario.convertError
            }
            elseif ($null -ne $scenario.convert) {
                Write-Envelope -Request $request -Result $scenario.convert -Warnings @() -ErrorObject $null
            }
            else {
                Write-Envelope -Request $request -Result $null -Warnings @() -ErrorObject (New-ProtocolError -Code 'backend-internal' -Message 'No fake convert result configured.')
            }
        }
        'save' {
            $countPath = [string]$scenario.saveCountPath
            if (-not [string]::IsNullOrWhiteSpace($countPath)) {
                $count = 0
                if (Test-Path -LiteralPath $countPath -PathType Leaf) {
                    $count = [int](Get-Content -LiteralPath $countPath -Raw)
                }
                Set-Content -LiteralPath $countPath -Value ([string]($count + 1)) -Encoding ASCII
            }

            switch ([string]$scenario.saveMode) {
                'timeout' { Start-Sleep -Seconds 5; continue }
                'exit' { exit 9 }
                'malformed' {
                    [Console]::Out.WriteLine('{bad save json')
                    [Console]::Out.Flush()
                    continue
                }
            }

            if ($null -ne $scenario.saveError) {
                Write-Envelope -Request $request -Result $null -Warnings @() -ErrorObject $scenario.saveError
            }
            elseif ($null -ne $scenario.save) {
                Write-Envelope -Request $request -Result $scenario.save -Warnings @() -ErrorObject $null
            }
            else {
                Write-Envelope -Request $request -Result $null -Warnings @() -ErrorObject (New-ProtocolError -Code 'backend-internal' -Message 'No fake save result configured.')
            }
        }
        'shutdown' {
            Write-Envelope -Request $request -Result ([ordered]@{ stopped = $true }) -Warnings @() -ErrorObject $null
            exit 0
        }
        default {
            Write-Envelope -Request $request -Result $null -Warnings @() -ErrorObject (New-ProtocolError -Code 'unsupported-operation' -Message "Operation '$op' is not implemented.")
        }
    }
}
