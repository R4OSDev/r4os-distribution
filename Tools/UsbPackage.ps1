function New-R4UsbStarterBundle {
 param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Zig,
       [Parameter(Mandatory)][string]$Sdk,[Parameter(Mandatory)][string]$Destination)
 $ErrorActionPreference='Stop'
 [IO.Directory]::CreateDirectory($Destination)|Out-Null
 foreach($path in @('CreateUSB.ps1','CreateUSB.bat','CreateUSB.sh','Tools/Usb.ps1','Tools/UsbHost.cs','Tools/InstallationImage.Check.cs','Tools/InstallationImage.Check.ps1')){
  $target=Join-Path $Destination $path;[IO.Directory]::CreateDirectory((Split-Path $target -Parent))|Out-Null
  Copy-Item -LiteralPath (Join-Path $Root $path) -Destination $target -Force
 }
 foreach($hostTarget in @(@{name='linux-x86_64';target='x86_64-linux-musl';suffix=''},@{name='windows-x86_64';target='x86_64-windows';suffix='.exe'})){
  $output=Join-Path $Destination "Tools/USB/$($hostTarget.name)/imagecreater$($hostTarget.suffix)"
  [IO.Directory]::CreateDirectory((Split-Path $output -Parent))|Out-Null
  & $Zig build-exe -OReleaseSafe -target $hostTarget.target --dep storage_tools "-Mroot=$(Join-Path $Root 'Tools/ImageCreator/src/main.zig')" "-Mstorage_tools=$(Join-Path $Sdk 'r4os/storage_tools.zig')" "-femit-bin=$output"
  if($LASTEXITCODE -ne 0){throw "USB-Werkzeugbau fehlgeschlagen: $($hostTarget.name)"}
  foreach($extension in @('.pdb','.obj','.o')){if(Test-Path ($output+$extension)){Remove-Item -LiteralPath ($output+$extension) -Force}}
 }
 if($IsLinux){& chmod +x -- (Join-Path $Destination 'CreateUSB.sh');if($LASTEXITCODE -ne 0){throw 'USB-Starter konnte nicht ausfuehrbar gesetzt werden.'}}
 return $Destination
}
