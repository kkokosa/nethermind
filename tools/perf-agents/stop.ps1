#Requires -Version 5.1
<#
.SYNOPSIS
    Stop the perf-ai agent system
#>

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path "$ScriptDir\..\..").Path
$RunDir = "$ScriptDir\run"

Write-Host "Stopping perf-ai agent system..."

# Kill decision server
$serverPidFile = "$RunDir\server.pid"
if (Test-Path $serverPidFile) {
    $pid = (Get-Content $serverPidFile).Trim()
    try {
        $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
        if ($proc) {
            Stop-Process -Id $pid -Force
            Write-Host "  Stopped server (PID $pid)"
        }
    } catch {}
    Remove-Item $serverPidFile -Force
}

# Kill workers
$workerPidFile = "$RunDir\workers.pid"
if (Test-Path $workerPidFile) {
    foreach ($line in Get-Content $workerPidFile) {
        $pid = $line.Trim()
        if (-not $pid) { continue }
        try {
            $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
            if ($proc) {
                # Kill entire process tree
                Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
                Write-Host "  Stopped worker PID $pid"
            }
        } catch {}
    }
    Remove-Item $workerPidFile -Force
}

# Clean status files + lock
Remove-Item "$RunDir\status\*.json" -Force -ErrorAction SilentlyContinue
Remove-Item "$RunDir\benchmark.lock" -Force -ErrorAction SilentlyContinue

Write-Host "All agents stopped."
Write-Host ""

# Show orphaned worktrees
$wtDir = "$RepoRoot\.worktrees"
if (Test-Path $wtDir) {
    $worktrees = Get-ChildItem $wtDir -Directory
    if ($worktrees.Count -gt 0) {
        Write-Host "Worktrees still present ($($worktrees.Count)):"
        $worktrees | ForEach-Object { Write-Host "  $($_.Name)" }
        Write-Host ""
        Write-Host "To clean up:  git worktree list; git worktree prune"
        Write-Host "Or remove all: Remove-Item .worktrees -Recurse -Force; git worktree prune"
    }
}
