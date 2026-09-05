param([string]$Image='', [ValidateSet('Both','Bios','Uefi')][string]$Firmware='Both', [string[]]$Cases=@(),
      [string]$Qemu='', [string]$OvmfCode='', [string]$OvmfVars='', [ValidateRange(30,180)][int]$TimeoutSeconds=120)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Tools/InstallationImage.ps1')
. (Join-Path $root 'Tools/InstallationImage.Check.ps1')
. (Join-Path $root 'Tools/Qemu-HostProfile.ps1')
$settings=Get-InstallationFields (Join-Path $root 'Settings.R4S')
$workspace=Get-InstallationPath $root $settings.WORKSPACE_ROOT
$repositories=Get-InstallationPath $root $settings.REPOSITORIES_ROOT
$recoveryRoot=Join-Path $repositories 'Recovery'
. (Join-Path $recoveryRoot 'Tools/Guest-Qmp.ps1')
. (Join-Path $recoveryRoot 'Tools/Guest-NetClients.ps1')
$devkit=Get-InstallationPath $workspace $settings.DEVKIT_ROOT
$artifacts=Get-InstallationPath $workspace $settings.ARTIFACTS_ROOT
$output=Join-Path (Get-InstallationPath $artifacts $settings.DISTRIBUTION_OUTPUT_ROOT) 'RecoveryImages/Acceptance'
$suffix=if($IsWindows){'.exe'}else{''}
if(!$Image){$Image=Join-Path (Split-Path $output -Parent) 'Slim-local/disk.img'}
if(!$Qemu){$Qemu=Join-Path $devkit "Emulation/QEMU/qemu-system-x86_64$suffix"}
if(!$OvmfCode){$OvmfCode=if($IsLinux){'/usr/share/OVMF/OVMF_CODE_4M.fd'}else{Join-Path $devkit 'Emulation/QEMU/share/edk2-x86_64-code.fd'}}
if(!$OvmfVars){$OvmfVars=if($IsLinux){'/usr/share/OVMF/OVMF_VARS_4M.fd'}else{Join-Path $devkit 'Emulation/QEMU/share/edk2-i386-vars.fd'}}
$utf8=[Text.UTF8Encoding]::new($false)
function Free-Port {$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop();return $port}
function Keys([string]$Text){foreach($c in $Text.ToLowerInvariant().ToCharArray()){$key=switch($c){'\'{'backslash'};':'{'shift+semicolon'};'/'{'slash'};'.'{'dot'};' '{'spc'};default{"$c"}};Send-Keys $session @($key)}}
function Wait-Guest([string]$Pattern,[switch]$ExpectCrash){
    while($true){
        [string]$text=if(Test-Path $serialLog){Get-Content -Raw -LiteralPath $serialLog}else{''}
        if(!$ExpectCrash -and $text -match '\[CRASH\]|panic-ret=|result=FAILED'){throw "Guest failure: $serialLog"}
        if($text -match $Pattern){return $text}
        if($process.HasExited -or $watch.Elapsed.TotalSeconds -gt $TimeoutSeconds){throw "Missing guest marker $Pattern ($serialLog)"}
        Start-Sleep -Milliseconds 100
    }
}
function Capture([string]$Label){$path=Join-Path $output "$name-$Label.ppm";$null=Qmp $session 'screendump' @{filename=$path};return $path}
function Fixture([string]$Name,[bool]$Reidentify,[bool]$Usb,[bool]$Damage){
    $path=Join-Path $output "$Name.img"
    Copy-Item -LiteralPath $Image -Destination $path -Force
    [InstallationImageFixtures]::Prepare($path,$initial.installation.installationId,$initial.installation.diskGuid,
        [string[]]@($roles|ForEach-Object {$initial.installation.partitions[$_].partitionGuid}),$manifestSectors,$manifestBytes,$configSectors,$configBytes,$Reidentify,$Usb,$Damage)
    return $path
}
try {
    [IO.Directory]::CreateDirectory($output)|Out-Null
    $resultPath=Join-Path $output 'image-results.json'
    if(Test-Path $resultPath){Remove-Item $resultPath -Force}
    $profile=Resolve-R4QemuHostProfile $Qemu
    $initial=Test-R4OSInstallationImage -Image $Image
    if($initial.bytes -ne 2048MB){throw 'This acceptance requires the standard 2048-MB image.'}
    $inputHash=(Get-FileHash -LiteralPath $Image -Algorithm SHA256).Hash.ToLowerInvariant()
    $view=[InstallationImageCheck]::new($Image)
    try {
        $manifestSectors=$view.Volumes['BOOT'].FileSectors('boot/r4os-installation.json');$manifestBytes=$view.Volumes['BOOT'].ReadFile('boot/r4os-installation.json')
        $configSectors=$view.Volumes['BOOT'].FileSectors('boot/limine.conf');$configBytes=$view.Volumes['BOOT'].ReadFile('boot/limine.conf')
    }finally{$view.Dispose()}
    Add-Type -Path (Join-Path $PSScriptRoot 'InstallationImage.Fixtures.cs')
    $roles=@('BIOSBOOT','BOOT','SYSTEM','RECOVERY','DATA')
    $otherImage=Fixture 'other' $true $false $false
    $other=Test-R4OSInstallationImage -Image $otherImage
    $usbImage=Fixture 'usb' $true $true $false
    $usb=Test-R4OSInstallationImage -Image $usbImage -Medium usb
    $damagedImage=Fixture 'damaged-system' $false $false $true
    $hashes=[ordered]@{}
    foreach($path in @($Image,$otherImage,$usbImage,$damagedImage)){$hashes[$path]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
    $zig=Join-Path (Get-InstallationPath $devkit $settings.ZIG_ROOT) "zig$suffix"
    $askpass=Join-Path $output "askpass$suffix"
    Invoke-InstallationTool $zig @('cc','-O2',(Join-Path $recoveryRoot 'Tools/Guest-Askpass.c'),'-o',$askpass)
    $ssh=(Get-Command "ssh$suffix" -CommandType Application|Select-Object -First 1).Source
    $sshOptions=@('-c','chacha20-poly1305@openssh.com','-o','StrictHostKeyChecking=no','-o',('UserKnownHostsFile='+$(if($IsWindows){'NUL'}else{'/dev/null'})),'-o','LogLevel=ERROR','-o','ConnectTimeout=5','-o','ConnectionAttempts=1')
    $runs=@();$matrix=@()
    foreach($mode in @('Bios','Uefi')) {
        if($Firmware -ne 'Both' -and $Firmware -ne $mode){continue}
        foreach($entry in @('Normal','Current','Previous')){
            # Reverse the selected installation under UEFI. In both cases the
            # other physical NVMe controller is enumerated first.
            $matrix+=@{name="$mode-$entry-multiple";firmware=$mode;entry=$entry;image=$(if($mode -eq 'Bios'){$Image}else{$otherImage});other=$(if($mode -eq 'Bios'){$otherImage}else{$Image});expected=$(if($mode -eq 'Bios'){$initial}else{$other});usb=$false;reject=$false}
        }
        $matrix+=@{name="$mode-damaged-system";firmware=$mode;entry=$(if($mode -eq 'Bios'){'Current'}else{'Previous'});image=$damagedImage;other='';expected=$initial;usb=$false;reject=$false}
    }
    if($Firmware -ne 'Uefi') {
        $matrix+=@{name='Bios-usb-default';firmware='Bios';entry='Current';image=$usbImage;other=$Image;expected=$usb;usb=$true;reject=$false}
        $matrix+=@{name='Bios-duplicate-identity';firmware='Bios';entry='Normal';image=$Image;other=$Image;expected=$initial;usb=$false;reject=$true}
    }
    if($Cases.Count){$matrix=@($matrix|Where-Object {$_.name -in $Cases});if($matrix.Count -ne $Cases.Count){throw 'Unknown case selection.'}}
    foreach($case in $matrix) {
        $name=$case.name;$serialLog=Join-Path $output "$name-serial.log";$clientLog=Join-Path $output "$name-clients.log"
        if(Test-Path $serialLog){Remove-Item $serialLog -Force};[IO.File]::WriteAllText($clientLog,'',$utf8)
        $qmpPort=Free-Port;$sshPort=Free-Port
        $arguments=@('-machine',"q35,accel=$($profile.AcceleratorChain)",'-cpu',$profile.CpuModel,'-m','2048','-smp','4','-display','none','-monitor','none','-no-reboot','-serial',"file:$serialLog",'-qmp',"tcp:127.0.0.1:$qmpPort,server=on,wait=off",'-device','qemu-xhci,id=xhci','-device','usb-kbd')
        if($case.entry -eq 'Normal'){$arguments+=@('-nic','none')}
        else{$arguments+=@('-netdev',"user,id=net,hostfwd=tcp:127.0.0.1:$sshPort-:22",'-device','virtio-net-pci,netdev=net')}
        if($case.other){$arguments+=@('-drive',"if=none,id=other,format=raw,file=$($case.other),snapshot=on",'-device','nvme,drive=other,serial=OTHER07617')}
        $arguments+=@('-drive',"if=none,id=actual,format=raw,file=$($case.image),snapshot=on",'-device',$(if($case.usb){'usb-storage,drive=actual,bootindex=1'}else{'nvme,drive=actual,serial=ACTUAL07617,bootindex=1'}))
        if($case.firmware -eq 'Uefi'){$vars=Join-Path $output "$name-vars.fd";Copy-Item -LiteralPath $OvmfVars -Destination $vars -Force;$arguments+=@('-drive',"if=pflash,format=raw,unit=0,readonly=on,file=$OvmfCode",'-drive',"if=pflash,format=raw,unit=1,file=$vars")}
        $start=[Diagnostics.ProcessStartInfo]::new($Qemu);$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($arg in $arguments){$start.ArgumentList.Add($arg)}
        $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$session=$null;$started=$false;$watch=[Diagnostics.Stopwatch]::StartNew()
        Write-Host "Installation image ${name}: SMP4, $($profile.Name)."
        try {
            if(!$process.Start()){throw 'QEMU did not start.'};$started=$true;$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            Start-Sleep -Milliseconds 2000
            $session=Open-Qmp $qmpPort;$null=Capture 'limine'
            if(!$case.usb -and $case.entry -ne 'Normal'){Send-Keys $session $(if($case.entry -eq 'Current'){@('down','ret')}else{@('down','down','ret')})}
            if($case.reject) {
                $text=Wait-Guest '\[CRASH\]' -ExpectCrash
                if($text -notmatch '\[INSTALLBOOT\] source=duplicate-disk-guid' -or $text -match '\[INSTALLBOOT\] mapping=verified'){throw 'Ambiguous installation was not rejected before mapping.'}
                $null=Capture 'rejected'
            } elseif($case.entry -eq 'Normal') {
                $text=Wait-Guest '\[INSTALLBOOT\] mapping=verified C=SYSTEM D=DATA BOOT=unlettered'
                $expected=$case.expected.installation
                $line='[INSTALLBOOT] installation='+$expected.installationId+' C='+$expected.partitions.SYSTEM.partitionGuid+' BOOT='+$expected.partitions.BOOT.partitionGuid+' D='+$expected.partitions.DATA.partitionGuid
                if(!$text.Contains($line)){throw 'Normal OS selected a foreign installation.'}
                # The desktop redirects launcher logging. Prove actual local
                # input and a loaded Terminal by its regular poweroff instead.
                Start-Sleep -Milliseconds 10000;$null=Capture 'desktop'
                Send-Keys $session @('d');Start-Sleep -Milliseconds 1500
                Keys 'VER';Send-Keys $session @('ret');Start-Sleep -Milliseconds 500;$null=Capture 'terminal'
                Keys 'POWEROFF';Send-Keys $session @('ret')
                if(!$process.WaitForExit(20000) -or $process.ExitCode -ne 0){throw 'Normal desktop/Terminal poweroff witness missing.'}
            } else {
                $text=Wait-Guest '\[RECOVERY\] shell=READY'
                $slot=$case.entry.ToLowerInvariant();$bus=if($case.usb){'usb'}else{'local'}
                $identity='disk='+$case.expected.installation.diskGuid+' partition='+$case.expected.installation.partitions.RECOVERY.partitionGuid
                if(!$text.Contains($identity) -or !$text.Contains("[RECOVERYSTORAGE] source=ok bus=$bus slot=$slot")){throw 'Recovery selected a foreign source/slot.'}
                $null=Wait-Guest '\[RECOVERYNET\] autostart=RETURNED';$null=Wait-Guest 'DHCP05913 state=bound'
                $mounted=Ssh ('TYPE R:\'+$slot.ToUpperInvariant()+'\manifest.json')
                $mountedManifest=$mounted|ConvertFrom-Json -AsHashtable
                if($mountedManifest.recoveryVersion -cne $case.expected.recoveryVersion){throw 'R: does not expose the selected Recovery package.'}
                $null=Capture 'recovery'
                Send-Keys $session @('up','up','ret');Start-Sleep -Milliseconds 500
                Keys 'POWEROFF';Send-Keys $session @('ret')
                if(!$process.WaitForExit(20000) -or $process.ExitCode -ne 0){throw 'Recovery did not power off cleanly.'}
            }
            $runs+=@([ordered]@{case=$name;firmware=$case.firmware;entry=$case.entry;cpus=4;imageSha256=$hashes[$case.image];installationId=$case.expected.installation.installationId;
                seconds=[Math]::Round($watch.Elapsed.TotalSeconds,3);result='PASS'})
            [IO.File]::WriteAllText($resultPath,(@{schema=1;sourceSha256=$inputHash;structure=$initial;runs=$runs}|ConvertTo-Json -Depth 20)+"`n",$utf8)
            Write-Host "PASS $name ($([Math]::Round($watch.Elapsed.TotalSeconds,2)) s)"
        } finally {
            if($null -ne $session){$session.Writer.Dispose();$session.Reader.Dispose();$session.Client.Dispose()}
            if($started){if(!$process.HasExited){$process.Kill($true)};$process.WaitForExit();[IO.File]::WriteAllText((Join-Path $output "$name-qemu.log"),$stderr.GetAwaiter().GetResult(),$utf8);$null=$stdout.GetAwaiter().GetResult()};$process.Dispose()
        }
    }
    foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hashes[$path]){throw 'A base image changed during the snapshot boot acceptance.'}}
    Write-Host "Installation image acceptance: $($runs.Count) cases PASS."
    exit 0
}catch{Write-Error $_ -ErrorAction Continue;exit 1}
