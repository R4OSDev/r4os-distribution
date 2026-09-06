# FreeBytes comes from the actual verified FAT, after both complete slots.
# The original ZIP/PART pairs are rounded independently; 1 MB remains for
# directory/cache journals. Slot update plans replace files in place.
function Test-R4RecoveryCacheBudget {
 param([Parameter(Mandatory)][long]$FreeBytes,[Parameter(Mandatory)][long]$ClusterBytes,
       [Parameter(Mandatory)][long]$ReleaseBytes,[Parameter(Mandatory)][long]$RecoveryBytes)
 if($ClusterBytes -le 0 -or $ClusterBytes -gt 65536 -or ($ClusterBytes -band ($ClusterBytes-1)) -ne 0 -or
    $FreeBytes -lt 0 -or $ReleaseBytes -lt 22 -or $ReleaseBytes -gt 2GB -or $RecoveryBytes -lt 22 -or $RecoveryBytes -gt 2GB){throw 'Invalid Recovery budget geometry or package size.'}
 [long]$release=[Math]::Ceiling($ReleaseBytes/[double]$ClusterBytes)*$ClusterBytes
 [long]$recovery=[Math]::Ceiling($RecoveryBytes/[double]$ClusterBytes)*$ClusterBytes
 [long]$needed=2*$release+2*$recovery+1MB
 if($needed -gt $FreeBytes){throw "RECOVERY cannot hold two complete slots, release ZIP/PART, Recovery ZIP/PART and metadata reserve: cache needs $needed B, free $FreeBytes B. The common partition size requires an explicit decision."}
 Write-Host "Recovery cache budget verified: $needed B reserved, $($FreeBytes-$needed) B margin after both slots."
 return [ordered]@{freeAfterSlots=$FreeBytes;releaseBytes=$ReleaseBytes;recoveryBytes=$RecoveryBytes;cacheBytes=$needed;marginBytes=$FreeBytes-$needed;clusterBytes=$ClusterBytes}
}
