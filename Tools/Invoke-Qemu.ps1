param(
    [ValidateSet('Gui', 'SshDebug')]
    [string]$Mode = 'Gui',

    [string]$QemuPath,

    [string]$ConfigPath,

    [string]$WorkingDirectory,

    [string]$SerialLogPath,

    [switch]$Snapshot,

    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

function Assert-File([string]$Path, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ($Label + ' fehlt: ' + $Path)
    }
}

function Assert-Directory([string]$Path, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw ($Label + ' fehlt: ' + $Path)
    }
}

function Get-QemuArguments([string]$SelectedMode, [string]$SelectedConfig, [string]$SelectedLog, [bool]$UseSnapshot) {
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @(
        '-readconfig', $SelectedConfig,
        '-m', '1024',
        '-smp', '4',
        '-cpu', 'max',
        '-boot', 'c',
        '-netdev', 'user,id=r4net0,hostfwd=tcp:127.0.0.1:10022-10.0.2.15:22',
        '-device', 'rtl8139,netdev=r4net0,id=r4net'
    )) {
        $arguments.Add($argument)
    }
    if ($SelectedMode -eq 'SshDebug') {
        foreach ($argument in @(
            '-audiodev', 'driver=none,id=debug-audio',
            '-global', 'hda-duplex.audiodev=debug-audio',
            '-serial', ('file:' + $SelectedLog),
            '-display', 'none',
            '-monitor', 'none',
            '-no-reboot',
            '-name', 'R4OS SSH debug'
        )) {
            $arguments.Add($argument)
        }
    }
    if ($UseSnapshot) { $arguments.Add('-snapshot') }
    return $arguments.ToArray()
}

function Assert-ArgumentPair([string[]]$Arguments, [string]$Name, [string]$Value) {
    for ($index = 0; $index -lt $Arguments.Count - 1; $index++) {
        if ($Arguments[$index] -ceq $Name -and $Arguments[$index + 1] -ceq $Value) { return }
    }
    throw ('QEMU-Argument fehlt: ' + $Name + ' ' + $Value)
}

function Test-Arguments {
    $network = 'user,id=r4net0,hostfwd=tcp:127.0.0.1:10022-10.0.2.15:22'
    $device = 'rtl8139,netdev=r4net0,id=r4net'
    $gui = @(Get-QemuArguments 'Gui' 'standard.conf' '' $false)
    Assert-ArgumentPair $gui '-netdev' $network
    Assert-ArgumentPair $gui '-device' $device
    if ($gui -contains '-display' -or $gui -contains '-snapshot') { throw 'GUI-Argumente enthalten Headless-/Snapshotoptionen.' }

    $debug = @(Get-QemuArguments 'SshDebug' 'standard.conf' 'qemu-ssh-debug.log' $true)
    Assert-ArgumentPair $debug '-netdev' $network
    Assert-ArgumentPair $debug '-device' $device
    Assert-ArgumentPair $debug '-serial' 'file:qemu-ssh-debug.log'
    Assert-ArgumentPair $debug '-display' 'none'
    if ($debug -notcontains '-snapshot') { throw 'Snapshotoption fehlt im Selbsttest.' }
    Write-Host 'QEMU GUI/SSH argument self-test OK.'
}

function Assert-DebugPortAvailable {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 10022)
    try {
        $listener.Start()
    }
    catch {
        throw 'Der lokale SSH-Debugport 127.0.0.1:10022 ist bereits belegt.'
    }
    finally {
        $listener.Stop()
    }
}

if ($SelfTest) {
    Test-Arguments
    exit 0
}

$QemuPath = [IO.Path]::GetFullPath($QemuPath)
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
if (-not [string]::IsNullOrWhiteSpace($SerialLogPath)) {
    $SerialLogPath = [IO.Path]::GetFullPath($SerialLogPath)
}
Assert-File $QemuPath 'QEMU'
Assert-File $ConfigPath 'QEMU-Konfiguration'
Assert-Directory $WorkingDirectory 'QEMU-Arbeitsverzeichnis'
Assert-File (Join-Path $WorkingDirectory 'disk.img') 'Systemimage'
Assert-File (Join-Path $WorkingDirectory 'data.img') 'Datenimage'
Assert-DebugPortAvailable

if ($Mode -eq 'SshDebug') {
    if ([string]::IsNullOrWhiteSpace($SerialLogPath)) { throw 'Der SSH-Debuglauf benoetigt einen seriellen Logpfad.' }
    $logParent = Split-Path -Parent $SerialLogPath
    if (-not (Test-Path -LiteralPath $logParent -PathType Container)) {
        New-Item -ItemType Directory -Path $logParent | Out-Null
    }
    if (Test-Path -LiteralPath $SerialLogPath -PathType Leaf) {
        Remove-Item -LiteralPath $SerialLogPath -Force
    }
    Write-Host 'QEMU SSH-Debugging:'
    Write-Host '  Host:  127.0.0.1:10022'
    Write-Host '  Gast:  10.0.2.15:22 (DHCP)'
    Write-Host ('  Log:   ' + $SerialLogPath)
    Write-Host '  Login: ssh -p 10022 -c chacha20-poly1305@openssh.com r4os@127.0.0.1'
}

$qemuArguments = @(Get-QemuArguments $Mode $ConfigPath $SerialLogPath $Snapshot.IsPresent)
$exitCode = 1
Push-Location -LiteralPath $WorkingDirectory
try {
    & $QemuPath @qemuArguments
    $exitCode = $LASTEXITCODE
}
finally {
    Pop-Location
}
if ($null -eq $exitCode) { exit 1 }
exit $exitCode
