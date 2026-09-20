#requires -Version 5.1
param(
    [switch]$PlanOnly,
    [switch]$NoLaunch,
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Tetradim\SentinelSuite')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'suite-manifest.json') -Raw | ConvertFrom-Json

if ($PlanOnly) {
    [pscustomobject]@{
        installRoot = $InstallRoot
        runtimes = @('Node.js', 'Python', 'MongoDB', 'Visual C++ Runtime')
        repositories = @($manifest.repositories.PSObject.Properties.Name)
        desktopBots = @($manifest.desktopBots)
    } | ConvertTo-Json -Depth 4
    return
}

if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'Sentinel Suite requires 64-bit Windows 10 or 11.'
}

$reposRoot = Join-Path $InstallRoot 'repos'
$runtimeRoot = Join-Path $InstallRoot 'runtime'
$cacheRoot = Join-Path $InstallRoot 'downloads'
$logsRoot = Join-Path $InstallRoot 'logs'
$dataRoot = Join-Path $InstallRoot 'data'
@($InstallRoot, $reposRoot, $runtimeRoot, $cacheRoot, $logsRoot, $dataRoot) |
    ForEach-Object { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
$logFile = Join-Path $logsRoot 'install.log'

function Write-Step([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    Write-Host $Message
}

function Invoke-Download([string]$Url, [string]$Path) {
    if (-not $Url.StartsWith('https://')) { throw "Refusing a non-HTTPS download: $Url" }
    if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt 0) { return }
    $part = "$Path.part"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            Write-Step "Downloading $([IO.Path]::GetFileName($Path)) (attempt $attempt of 3)..."
            Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing -TimeoutSec 600
            if ((Get-Item -LiteralPath $part).Length -eq 0) { throw 'Download was empty.' }
            Move-Item -LiteralPath $part -Destination $Path -Force
            return
        } catch {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            if ($attempt -eq 3) { throw "Download failed for $Url. $($_.Exception.Message)" }
            Start-Sleep -Seconds 3
        }
    }
}

function Assert-Signed([string]$Path) {
    if ((Get-AuthenticodeSignature -LiteralPath $Path).Status -ne 'Valid') {
        throw "Windows signature verification failed: $Path"
    }
}

function Invoke-External([string]$File, [string[]]$Arguments, [string]$Label) {
    Write-Step $Label
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Label failed with exit code $LASTEXITCODE. See $logFile" }
}

function Copy-InstallerFile([string]$SourceName, [string]$DestinationName) {
    $source = Join-Path $PSScriptRoot $SourceName
    $destination = Join-Path $InstallRoot $DestinationName
    if ([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($destination)) {
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}

function Expand-VerifiedRuntime([string]$Archive, [string]$Destination, [string]$Executable) {
    if (Test-Path -LiteralPath (Join-Path $Destination $Executable)) { return }
    $temp = "$Destination.extracting"
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    try {
        Expand-Archive -LiteralPath $Archive -DestinationPath $temp -Force
        $source = Get-ChildItem -LiteralPath $temp -Directory | Select-Object -First 1
        if (-not $source) { throw "$Archive did not contain a runtime folder" }
        $candidate = Get-ChildItem -LiteralPath $source.FullName -Recurse -File -Filter $Executable | Select-Object -First 1
        if (-not $candidate) { throw "$Archive does not contain $Executable" }
        Assert-Signed $candidate.FullName
        if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
        Move-Item -LiteralPath $source.FullName -Destination $Destination
    } catch {
        Remove-Item -LiteralPath $Archive -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
    }
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Step 'Starting Sentinel Suite setup. You can rerun this installer to repair an interrupted setup.'

    $vcInstalled = $false
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
                       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64')) {
        $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($item -and $item.Installed -eq 1) { $vcInstalled = $true; break }
    }
    if (-not $vcInstalled) {
        $vcFile = Join-Path $cacheRoot 'vc_redist.x64.exe'
        Invoke-Download 'https://aka.ms/vs/17/release/vc_redist.x64.exe' $vcFile
        Assert-Signed $vcFile
        Write-Step 'Installing Microsoft Visual C++ Runtime. Windows may request administrator approval once.'
        $vcProcess = Start-Process -FilePath $vcFile -ArgumentList '/install /quiet /norestart' -Verb RunAs -Wait -PassThru
        if (@(0, 3010, 1638) -notcontains $vcProcess.ExitCode) { throw "Visual C++ Runtime installer exited $($vcProcess.ExitCode)" }
    }

    $nodeVersion = [string]$manifest.runtimes.'Node.js'
    $nodeDir = Join-Path $runtimeRoot 'node'
    $nodeExe = Join-Path $nodeDir 'node.exe'
    if (-not (Test-Path -LiteralPath $nodeExe)) {
        $nodeZip = Join-Path $cacheRoot "node-$nodeVersion-win-x64.zip"
        Invoke-Download "https://nodejs.org/dist/v$nodeVersion/node-v$nodeVersion-win-x64.zip" $nodeZip
        Expand-VerifiedRuntime $nodeZip $nodeDir 'node.exe'
    }
    $env:Path = "$nodeDir;$env:Path"
    Invoke-External $nodeExe @('--version') 'Checking private Node.js runtime'
    $npm = Join-Path $nodeDir 'npm.cmd'
    if (-not (Test-Path -LiteralPath $npm)) { throw "npm.cmd is missing from $nodeDir" }

    $pythonVersion = [string]$manifest.runtimes.Python
    $pythonDir = Join-Path $runtimeRoot 'python'
    $pythonExe = Join-Path $pythonDir 'python.exe'
    if (-not (Test-Path -LiteralPath $pythonExe)) {
        $pythonInstaller = Join-Path $cacheRoot "python-$pythonVersion-amd64.exe"
        Invoke-Download "https://www.python.org/ftp/python/$pythonVersion/python-$pythonVersion-amd64.exe" $pythonInstaller
        Assert-Signed $pythonInstaller
        Write-Step "Installing private Python $pythonVersion runtime..."
        $arguments = '/quiet InstallAllUsers=0 Include_launcher=0 PrependPath=0 Include_test=0 Shortcuts=0 TargetDir="{0}"' -f $pythonDir
        $pythonProcess = Start-Process -FilePath $pythonInstaller -ArgumentList $arguments -Wait -PassThru
        if (@(0, 3010) -notcontains $pythonProcess.ExitCode) { throw "Python installer exited $($pythonProcess.ExitCode)" }
    }
    if (-not (Test-Path -LiteralPath $pythonExe)) { throw "Python is missing from $pythonDir" }
    $env:Path = "$pythonDir;$nodeDir;$env:Path"
    Invoke-External $pythonExe @('--version') 'Checking private Python runtime'

    $mongoVersion = [string]$manifest.runtimes.MongoDB
    $mongoDir = Join-Path $runtimeRoot 'mongodb'
    $mongoExe = Join-Path $mongoDir 'bin\mongod.exe'
    if (-not (Test-Path -LiteralPath $mongoExe)) {
        $mongoZip = Join-Path $cacheRoot "mongodb-$mongoVersion.zip"
        Invoke-Download "https://fastdl.mongodb.org/windows/mongodb-windows-x86_64-$mongoVersion.zip" $mongoZip
        Expand-VerifiedRuntime $mongoZip $mongoDir 'mongod.exe'
    }
    if (-not (Test-Path -LiteralPath $mongoExe)) { throw "MongoDB is missing from $mongoDir" }

    foreach ($repo in $manifest.repositories.PSObject.Properties) {
        $name = $repo.Name
        $commit = [string]$repo.Value
        $destination = Join-Path $reposRoot $name
        if (Test-Path -LiteralPath $destination) {
            $marker = Join-Path $destination 'INSTALLER-COMMIT.txt'
            if (-not (Test-Path -LiteralPath $marker)) { throw "$name has an incomplete or unmanaged installation at $destination. Back it up and remove that folder before retrying." }
            $installedCommit = (Get-Content -LiteralPath $marker -Raw).Trim()
            if ($installedCommit -ne $commit) { throw "$name is installed from a different commit. Back up the existing installation before upgrading it." }
            Write-Step "Keeping existing $name installation."
            continue
        }
        $zip = Join-Path $cacheRoot "$name-$commit.zip"
        Invoke-Download "https://github.com/Tetradim/$name/archive/$commit.zip" $zip
        $unpack = Join-Path $cacheRoot "$name.extracting"
        if (Test-Path -LiteralPath $unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force }
        try {
            Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force
            $source = Get-ChildItem -LiteralPath $unpack -Directory | Select-Object -First 1
            if (-not $source) { throw "No project folder found in $zip" }
            if ($source.Name -ne "$name-$commit") { throw "Unexpected project folder in $zip" }
            Set-Content -LiteralPath (Join-Path $source.FullName 'INSTALLER-COMMIT.txt') -Value $commit -Encoding ASCII
            Move-Item -LiteralPath $source.FullName -Destination $destination
            Write-Step "$name source is ready."
        } catch {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            throw
        } finally {
            if (Test-Path -LiteralPath $unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force }
        }
    }

    function Install-PythonProject([string]$Name, [string]$ProjectPath, [string]$Requirements, [string]$Editable) {
        $root = Join-Path $reposRoot $Name
        $project = if ($ProjectPath) { Join-Path $root $ProjectPath } else { $root }
        $venv = Join-Path $project '.venv'
        $venvPython = Join-Path $venv 'Scripts\python.exe'
        $marker = Join-Path $venv 'sentinel-installer-ready.txt'
        if (Test-Path -LiteralPath $marker) { Write-Step "$Name Python packages already ready."; return }
        if (-not (Test-Path -LiteralPath $venvPython)) {
            Invoke-External $pythonExe @('-m', 'venv', $venv) "Creating $Name Python environment"
        }
        Invoke-External $venvPython @('-m', 'pip', 'install', '--disable-pip-version-check', '--upgrade', 'pip') "Updating $Name pip"
        if ($Requirements) {
            $reqPath = Join-Path $root $Requirements
            if (-not (Test-Path -LiteralPath $reqPath)) { throw "Missing $Name requirements: $reqPath" }
            Invoke-External $venvPython @('-m', 'pip', 'install', '--disable-pip-version-check', '-r', $reqPath) "Installing $Name Python packages"
        }
        if ($Editable) {
            Push-Location $root
            try { Invoke-External $venvPython @('-m', 'pip', 'install', '--disable-pip-version-check', '-e', $Editable) "Installing $Name Python package" }
            finally { Pop-Location }
        }
        Set-Content -LiteralPath $marker -Value 'ready' -Encoding ASCII
    }

    Install-PythonProject 'Sentinel-Pulse' 'backend' 'backend\requirements.txt' ''
    Install-PythonProject 'Sentinel-Edge' 'backend' 'backend\requirements.txt' ''
    Install-PythonProject 'Sentinel-Echo' 'backend' 'backend\requirements.txt' ''
    Install-PythonProject 'Sentinel-Flare' '' 'requirements.txt' ''
    Install-PythonProject 'Sentinel-Archive' '' 'requirements.txt' ''
    Install-PythonProject 'Sentinel-Chain' '' '' '.[exchange]'
    Install-PythonProject 'Sentinel-Iron' '' '' '.[ibkr]'

    function Install-NodeProject([string]$Name, [string]$RelativePath) {
        $root = Join-Path $reposRoot $Name
        $project = if ($RelativePath) { Join-Path $root $RelativePath } else { $root }
        if (-not (Test-Path -LiteralPath (Join-Path $project 'package.json'))) { throw "Missing package.json in $project" }
        $marker = Join-Path $project 'node_modules\.sentinel-installer-ready'
        if (Test-Path -LiteralPath $marker) { Write-Step "$Name Node packages already ready."; return }
        Push-Location $project
        try {
            if (Test-Path -LiteralPath (Join-Path $project 'package-lock.json')) {
                Write-Step "Installing $Name Node packages with npm ci..."
                & $npm ci --no-audit --no-fund
                if ($LASTEXITCODE -ne 0) {
                    Write-Step "npm ci failed for $Name; trying npm install."
                    Invoke-External $npm @('install', '--no-audit', '--no-fund') "Repairing $Name Node packages"
                }
            } else {
                Invoke-External $npm @('install', '--no-audit', '--no-fund') "Installing $Name Node packages"
            }
        } finally { Pop-Location }
        New-Item -ItemType File -Path $marker -Force | Out-Null
    }

    foreach ($name in @('Sentinel-Pulse', 'Sentinel-Edge', 'Sentinel-Echo')) { Install-NodeProject $name 'frontend' }
    foreach ($name in @('Sentinel-Flare', 'Sentinel-Core', 'Sentinel-Archive', 'Sentinel-Link', 'Sentinel-Nexus')) { Install-NodeProject $name '' }
    foreach ($name in @('Sentinel-Core', 'Sentinel-Archive')) {
        $project = Join-Path $reposRoot $name
        Push-Location $project
        try { Invoke-External $npm @('run', 'build') "Building $name dashboard" }
        finally { Pop-Location }
    }

    foreach ($entry in @(
        @('Sentinel-Pulse', 'backend\.env.example', 'backend\.env'),
        @('Sentinel-Chain', '.env.example', '.env')
    )) {
        $root = Join-Path $reposRoot $entry[0]
        $source = Join-Path $root $entry[1]
        $target = Join-Path $root $entry[2]
        if ((Test-Path -LiteralPath $source) -and -not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $source -Destination $target }
    }

    Copy-InstallerFile 'Start-Sentinel-Suite.ps1' 'Start-Sentinel-Suite.ps1'
    Copy-InstallerFile 'Install-Sentinel-Suite.cmd' 'Install-Sentinel-Suite.cmd'
    Copy-InstallerFile 'Install-Sentinel-Suite.ps1' 'Install-Sentinel-Suite.ps1'
    Copy-InstallerFile 'Install-Sentinel-Suite.ps1' 'Repair-Sentinel-Suite.ps1'
    Copy-InstallerFile 'suite-manifest.json' 'suite-manifest.json'

    $desktop = [Environment]::GetFolderPath('Desktop')
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $desktop 'Sentinel Suite.lnk'))
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $InstallRoot 'Start-Sentinel-Suite.ps1')
    $shortcut.WorkingDirectory = $InstallRoot
    $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,137"
    $shortcut.Save()
    Get-ChildItem -LiteralPath $cacheRoot -File | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Step "Installation complete. Open the Sentinel Suite shortcut on your desktop. Log: $logFile"
    if (-not $NoLaunch) {
        & (Join-Path $InstallRoot 'Start-Sentinel-Suite.ps1')
    }
} catch {
    Write-Step "INSTALLATION FAILED: $($_.Exception.Message)"
    throw
}
