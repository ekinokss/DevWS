# DevWS P9-H replay instrumentation - module loader.
#
# Dot-source this file to load the whole instrumentation surface. Importing it
# MUST remain side-effect free: no process launch, no VM contact, no session
# manipulation, no host configuration change. Every external action lives behind
# an explicit function call with its own authorization gate.
#
# Loading order matters: core defines the artifact/time primitives that the
# other modules consume.

Set-StrictMode -Version Latest

$script:P9HModuleRoot = $PSScriptRoot

$script:P9HModuleFiles = @(
    'p9h-core.ps1'
    'p9h-e1-observer.ps1'
    'p9h-e1-state.ps1'
    'p9h-n2-recorder.ps1'
    'p9h-n2-inventory.ps1'
    'p9h-verdict.ps1'
    'p9h-evidence.ps1'
    'p9h-fault.ps1'
)

foreach ($file in $script:P9HModuleFiles) {
    $path = Join-Path $script:P9HModuleRoot $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "P9-H instrumentation: module file is missing: $path"
    }
    . $path
}

function Get-P9HModuleInventory {
    # Report what was loaded, so a test can assert the surface is complete.
    param()
    return [pscustomobject][ordered]@{
        ModuleRoot = $script:P9HModuleRoot
        Files      = @($script:P9HModuleFiles)
        Count      = @($script:P9HModuleFiles).Count
    }
}
