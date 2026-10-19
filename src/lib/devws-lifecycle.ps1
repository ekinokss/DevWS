# DevWS lifecycle lock.
#
# One small cross-process named mutex serializes the live side effects of
# `ws launch` (app ownership/adoption, app launches, app moves, and the
# elevated terminal launch worker request). It is deliberately not a
# scheduler: there is no queue, no request ordering, no lock file, no
# background service, and no persistent state.
#
# The mutex lives in the Local\ namespace, so it is scoped to the interactive
# Windows session and never spans sessions or the network.

function Get-DevWSLifecycleMutexName {
    # Production mutex name; tests must pass their own -MutexName.
    return "Local\DevWS.Lifecycle.v1"
}

function Get-DevWSLifecycleTimeoutSeconds {
    # Generous but bounded: a stuck owner fails the wait actionably instead of
    # hanging a launch forever.
    return 300
}

function Invoke-DevWSWithLifecycleLock {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [int]$TimeoutSeconds = (Get-DevWSLifecycleTimeoutSeconds),
        [string]$MutexName = (Get-DevWSLifecycleMutexName)
    )

    if ($TimeoutSeconds -lt 1) {
        throw "The lifecycle lock timeout must be at least 1 second."
    }

    if ([string]::IsNullOrWhiteSpace($MutexName)) {
        throw "The lifecycle lock mutex name must not be empty."
    }

    $mutex    = [System.Threading.Mutex]::new($false, $MutexName)
    $acquired = $false

    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        }
        catch [System.Threading.AbandonedMutexException] {
            # The previous owner died without releasing the mutex; ownership
            # has been transferred to this process. Continue safely.
            $acquired = $true
        }

        if (-not $acquired) {
            throw "Timed out after $TimeoutSeconds seconds waiting for another DevWS launch to finish. Wait for it to complete and retry; this launch made no workspace changes."
        }

        return (& $ScriptBlock)
    }
    finally {
        if ($acquired) {
            $mutex.ReleaseMutex()
        }

        $mutex.Dispose()
    }
}
