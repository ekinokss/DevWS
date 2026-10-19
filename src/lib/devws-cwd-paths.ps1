# DevWS Phase 2-C protected cwd path/key policy (dependency-free leaf).
#
# ONE implementation of every protected cwd filesystem rule:
#   - the deterministic logical-ID -> filesystem-key mapping;
#   - the protected cwd namespace derivation (ProgramData + current SID only);
#   - the accepted conservative Windows pathname budget;
#   - the installed bootstrap publication-target decision.
#
# This leaf must stay loadable by the static tracked-shell bootstrap: it never
# dot-sources another library, never consults environment path overrides and
# never falls back to user-writable locations. Security policy (owner/DACL
# validation, exclusive creation, the P2-A root contract) deliberately lives
# in the existing protected-state primitives; this leaf only derives names and
# enforces the budget.
#
# Namespace (authority owned by High writers only):
#   <SID root>\cwd\sessions\<set-key>\<terminal-key>.json        (tab 0)
#   <SID root>\cwd\sessions\<set-key>\<terminal-key>\<tab>.json  (tabs 1+)
#   <SID root>\cwd\publications\<set-key>\<terminal-key>.json    (tab 0)
#   <SID root>\cwd\publications\<set-key>\<terminal-key>\<tab>.json (tabs 1+)

function Get-DevWSCwdPathsLayout {
    # Same discriminator rule as devws-paths.ps1, derived from this file's own
    # location so the bootstrap can classify itself without any dependency.
    $appRootName = Split-Path -Leaf (Split-Path -Parent $PSScriptRoot)

    if ($appRootName -ieq "src")        { return "repository" }
    if ($appRootName -ieq "app")        { return "installed-normal" }
    if ($appRootName -ieq "privileged") { return "installed-privileged" }

    return "unsupported"
}

function Get-DevWSCwdProtectedBudgets {
    # Accepted conservative contract (Public Security Phase 2-C path budget):
    # the longest materialized pathname is the atomic temporary file in the
    # indexed publications terminal directory = SID root + 138 characters
    # (category prefixes + two 33-character keys + '\' + the 52-character
    # '.cwd-<pid>-<guidN>.tmp' name), so the supported SID-root maximum is
    # 255 - 138 = 117. Nothing here relies on Windows long-path support.
    return [pscustomobject]@{
        MaxPathLength           = 255
        MaxRootLength           = 117
        MaxRelativePathLength   = 138
        MaxKeyLength            = 33
        MaxTempNameLength       = 52
        MaxTabIndexStringLength = 10
    }
}

function Test-DevWSCwdPathIdentifier {
    # The canonical stable-ID domain (canonical config validation owns the
    # authoritative check; this is the defensive duplicate for direct callers).
    param([AllowEmptyString()][string]$Id)

    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    return ($Id -match '^[A-Za-z0-9._-]+$')
}

function ConvertTo-DevWSCwdProtectedKey {
    # identity = invariant-lowercase ID (case variants deliberately map to the
    # same key). key = slug + '-' + first 24 lowercase hex characters of
    # SHA-256(UTF-8(identity)).
    #
    # slug: encoded readable prefix - [a-z0-9_-] retained, every other ASCII
    # char becomes '~' + lowercase hex of its code ('.' => '~2e'), unit-wise
    # truncated to at most 8 encoded characters without ever cutting an escape
    # token in half.
    #
    # Result grammar: ^[a-z0-9_~-]{1,33}$ - no dots, no separators, no ADS
    # separator, no traversal, no reserved device base name, no trailing-dot
    # ambiguity. 96-bit truncated-hash collision model: an unexpected mapping
    # collision never grants authority (readers fail with a raw-identity
    # mismatch; writers refuse to overwrite a foreign leaf).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Id)

    if (-not (Test-DevWSCwdPathIdentifier -Id $Id)) {
        throw "The logical identity '$Id' is not a canonical stable identifier; refusing to derive a protected cwd key."
    }

    $identity = $Id.ToLowerInvariant()
    $slug = [System.Text.StringBuilder]::new()
    $total = 0

    foreach ($ch in $identity.ToCharArray()) {
        $piece = $(if ($ch -match '^[a-z0-9_\-]$') { [string]$ch } else { '~' + ([int]$ch).ToString('x') })

        if ($total + $piece.Length -gt 8) { break }

        [void]$slug.Append($piece)
        $total += $piece.Length
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $hex = [System.Convert]::ToHexString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }

    return ($slug.ToString() + '-' + $hex.Substring(0, 24))
}

function Get-DevWSCwdProtectedSidRoot {
    # Installed authority: ProgramData known folder + the DevWS container +
    # privileged-state + the CURRENT user SID. No environment variable, caller
    # parameter or repository seam can redirect this derivation.
    $programData = [Environment]::GetFolderPath('CommonApplicationData')

    if ([string]::IsNullOrWhiteSpace($programData)) {
        throw "The ProgramData known folder could not be resolved; refusing to derive the protected cwd state root."
    }

    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value

    if ([string]::IsNullOrWhiteSpace($sid)) {
        throw "The current user SID could not be resolved; refusing to derive the protected cwd state root."
    }

    return (Join-Path (Join-Path (Join-Path $programData "DevWS") "privileged-state") $sid)
}

function Test-DevWSCwdProtectedPathBudget {
    # The guard covers EVERY protected cwd pathname the implementation can
    # materialize: both category roots, encoded set and terminal directories,
    # tab-0 and indexed destinations, expected records, publications and the
    # atomic temporary files (maximum Int32 tabIndex and 10-digit PID strings
    # included). root + 138 <= 255 is the total rule.
    param([Parameter(Mandatory)][string]$SidRoot)

    $budgets = Get-DevWSCwdProtectedBudgets
    $rootLength = $SidRoot.Length

    if ($rootLength -gt $budgets.MaxRootLength) {
        return [pscustomobject]@{
            Ok                 = $false
            Reason             = "protected-root-budget"
            RootLength         = $rootLength
            MaxRootLength      = $budgets.MaxRootLength
            LongestPathLength  = $rootLength + $budgets.MaxRelativePathLength
        }
    }

    $longest = $rootLength + $budgets.MaxRelativePathLength

    if ($longest -gt $budgets.MaxPathLength) {
        return [pscustomobject]@{
            Ok                = $false
            Reason            = "protected-path-budget"
            RootLength        = $rootLength
            MaxRootLength     = $budgets.MaxRootLength
            LongestPathLength = $longest
        }
    }

    return [pscustomobject]@{
        Ok                = $true
        Reason            = "ok"
        RootLength        = $rootLength
        MaxRootLength     = $budgets.MaxRootLength
        LongestPathLength = $longest
    }
}

function Assert-DevWSCwdProtectedPathBudget {
    # Fail-closed writer guard. Must run before any protected cwd descendant
    # or leaf is created or modified.
    param(
        [Parameter(Mandatory)][string]$SidRoot,
        [string]$Operation = "protected cwd operation"
    )

    $budget = Test-DevWSCwdProtectedPathBudget -SidRoot $SidRoot

    if (-not [bool]$budget.Ok) {
        throw ("DevWS protected cwd path budget exceeded for '$Operation': the protected SID root is $($budget.RootLength) characters; the supported maximum is $($budget.MaxRootLength) (longest materialized path = root + 138 <= 255). Refusing before any protected write.")
    }

    return $budget
}

function Test-DevWSCwdProtectedContainment {
    # True only when the path is strictly inside the SID root.
    param(
        [Parameter(Mandatory)][string]$SidRoot,
        [AllowEmptyString()][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    try {
        $rootFull = [System.IO.Path]::GetFullPath($SidRoot)
        $pathFull = [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        return $false
    }

    if ([string]::Equals($rootFull, $pathFull, [StringComparison]::OrdinalIgnoreCase)) { return $false }

    return $pathFull.StartsWith($rootFull.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-DevWSCwdProtectedChain {
    # The ORDERED directory components a protected leaf addresses, from the
    # SID root down. Tab-0 leaves stop at the encoded set directory; indexed
    # leaves additionally address the encoded terminal directory. This is the
    # only chain definition; readers and writers share it.
    param(
        [Parameter(Mandatory)][string]$SidRoot,
        [Parameter(Mandatory)][ValidateSet('sessions', 'publications')][string]$Kind,
        [Parameter(Mandatory)][string]$SetId,
        [Parameter(Mandatory)][string]$TerminalId,
        [int]$TabIndex = 0
    )

    if ($TabIndex -lt 0) {
        throw "A configured tab index cannot be negative (got $TabIndex)."
    }

    $setKey    = ConvertTo-DevWSCwdProtectedKey -Id $SetId
    $termKey   = ConvertTo-DevWSCwdProtectedKey -Id $TerminalId

    $list = [System.Collections.Generic.List[string]]::new()
    $list.Add((Join-Path $SidRoot "cwd"))
    $kindRoot = Join-Path (Join-Path $SidRoot "cwd") $Kind
    $list.Add($kindRoot)
    $setDir = Join-Path $kindRoot $setKey
    $list.Add($setDir)

    if ($TabIndex -gt 0) {
        $list.Add((Join-Path $setDir $termKey))
    }

    return $list.ToArray()
}

function Get-DevWSCwdProtectedPath {
    # The authoritative destination leaf for one logical identity. Tab 0 keeps
    # the historical terminal-level file shape; tabs 1+ live in the encoded
    # terminal directory under their canonical decimal tabIndex.
    param(
        [Parameter(Mandatory)][string]$SidRoot,
        [Parameter(Mandatory)][ValidateSet('sessions', 'publications')][string]$Kind,
        [Parameter(Mandatory)][string]$SetId,
        [Parameter(Mandatory)][string]$TerminalId,
        [int]$TabIndex = 0
    )

    $chain  = Get-DevWSCwdProtectedChain -SidRoot $SidRoot -Kind $Kind -SetId $SetId -TerminalId $TerminalId -TabIndex $TabIndex
    $leafName = $(if ($TabIndex -eq 0) { (ConvertTo-DevWSCwdProtectedKey -Id $TerminalId) + ".json" } else { $TabIndex.ToString() + ".json" })

    return (Join-Path $chain[$chain.Count - 1] $leafName)
}

function Test-DevWSCwdBootstrapPublicationTarget {
    # Installed bootstrap decision: derive the protected publication path from
    # the validated logical identity and accept a supplied path ONLY when it
    # exactly equals the derived path. Any failure disables publication for
    # this shell without affecting the interactive session.
    param(
        [Parameter(Mandatory)][string]$SidRoot,
        [Parameter(Mandatory)][string]$SetId,
        [Parameter(Mandatory)][string]$TerminalId,
        [int]$TabIndex = 0,
        [AllowEmptyString()][string]$SuppliedPath
    )

    if ($TabIndex -lt 0) {
        return [pscustomobject]@{ Ok = $false; Reason = "tab-index-negative"; DerivedPath = $null }
    }

    $budget = Test-DevWSCwdProtectedPathBudget -SidRoot $SidRoot

    if (-not [bool]$budget.Ok) {
        return [pscustomobject]@{ Ok = $false; Reason = [string]$budget.Reason; DerivedPath = $null }
    }

    if (-not (Test-DevWSCwdPathIdentifier -Id $SetId) -or -not (Test-DevWSCwdPathIdentifier -Id $TerminalId)) {
        return [pscustomobject]@{ Ok = $false; Reason = "identity-invalid"; DerivedPath = $null }
    }

    $derived = Get-DevWSCwdProtectedPath -SidRoot $SidRoot -Kind 'publications' -SetId $SetId -TerminalId $TerminalId -TabIndex $TabIndex

    if ([string]::IsNullOrWhiteSpace($SuppliedPath) -or -not [string]::Equals([System.IO.Path]::GetFullPath($SuppliedPath), [System.IO.Path]::GetFullPath($derived), [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Ok = $false; Reason = "publication-path-mismatch"; DerivedPath = $derived }
    }

    return [pscustomobject]@{ Ok = $true; Reason = "ok"; DerivedPath = $derived }
}
