#requires -Version 5.1
param(
    [string]$Component = '',
    [string]$InstallRoot = $PSScriptRoot,
    [switch]$PlanOnly
)

$ErrorActionPreference = 'Stop'
$allowed = @('Sentinel-Core', 'Sentinel-Pulse', 'Sentinel-Edge', 'Sentinel-Echo',
             'Sentinel-Flare', 'Sentinel-Chain', 'Sentinel-Archive', 'All', 'Stop')
if ($Component -and $allowed -notcontains $Component) {
    throw "Unknown component: $Component"
}

function Select-Component {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Sentinel Suite'
    $form.Width = 420
    $form.Height = 480
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'Choose the bot you want to open'
    $label.Location = New-Object System.Drawing.Point(20, 15)
    $label.Size = New-Object System.Drawing.Size(365, 30)
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 12)
    $form.Controls.Add($label)
    $choices = @(
        @('Sentinel-Core', 'Suite dashboard (Pulse + Edge)'),
        @('Sentinel-Pulse', 'Broker execution bot'),
        @('Sentinel-Edge', 'Market analysis bot'),
        @('Sentinel-Echo', 'Discord options bot'),
        @('Sentinel-Flare', 'Darkpool monitor'),
        @('Sentinel-Chain', 'Crypto paper bot'),
        @('Sentinel-Archive', 'Replay and simulation'),
        @('All', 'Start all desktop bots'),
        @('Stop', 'Stop running Sentinel bots')
    )
    $script:selection = ''
    for ($i = 0; $i -lt $choices.Count; $i++) {
        $entry = $choices[$i]
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $entry[1]
        $button.Tag = $entry[0]
        $button.Size = New-Object System.Drawing.Size(365, 38)
        $button.Location = New-Object System.Drawing.Point(20, (50 + $i * 41))
        $button.Font = New-Object System.Drawing.Font('Segoe UI', 10)
        $button.Add_Click({ $script:selection = [string]$this.Tag; $form.Close() })
        $form.Controls.Add($button)
    }
    [void]$form.ShowDialog()
    return $script:selection
}

if (-not $Component) { $Component = Select-Component }
if (-not $Component) { return }

$order = @(switch ($Component) {
    'Sentinel-Core' { @('Sentinel-Pulse', 'Sentinel-Edge', 'Sentinel-Core') }
    'Sentinel-Edge' { @('Sentinel-Edge') }
    'All' { @('Sentinel-Pulse', 'Sentinel-Edge', 'Sentinel-Flare', 'Sentinel-Echo', 'Sentinel-Chain', 'Sentinel-Archive', 'Sentinel-Core') }
    'Stop' { @() }
    default { @($Component) }
})
$needsMongo = @($order | Where-Object { $_ -in @('Sentinel-Pulse', 'Sentinel-Edge', 'Sentinel-Echo') }).Count -gt 0
if ($PlanOnly) {
    [pscustomobject]@{ startupOrder = @($order); startsMongoDB = $needsMongo } | ConvertTo-Json -Depth 3
    return
}

$reposRoot = Join-Path $InstallRoot 'repos'
$nodeDir = Join-Path $InstallRoot 'runtime\node'
$pythonDir = Join-Path $InstallRoot 'runtime\python'
$mongoExe = Join-Path $InstallRoot 'runtime\mongodb\bin\mongod.exe'
$logsRoot = Join-Path $InstallRoot 'logs'
$dataRoot = Join-Path $InstallRoot 'data'
$runRoot = Join-Path $InstallRoot 'run'
if (-not (Test-Path -LiteralPath $nodeDir) -or -not (Test-Path -LiteralPath $pythonDir)) {
    throw 'Sentinel Suite setup is incomplete. Run Repair-Sentinel-Suite.ps1 from the installation folder.'
}
$env:Path = "$nodeDir;$pythonDir;$env:Path"
$env:MONGO_URL = 'mongodb://127.0.0.1:27017'
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

function Test-Port([int]$Port) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $wait = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $wait.AsyncWaitHandle.WaitOne(700, $false)) { return $false }
        $client.EndConnect($wait)
        return $true
    } catch { return $false }
    finally { $client.Close() }
}

function Wait-Url([string]$Url, [int]$Seconds = 90) {
    for ($i = 0; $i -lt $Seconds; $i++) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) { return }
        } catch {}
        Start-Sleep -Seconds 1
    }
    throw "A Sentinel component did not become ready at $Url. Check $logsRoot and the bot's launcher log on the desktop."
}

function Start-Mongo {
    Write-Host 'Checking MongoDB...'
    if (Test-Port 27017) {
        $owner = Get-NetTCPConnection -LocalPort 27017 -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalAddress -in @('127.0.0.1', '0.0.0.0') } | Select-Object -First 1
        if ($owner) {
            $process = Get-CimInstance Win32_Process -Filter "ProcessId = $($owner.OwningProcess)" -ErrorAction SilentlyContinue
            $mongoData = Join-Path $dataRoot 'mongodb'
            if (-not $process -or -not $process.ExecutablePath -or $process.ExecutablePath -ne $mongoExe -or
                -not $process.CommandLine -or
                $process.CommandLine.IndexOf($mongoData, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                throw 'Port 27017 belongs to another program or could not be verified. Close it before starting Sentinel Suite.'
            }
        } else {
            throw 'Port 27017 is open but its owner could not be verified. Close it before starting Sentinel Suite.'
        }
        return
    }
    if (-not (Test-Path -LiteralPath $mongoExe)) { throw 'MongoDB is missing. Rerun the Sentinel Suite installer.' }
    $mongoData = Join-Path $dataRoot 'mongodb'
    $mongoLog = Join-Path $logsRoot 'mongodb.log'
    New-Item -ItemType Directory -Path $mongoData -Force | Out-Null
    $arguments = '--dbpath "{0}" --bind_ip 127.0.0.1 --port 27017 --logpath "{1}" --logappend' -f $mongoData, $mongoLog
    $mongoProcess = Start-Process -FilePath $mongoExe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    Set-Content -LiteralPath (Join-Path $runRoot 'MongoDB.pid') -Value $mongoProcess.Id -Encoding ASCII
    for ($i = 0; $i -lt 45; $i++) {
        if (Test-Port 27017) { Write-Host 'MongoDB is ready.'; return }
        Start-Sleep -Seconds 1
    }
    throw "MongoDB did not start. Check $mongoLog"
}

$launchers = @{
    'Sentinel-Pulse' = @('Launch-Sentinel-Pulse-Local.ps1', '-BackendPort 8001 -FrontendPort 3001 -SkipMongo -NoBrowser')
    'Sentinel-Edge' = @('Launch-Sentinel-Edge-Local.ps1', '-BackendPort 8000 -FrontendPort 3000 -PulseApiUrl http://127.0.0.1:8001 -NoBrowser')
    'Sentinel-Echo' = @('Launch-Consolidation-Bot.ps1', '-BackendPort 8003 -FrontendPort 3003 -NoBrowser')
    'Sentinel-Flare' = @('Launch-Darkpool-Monitor.ps1', '-BackendPort 8002 -FrontendPort 3002 -NoBrowser')
    'Sentinel-Chain' = @('Launch-Sentinel-Chain.ps1', '-Port 8004 -FrontendPort 3004 -NoBrowser')
    'Sentinel-Archive' = @('Launch-Sentinel-Archive.ps1', '-Port 9200 -NoBrowser')
    'Sentinel-Core' = @('Launch-Sentinel-Core.ps1', '-BackendPort 8005 -FrontendPort 3005 -EdgeApiUrl http://127.0.0.1:8000 -PulseApiUrl http://127.0.0.1:8001 -NoBrowser')
}
$readyUrls = @{
    'Sentinel-Pulse' = 'http://127.0.0.1:8001/api/health'
    'Sentinel-Edge' = 'http://127.0.0.1:8000/api/ready'
    'Sentinel-Echo' = 'http://127.0.0.1:8003/api/health'
    'Sentinel-Flare' = 'http://127.0.0.1:8002/health'
    'Sentinel-Chain' = 'http://127.0.0.1:8004/health'
    'Sentinel-Archive' = 'http://127.0.0.1:9200/api/health'
    'Sentinel-Core' = 'http://127.0.0.1:3005/'
}
$browserUrls = @{
    'Sentinel-Pulse' = 'http://127.0.0.1:3001/'
    'Sentinel-Edge' = 'http://127.0.0.1:3000/'
    'Sentinel-Echo' = 'http://127.0.0.1:3003/'
    'Sentinel-Flare' = 'http://127.0.0.1:3002/'
    'Sentinel-Chain' = 'http://127.0.0.1:8004/ui'
    'Sentinel-Archive' = 'http://127.0.0.1:9200/'
    'Sentinel-Core' = 'http://127.0.0.1:3005/'
}

function Stop-ManagedProcesses {
    foreach ($name in @('Sentinel-Core', 'Sentinel-Archive', 'Sentinel-Chain', 'Sentinel-Flare',
                        'Sentinel-Echo', 'Sentinel-Edge', 'Sentinel-Pulse', 'MongoDB')) {
        $pidFile = Join-Path $runRoot "$name.pid"
        if (-not (Test-Path -LiteralPath $pidFile)) { continue }
        $processId = 0
        if (-not [int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$processId)) {
            Remove-Item -LiteralPath $pidFile -Force
            continue
        }
        $process = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
        if ($process) {
            $owned = $false
            if ($name -eq 'MongoDB') {
                $owned = $process.ExecutablePath -eq $mongoExe
            } else {
                $expectedScript = Join-Path (Join-Path $reposRoot $name) $launchers[$name][0]
                $owned = $process.Name -eq 'powershell.exe' -and $process.CommandLine -and
                    $process.CommandLine.IndexOf($expectedScript, [StringComparison]::OrdinalIgnoreCase) -ge 0
            }
            if ($owned) { & taskkill.exe /PID $processId /T /F | Out-Null }
        }
        Remove-Item -LiteralPath $pidFile -Force
    }
}

function Start-Bot([string]$Name) {
    Write-Host "Starting $Name..."
    $entry = $launchers[$Name]
    $root = Join-Path $reposRoot $Name
    $script = Join-Path $root $entry[0]
    if (-not (Test-Path -LiteralPath $script)) { throw "Missing $Name launcher. Rerun the installer: $script" }
    $url = $readyUrls[$Name]
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) { Write-Host "$Name is already running."; return }
    } catch {}
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $script, $entry[1]
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $root -WindowStyle Minimized -PassThru
    Set-Content -LiteralPath (Join-Path $runRoot "$Name.pid") -Value $process.Id -Encoding ASCII
    Wait-Url $url 120
    Write-Host "$Name is ready."
}

try {
    if ($Component -eq 'Stop') { Stop-ManagedProcesses; Write-Host 'Stop request completed.'; return }
    if ($needsMongo) { Start-Mongo }
    foreach ($name in $order) { Start-Bot $name }
    $browserComponent = if ($Component -eq 'All') { 'Sentinel-Core' } else { $Component }
    Start-Process $browserUrls[$browserComponent] | Out-Null
} catch {
    Write-Error $_.Exception.Message
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Sentinel Suite could not start')
    } catch {}
    exit 1
}
