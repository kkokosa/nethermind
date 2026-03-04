#Requires -Version 5.1
<#
.SYNOPSIS
    Launch the perf-ai agent system (PowerShell version)

.DESCRIPTION
    Starts the decision server (dashboard) and optionally spawns worker processes.
    Each worker claims an optimization target and runs the AI loop.

.PARAMETER Workers
    Number of workers to spawn (default: 2)

.PARAMETER Target
    Force a specific target ID (spawns 1 worker)

.PARAMETER Exclude
    Comma-separated target IDs to skip

.PARAMETER Port
    Dashboard port (default: 4040)

.PARAMETER ServerOnly
    Only start the decision server (dashboard), no workers

.PARAMETER WorkersOnly
    Only start workers, skip the decision server

.EXAMPLE
    .\tools\perf-agents\start.ps1
    .\tools\perf-agents\start.ps1 -Workers 3
    .\tools\perf-agents\start.ps1 -Target EVM-1
    .\tools\perf-agents\start.ps1 -ServerOnly
    .\tools\perf-agents\start.ps1 -WorkersOnly
#>

param(
    [int]$Workers = 2,
    [string]$Target = "",
    [string]$Exclude = "",
    [int]$Port = 4040,
    [switch]$ServerOnly,
    [switch]$WorkersOnly
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path "$ScriptDir\..\..").Path
$RunDir = "$ScriptDir\run"
$DbPath = "$RepoRoot\tools\perf-dashboard\db\perf.db"
$GitBash = "C:\Program Files\Git\bin\bash.exe"

# -- Find Python --
$Python = $null
foreach ($cmd in @("python", "python3", "py")) {
    try {
        $null = & $cmd --version 2>&1
        if ($LASTEXITCODE -eq 0) { $Python = $cmd; break }
    } catch {}
}
if (-not $Python) {
    Write-Error "No Python found. Install Python and add to PATH."
    exit 1
}
Write-Host "Using Python: $Python ($(& $Python --version 2>&1))" -ForegroundColor DarkGray

# -- Find Git Bash (needed for worker.sh) --
if (-not $ServerOnly) {
    if (-not (Test-Path $GitBash)) {
        # Try PATH
        $GitBash = (Get-Command bash -ErrorAction SilentlyContinue).Source
        if (-not $GitBash -or $GitBash -match "System32") {
            Write-Error "Git Bash not found. Install Git for Windows."
            exit 1
        }
    }
    Write-Host "Using Bash:   $GitBash" -ForegroundColor DarkGray
}

# -- Create dirs --
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
New-Item -ItemType Directory -Force -Path "$RunDir\logs" | Out-Null
New-Item -ItemType Directory -Force -Path "$RunDir\status" | Out-Null
New-Item -ItemType Directory -Force -Path "$RepoRoot\.worktrees" | Out-Null

Write-Host ""
Write-Host "  PERF-AI AGENT SYSTEM" -ForegroundColor Cyan
Write-Host ("=" * 52) -ForegroundColor DarkGray

# -- Ensure .worktrees is gitignored --
$Gitignore = "$RepoRoot\.gitignore"
if (Test-Path $Gitignore) {
    $content = Get-Content $Gitignore -Raw
    if ($content -notmatch '(?m)^\.worktrees/') {
        Add-Content $Gitignore ".worktrees/"
        Write-Host "[init] Added .worktrees/ to .gitignore"
    }
}

# -- Initialize DB if needed --
if (-not (Test-Path $DbPath)) {
    Write-Host "[init] Creating database..."
    & $Python "$RepoRoot\tools\perf-dashboard\scripts\init_db.py" --db $DbPath
}

# -- Start decision server --
if (-not $WorkersOnly) {
    Write-Host "[server] Starting on port $Port..."
    $serverArgs = @("$ScriptDir\decision-server.py", "--port", $Port, "--host", "127.0.0.1")
    $serverProc = Start-Process -FilePath $Python -ArgumentList $serverArgs `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput "$RunDir\logs\server-stdout.log" `
        -RedirectStandardError "$RunDir\logs\server-stderr.log"

    Start-Sleep -Seconds 2

    if ($serverProc.HasExited) {
        Write-Host "[server] FAILED to start. Check $RunDir\logs\server-stderr.log" -ForegroundColor Red
        Get-Content "$RunDir\logs\server-stderr.log" -ErrorAction SilentlyContinue | Select-Object -Last 5
        exit 1
    }

    $serverProc.Id | Out-File "$RunDir\server.pid" -Encoding ascii
    Write-Host "[server] http://localhost:$Port (PID $($serverProc.Id))" -ForegroundColor Green
}

if ($ServerOnly) {
    Write-Host ""
    Write-Host "Server running. Stop with: .\tools\perf-agents\stop.ps1 -ServerOnly" -ForegroundColor Yellow
    exit 0
}

# -- Spawn workers --
Write-Host ""

$workerPids = @()
$workerCount = if ($Target) { 1 } else { $Workers }

for ($i = 1; $i -le $workerCount; $i++) {
    $workerArgs = @()
    if ($Target) { $workerArgs += @("--target", $Target) }
    if ($Exclude) { $workerArgs += @("--exclude", $Exclude) }

    $bashArgs = @("$ScriptDir/worker.sh") + $workerArgs
    # Convert backslashes to forward slashes for bash
    $bashArgs = $bashArgs | ForEach-Object { $_ -replace '\\', '/' }
    $bashArgString = $bashArgs -join ' '

    $logFile = "$RunDir\logs\worker-$i-$(Get-Date -Format 'HHmmss').log"

    $workerProc = Start-Process -FilePath $GitBash -ArgumentList @("-c", $bashArgString) `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $logFile `
        -RedirectStandardError "$logFile.err" `
        -WorkingDirectory $RepoRoot

    $workerPids += $workerProc.Id
    $workerProc.Id | Out-File "$RunDir\workers.pid" -Append -Encoding ascii

    $targetLabel = if ($Target) { $Target } else { "auto-claim" }
    Write-Host "  Worker $i/$workerCount -- PID $($workerProc.Id) ($targetLabel)" -ForegroundColor Yellow
    Write-Host "    Log: $logFile" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host ("=" * 52) -ForegroundColor DarkGray
Write-Host "  Dashboard:  http://localhost:$Port" -ForegroundColor Cyan
Write-Host "  Status:     $Python $ScriptDir\orchestrate.py --status"
Write-Host "  Stop:       .\tools\perf-agents\stop.ps1" -ForegroundColor Yellow
Write-Host "  Logs:       $RunDir\logs\"
Write-Host ("=" * 52) -ForegroundColor DarkGray
