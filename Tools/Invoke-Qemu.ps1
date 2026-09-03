param(
    [ValidateSet('Gui', 'SshDebug')]
    [string]$Mode = 'Gui',

    [string]$QemuPath,

    [string]$ConfigPath,

    [string]$WorkingDirectory,

    [string]$SerialLogPath,

    [ValidateSet('VirtioNet', 'RTL8139')]
    [string]$NetworkAdapter = 'VirtioNet',

    [switch]$Snapshot,

    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$hostProfileTool = Join-Path $PSScriptRoot 'Qemu-HostProfile.ps1'
if (-not (Test-Path -LiteralPath $hostProfileTool -PathType Leaf)) {
    throw ('QEMU-Hostprofilauswahl fehlt: ' + $hostProfileTool)
}
. $hostProfileTool

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

function Get-NetworkDevice([string]$SelectedAdapter) {
    switch ($SelectedAdapter) {
        'VirtioNet' { return 'virtio-net-pci,disable-legacy=on,netdev=r4net0,id=r4net' }
        'RTL8139' { return 'rtl8139,netdev=r4net0,id=r4net' }
        default { throw ('Unbekannter QEMU-Netzwerkadapter: ' + $SelectedAdapter) }
    }
}

function Get-QemuArguments([string]$SelectedMode, [string]$SelectedConfig, [string]$SelectedLog, [bool]$UseSnapshot, $HostProfile, [string]$SelectedAdapter) {
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @(
        '-readconfig', $SelectedConfig,
        '-machine', ('accel=' + $HostProfile.AcceleratorChain),
        '-m', '1024',
        '-smp', '4',
        '-cpu', $HostProfile.CpuModel,
        '-boot', 'c',
        '-netdev', 'user,id=r4net0,hostfwd=tcp:127.0.0.1:10022-10.0.2.15:22',
        '-device', (Get-NetworkDevice $SelectedAdapter)
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
    Test-R4QemuHostProfileSelection
    $network = 'user,id=r4net0,hostfwd=tcp:127.0.0.1:10022-10.0.2.15:22'
    $virtio = 'virtio-net-pci,disable-legacy=on,netdev=r4net0,id=r4net'
    $rtl8139 = 'rtl8139,netdev=r4net0,id=r4net'
    $kvm = Select-R4QemuHostProfile Linux X64 @('tcg', 'kvm') $true $false
    $tcg = Select-R4QemuHostProfile Other X64 @('tcg') $false $false
    $gui = @(Get-QemuArguments 'Gui' 'standard.conf' '' $false $kvm 'VirtioNet')
    Assert-ArgumentPair $gui '-netdev' $network
    Assert-ArgumentPair $gui '-device' $virtio
    Assert-ArgumentPair $gui '-machine' 'accel=kvm:tcg'
    Assert-ArgumentPair $gui '-cpu' 'host'
    if ($gui -contains '-display' -or $gui -contains '-snapshot') { throw 'GUI-Argumente enthalten Headless-/Snapshotoptionen.' }

    $debug = @(Get-QemuArguments 'SshDebug' 'standard.conf' 'qemu-ssh-debug.log' $true $tcg 'RTL8139')
    Assert-ArgumentPair $debug '-netdev' $network
    Assert-ArgumentPair $debug '-device' $rtl8139
    Assert-ArgumentPair $debug '-machine' 'accel=tcg'
    Assert-ArgumentPair $debug '-cpu' 'Haswell'
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
    if (-not [string]::IsNullOrWhiteSpace($QemuPath)) {
        $QemuPath = [IO.Path]::GetFullPath($QemuPath)
        Assert-File $QemuPath 'QEMU'
        $detectedProfile = Resolve-R4QemuHostProfile $QemuPath
        Write-Host ('QEMU detected host profile: ' + $detectedProfile.Name +
            '; accel=' + $detectedProfile.AcceleratorChain + '; cpu=' + $detectedProfile.CpuModel)
    }
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
$hostProfile = Resolve-R4QemuHostProfile $QemuPath
Write-Host ('QEMU host profile: ' + $hostProfile.Name +
    '; accel=' + $hostProfile.AcceleratorChain + '; cpu=' + $hostProfile.CpuModel +
    '; nic=' + $NetworkAdapter)

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

$qemuArguments = @(Get-QemuArguments $Mode $ConfigPath $SerialLogPath $Snapshot.IsPresent $hostProfile $NetworkAdapter)
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
