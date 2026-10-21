param(
    [ValidateSet('Foundation','Multi')][string]$Mode='Multi',
    [string]$Qemu='',
    [string]$OutputRoot='',
    [ValidateRange(30,600)][int]$TimeoutSeconds=180
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$distribution=Split-Path $PSScriptRoot -Parent
$workspace=[IO.Path]::GetFullPath((Join-Path $distribution '../..'))
$recoveryTools=Join-Path $workspace 'Repositories/Recovery/Tools'
. (Join-Path $distribution 'Tools/Qemu-HostProfile.ps1')
. (Join-Path $recoveryTools 'Guest-Qmp.ps1')
. (Join-Path $recoveryTools 'Guest-NetClients.ps1')
$utf8=[Text.UTF8Encoding]::new($false)
$suffix=if($IsWindows){'.exe'}else{''}
if(!$Qemu){$Qemu=(Get-Command "qemu-system-x86_64$suffix" -CommandType Application | Select-Object -First 1).Source}
if(!$OutputRoot){$OutputRoot=Join-Path $workspace ('Temp/UsbControllers/'+[Guid]::NewGuid().ToString('N'))}
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
[IO.Directory]::CreateDirectory($OutputRoot)|Out-Null
$usbHostProfile=Resolve-R4QemuHostProfile $Qemu
$creator=Join-Path $workspace "Artifacts/Distribution/HostTools/bin/imagecreater$suffix"
$zig=Join-Path $workspace "DevKit/Toolchains/Zig/zig$suffix"
$limine=Join-Path $workspace $(if($IsWindows){'DevKit/Boot/Limine/limine-tool-windows-x86/limine.exe'}else{'DevKit/Boot/Limine/limine'})
$source=Join-Path $workspace 'Artifacts/Distribution/Profiles/Test'
$image=Join-Path $OutputRoot 'guest.img'
$serialLog=Join-Path $OutputRoot 'serial.log'
$clientLog=Join-Path $OutputRoot 'clients.log'
$askpass=Join-Path $OutputRoot "askpass$suffix"
$ssh=(Get-Command "ssh$suffix" -CommandType Application|Select-Object -First 1).Source
$sftp=(Get-Command "sftp$suffix" -CommandType Application|Select-Object -First 1).Source
$sshOptions=@('-c','chacha20-poly1305@openssh.com','-o','StrictHostKeyChecking=no','-o',('UserKnownHostsFile='+$(if($IsWindows){'NUL'}else{'/dev/null'})),'-o','LogLevel=ERROR','-o','ConnectTimeout=3','-o','ConnectionAttempts=1')
function Free-Port {
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    try{$listener.Start();return $listener.LocalEndpoint.Port}finally{$listener.Stop()}
}
function Checked([string]$Program,[string[]]$Arguments){& $Program @Arguments;if($LASTEXITCODE -ne 0){throw "Host tool failed: $Program"}}
function Read-Version([string]$Path,[string]$Key){
    $match=[regex]::Match([IO.File]::ReadAllText($Path),"(?m)^$Key=(.+)$")
    if(!$match.Success){throw "Missing version: $Key"};return $match.Groups[1].Value.Trim()
}
function Input-Snapshot {
    $text=Ssh 'SPECTRA CHECK INPUT'
    if($text -notmatch 'mouse present=(\d+) x=(-?\d+) y=(-?\d+) buttons=(\d+) packets=(\d+)'){throw 'Missing mouse snapshot.'}
    $value=@{present=[long]$Matches[1];x=[int]$Matches[2];y=[int]$Matches[3];packets=[long]$Matches[5]}
    if($text -notmatch 'keyboard capacity=\d+ pending=\d+ highWater=\d+ accepted=(\d+) dropped=(\d+)'){throw 'Missing keyboard snapshot.'}
    $value.accepted=[long]$Matches[1];$value.dropped=[long]$Matches[2]
    return $value
}
$process=$null;$session=$null;$stdout=$null;$stderr=$null;$success=$false
$expectedActive=if($Mode -ceq 'Foundation'){1}else{3}
try {
    foreach($path in @($creator,$zig,$limine,(Join-Path $source 'image-adds.txt'),(Join-Path $source 'recovery-adds.txt'))){if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw "Missing input: $path"}}
    $kernel=Join-Path $workspace 'Repositories/Kernel/zig-out/bin/r4os.elf'
    $kernelHash=(Get-FileHash -LiteralPath $kernel -Algorithm SHA256).Hash.ToLowerInvariant()
    $canonical=Get-Content -Raw -LiteralPath (Join-Path $source 'image.json')|ConvertFrom-Json -AsHashtable
    if($canonical.structure.bootHashes['boot/r4os.elf'] -cne $kernelHash){throw 'Build the current kernel and Test image before USB acceptance.'}
    $release=Read-Version (Join-Path $distribution 'Injection/R4OS/CONFIG/VERSION.R4S') 'RELEASE_VERSION'
    $kernelVersion=Read-Version (Join-Path $workspace 'Repositories/Kernel/VERSION.R4S') 'KERNEL_VERSION'
    Checked $zig @('cc','-O2',(Join-Path $recoveryTools 'Guest-Askpass.c'),'-o',$askpass)
    # Derive one private image with an ordinary console. Never enable the
    # unrelated full subsystem/headless test matrix or alter source injections.
    $config=Join-Path $OutputRoot 'CONFIG.R4S'
    $configuration=[IO.File]::ReadAllText((Join-Path $distribution 'Injection/CONFIG.R4S'))
    $configuration=$configuration -replace '(?m)^SHELL=.+$','SHELL=/R4OS/SOFTWARE/TERMINAL/TERMINAL.R4X'
    [IO.File]::WriteAllText($config,$configuration,$utf8)
    $autoexec=Join-Path $OutputRoot 'AUTOEXEC.BAT'
    [IO.File]::WriteAllText($autoexec,"@ECHO OFF`r`nSET TEMP=C:\TEMP`r`nC:\R4OS\SOFTWARE\TERMINAL\SERVMAN.R4X BOOT`r`nECHO USB-ACCEPTANCE-READY`r`n",$utf8)
    $adds=foreach($line in Get-Content -LiteralPath (Join-Path $source 'image-adds.txt')){
        if($line -match '[:|]/CONFIG\.R4S$'){"$config|/CONFIG.R4S"}
        elseif($line -match '[:|]/AUTOEXEC\.BAT$'){"$autoexec|/AUTOEXEC.BAT"}
        elseif($line -match '[:|]/R4OS/CONFIG/SERVICES\.R4S$'){"$(Join-Path $distribution 'Injection/R4OS/CONFIG/SERVICES.R4S')|/R4OS/CONFIG/SERVICES.R4S"}
        else{$line}
    }
    # SSH is deliberately Full-only in the normal profile catalogue. Include
    # that unchanged existing artifact explicitly for this host-driven fixture.
    foreach($extra in @(
        @{source='Artifacts/Modules/SshService/SSHD.R4X';target='/R4OS/SERVICES/SSHD.R4X'},
        @{source='Artifacts/Modules/DeviceManager/DEVMGR.R4X';target='/R4OS/SOFTWARE/DESKTOP/DEVMGR.R4X'}
    )){
        $artifact=Join-Path $workspace $extra.source
        if(!(Test-Path -LiteralPath $artifact -PathType Leaf)){throw "Build the existing fixture dependency first: $($extra.source)"}
        $targetPattern='[:|]'+[regex]::Escape($extra.target)+'$'
        if(!(@($adds|Where-Object {$_ -match $targetPattern}).Count)){$adds+="$artifact|$($extra.target)"}
    }
    $inputList=Join-Path $OutputRoot 'adds.txt'
    [IO.File]::WriteAllText($inputList,($adds -join "`n")+"`n",$utf8)
    Checked $creator @('create-installation','--output',$image,'--manifest-out',(Join-Path $OutputRoot 'installation.json'),'--add-list',$inputList,'--recovery-list',(Join-Path $source 'recovery-adds.txt'),'--release-version',$release,'--kernel-version',$kernelVersion,'--medium','local','--image-mb','22528')
    Checked $limine @('bios-install',$image)
    if(!('InstallationImageCheck' -as [type])){Add-Type -Path (Join-Path $distribution 'Tools/InstallationImage.Check.cs')}
    $check=[InstallationImageCheck]::new($image,$false)
    try{
        $bootHash=[InstallationImageCheck]::Hash($check.Volumes['BOOT'].ReadFile('boot/r4os.elf'))
        if($bootHash -cne $kernelHash){throw 'Actual guest BOOT kernel differs from the built artifact.'}
    }finally{$check.Dispose()}
    $payloads=@()
    foreach($i in 0..1){
        $path=Join-Path $OutputRoot "PAYLOAD$i.BIN"
        $bytes=[byte[]]::new(256KB);[Random]::new(86025+$i).NextBytes($bytes);[IO.File]::WriteAllBytes($path,$bytes)
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $payloads+=@{index=$i;bytes=$bytes.Length;sha256=$hash;source=$path}
        Checked $creator @('format-ntfs','--output',(Join-Path $OutputRoot "usb$i.img"),'--meta',(Join-Path $workspace 'Repositories/SDK/Tests/Fixture/Ntfs/Meta0605'),'--size','32','--partition','--label',"USBTEST$i",'--serial',('86610'+$i),'--add',"${path}:/PAYLOAD$i.BIN")
    }
    $sshPort=Free-Port;$qmpPort=Free-Port
    $arguments=@('-machine',"q35,i8042=off,accel=$($usbHostProfile.AcceleratorChain)",'-cpu',$usbHostProfile.CpuModel,'-m','8192','-smp','4','-display','none','-monitor','none','-no-reboot','-serial',"file:$serialLog",'-qmp',"tcp:127.0.0.1:$qmpPort,server=on,wait=off",'-device','ich9-ahci,id=ahci','-drive',"if=none,id=system,format=raw,file=$image",'-device','ide-hd,drive=system,bus=ahci.0,bootindex=1','-netdev',"user,id=net,hostfwd=tcp:127.0.0.1:$sshPort-:22",'-device','virtio-net-pci,netdev=net')
    foreach($i in 0..2){$arguments+=@('-device',"qemu-xhci,id=usb$i,addr=0x$($i+6)")}
    $mouseHost=if($Mode -ceq 'Foundation'){0}else{1}
    $mediaHost=if($Mode -ceq 'Foundation'){0}else{2}
    $secondHost=if($Mode -ceq 'Foundation'){0}else{1}
    $arguments+=@('-device','usb-kbd,id=keyboard,bus=usb0.0,port=1','-device',"usb-mouse,id=mouse,bus=usb$mouseHost.0,port=2",'-drive',"if=none,id=media0,format=raw,file=$(Join-Path $OutputRoot 'usb0.img')",'-device',"usb-storage,id=media0-usb,drive=media0,bus=usb$mediaHost.0,port=3",'-drive',"if=none,id=media1,format=raw,file=$(Join-Path $OutputRoot 'usb1.img')",'-device',"usb-storage,id=media1-usb,drive=media1,bus=usb$secondHost.0,port=4")
    $start=[Diagnostics.ProcessStartInfo]::new($Qemu);$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($arg in $arguments){$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    if(!$process.Start()){throw 'QEMU did not start.'}
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    $watch=[Diagnostics.Stopwatch]::StartNew();$ready=$false
    while(!$ready){
        if($process.HasExited -or $watch.Elapsed.TotalSeconds -gt $TimeoutSeconds){throw 'USB guest did not become ready.'}
        $log=if(Test-Path -LiteralPath $serialLog){[IO.File]::ReadAllText($serialLog)}else{''}
        if($log -match '\[CRASH\]|panicked at|kernel panic|Usage: TERMINAL\.R4X'){throw 'Guest failed during USB boot.'}
        if($log -match 'SSHD|boot-ready|USB-ACCEPTANCE-READY'){
            try{$ver=Ssh 'VER';$ready=$ver -match [regex]::Escape($release)}catch{}
        }
        if(!$ready){Start-Sleep -Milliseconds 200}
    }
    $session=Open-Qmp $qmpPort
    $system=Ssh 'SYSINFO'
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'sysinfo.txt'),$system,$utf8)
    $hid=Ssh 'SYSINFO /USBHID';$msc=Ssh 'SYSINFO /USBMSC'
    if($hid -notmatch 'SYSINFO usbhid: ok' -or $msc -notmatch 'SYSINFO usbmsc: ok'){throw 'Missing native HID/MSC binding.'}
    $inventory=Ssh 'C:\R4OS\SOFTWARE\DESKTOP\DEVMGR.R4X /CONSOLE'
    $controllerRows=@($inventory -split '\r?\n'|Where-Object {$_ -match 'xHCI USB controller'})
    $activeRows=@($controllerRows|Where-Object {$_ -match 'status=host-(preload|rescue)-active'})
    if($controllerRows.Count -ne 3 -or $activeRows.Count -ne $expectedActive){throw 'PCI inventory repeats a foreign controller state or misses a controller.'}
    $usbLetters=@([regex]::Matches($system,'(?m)^\s*([A-Z]):\s+NTFS\s+general\s+usb\d+\b')|ForEach-Object {$_.Groups[1].Value})
    if($usbLetters.Count -ne 2){throw 'Missing two mounted USB media.'}
    $mediumLetters=@{}
    foreach($letter in $usbLetters){
        $listing=Sftp @("ls /$letter/")
        if($listing -notmatch 'PAYLOAD([01])\.BIN'){throw "USB fixture not identified on ${letter}:"}
        $mediumLetters[[int]$Matches[1]]=$letter
    }
    if($mediumLetters.Count -ne 2){throw 'USB media identities collided.'}
    $beforeInput=Input-Snapshot
    Send-Keys $session @('a','shift+b','left')
    $null=Qmp $session 'input-send-event' @{events=@(@{type='rel';data=@{axis='x';value=13}},@{type='rel';data=@{axis='y';value=9}})}
    Start-Sleep -Milliseconds 100
    $afterInput=Input-Snapshot
    if($afterInput.accepted -le $beforeInput.accepted -or $afterInput.dropped -ne $beforeInput.dropped -or $afterInput.packets -le $beforeInput.packets){throw 'USB hardware input was not delivered without PS/2.'}
    $copies=@()
    foreach($item in $payloads){
        $i=$item.index;$letter=$mediumLetters[$i]
        $remote="/$letter/PAYLOAD$i.BIN";$download=Join-Path $OutputRoot "read$i.bin"
        $null=Sftp @("get $remote $(Host-Path $download)")
        if((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant() -cne $item.sha256){throw "USB read $i hash mismatch."}
        $null=Ssh "COPY ${letter}:\PAYLOAD$i.BIN ${letter}:\COPY$i.BIN"
        $null=Sftp @("get /$letter/COPY$i.BIN $(Host-Path $download)")
        if((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant() -cne $item.sha256){throw "USB copy $i hash mismatch."}
        $null=Ssh "DEL ${letter}:\COPY$i.BIN"
        $copies+=@{medium=$i;letter=$letter;bytes=$item.bytes;sha256=$item.sha256;read=$true;copy=$true;delete=$true}
    }
    $usbCheck=Ssh 'SPECTRA CHECK USB /JSON'
    if($usbCheck -match '"passed":false|"failed":[1-9]'){throw 'Existing USB owner cases failed.'}
    # The guest can close SSH while draining services before ACPI poweroff.
    # Its actual clean QEMU exit is the terminal acknowledgement below.
    try{$null=Ssh 'POWEROFF'}catch{
        if($_.Exception.Message -notmatch 'Client failed \(255\)'){throw}
    }
    if(!$process.WaitForExit(30000) -or $process.ExitCode -ne 0){throw 'USB guest did not power off normally.'}
    $result=[ordered]@{schema=1;mode=$Mode;release=$release;kernelVersion=$kernelVersion;kernelSha256=$kernelHash;actualBootKernelSha256=$bootHash;cpus=4;controllersDetected=3;controllersStarted=$activeRows.Count;pciRecords=$controllerRows;ps2Disabled=$true;inputBefore=$beforeInput;inputAfter=$afterInput;media=$copies;normalShutdown=$true;seconds=$watch.Elapsed.TotalSeconds;scope='One bounded local KVM/SMP4 HID/two-media and PCI-diagnosis acceptance; no native-hardware qualification or general performance claim.'}
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'result.json'),($result|ConvertTo-Json -Depth 12)+"`n",$utf8)
    $success=$true
    Write-Host "USB $Mode PASS: $($activeRows.Count)/3 active controllers, real HID, two hash-verified media, regular shutdown."
} finally {
    if($null -ne $session){$session.Writer.Dispose();$session.Reader.Dispose();$session.Client.Dispose()}
    if($null -ne $process){
        if(!$process.HasExited){$process.Kill($true);$process.WaitForExit()}
        if($null -ne $stdout){[IO.File]::WriteAllText((Join-Path $OutputRoot 'qemu.log'),$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult(),$utf8)}
        $process.Dispose()
    }
    # Large guest/media copies never become an archive, including on failure.
    foreach($name in @('guest.img','usb0.img','usb1.img')){Remove-Item -LiteralPath (Join-Path $OutputRoot $name) -Force -ErrorAction SilentlyContinue}
    if($success){
        Get-ChildItem -LiteralPath $OutputRoot -File|Where-Object Name -ne 'result.json'|Remove-Item -Force
    }
}
