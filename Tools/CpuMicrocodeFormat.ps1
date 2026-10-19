# Shared host-only CPU firmware construction and strict preload-tail checking.
function New-R4CpuMicrocodeAppendix([string]$Manifest=(Join-Path $PSScriptRoot '../Firmware/CPU/Manifest.json')) {
$manifestPath=[IO.Path]::GetFullPath($Manifest)
$base=Split-Path $manifestPath -Parent
$spec=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json -AsHashtable
if($spec.schema -ne 1 -or $spec.format -cne 'R4U0' -or $spec.firmware.Count -ne 2){throw 'Unsupported CPU firmware manifest.'}
$records=@($spec.firmware|Sort-Object id)
$payloads=[Collections.Generic.List[byte[]]]::new()
$offset=32+64*$records.Count
for($index=0;$index -lt $records.Count;$index++){
 $entry=$records[$index]
 if($entry.id -ne $index+1 -or $entry.vendor -ne $index+1 -or $entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
    $entry.bytes -lt 64 -or $entry.bytes -gt 131072 -or $entry.revision -le 0 -or $entry.minimum_revision -gt $entry.revision){throw 'Invalid exact CPU firmware identity.'}
 if($entry.path -cnotmatch '^(Intel|AMD)/[A-Za-z0-9_.-]+$' -or $entry.path.Contains('..')){throw 'CPU firmware must remain in its owner directory.'}
 $path=[IO.Path]::GetFullPath((Join-Path $base $entry.path))
 if(![IO.File]::Exists($path) -or ([IO.FileInfo]$path).Length -ne $entry.bytes){throw ('CPU firmware length differs: '+$entry.name)}
 $bytes=[IO.File]::ReadAllBytes($path)
 if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() -cne $entry.sha256){throw ('CPU firmware origin hash differs: '+$entry.name)}
 $payloads.Add($bytes);$offset+=$bytes.Length
}
if($offset -gt 262144){throw 'CPU firmware exceeds bounded preload appendix.'}
$image=[byte[]]::new($offset)
$stream=[IO.MemoryStream]::new($image,$true)
$writer=[IO.BinaryWriter]::new($stream)
try{
 $writer.Write([Text.Encoding]::ASCII.GetBytes('R4U0'));$writer.Write([uint16]1);$writer.Write([uint16]32)
 $writer.Write([uint32]$records.Count);$writer.Write([uint32]$image.Length);$writer.Write([uint32]64)
 $stream.Position=32;$offset=32+64*$records.Count
 for($index=0;$index -lt $records.Count;$index++){
  $entry=$records[$index]
  foreach($value in @($entry.vendor,$entry.id,$offset,$entry.bytes,$entry.signature,$entry.revision,$entry.minimum_revision,$entry.platform_mask)){$writer.Write([uint32]$value)}
  $writer.Write([Convert]::FromHexString($entry.sha256))
  [Array]::Copy($payloads[$index],0,$image,$offset,$payloads[$index].Length);$offset+=$payloads[$index].Length
 }
}finally{$writer.Dispose();$stream.Dispose()}
return ,$image
}
function Test-R4CpuMicrocodeAppendix([IO.Stream]$Stream,[long]$LegacyBytes) {
 if($LegacyBytes -lt 64 -or $LegacyBytes -gt $Stream.Length){throw 'Invalid legacy preload extent.'}
 if($LegacyBytes -eq $Stream.Length){return}
 $expected=New-R4CpuMicrocodeAppendix
 if($Stream.Length-$LegacyBytes -ne $expected.Length){throw 'Unrecognized CPU firmware appendix size.'}
 $actual=[byte[]]::new($expected.Length);$Stream.Position=$LegacyBytes;$Stream.ReadExactly($actual,0,$actual.Length)
 $actualHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($actual))
 $expectedHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($expected))
 if($actualHash -cne $expectedHash){throw 'CPU firmware appendix differs from its exact pinned owner data.'}
}
