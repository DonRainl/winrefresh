# Logger.ps1 — JSON Lines logging with Event Log integration and rotation
# Functions: Write-Log, Get-WinRefreshLog, Export-WinRefreshLog, ConvertTo-Hashtable

# PS 5.1-compatible PSCustomObject → Hashtable conversion (replaces -AsHashtable from PS 6+)
# RECURSIVE: nested PSCustomObjects are converted to nested hashtables
function ConvertTo-Hashtable {
    param([Parameter(Mandatory)][object]$InputObject)
    $ht = @{}
    if ($null -eq $InputObject) { return $ht }
    foreach ($prop in $InputObject.PSObject.Properties) {
        if ($prop.Value -is [System.Management.Automation.PSCustomObject]) {
            $ht[$prop.Name] = ConvertTo-Hashtable -InputObject $prop.Value
        } else {
            $ht[$prop.Name] = $prop.Value
        }
    }
    return $ht
}

$script:LogDir = "$env:ProgramData\WinRefresh\logs"
$script:FallbackLog = "$env:TEMP\WinRefresh_Fallback.log"
$script:CurrentLogFile = $null
$script:MaxLogSize = 10MB
$script:MaxArchives = 5
$script:ArchiveRetentionDays = 30

function Initialize-Logger {
    param([int]$MaxSizeMB = 10, [int]$Archives = 5, [int]$RetentionDays = 30)
    $script:MaxLogSize = $MaxSizeMB * 1MB
    $script:MaxArchives = $Archives
    $script:ArchiveRetentionDays = $RetentionDays
    if (-not (Test-Path $script:LogDir)) {
        New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    }
    $script:CurrentLogFile = Join-Path $script:LogDir "winrefresh.log"
}

function Write-Log {
    param(
        [ValidateSet('DEBUG','INFO','WARN','ERROR','CRITICAL')]
        [string]$Level = 'INFO',
        [string]$Operation = '',
        [string]$Message = ''
    )
    if (-not $script:CurrentLogFile) { Initialize-Logger }

    $entry = [ordered]@{
        ts  = (Get-Date -Format 'o')
        lvl = $Level
        op  = $Operation
        msg = $Message
    }

    # Write to JSON Lines file — use File.AppendAllText to avoid BOM-per-line in PS 5.1
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    try {
        $json = $entry | ConvertTo-Json -Compress
        [System.IO.File]::AppendAllText($script:CurrentLogFile, $json + [Environment]::NewLine, $utf8NoBom)
    } catch {
        try { [System.IO.File]::AppendAllText($script:FallbackLog, $json + [Environment]::NewLine, $utf8NoBom) } catch {}
    }

    # Write WARN+ to Event Log (summary only, 32766 byte limit)
    if ($Level -in @('WARN','ERROR','CRITICAL')) {
        $eventLevel = switch ($Level) { 'WARN' { 2 } 'ERROR' { 1 } 'CRITICAL' { 1 } }
        $summary = "[$Level] $Operation : $Message"
        if ($summary.Length -gt 32766) { $summary = $summary.Substring(0, 32763) + '...' }
        try {
            Write-EventLog -LogName Application -Source "WinRefresh" -EventId 1000 `
                -EntryType $([System.Diagnostics.EventLogEntryType]$eventLevel) `
                -Message $summary -ErrorAction Stop
        } catch [System.InvalidOperationException] {
            # Source not registered — this is expected before install, skip silently
        } catch {
            try { [System.IO.File]::AppendAllText($script:FallbackLog, "[EventLogFail] $json" + [Environment]::NewLine, $utf8NoBom) } catch {}
        }
    }

    # Check rotation
    Rotate-LogIfNeeded
}

function Rotate-LogIfNeeded {
    if (-not (Test-Path $script:CurrentLogFile)) { return }
    $size = (Get-Item $script:CurrentLogFile).Length
    if ($size -lt $script:MaxLogSize) { return }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $archiveName = "winrefresh_$timestamp.jsonl"
    $archivePath = Join-Path $script:LogDir $archiveName
    try {
        Move-Item -Path $script:CurrentLogFile -Destination $archivePath -Force -ErrorAction Stop
        # Remove old archives
        $archives = Get-ChildItem -Path $script:LogDir -Filter "winrefresh_*.jsonl" |
            Sort-Object LastWriteTime -Descending
        if ($archives.Count -gt $script:MaxArchives) {
            $archives | Select-Object -Skip $script:MaxArchives | Remove-Item -Force
        }
        # Remove archives older than 30 days
        $cutoff = (Get-Date).AddDays(-$script:ArchiveRetentionDays)
        Get-ChildItem -Path $script:LogDir -Filter "winrefresh_*.jsonl" |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        # Rotation failed — continue with new log (old log will stay, we just append)
    }
}

function Get-WinRefreshLog {
    param(
        [DateTime]$After,
        [DateTime]$Before,
        [ValidateSet('DEBUG','INFO','WARN','ERROR','CRITICAL')]
        [string[]]$Level
    )
    $files = @()
    if (Test-Path $script:LogDir) {
        $files = Get-ChildItem -Path $script:LogDir -Filter "*.jsonl" | Sort-Object LastWriteTime
    }
    $results = @()
    foreach ($file in $files) {
        Get-Content $file.FullName -Encoding UTF8 | ForEach-Object {
            try {
                $obj = $_ | ConvertFrom-Json
                if ($After -and [DateTime]$obj.ts -lt $After) { return }
                if ($Before -and [DateTime]$obj.ts -gt $Before) { return }
                if ($Level -and $obj.lvl -notin $Level) { return }
                $results += $obj
            } catch {}
        }
    }
    $results
}

function Export-WinRefreshLog {
    param(
        [ValidateSet('Csv','Json')]
        [string]$Format = 'Csv',
        [string]$OutputPath
    )
    $logs = Get-WinRefreshLog
    if (-not $OutputPath) {
        $OutputPath = Join-Path $env:TEMP "WinRefresh_Export.$($Format.ToLower())"
    }
    switch ($Format) {
        'Csv' { $logs | Export-Csv -Path $OutputPath -NoTypeInformation }
        'Json' { $logs | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8 }
    }
    Write-Host "Exported $($logs.Count) entries to $OutputPath"
}
