# Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
# Product selection only. module.R4MF owns every version and installation path.
function Get-GraphicsPackageProfile {
 param([ValidateSet('nvidia','amd')][string]$Vendor)
 $amd=$Vendor -ieq 'amd'
 $groups=[ordered]@{
  platform=@('SYSUPD','UPDSVC')
  preload=@('HIDREPORT','USBHID','USBBOT','USBSCSI','XHCI','USBMSC','AHCI','NVME','ATAPIO')
  core=if($amd){@('R4STD','R4IMG','AMDGPU','R4AMD','R4GFX','HDA','DISPBLIT','ACPIPLAT')}else{@('R4STD','R4IMG','NVIDIA','R4NV','R4GFX','HDA','DISPBLIT')}
  api=if($amd){@('R4ACO','R4VK','R4GL')}else{@('R4NAK','R4VK','R4GL')}
  video=@('R4VIDEO','R4ENC')
  desktop=@('R4DESK','WINSVC','AUDSVC','APPEARANCE','DEVMGR','DISPLAYD','RDPSVC','R4TLS','R4AUTH')
 }
 $legal=@{
  preload=@()
  core=@('libdisplay-info-MIT.txt','LITTLECMS-LICENSE.txt','stb_image-MIT.txt')
  api=@('R4NAK-NOTICES.txt','R4ACO-NOTICES.txt','R4VK-NOTICES.txt','R4GL-NOTICES.txt','NATIVE-MATH-NOTICES.txt','NATIVE-SCAN-NOTICES.txt')
  video=@('R4AMD-NOTICES.txt','R4VIDEO-NOTICES.txt','FFmpeg-LGPL-2.1.txt','R4ENC-NOTICES.txt','OpenH264-BSD-2-Clause.txt','NATIVE-MATH-NOTICES.txt','NATIVE-SCAN-NOTICES.txt')
  desktop=@()
 }
 if($amd){$legal.core+=@('AMDGPU-SOURCE-NOTICES.txt','AMD-FIRMWARE-LICENSE.txt','AMD-FIRMWARE-WHENCE.txt','R4AMD-NOTICES.txt','uACPI-MIT.txt')}
 return @{groups=$groups;legal=$legal;providers=if($amd){@('R4AMD','R4GFX')}else{@('R4NV','R4GFX')}}
}
