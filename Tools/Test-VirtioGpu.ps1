# Explicit bounded integration probe; never invoked by ordinary build/test.
param([ValidateSet('all','probe','native','timeout','fallback','nvidia-passive')][string]$Variant='all')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$distribution=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Distribution.ps1')
$context=Get-R4DistributionContext $distribution
$workspace=$context.workspace
$nvidia=$Variant -eq 'nvidia-passive'
$driverName=if($nvidia){'NVIDIA'}else{'VIRTGPU'}
if($Variant -eq 'all'){
    foreach($part in @('native','timeout','fallback')){& $PSCommandPath -Variant $part}
    return
}
$scratch=Join-Path $workspace ('Temp/gfx-virtio/'+$Variant)
$null=New-Item -ItemType Directory -Force $scratch
$output=Join-Path $context.output ('Technical/virtio-gpu-'+$Variant)
$starter=Join-Path $distribution $(if($IsWindows){'Build.bat'}else{'Build.sh'})
$autoexec=Join-Path $scratch 'AUTOEXEC.BAT'
 $lines=@('@ECHO OFF','VER','C:\R4OS\SOFTWARE\TERMINAL\DIAG\DISPLAYD.R4X /STATE')
 if($Variant -eq 'native'){$lines+='C:\R4OS\SOFTWARE\TERMINAL\DIAG\DISPLAYD.R4X /VIRTIO /RESIZE'}
 if($Variant -eq 'timeout'){$lines+='C:\R4OS\SOFTWARE\TERMINAL\DIAG\DISPLAYD.R4X /VIRTIO /FAIL'}
 $driverReport=if($nvidia){'/NVIDIA'}else{'/VIRTIO'}
 $lines+=@('C:\R4OS\SOFTWARE\TERMINAL\DIAG\DISPLAYD.R4X','SET',"C:\R4OS\SOFTWARE\TERMINAL\DIAG\DISPLAYD.R4X $driverReport",'ECHO [GFX07908] complete','POWEROFF')
 [IO.File]::WriteAllText($autoexec,(($lines -join "`r`n")+"`r`n"),[Text.UTF8Encoding]::new($false))
 & $starter plan Test
 if($LASTEXITCODE -ne 0){throw "Plan failed: $LASTEXITCODE"}
 $catalog=Join-Path $context.sdk ('zig-out/bin/module-catalog'+$context.suffix)
 $regular=Get-Content -Raw (Join-Path $context.output 'Generated/MODULES.JSON')|ConvertFrom-Json
 $target="/R4OS/DRIVERS/$driverName.R4D"
 $privateInventory=Join-Path $scratch "MODULES-$Variant.JSON"
 $extraPlan=Join-Path $scratch "components-$Variant.plan"
 $map=Join-Path $context.input 'WorkspaceModules.map'
 $selection=@('workspace-image-plan','--workspace-map',$map,'--image-mode','test',
     '--output',$extraPlan,'--inventory-output',$privateInventory,'--kernel-version-source',(Join-Path $context.repositories 'Kernel/VERSION.R4S'),
     '--kernel-artifact',(Join-Path $context.repositories 'Kernel/zig-out/bin/r4os.elf'),'--include-target',$target)
 & $catalog @selection
 if($LASTEXITCODE -ne 0){throw 'Private Virtio catalog failed'}
 $base=Get-Content -Raw $privateInventory|ConvertFrom-Json
 foreach($entry in $regular.entries){
     if($entry.kind -ne 'KERNEL' -and $entry.target -notin $base.entries.target){$selection+=@('--include-target',$entry.target)}
 }
 & $catalog @selection
 if($LASTEXITCODE -ne 0){throw 'Private Virtio catalog with regular Test includes failed'}
 $final=Get-Content -Raw $privateInventory|ConvertFrom-Json
 if(@(Compare-Object (@($regular.entries.target)+$target|Sort-Object -Unique) ($final.entries.target|Sort-Object -Unique)).Count){throw 'Unexpected private selection'}
 $extra=@(Get-Content $extraPlan|Where-Object {$_.EndsWith(':'+$target,[StringComparison]::OrdinalIgnoreCase)})
 if($extra.Count -ne 1){throw 'Expected canonical Virtio GPU artifact'}
 $config=(Get-Content -Raw (Join-Path $distribution 'TestInjection/CONFIG.R4S')) -replace '(?m)^SHELL=.*','SHELL=/R4OS/SOFTWARE/TERMINAL/TERMINAL.R4X' -replace '(?m)^SHELL_ARGS=.*','SHELL_ARGS='
 $config=$config -replace '(?m)^OPTION SMP selftest=yes\r?\n','' -replace '(?m)^DRIVER=(DISPBLIT|EXAMPLE)\r?\n',''
 $driverMode=if($nvidia){'passive'}elseif($Variant -eq 'probe'){'probe'}elseif($Variant -eq 'timeout'){'timeout'}else{'native'}
 $config+="`nDRIVER=$driverName`nOPTION $driverName mode=$driverMode`nGRAPHICS=AUTO`n"
 $configPath=Join-Path $scratch "CONFIG-$Variant.R4S"
 [IO.File]::WriteAllText($configPath,$config,[Text.UTF8Encoding]::new($true))
 $plan=@(Get-Content (Join-Path $context.output 'Profiles/Test/image-adds.txt')|ForEach-Object {
     if($_.EndsWith(':/AUTOEXEC.BAT',[StringComparison]::OrdinalIgnoreCase)){$autoexec.Replace('\','/')+':/AUTOEXEC.BAT'}
     elseif($_.EndsWith(':/CONFIG.R4S',[StringComparison]::OrdinalIgnoreCase)){$configPath.Replace('\','/')+':/CONFIG.R4S'}
     elseif($_.EndsWith(':/R4OS/CONFIG/MODULES.JSON',[StringComparison]::OrdinalIgnoreCase)){$privateInventory.Replace('\','/')+':/R4OS/CONFIG/MODULES.JSON'}
     else{$_}
 })
 $plan+=$extra
 $planPath=Join-Path $scratch "image-adds-$Variant.txt"
 [IO.File]::WriteAllLines($planPath,$plan,[Text.UTF8Encoding]::new($false))
 & $starter image Test -InputList $planPath -OutputRoot $output
 if($LASTEXITCODE -ne 0){throw "Image failed: $LASTEXITCODE"}
. (Join-Path $distribution 'Tools/Qemu-Media.ps1')
. (Join-Path $distribution 'Tools/Qemu-HostProfile.ps1')
$profile=Resolve-R4QemuHostProfile $context.qemu
$media=New-R4QemuMedia -SourceRoot $output -Mode Fresh -Name 'gfx-virtio'
$serialPath=Join-Path $scratch "qemu-$Variant.log"
[IO.File]::WriteAllText($serialPath,'',[Text.UTF8Encoding]::new($false))
function Read-Serial {
    $stream=[IO.File]::Open($serialPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try{$reader=[IO.StreamReader]::new($stream);try{return $reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$stream.Dispose()}
}
$start=[Diagnostics.ProcessStartInfo]::new($context.qemu)
$start.UseShellExecute=$false;$start.RedirectStandardError=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.WorkingDirectory=$media
$arguments=@('-readconfig',(Join-Path $distribution 'QEMU/standard.conf'),'-cpu',$profile.CpuModel,'-m','1G','-smp','4','-machine',('accel='+$profile.AcceleratorChain),
    '-audiodev','driver=none,id=headless-audio','-global','hda-duplex.audiodev=headless-audio','-serial',('file:'+$serialPath),'-display','none','-monitor','none','-qmp','stdio','-no-reboot','-nic','none','-name',"R4OS virtio-gpu-$Variant SMP4")
if($Variant -ne 'fallback' -and !$nvidia){$arguments+=@('-vga','none','-readconfig',(Join-Path $distribution 'QEMU/virtio-gpu.conf'))}
$vnc=$null
if($Variant -eq 'native'){
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start();$vncPort=$listener.LocalEndpoint.Port;$listener.Stop()
    $arguments+=@('-vnc',('127.0.0.1:'+($vncPort-5900)))
}
foreach($argument in $arguments){$start.ArgumentList.Add($argument)}
$qemu=[Diagnostics.Process]::Start($start);$errors=$qemu.StandardError.ReadToEndAsync()
$clock=[Diagnostics.Stopwatch]::StartNew()
$proof=[ordered]@{variant=$Variant;cpus=4;host=$profile.Name;realHardware=$false;elapsedSeconds=$null;passed=$false;captures=@()}
$script:qmpCounter=0
function Read-Vnc([int]$Count) {
    $data=[byte[]]::new($Count);$offset=0
    while($offset -lt $Count){
        $got=$vnc.GetStream().Read($data,$offset,$Count-$offset)
        if($got -le 0){throw 'VNC connection closed'}
        $offset+=$got
    }
    return ,$data
}
function Open-Vnc {
    $script:vnc=[Net.Sockets.TcpClient]::new()
    $vnc.ReceiveTimeout=3000;$vnc.SendTimeout=3000;$vnc.Connect('127.0.0.1',$vncPort)
    $banner=Read-Vnc 12
    if([Text.Encoding]::ASCII.GetString($banner) -cne "RFB 003.008`n"){throw 'Unexpected RFB version'}
    $vnc.GetStream().Write($banner)
    $count=Read-Vnc 1;$security=Read-Vnc $count[0]
    if(1 -notin $security){throw 'Expected local RFB no-auth transport'}
    $vnc.GetStream().Write([byte[]]@(1))
    $result=Read-Vnc 4
    if(@($result|Where-Object {$_ -ne 0}).Count){throw 'RFB negotiation rejected'}
    $vnc.GetStream().Write([byte[]]@(1))
    $server=Read-Vnc 24
    $length=([int]$server[20] -shl 24) -bor ([int]$server[21] -shl 16) -bor ([int]$server[22] -shl 8) -bor $server[23]
    if($length -gt 4096){throw 'RFB name limit'}
    $null=Read-Vnc $length
    $vnc.GetStream().Write([byte[]]@(2,0,0,1,255,255,254,204)) # ExtendedDesktopSize (-308).
}
function Set-VncSize([int]$Width,[int]$Height) {
    if($null -eq $vnc){Open-Vnc}
    # RFB SetDesktopSize, one screen, all multi-byte fields in network order.
    $data=[byte[]]::new(24);$data[0]=251;$data[6]=1
    foreach($pair in @(@(2,$Width),@(4,$Height),@(16,$Width),@(18,$Height))){
        $data[$pair[0]]=[byte]($pair[1] -shr 8);$data[$pair[0]+1]=[byte]($pair[1] -band 255)
    }
    $vnc.GetStream().Write($data)
}
function Invoke-Qmp([string]$Execute,[hashtable]$Arguments=@{}) {
    $script:qmpCounter++
    $request=@{execute=$Execute;arguments=$Arguments;id=$script:qmpCounter}
    $qemu.StandardInput.WriteLine(($request|ConvertTo-Json -Depth 8 -Compress));$qemu.StandardInput.Flush()
    for($attempt=0;$attempt -lt 64;$attempt++){
        $line=$qemu.StandardOutput.ReadLineAsync().WaitAsync([TimeSpan]::FromSeconds(10)).GetAwaiter().GetResult()
        if(-not $line){throw 'QMP closed'}
        $reply=$line|ConvertFrom-Json -AsHashtable
        if($reply.ContainsKey('error')){throw ($reply|ConvertTo-Json -Compress)}
        if($reply.ContainsKey('id') -and $reply.id -eq $script:qmpCounter){return $reply['return']}
    }
    throw 'QMP reply limit'
}
function Test-Screen([string]$Path,[int]$Phase) {
    $bytes=[IO.File]::ReadAllBytes($Path)
    $prefix=[Text.Encoding]::ASCII.GetString($bytes,0,[Math]::Min(80,$bytes.Length))
    $match=[regex]::Match($prefix,'\AP6\s+(\d+)\s+(\d+)\s+255\n')
    if(-not $match.Success){throw 'Unexpected QEMU PPM header'}
    $width=[int]$match.Groups[1].Value;$height=[int]$match.Groups[2].Value;$header=$match.Length
    if($width -ne 1280 -or $height -ne 720 -or $bytes.Length -ne $header+$width*$height*3){throw 'Unexpected captured mode'}
    $areas=@(@([int]($width/4),[int]($height/4),128,96),@([int]($width/2),[int]($height/2),64,64))
    $colors=if($Phase -eq 1){@(0xE07030,0x3060D0)}else{@(0x30B070,0xB03090)}
    $checked=0
    for($area=0;$area -lt $areas.Count;$area++){
        $rect=$areas[$area];$color=$colors[$area]
        for($y=$rect[1];$y -lt $rect[1]+$rect[3];$y++){
            for($x=$rect[0];$x -lt $rect[0]+$rect[2];$x++){
                $offset=$header+($y*$width+$x)*3
                $actual=([int]$bytes[$offset] -shl 16) -bor ([int]$bytes[$offset+1] -shl 8) -bor $bytes[$offset+2]
                if($actual -ne $color){throw "Wrong captured pixel phase=$Phase x=$x y=$y expected=$color actual=$actual"}
                $checked++
            }
        }
    }
    return @{phase=$Phase;file=$Path;width=$width;height=$height;verifiedPixels=$checked;sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()}
}
try{
    $greeting=$qemu.StandardOutput.ReadLineAsync().WaitAsync([TimeSpan]::FromSeconds(10)).GetAwaiter().GetResult()
    if($greeting -notmatch 'QMP'){throw 'Missing QMP greeting'}
    $null=Invoke-Qmp qmp_capabilities
    Write-Host "SMP4 graphics: $Variant, $($profile.Name), explicit fresh medium"
    while(-not $qemu.HasExited -and $clock.Elapsed.TotalSeconds -lt 90){
        $serial=Read-Serial
        if($serial -match '\[CRASH\]|\[PANIC\]'){throw 'Guest crash'}
        if($Variant -eq 'native'){
            foreach($phase in @(1,2)){
                if($serial.Contains("[GFX07908] screen=$phase") -and $phase -notin @($proof.captures|ForEach-Object {$_.phase})){
                    $capture=Join-Path $scratch "screen-$Variant-$phase.ppm"
                    $null=Invoke-Qmp screendump @{filename=$capture;format='ppm'}
                    $proof.captures+=Test-Screen $capture $phase
                    Write-Host "QEMU scanout phase ${phase}: 16384 pixels verified"
                    if($phase -eq 1){Set-VncSize 1600 900}else{Set-VncSize 1280 720}
                }
            }
        }
        Start-Sleep -Milliseconds 100
    }
    if(-not $qemu.HasExited){throw 'Guest exceeded 90 seconds'}
    if($qemu.ExitCode -ne 0){throw "QEMU failed: $($qemu.ExitCode)"}
    $serial=Read-Serial
    foreach($marker in @('DISPLAYD result: OK','[GFX07908] complete','System poweroff.')){if(-not $serial.Contains($marker)){throw "Missing proof: $marker"}}
    if($Variant -eq 'probe' -and -not $serial.Contains('VIRTGPU transport probe: OK')){throw 'Missing Virtio transport proof'}
    if($Variant -eq 'native' -and (-not $serial.Contains('DISPLAYD virtio frames: OK') -or -not $serial.Contains('VIRTGPU frame=32') -or $proof.captures.Count -ne 2)){throw 'Missing native display/BO reuse proof'}
    if($Variant -eq 'native' -and ([regex]::Matches($serial,'DISPLAYD virtio resize: OK').Count -ne 2 -or -not $serial.Contains('host-request=1600x900') -or -not $serial.Contains('host-request=1280x720'))){throw 'Missing live host resize/idle IRQ proof'}
    if($Variant -eq 'native' -and -not $serial.Contains('completion=device-execution bytes=11993088')){throw 'Sparse 32-frame upload unexpectedly copied a whole surface'}
    if($Variant -eq 'timeout' -and -not $serial.Contains('DISPLAYD virtio recovery: OK')){throw 'Missing timeout/reset/fallback proof'}
    if($Variant -eq 'fallback' -and -not $serial.Contains('VIRTGPU native: error=NotFound')){throw 'Missing absent-device proof'}
    if($nvidia){
        foreach($marker in @('NVIDIA bind: absent inventory=canonical native-writes=disabled fallback=preserved',
            'NVIDIA unbind: OK resources=0 native-writes=disabled fallback=preserved',
            'DISPLAYD nvidia: records=available source=boot-log hardware-acceptance=separate',
            'DISPLAYD state: OK state=bootfb')){
            if(!$serial.Contains($marker)){throw "Missing passive NVIDIA proof: $marker"}
        }
    }
    if($serial -match 'DISPLAYD.*FAILED|\[PANIC\]|\[CRASH\]|General Protection Fault|Page Fault|resources=quarantined'){throw 'Guest failure'}
    $proof.passed=$true
}finally{
    if($null -ne $vnc){$vnc.Dispose()}
    if(-not $qemu.HasExited){$qemu.Kill();$qemu.WaitForExit()}
    [IO.File]::WriteAllText((Join-Path $scratch "qemu-$Variant.err"),$errors.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
    $proof.elapsedSeconds=[Math]::Round($clock.Elapsed.TotalSeconds,2)
    [IO.File]::WriteAllText((Join-Path $scratch "qemu-$Variant.json"),($proof|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
    $qemu.Dispose()
}
$proof|ConvertTo-Json
