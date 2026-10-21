param(
    [ValidateSet('Foundation','Multi')][string]$Mode='Multi',
    [switch]$WorkOnly,
    [switch]$InputOnly,
    [switch]$InputIrqFallback,
    [switch]$SkipComparison,
    [switch]$IrqFallback,
    [string]$KernelArtifact='',
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
$sshOptions=@('-c','chacha20-poly1305@openssh.com','-o','StrictHostKeyChecking=no','-o',('UserKnownHostsFile='+$(if($IsWindows){'NUL'}else{'/dev/null'})),'-o','LogLevel=ERROR','-o','ConnectTimeout=10','-o','ConnectionAttempts=1')
function Free-Port {
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    try{$listener.Start();return $listener.LocalEndpoint.Port}finally{$listener.Stop()}
}
function Checked([string]$Program,[string[]]$Arguments){& $Program @Arguments;if($LASTEXITCODE -ne 0){throw "Host tool failed: $Program"}}
function Read-Version([string]$Path,[string]$Key){
    $match=[regex]::Match([IO.File]::ReadAllText($Path),"(?m)^$Key=(.+)$")
    if(!$match.Success){throw "Missing version: $Key"};return $match.Groups[1].Value.Trim()
}
function Work-Snapshot {
    $text=Ssh 'C:\R4OS\SOFTWARE\DESKTOP\DEVMGR.R4X /CONSOLE'
    $buffers=(@($text -split '\r?\n'|Where-Object {$_ -match 'USB buffer work'}) -join ' ')
    $completion=(@($text -split '\r?\n'|Where-Object {$_ -match 'USB completion wake'}) -join ' ')
    $text=(@($text -split '\r?\n'|Where-Object {$_ -match 'USB (completion|IRQ) work'}) -join ' ')
    $out=@{}
    foreach($key in @('calls','loops','sleep','to','ns','irq','wake','fallback')){
        if($text -notmatch "\b$key=(\d+)"){throw "Missing USB work counter $key."}
        $out[$key]=[long]$Matches[1]
    }
    foreach($key in @('fast','enrolled','recheck','signal','fallbackwait','parks')){
        if($completion -match "\b$key=(\d+)"){$out[$key]=[long]$Matches[1]}
    }
    foreach($key in @('clear','inbytes','outbytes','pages')){if($buffers -match "\b$key=(\d+)"){$out[$key]=[long]$Matches[1]}}
    return $out
}
function Hid-Snapshot {
    $text=Ssh 'C:\R4OS\SOFTWARE\DESKTOP\DEVMGR.R4X /CONSOLE'
    $row=@($text -split '\r?\n'|Where-Object {$_ -match 'USB HID work'}) -join ' '
    $value=@{}
    foreach($key in @('tick','hz','svc','worker','empty','keys','mouse','bp')){
        if($row -notmatch "\b$key=(\d+)"){throw "Missing HID work counter $key."}
        $value[$key]=[long]$Matches[1]
    }
    foreach($key in @('sig','mods','kb','mb')){if($row -match "\b$key=(\d+)"){$value[$key]=[long]$Matches[1]}}
    return $value
}
function Await-InputState([scriptblock]$Predicate) {
    $until=[DateTime]::UtcNow.AddSeconds(15)
    do{$value=Hid-Snapshot;if(&$Predicate $value){return $value};Start-Sleep -Milliseconds 50}while([DateTime]::UtcNow -lt $until)
    throw 'Exact HID state did not converge.'
}
function Input-Lifetime($Session,$MediumLetters,$Payloads) {
    $null=Qmp $Session 'input-send-event' @{events=@(@{type='key';data=@{down=$true;key=@{type='qcode';data='shift'}}})}
    $held=Await-InputState {param($v) ($v.mods-band 2) -ne 0}
    $null=Qmp $Session 'device_del' @{id='keyboard'}
    # The old guest binding must release its state before a replacement or
    # hardware key-up exists. QEMU has no key handler while USB is absent.
    $released=Await-InputState {param($v) $v.kb -eq 0 -and $v.mods -eq 0}
    $mouseBefore=Input-Snapshot
    $null=Qmp $Session 'input-send-event' @{events=@(@{type='rel';data=@{axis='x';value=5}})}
    $mouseAfter=Input-Snapshot
    if($mouseAfter.packets -le $mouseBefore.packets){throw 'Keyboard detach stopped the foreign mouse.'}
    $neighbor=Join-Path $OutputRoot 'hid-neighbor.bin'
    $null=Sftp @("get /$($MediumLetters[1])/PAYLOAD1.BIN $(Host-Path $neighbor)")
    if((Get-FileHash -LiteralPath $neighbor).Hash.ToLowerInvariant() -cne $Payloads[1].sha256){throw 'Keyboard detach stopped foreign media.'}
    $null=Qmp $Session 'device_add' @{driver='usb-kbd';id='keyboard';bus='usb0.0';port='1'}
    $null=Qmp $Session 'input-send-event' @{events=@(@{type='key';data=@{down=$false;key=@{type='qcode';data='shift'}}})}
    $fresh=Await-InputState {param($v) $v.kb -eq 1 -and $v.mods -eq 0}
    Send-Keys $Session @('e','c','h','o','spc','r','e','l','e','a','s','e','2','9','minus','1','spc','shift+dot','spc','c','shift+semicolon','backslash','r','e','l','e','a','s','e','2','9','dot','t','x','t','ret')
    $path=Join-Path $OutputRoot 'release29.txt'
    $null=Sftp @("get /C/RELEASE29.TXT $(Host-Path $path)")
    if([IO.File]::ReadAllText($path).Trim() -cne 'RELEASE29-1'){throw 'Old modifier leaked into the replacement keyboard.'}
    $out=[ordered]@{held=$held;released=$released;fresh=$fresh;foreignMouse=$true;foreignMediaSha256=$Payloads[1].sha256;replacementTyped='RELEASE29-1'}
    if($InputIrqFallback){
        $out.irq=Set-ControllerFault $Session -DisableInterrupts -ControllerId usb0
        Send-Keys $Session @('e','c','h','o','spc','i','r','q','2','9','spc','shift+dot','spc','c','shift+semicolon','backslash','i','r','q','2','9','dot','t','x','t','ret')
        $path=Join-Path $OutputRoot 'irq29.txt';$null=Sftp @("get /C/IRQ29.TXT $(Host-Path $path)")
        if([IO.File]::ReadAllText($path).Trim() -cne 'IRQ29'){throw 'HID notification fallback did not deliver typed keys.'}
        $out.irq.typed='IRQ29';$out.irq.hid=Hid-Snapshot
    }
    return $out
}
function Input-Work($Session,$MediumLetters,$Payloads) {
    $idleBefore=Hid-Snapshot
    Start-Sleep -Milliseconds 600
    $idleAfter=Hid-Snapshot
    if($idleAfter.tick -le $idleBefore.tick -or $idleAfter.hz -ne $idleBefore.hz){throw 'Invalid HID guest clock interval.'}
    $inputBefore=Input-Snapshot
    $payload=$Payloads[0];$letter=$MediumLetters[0]
    $download=Join-Path $OutputRoot 'hid-msc.bin'
    $client=Start-Transfer @("put $(Host-Path $payload.source) /$letter/HID29.BIN","get /$letter/HID29.BIN $(Host-Path $download)","rm /$letter/HID29.BIN")
    $inputClock=[Diagnostics.Stopwatch]::StartNew()
    # Actual unchanged local Terminal must execute this typed line. !1 checks
    # modifier release, the corrected X checks editing/order, not just counts.
    Send-Keys $Session @('e','c','h','o','spc','h','i','d','2','9','minus','shift+1','1','minus')
    $overlap=!$client.process.HasExited
    $null=Qmp $Session 'input-send-event' @{events=@(@{type='rel';data=@{axis='x';value=17}},@{type='rel';data=@{axis='y';value=11}},@{type='btn';data=@{button='left';down=$true}})}
    Start-Sleep -Milliseconds 50
    $null=Qmp $Session 'input-send-event' @{events=@(@{type='rel';data=@{axis='x';value=7}},@{type='btn';data=@{button='left';down=$false}})}
    Send-Keys $Session @('a','b','c','x','backspace','d','spc','shift+dot','spc','c','shift+semicolon','backslash','h','i','d','2','9','dot','t','x','t','ret')
    $done=Complete-Transfer $client
    if((Get-FileHash -LiteralPath $download).Hash.ToLowerInvariant() -cne $payload.sha256){throw 'MSC bytes differ during HID work.'}
    $typed=Join-Path $OutputRoot 'typed.txt'
    $null=Sftp @("get /C/HID29.TXT $(Host-Path $typed)")
    if([IO.File]::ReadAllText($typed).Trim() -cne 'HID29-!1-ABCD'){throw 'Typed HID witness lost/reordered a key or modifier release.'}
    $inputAfter=Input-Snapshot
    if($inputAfter.buttons -ne 0){$inputAfter=Input-Snapshot}
    if($inputAfter.accepted -le $inputBefore.accepted -or $inputAfter.dropped -ne $inputBefore.dropped -or $inputAfter.packets -le $inputBefore.packets -or $inputAfter.buttons -ne 0){throw 'Input burst/drop/button-release witness failed.'}
    $hidAfter=Hid-Snapshot
    return [ordered]@{definition='600ms host idle window measured in guest ticks; typed Terminal ECHO with !1 release, ordered corrected burst, mouse move/button release; concurrent256KB MSC put/get/delete on foreign controller';idleBefore=$idleBefore;idleAfter=$idleAfter;idleSeconds=($idleAfter.tick-$idleBefore.tick)/[double]$idleBefore.hz;idleWorkerCalls=($idleAfter.worker-$idleBefore.worker);idleServiceCalls=($idleAfter.svc-$idleBefore.svc);idleEmptyPolls=($idleAfter.empty-$idleBefore.empty);inputBefore=$inputBefore;inputAfter=$inputAfter;hidAfter=$hidAfter;typed='HID29-!1-ABCD';hostWitnessMilliseconds=$inputClock.Elapsed.TotalMilliseconds;mscOverlapped=$overlap;msc=$done;mscBytes=256KB;mscSha256=$payload.sha256;limits='Host witness includes deliberate key spacing, SSH/SFTP and hash work; it is not isolated report latency. Guest ticks normalize the idle counter interval.'}
}
function Input-Snapshot {
    $text=Ssh 'SPECTRA CHECK INPUT'
    if($text -notmatch 'mouse present=(\d+) x=(-?\d+) y=(-?\d+) buttons=(\d+) packets=(\d+)'){throw 'Missing mouse snapshot.'}
    $value=@{present=[long]$Matches[1];x=[int]$Matches[2];y=[int]$Matches[3];packets=[long]$Matches[5];buttons=[int]$Matches[4]}
    if($text -notmatch 'keyboard capacity=\d+ pending=\d+ highWater=\d+ accepted=(\d+) dropped=(\d+)'){throw 'Missing keyboard snapshot.'}
    $value.accepted=[long]$Matches[1];$value.dropped=[long]$Matches[2]
    return $value
}
$transferClients=[Collections.Generic.List[object]]::new()
function Start-Transfer([string[]]$Commands){
    $start=[Diagnostics.ProcessStartInfo]::new($sftp);$start.UseShellExecute=$false
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.RedirectStandardInput=$true
    $start.Environment['SSH_ASKPASS']=$askpass;$start.Environment['SSH_ASKPASS_REQUIRE']='force';$start.Environment['DISPLAY']='usb-acceptance'
    foreach($arg in (@('-P',"$sshPort",'-o','BatchMode=no','-b','-')+$sshOptions+@('r4os@127.0.0.1'))){$start.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$start
    if(!$p.Start()){throw 'Parallel SFTP did not start.'}
    $client=@{process=$p;stdout=$p.StandardOutput.ReadToEndAsync();stderr=$p.StandardError.ReadToEndAsync();started=[Diagnostics.Stopwatch]::GetTimestamp()}
    $transferClients.Add($client)
    $p.StandardInput.Write(($Commands -join "`n")+"`n");$p.StandardInput.Close()
    return $client
}
function Complete-Transfer($Client,[switch]$MustFail){
    $p=$Client.process
    if(!$p.WaitForExit(60000)){$p.Kill($true);$p.WaitForExit();throw 'Parallel SFTP timed out.'}
    $text=$Client.stdout.GetAwaiter().GetResult()+$Client.stderr.GetAwaiter().GetResult()
    [IO.File]::AppendAllText($clientLog,$text,$utf8)
    if(($MustFail -and $p.ExitCode -ne 1) -or (!$MustFail -and $p.ExitCode -ne 0)){throw "Unexpected SFTP exit $($p.ExitCode): $text"}
    return [ordered]@{exitCode=$p.ExitCode;milliseconds=(([Diagnostics.Stopwatch]::GetTimestamp()-$Client.started)*1000.0/[Diagnostics.Stopwatch]::Frequency)}
}
function Await-Hid([int]$MouseCount){
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    do {
        $text=Ssh 'SYSINFO /USBHID'
        if($text -match "records: keyboard=1 mouse=$MouseCount" -and $text -match 'SYSINFO usbhid: ok'){return}
        Start-Sleep -Milliseconds 100
    }while([DateTime]::UtcNow -lt $deadline)
    throw 'HID topology did not converge.'
}
# Shared exact hardware injection remains with the existing QMP owner.
function Set-ControllerFault($Session,[switch]$DisableInterrupts,[ValidateSet('usb0','usb1','usb2')][string]$ControllerId='usb2'){
    Set-QmpXhciFault $Session -DisableInterrupts:$DisableInterrupts -ControllerId $ControllerId
}
$process=$null;$session=$null;$stdout=$null;$stderr=$null;$success=$false
$expectedActive=if($Mode -ceq 'Foundation'){1}else{3}
try {
    if($InputIrqFallback -and (!$InputOnly -or $WorkOnly)){throw '-InputIrqFallback requires the candidate InputOnly lifetime case.'}
    if($InputOnly -and $Mode -ne 'Multi'){throw '-InputOnly requires Multi routing.'}
    if($SkipComparison -and ($WorkOnly -or $Mode -ne 'Multi')){throw '-SkipComparison requires a Multi lifecycle run.'}
    foreach($path in @($creator,$zig,$limine,(Join-Path $source 'image-adds.txt'),(Join-Path $source 'recovery-adds.txt'))){if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw "Missing input: $path"}}
    $kernel=if($KernelArtifact){[IO.Path]::GetFullPath($KernelArtifact,$workspace)}else{Join-Path $workspace 'Repositories/Kernel/zig-out/bin/r4os.elf'}
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
        elseif($line -match '[:|]/boot/r4os\.elf$'){"$kernel|/boot/r4os.elf"}
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
        $mediaArgs=@('format-ntfs','--output',(Join-Path $OutputRoot "usb$i.img"),'--meta',(Join-Path $workspace 'Repositories/SDK/Tests/Fixture/Ntfs/Meta0605'),'--size','32','--partition','--label',"USBTEST$i",'--serial',('86610'+$i),'--add',"${path}:/PAYLOAD$i.BIN")
        if($Mode -ceq 'Multi'){
            $unread=Join-Path $OutputRoot "UNREAD$i.BIN";$bytes=[byte[]]::new(4MB);[Random]::new(86620+$i).NextBytes($bytes)
            [IO.File]::WriteAllBytes($unread,$bytes);$mediaArgs+=@('--add',"${unread}:/UNREAD$i.BIN",'--add',"${unread}:/FALLBACK$i.BIN")
        }
        Checked $creator $mediaArgs
    }
    $sshPort=Free-Port;$qmpPort=Free-Port
    $arguments=@('-machine',"q35,i8042=off,accel=$($usbHostProfile.AcceleratorChain)",'-cpu',$usbHostProfile.CpuModel,'-m','8192','-smp','4','-display','none','-monitor','none','-no-reboot','-serial',"file:$serialLog",'-qmp',"tcp:127.0.0.1:$qmpPort,server=on,wait=off",'-device','ich9-ahci,id=ahci','-drive',"if=none,id=system,format=raw,file=$image",'-device','ide-hd,drive=system,bus=ahci.0,bootindex=1','-netdev',"user,id=net,hostfwd=tcp:127.0.0.1:$sshPort-:22",'-device','virtio-net-pci,netdev=net')
    foreach($i in 0..2){$arguments+=@('-device',"qemu-xhci,id=usb$i,addr=0x$($i+6)")}
    $mouseHost=if($Mode -ceq 'Foundation'){0}else{1}
    $mediaHost=if($Mode -ceq 'Foundation'){0}else{2}
    $secondHost=if($Mode -ceq 'Foundation'){0}else{1}
    $mousePort=if($Mode -ceq 'Foundation'){2}else{1}
    $mediaPort=if($Mode -ceq 'Foundation'){3}else{1}
    $secondPort=if($Mode -ceq 'Foundation'){4}else{2}
    $arguments+=@('-device','usb-kbd,id=keyboard,bus=usb0.0,port=1','-device',"usb-mouse,id=mouse,bus=usb$mouseHost.0,port=$mousePort")
    foreach($i in 0..1){
        if($Mode -ceq 'Multi'){
            # Named block nodes survive device_del; legacy -drive backends
            # are auto-deleted by QEMU together with their USB device.
            $file=@{driver='file';filename=(Join-Path $OutputRoot "usb$i.img");'node-name'="media$i-file"}|ConvertTo-Json -Compress
            $raw=@{driver='raw';file="media$i-file";'node-name'="media$i"}|ConvertTo-Json -Compress
            $arguments+=@('-blockdev',$file,'-blockdev',$raw)
        }else{$arguments+=@('-drive',"if=none,id=media$i,format=raw,file=$(Join-Path $OutputRoot "usb$i.img")")}
        $hostIndex=if($i -eq 0){$mediaHost}else{$secondHost};$portIndex=if($i -eq 0){$mediaPort}else{$secondPort}
        $arguments+=@('-device',"usb-storage,id=media$i-usb,drive=media$i,bus=usb$hostIndex.0,port=$portIndex")
    }
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
    if($Mode -ceq 'Multi'){
        $ids=@($activeRows|ForEach-Object {if($_ -match 'xHCI id=(\d+) pci=0:([678])\.0'){$Matches[1]}else{throw 'Missing exact controller diagnosis.'}})
        if(@($ids|Select-Object -Unique).Count -ne 3){throw 'Controller IDs or note storage collide.'}
    }
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
    $inputWork=@{};$inputLifetime=@{}
    if($InputOnly){
        $inputWork=Input-Work $session $mediumLetters $payloads
        [IO.File]::WriteAllText((Join-Path $OutputRoot 'input-work-receipt.json'),(@{kernelSha256=$kernelHash;actualBootKernelSha256=$bootHash;inputWork=$inputWork}|ConvertTo-Json -Depth 12)+"`n",$utf8)
        $afterInput=$inputWork.inputAfter
        if(!$WorkOnly){$inputLifetime=Input-Lifetime $session $mediumLetters $payloads}
    }else{
    Send-Keys $session @('a','shift+b','left')
    $null=Qmp $session 'input-send-event' @{events=@(@{type='rel';data=@{axis='x';value=13}},@{type='rel';data=@{axis='y';value=9}})}
    Start-Sleep -Milliseconds 100
    $afterInput=Input-Snapshot
    if($afterInput.accepted -le $beforeInput.accepted -or $afterInput.dropped -ne $beforeInput.dropped -or $afterInput.packets -le $beforeInput.packets){throw 'USB hardware input was not delivered without PS/2.'}
    }
    $copies=@();$parallel=@();$hotplug=@{};$fault=@{};$parallelMs=0
    $work=@{skipped=$true;reason='Targeted lifecycle/fault follow-up; fixed comparison retained separately.'}
    if(!$SkipComparison -and !$InputOnly){
    $workBefore=Work-Snapshot
    $process.Refresh();$cpuBefore=$process.TotalProcessorTime.TotalSeconds
    $workClock=[Diagnostics.Stopwatch]::StartNew()
    $copies=@()
    foreach($item in $payloads){
        $serialClock=[Diagnostics.Stopwatch]::StartNew()
        $i=$item.index;$letter=$mediumLetters[$i]
        $remote="/$letter/PAYLOAD$i.BIN";$download=Join-Path $OutputRoot "read$i.bin"
        $null=Sftp @("get $remote $(Host-Path $download)")
        if((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant() -cne $item.sha256){throw "USB read $i hash mismatch."}
        $null=Ssh "COPY ${letter}:\PAYLOAD$i.BIN ${letter}:\COPY$i.BIN"
        $null=Sftp @("get /$letter/COPY$i.BIN $(Host-Path $download)")
        if((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant() -cne $item.sha256){throw "USB copy $i hash mismatch."}
        $null=Ssh "DEL ${letter}:\COPY$i.BIN"
        $copies+=@{medium=$i;letter=$letter;bytes=$item.bytes;sha256=$item.sha256;read=$true;copy=$true;delete=$true;milliseconds=$serialClock.Elapsed.TotalMilliseconds}
    }
    $parallel=@();$hotplug=@{};$fault=@{}
    if($Mode -ceq 'Multi'){
        $started=[Diagnostics.Stopwatch]::GetTimestamp();$clients=@()
        foreach($item in $payloads){
            $i=$item.index;$letter=$mediumLetters[$i];$download=Join-Path $OutputRoot "parallel$i.bin"
            $clients+=Start-Transfer @("put $(Host-Path $item.source) /$letter/PAR$i.BIN","get /$letter/PAR$i.BIN $(Host-Path $download)","rm /$letter/PAR$i.BIN")
        }
        Send-Keys $session @('c','d')
        foreach($i in 0..1){
            $done=Complete-Transfer $clients[$i];$download=Join-Path $OutputRoot "parallel$i.bin"
            if((Get-FileHash -LiteralPath $download).Hash.ToLowerInvariant() -cne $payloads[$i].sha256){throw 'Parallel USB bytes differ.'}
            $parallel+=@{medium=$i;bytes=$payloads[$i].bytes;sha256=$payloads[$i].sha256;transfer=$done}
        }
        $parallelMs=([Diagnostics.Stopwatch]::GetTimestamp()-$started)*1000.0/[Diagnostics.Stopwatch]::Frequency
    }
    $workClock.Stop();$process.Refresh();$cpuAfter=$process.TotalProcessorTime.TotalSeconds
    $workAfter=Work-Snapshot;$workDelta=@{}
    foreach($key in $workBefore.Keys){$workDelta[$key]=$workAfter[$key]-$workBefore[$key];if($workDelta[$key] -lt 0){throw 'USB counters reset during fixed work.'}}
    if($workDelta.to -ne 0){throw 'Fixed USB work had a timeout.'}
    $work=[ordered]@{definition='2 media: cold payload get, guest COPY/get/delete, concurrent put/get/delete; each payload exactly256KB';payloadBytesPerMedium=256KB;media=2;completedFileOperations=14;hostTransferredBytes=2MB;guestCopyPayloadBytes=512KB;elapsedMilliseconds=$workClock.Elapsed.TotalMilliseconds;qemuCpuSeconds=($cpuAfter-$cpuBefore);counters=$workDelta;before=$workBefore;after=$workAfter;limits='QEMU CPU includes guest/services/emulation; wait loops/parks are quantities, ns includes blocked time. Host SSH/SFTP latency is not isolated hardware completion time.'}
    }
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'work-receipt.json'),(@{schema=1;kernelSha256=$kernelHash;actualBootKernelSha256=$bootHash;work=$work;media=$copies;parallel=$parallel}|ConvertTo-Json -Depth 12)+"`n",$utf8)
    $fallback=@{}
    if($Mode -ceq 'Multi' -and !$WorkOnly -and !$InputOnly){
        if($IrqFallback){
            $fallback=Set-ControllerFault $session -DisableInterrupts
            # Only the fault phase changes host caching. Real direct file I/O
            # makes delayed completions observable with controller INTE off.
            $null=Qmp $session 'blockdev-reopen' @{options=@(@{driver='file';'node-name'='media0-file';filename=(Join-Path $OutputRoot 'usb0.img');cache=@{direct=$true;'no-flush'=$false}})}
            $fallback.directHostIo=$true
            $beforeFallback=Work-Snapshot
            $download=Join-Path $OutputRoot 'fallback.bin'
            $fallbackClock=[Diagnostics.Stopwatch]::StartNew()
            $null=Sftp @("get /$($mediumLetters[0])/FALLBACK0.BIN $(Host-Path $download)") -TimeoutMilliseconds 60000
            if((Get-FileHash -LiteralPath $download).Hash.ToLowerInvariant() -cne (Get-FileHash -LiteralPath (Join-Path $OutputRoot 'UNREAD0.BIN')).Hash.ToLowerInvariant()){throw 'IRQ fallback returned wrong bytes.'}
            $fallback.bytes=4MB;$fallback.milliseconds=$fallbackClock.Elapsed.TotalMilliseconds;$fallback.countersBefore=$beforeFallback;$fallback.countersAfter=Work-Snapshot
            if($fallback.countersAfter.to -ne $beforeFallback.to){throw 'IRQ fallback timed out.'}
            if($fallback.countersAfter.fallbackwait -le $beforeFallback.fallbackwait){throw 'No delayed completion exercised the bounded wait fallback.'}
        }
        $null=Qmp $session 'device_del' @{id='mouse'};Await-Hid 0
        $keyboard=Input-Snapshot;Send-Keys $session @('e');$continued=Input-Snapshot
        if($continued.accepted -le $keyboard.accepted){throw 'Foreign mouse detach reset the keyboard.'}
        $null=Qmp $session 'device_add' @{driver='usb-mouse';id='mouse';bus='usb1.0';port='1'};Await-Hid 1
        $before=Input-Snapshot
        $null=Qmp $session 'input-send-event' @{events=@(@{type='rel';data=@{axis='x';value=7}})}
        $after=Input-Snapshot
        if($after.packets -le $before.packets){throw 'Reattached mouse is not usable.'}
        $oldLetter=$mediumLetters[0]
        $null=Qmp $session 'device_del' @{id='media0-usb'}
        Start-Sleep -Milliseconds 200
        $null=Qmp $session 'device_add' @{driver='usb-storage';id='media0-usb';drive='media0';bus='usb2.0';port='1'}
        $deadline=[DateTime]::UtcNow.AddSeconds(20);$newLetter=$null
        do {
            $current=Ssh 'SYSINFO'
            $new=@([regex]::Matches($current,'(?m)^\s*([A-Z]):\s+NTFS\s+general\s+usb\d+\b')|ForEach-Object {$_.Groups[1].Value}|Where-Object {$_ -notin $usbLetters})
            if($new.Count -eq 1){$newLetter=$new[0];break}
            Start-Sleep -Milliseconds 100
        }while([DateTime]::UtcNow -lt $deadline)
        if(!$newLetter){throw 'Reattached medium was not registered and mounted as a new exact identity.'}
        # Old mount/context must fail rather than selecting the replacement
        # at the same physical controller port and reused local slot.
        $stale=Start-Transfer @("get /$oldLetter/UNREAD0.BIN $(Host-Path (Join-Path $OutputRoot 'stale.bin'))")
        $staleResult=Complete-Transfer $stale -MustFail
        $download=Join-Path $OutputRoot 'reattached.bin';$null=Sftp @("get /$newLetter/PAYLOAD0.BIN $(Host-Path $download)")
        if((Get-FileHash -LiteralPath $download).Hash.ToLowerInvariant() -cne $payloads[0].sha256){throw 'Reattached medium bytes differ.'}
        $hotplug=@{mouseDetachedReattached=$true;foreignKeyboardPreserved=$true;mediumDetachedReattached=$true;oldLetter=$oldLetter;newLetter=$newLetter;staleMountRejected=$staleResult;newMediumHash=$payloads[0].sha256;parallelMilliseconds=$parallelMs}
        $fault=Set-ControllerFault $session
        $failed=Start-Transfer @("get /$newLetter/UNREAD0.BIN $(Host-Path (Join-Path $OutputRoot 'failed.bin'))")
        $otherLetter=$mediumLetters[1];$other=Join-Path $OutputRoot 'neighbor.bin'
        $null=Sftp @("put $(Host-Path $payloads[1].source) /$otherLetter/NEIGHBOR.BIN","get /$otherLetter/NEIGHBOR.BIN $(Host-Path $other)","rm /$otherLetter/NEIGHBOR.BIN") -TimeoutMilliseconds 60000
        if((Get-FileHash -LiteralPath $other).Hash.ToLowerInvariant() -cne $payloads[1].sha256){throw 'Neighbor failed during the isolated controller fault.'}
        $fault.failedRead=Complete-Transfer $failed -MustFail
        $before=Input-Snapshot;Send-Keys $session @('f')
        $null=Qmp $session 'input-send-event' @{events=@(@{type='rel';data=@{axis='x';value=5}})}
        $after=Input-Snapshot
        if($after.accepted -le $before.accepted -or $after.packets -le $before.packets){throw 'Controller fault affected foreign HID.'}
        $fault.neighborMediaHash=$payloads[1].sha256;$fault.foreignHidPreserved=$true
    }
    if(!$WorkOnly){
        $usbCheck=Ssh 'SPECTRA CHECK USB /JSON'
        if($usbCheck -match '"passed":false|"failed":[1-9]'){throw 'Existing USB owner cases failed.'}
    }
    # The guest can close SSH while draining services before ACPI poweroff.
    # Its actual clean QEMU exit is the terminal acknowledgement below.
    try{$null=Ssh 'POWEROFF'}catch{
        if($_.Exception.Message -notmatch 'Client failed \(255\)'){throw}
    }
    if(!$process.WaitForExit(30000) -or $process.ExitCode -ne 0){throw 'USB guest did not power off normally.'}
    $result=[ordered]@{schema=1;mode=$Mode;release=$release;kernelVersion=$kernelVersion;kernelSha256=$kernelHash;actualBootKernelSha256=$bootHash;cpus=4;controllersDetected=3;controllersStarted=$activeRows.Count;pciRecords=$controllerRows;ps2Disabled=$true;inputBefore=$beforeInput;inputAfter=$afterInput;media=$copies;parallel=$parallel;inputWork=$inputWork;inputLifetime=$inputLifetime;work=$work;workOnly=[bool]$WorkOnly;irqFallback=$fallback;hotplug=$hotplug;fault=$fault;normalShutdown=$true;seconds=$watch.Elapsed.TotalSeconds;scope='One bounded local KVM/SMP4 HID/two-media and PCI-diagnosis acceptance; no native-hardware qualification or general performance claim.'}
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'result.json'),($result|ConvertTo-Json -Depth 12)+"`n",$utf8)
    $success=$true
    Write-Host "USB $Mode PASS: $($activeRows.Count)/3 active controllers, real HID, two hash-verified media, regular shutdown."
} finally {
    foreach($client in $transferClients){$p=$client.process;if(!$p.HasExited){$p.Kill($true);$p.WaitForExit()};$p.Dispose()}
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
