# Canonical profile images are never an interactive guest's writable disk.
if(-not ('R4OS.Distribution.QemuMediaCopy' -as [type])){
 Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace R4OS.Distribution {
 public static class QemuMediaCopy {
  [DllImport("kernel32.dll", SetLastError=true)]
  private static extern bool DeviceIoControl(SafeFileHandle file, uint code,
   IntPtr input, uint inputBytes, IntPtr output, uint outputBytes,
   out uint returned, IntPtr overlapped);
  public static void Copy(FileStream source, FileStream destination) {
   // Linux creates holes through seek; Windows first needs FSCTL_SET_SPARSE.
   // Filesystems without sparse support keep the previous ordinary copy.
   if (OperatingSystem.IsWindows() && !DeviceIoControl(destination.SafeFileHandle,
       0x000900C4, IntPtr.Zero, 0, IntPtr.Zero, 0, out _, IntPtr.Zero)) {
    source.CopyTo(destination);
    return;
   }
   var buffer = new byte[1024 * 1024];
   int count;
   while ((count = source.Read(buffer, 0, buffer.Length)) != 0) {
    if (buffer.AsSpan(0, count).IndexOfAnyExcept((byte)0) < 0)
     destination.Seek(count, SeekOrigin.Current);
    else destination.Write(buffer, 0, count);
   }
   // A trailing hole must retain the exact logical disk length.
   destination.SetLength(destination.Position);
  }
 }
}
'@
}
function New-R4QemuMedia {
 param([Parameter(Mandatory)][string]$SourceRoot,[ValidateSet('Fresh','Persistent')][string]$Mode='Fresh',[string]$Name='run')
 $ErrorActionPreference='Stop'
 if($Name -cnotmatch '^[a-zA-Z0-9_-]+$'){throw 'Invalid QEMU run name.'}
 $SourceRoot=[IO.Path]::GetFullPath($SourceRoot);$source=Join-Path $SourceRoot 'disk.img'
 $digest=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
 $imageRecord=Get-Content -Raw -LiteralPath (Join-Path $SourceRoot 'image.json')|ConvertFrom-Json -AsHashtable
 if($imageRecord.sha256 -cne $digest){throw 'Canonical profile image was modified; rebuild it before creating a guest work copy.'}
 $directory=if($Mode -ceq 'Persistent'){Join-Path $SourceRoot "Interactive/$digest"}else{Join-Path $SourceRoot "Runs/$Name"}
 [IO.Directory]::CreateDirectory($directory)|Out-Null
 $target=Join-Path $directory 'disk.img';$stamp=Join-Path $directory 'source.json'
 if($Mode -ceq 'Fresh' -or !(Test-Path -LiteralPath $target -PathType Leaf)){
  # Replace a file only after taking a host lock, so an active guest cannot
  # silently lose its disk if another run is launched with the same name.
  $inputFile=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  $outputFile=$null
  try{
   $outputFile=[IO.File]::Open($target,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
   # FileStream's share check is mandatory on Windows; Linux also honors
   # the fcntl/share lock used by .NET. QEMU's own image lock is checked by
   # a nonblocking platform file lock before any length or payload change.
   $outputFile.Lock(0,[Math]::Max([long]1,$outputFile.Length))
   $outputFile.SetLength(0);[R4OS.Distribution.QemuMediaCopy]::Copy($inputFile,$outputFile);$outputFile.Flush($true)
  }finally{if($outputFile){$outputFile.Dispose()};$inputFile.Dispose()}
  if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $digest){throw 'QEMU work copy differs from its source.'}
  [IO.File]::WriteAllText($stamp,((@{schema=1;sourceSha256=$digest;mode=$Mode}|ConvertTo-Json)+"`n"),[Text.UTF8Encoding]::new($false))
 }else{
  $saved=Get-Content -Raw -LiteralPath $stamp|ConvertFrom-Json -AsHashtable
  if($saved.sourceSha256 -cne $digest -or $saved.mode -cne 'Persistent'){throw 'Interactive image provenance differs.'}
 }
 Write-Host "QEMU $Mode working disk: $target (source $digest)"
 return $directory
}
