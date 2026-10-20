# Disposable host test media; canonical profiles, inputs and STANDARD JSON
# remain with their owners. Paths must be explicit workspace descendants.
function Remove-R4TestDirectory([string]$Workspace,[string]$Path) {
 $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
 $workspaceRoot=[IO.Path]::GetFullPath($Workspace).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
 $full=[IO.Path]::GetFullPath($Path)
 if(!$full.StartsWith($workspaceRoot+[IO.Path]::DirectorySeparatorChar,$comparison)){throw 'Test cleanup target is outside the workspace.'}
 $parent=[IO.Path]::GetDirectoryName($full)
 while(!$parent.Equals($workspaceRoot,$comparison)){
  $parentItem=Get-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
  if($parentItem -and (!$parentItem.PSIsContainer -or ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint))){throw 'Linked parent in test cleanup target.'}
  $parent=[IO.Path]::GetDirectoryName($parent)
 }
 $item=Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
 if(!$item){return}
 if(!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Test cleanup target must be a real directory.'}
 # A failed/timed-out guest must release its images before any unlink.
 $pending=[Collections.Generic.Stack[IO.DirectoryInfo]]::new();$pending.Push($item)
 while($pending.Count){
  foreach($entry in $pending.Pop().EnumerateFileSystemInfos()){
   if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
   if($entry -is [IO.DirectoryInfo]){$pending.Push($entry)}
   elseif($entry.Extension -ieq '.img'){
    $probe=[IO.File]::Open($entry.FullName,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{$probe.Lock(0,[Math]::Max([long]1,$probe.Length))}finally{$probe.Dispose()}
   }
  }
 }
 Remove-R4TestItem $item
}
function Remove-R4TestItem([IO.FileSystemInfo]$Item) {
 if($Item.Attributes -band [IO.FileAttributes]::ReparsePoint){Remove-Item -LiteralPath $Item.FullName -Force;return}
 if($Item -is [IO.DirectoryInfo]){foreach($child in $Item.EnumerateFileSystemInfos()){Remove-R4TestItem $child}}
 if($Item.Attributes -band [IO.FileAttributes]::ReadOnly){$Item.Attributes=$Item.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)}
 $Item.Delete()
}
