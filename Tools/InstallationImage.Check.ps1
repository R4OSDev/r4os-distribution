function Test-R4OSInstallationImage {
    param([Parameter(Mandatory)][string]$Image,[ValidateSet('local','usb')][string]$Medium='local',
          [switch]$AllowNonstandardSystem,[switch]$PreservedMenu)
    if(!('InstallationImageCheck' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'InstallationImage.Check.cs')}
    $imageCheck=[InstallationImageCheck]::new($Image,[bool]$AllowNonstandardSystem)
    try {
        $utf8=[Text.UTF8Encoding]::new($false,$true)
        $boot=$imageCheck.Volumes['BOOT'];$recovery=$imageCheck.Volumes['RECOVERY']
        $manifest=$utf8.GetString($boot.ReadFile('boot/r4os-installation.json'))|ConvertFrom-Json -AsHashtable
        if($manifest.schema -ne 1 -or $manifest.logicalSectorBytes -ne 512 -or $manifest.diskGuid -cne $imageCheck.DiskGuid -or $manifest.partitions.Count -ne 5){throw 'Installation description header differs from the image.'}
        $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $null=$ids.Add($imageCheck.DiskGuid)
        foreach($part in $imageCheck.Partitions.Values) {
            $record=$manifest.partitions[$part.Role]
            if($record.partitionGuid -cne $part.Guid -or $record.typeGuid -cne $part.Type -or $record.firstLba -ne $part.First -or $record.sectorCount -ne $part.Count){throw "Installation description differs from GPT: $($part.Role)"}
            if(!$ids.Add($part.Guid)){throw 'Duplicate physical identity.'}
        }
        if([Guid]$manifest.installationId -eq [Guid]::Empty -or !$ids.Add($manifest.installationId)){throw 'Invalid installation ID.'}
        $config=$utf8.GetString($boot.ReadFile('boot/limine.conf'))
        $default=if($Medium -eq 'local'){1}else{2}
        if(!$PreservedMenu -and ($config -cnotmatch "^timeout: 5`ndefault_entry: $default`n" -or
            (@([regex]::Matches($config,'(?m)^/[^\r\n]+')).Value -join '|') -cne '/R4OS|/R4OS Recovery|/R4OS Recovery Previous')){throw 'Limine menu/default differs.'}
        $bootGuid=$manifest.partitions.BOOT.partitionGuid;$recoveryGuid=$manifest.partitions.RECOVERY.partitionGuid
        $paths=@([regex]::Matches($config,'(?m)^    (?:module_)?path: guid\(([^)]+)\):/([^\r\n]+)$'))
        $expected=@('boot/r4os.elf','boot/preload.r4i','boot/preload/hidreport.r4p','boot/preload/usbhid.r4p','boot/preload/usbbot.r4p','boot/preload/usbscsi.r4p','CURRENT/recovery.elf','CURRENT/runtime.img','PREVIOUS/recovery.elf','PREVIOUS/runtime.img')
        if($paths.Count -ne $expected.Count){throw 'Unexpected Limine file references.'}
        for($i=0;$i -lt $paths.Count;$i++) {
            if($paths[$i].Groups[1].Value -cne $(if($i -lt 6){$bootGuid}else{$recoveryGuid}) -or $paths[$i].Groups[2].Value -cne $expected[$i]){throw 'Limine reference differs from the physical installation.'}
        }
        $required=@('boot/r4os.elf','boot/preload.r4i','boot/preload/hidreport.r4p','boot/preload/usbhid.r4p','boot/preload/usbbot.r4p','boot/preload/usbscsi.r4p','boot/limine-bios.sys','EFI/BOOT/BOOTX64.EFI')
        if((@($manifest.bootFiles|Sort-Object -CaseSensitive) -join '|') -cne (@($required|Sort-Object -CaseSensitive) -join '|')){throw 'Managed BOOT file list differs.'}
        $bootHashes=[ordered]@{}
        foreach($path in $required){$bytes=$boot.ReadFile($path);if($bytes.Length -eq 0){throw "Empty BOOT file: $path"};$bootHashes[$path]=[InstallationImageCheck]::Hash($bytes)}
        if([InstallationImageCheck]::KernelVersion($boot.ReadFile('boot/r4os.elf')) -cne $manifest.kernelVersion){throw 'Normal kernel artifact and installation version differ.'}
        $slotManifest=$recovery.ReadFile('CURRENT/manifest.json')
        if([InstallationImageCheck]::Hash($slotManifest) -cne [InstallationImageCheck]::Hash($recovery.ReadFile('PREVIOUS/manifest.json'))){throw 'Initial Recovery manifests differ.'}
        $package=$utf8.GetString($slotManifest)|ConvertFrom-Json -AsHashtable
        if($package.schema -ne 1 -or $package.product -cne 'r4os-recovery' -or $package.architecture -cne 'x86_64'){throw 'Recovery package contract differs.'}
        foreach($slot in @('CURRENT','PREVIOUS')) {
            $expectedFiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $null=$expectedFiles.Add("$slot/manifest.json")
            foreach($file in $package.files) {
                $path="$slot/$($file.path)"
                if(!$expectedFiles.Add($path)){throw 'Duplicate Recovery package file.'}
                $bytes=$recovery.ReadFile($path)
                if($bytes.LongLength -ne $file.bytes -or [InstallationImageCheck]::Hash($bytes) -cne $file.sha256){throw "Installed Recovery file differs: $path"}
            }
            $actual=@($recovery.Paths()|Where-Object {$_.StartsWith("$slot/",[StringComparison]::OrdinalIgnoreCase)})
            if($actual.Count -ne $expectedFiles.Count){throw 'Extra installed Recovery file.'}
            if([InstallationImageCheck]::KernelVersion($recovery.ReadFile("$slot/recovery.elf")) -cne $package.recoveryKernelVersion){throw 'Recovery kernel artifact and manifest version differ.'}
        }
        return [ordered]@{schema=1;bytes=$imageCheck.Bytes;installation=$manifest;medium=$Medium;bootHashes=$bootHashes;
            recoveryVersion=$package.recoveryVersion;recoveryManifestSha256=[InstallationImageCheck]::Hash($slotManifest);
            bootFreeBytes=$boot.FreeBytes;recoveryFreeBytes=$recovery.FreeBytes;physicalStructure='verified'}
    }finally{$imageCheck.Dispose()}
}
