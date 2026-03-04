#Requires -Version 5.1
<#
.SYNOPSIS
    Stop the perf-ai agent system

.PARAMETER ServerOnly
    Only stop the decision server, leave workers running

.PARAMETER WorkersOnly
    Only stop workers, leave the decision server running

.EXAMPLE
    .\tools\perf-agents\stop.ps1
    .\tools\perf-agents\stop.ps1 -ServerOnly
    .\tools\perf-agents\stop.ps1 -WorkersOnly
#>

param(
    [switch]$ServerOnly,
    [switch]$WorkersOnly
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path "$ScriptDir\..\..").Path
$RunDir = "$ScriptDir\run"

$stopServer = -not $WorkersOnly
$stopWorkers = -not $ServerOnly

Write-Host "Stopping perf-ai agent system..."

# Kill decision server
if ($stopServer) {
    $serverPidFile = "$RunDir\server.pid"
    if (Test-Path $serverPidFile) {
        $procId = (Get-Content $serverPidFile).Trim()
        try {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc) {
                Stop-Process -Id $procId -Force
                Write-Host "  Stopped server (PID $procId)"
            }
        } catch {}
        Remove-Item $serverPidFile -Force
    }
}

# Kill workers
if ($stopWorkers) {
    $workerPidFile = "$RunDir\workers.pid"
    if (Test-Path $workerPidFile) {
        foreach ($line in Get-Content $workerPidFile) {
            $procId = $line.Trim()
            if (-not $procId) { continue }
            try {
                $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
                if ($proc) {
                    # Kill entire process tree
                    Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                    Write-Host "  Stopped worker PID $procId"
                }
            } catch {}
        }
        Remove-Item $workerPidFile -Force
    }

    # Clean status files + lock
    Remove-Item "$RunDir\status\*.json" -Force -ErrorAction SilentlyContinue
    Remove-Item "$RunDir\benchmark.lock" -Force -ErrorAction SilentlyContinue
}

if ($stopServer -and $stopWorkers) {
    Write-Host "All agents stopped."
} elseif ($stopServer) {
    Write-Host "Server stopped. Workers still running."
} else {
    Write-Host "Workers stopped. Server still running."
}
Write-Host ""

# Clean up worktrees when stopping workers
if ($stopWorkers) {
    $wtDir = "$RepoRoot\.worktrees"
    if (Test-Path $wtDir) {
        $worktrees = Get-ChildItem $wtDir -Directory
        if ($worktrees.Count -gt 0) {
            Write-Host "Cleaning up $($worktrees.Count) worktree(s)..."
            foreach ($wt in $worktrees) {
                try {
                    & git -C $RepoRoot worktree remove $wt.FullName --force 2>$null
                    Write-Host "  Removed $($wt.Name)"
                } catch {
                    Write-Host "  Failed to remove $($wt.Name), removing directory" -ForegroundColor Yellow
                    Remove-Item $wt.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            & git -C $RepoRoot worktree prune 2>$null
        }
    }
}
