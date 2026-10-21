param([string]$OutputRoot='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
if(!$OutputRoot){$OutputRoot=Join-Path $workspace ('Temp/XhciAllocation/'+[Guid]::NewGuid().ToString('N'))}
[IO.Directory]::CreateDirectory($OutputRoot)|Out-Null
$owner=Join-Path $workspace 'Repositories/Kernel/Rust/usb/xhci_runtime.rs'
$source=[IO.File]::ReadAllText($owner)
function Read-OwnerFunction([string]$Name){
    $start=$source.IndexOf("pub(super) unsafe fn $Name(",[StringComparison]::Ordinal)
    if($start -lt 0){throw "Missing owner function $Name"}
    $open=$source.IndexOf('{',$start);$depth=1;$end=$open+1
    while($end -lt $source.Length -and $depth -gt 0){
        if($source[$end] -eq '{'){$depth++}elseif($source[$end] -eq '}'){$depth--}
        $end++
    }
    if($depth -ne 0){throw "Unbalanced owner function $Name"}
    return $source.Substring($start,$end-$start)
}
# Compile the actual owner functions; only allocation, mapping and ring IO
# are substituted. This proves local rollback, not hardware quiescence.
$functions=@('ensure_interrupt_storage','ensure_bulk_storage','free_dma_frame')|ForEach-Object {Read-OwnerFunction $_}
$fixture=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'XhciAllocation.rs'))
$generated=$fixture.Replace('// OWNER_FUNCTIONS',($functions -join "`n"))
$utf8=[Text.UTF8Encoding]::new($false)
$inputPath=Join-Path $OutputRoot 'owner-test.rs'
$binary=Join-Path $OutputRoot $(if($IsWindows){'owner-test.exe'}else{'owner-test'})
[IO.File]::WriteAllText($inputPath,$generated,$utf8)
$starter=Join-Path $workspace $(if($IsWindows){'DevKit/Setup/Rust.bat'}else{'DevKit/Setup/Rust.sh'})
try {
    & $starter rustc --edition 2024 --test $inputPath -o $binary
    if($LASTEXITCODE -ne 0){throw 'Owner allocation test compilation failed'}
    & $binary --test-threads=1
    if($LASTEXITCODE -ne 0){throw 'Owner allocation test failed'}
    $receipt=@{owner='Rust/usb/xhci_runtime.rs';source_sha256=(Get-FileHash $owner -Algorithm SHA256).Hash.ToLowerInvariant();cases=4;allocation_failure_positions=5;status='passed';scope='Exact owner functions with host allocator/MMIO stubs; no physical DMA claim'}
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'result.json'),($receipt|ConvertTo-Json),$utf8)
} finally {
    Remove-Item $inputPath,$binary -Force -ErrorAction SilentlyContinue
}
