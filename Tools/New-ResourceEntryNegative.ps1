<#
Build RSRCBAD from an ordinary SDK-built resource-positive R4X.
SDK Smoke/Resources owns the existing four deterministic resource files.
The sole corruption selects its non-allocated resource section as entry.
Use a new temporary OutputFile; qualify the positive and exact loader error
before replacing TestInjection/Temp/RSRCBAD.R4X. This is no runtime probe.
#>
param([Parameter(Mandatory)][string]$InputFile,[Parameter(Mandatory)][string]$OutputFile)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$inputPath=[IO.Path]::GetFullPath($InputFile,$root)
$outputPath=[IO.Path]::GetFullPath($OutputFile,$root)
$bytes=[IO.File]::ReadAllBytes($inputPath)
if(!$([BitConverter]::IsLittleEndian) -or $bytes.Length -lt 64 -or [Text.Encoding]::ASCII.GetString($bytes,0,4) -cne 'R4M0' -or [BitConverter]::ToUInt16($bytes,4) -ne 1 -or [BitConverter]::ToUInt16($bytes,6) -ne 1 -or [BitConverter]::ToUInt16($bytes,8) -ne 1 -or [BitConverter]::ToUInt16($bytes,10) -ne 64){throw 'Expected ordinary x86_64 R4X container'}
function U32([int]$At){if($At -lt 0 -or $At -gt $bytes.Length-4){throw 'Record outside container'};[BitConverter]::ToUInt32($bytes,$At)}
function Range([uint64]$At,[uint64]$Length){if($At -gt $bytes.Length -or $Length -gt $bytes.Length-$At){throw 'Record outside container'}}
$strings=U32 56;$stringBytes=U32 60;Range $strings $stringBytes
function Name([uint32]$At){
 if($At -lt $strings -or $At -ge [uint64]$strings+$stringBytes){throw 'Name outside string area'}
 $end=[Array]::IndexOf($bytes,[byte]0,[int]$At,[int]([uint64]$strings+$stringBytes-$At))
 if($end -lt 0){throw 'Unterminated name'}
 [Text.UTF8Encoding]::new($false,$true).GetString($bytes,[int]$At,$end-[int]$At)
}
$offset=U32 24;$count=U32 28;Range $offset ([uint64]$count*16)
$central=@('R4SYS','R4DESK','R4DRAW','R4NET','R4AUDIO','R4DEV');$platform=0
for($i=0;$i -lt $count;$i++){
 $at=$offset+$i*16;$module=Name (U32 $at);$symbol=Name (U32 ($at+4));$version=U32 ($at+8)
 if($module -cin $central){if($symbol -cne 'Query2' -or $version -ne 2){throw 'Legacy platform import in positive scaffold'};$platform++}
}
if(!$platform){throw 'Missing real platform2 scaffold'}
$offset=U32 32;$count=U32 36;Range $offset ([uint64]$count*16);$start=$false
for($i=0;$i -lt $count;$i++){
 $at=$offset+$i*16;$symbol=Name (U32 $at);$version=U32 ($at+12)
 if($symbol -ceq 'R4XStart2' -and $version -eq 2){$start=$true}
 if($symbol -ceq 'R4XStart'){throw 'Legacy positive start export'}
}
if(!$start){throw 'Missing ordinary Start2 export'}
$sectionOffset=U32 16;$sections=U32 20;Range $sectionOffset ([uint64]$sections*32)
$resource=-1
for($i=0;$i -lt $sections;$i++){
 $at=$sectionOffset+$i*32;$name=[Text.Encoding]::ASCII.GetString($bytes,[int]$at,8).TrimEnd([char]0)
 if($name -ceq '.rsrc'){
  if($resource -ne -1 -or (U32 ($at+8)) -ne 0 -or (U32 ($at+16)) -eq 0){throw 'Expected one non-allocated resource section'}
  Range (U32 ($at+12)) (U32 ($at+16));$resource=$i
 }
}
$entry=U32 48
if($resource -lt 0 -or (U32 52) -ne 1){throw 'Expected one entry and a resource section'}
Range $entry 16
$original=U32 ($entry+4)
if((U32 $entry) -ne 1 -or $original -ge $sections -or $original -eq $resource -or ((U32 ($sectionOffset+$original*32+8)) -band 3) -ne 3){throw 'Positive entry must point at executable allocated code'}
$positiveHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
[Array]::Copy([BitConverter]::GetBytes([uint32]$resource),0,$bytes,[int]$entry+4,4)
$stream=[IO.File]::Open($outputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$stream.Write($bytes)}finally{$stream.Dispose()}
[ordered]@{input_sha256=$positiveHash;output_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant();mutated_u32_offset=$entry+4;old_entry_section=$original;new_entry_section=$resource;bytes=$bytes.Length;expected_error='Invalid R4M0 entry section';scope='Only entry.section changed; complete original resources, imports, relocations, exports and executable bytes retained. Actual positive start and exact native rejection remain separate.'}|ConvertTo-Json
