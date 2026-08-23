param(
    [switch]$SelfTest,
    [string]$Suite,
    [string]$WorkloadVersion,
    [string]$CacheState,
    [int]$Repetitions,
    [string]$EnvironmentId
)

$ErrorActionPreference = 'Stop'

$benchmarkEnvironmentId = 'r4os-q35-haswell-1vcpu-1g-tcg-v1'
$suiteWorkloads = @{
    'perfdiag-blit' = 'blit'
    'perfdiag-clock' = 'clock'
    'perfdiag-service-registry' = 'service-registry'
    'perfdiag-kernel-ipc' = 'kernel-ipc'
    'perfdiag-driver-work' = 'driver-work'
    'perfdiag-pci-inventory' = 'pci-inventory'
}

function Assert-File([string]$Path, [string]$Label) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ($Label + ' not found: ' + $Path)
    }
}

function Assert-Directory([string]$Path, [string]$Label) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw ($Label + ' not found: ' + $Path)
    }
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-ValidatedRequest(
    [string]$RequestedSuite,
    [string]$RequestedVersion,
    [string]$RequestedCacheState,
    [int]$RequestedRepetitions,
    [string]$RequestedEnvironmentId
) {
    if ([string]::IsNullOrWhiteSpace($RequestedSuite)) { throw 'Benchmark suite is required.' }
    if ([string]::IsNullOrWhiteSpace($RequestedVersion)) { throw 'Benchmark workload version is required.' }
    if ([string]::IsNullOrWhiteSpace($RequestedCacheState)) { throw 'Benchmark cache state is required.' }
    if ([string]::IsNullOrWhiteSpace($RequestedEnvironmentId)) { throw 'Benchmark environment ID is required.' }

    $normalizedSuite = $RequestedSuite.Trim().ToLowerInvariant()
    if (-not $suiteWorkloads.ContainsKey($normalizedSuite)) {
        throw ('Unknown benchmark suite: ' + $RequestedSuite)
    }
    if ($RequestedVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw ('Invalid benchmark workload version: ' + $RequestedVersion)
    }
    $normalizedCache = $RequestedCacheState.Trim().ToLowerInvariant()
    if ($normalizedCache -notin @('warm', 'cold')) {
        throw ('Benchmark cache state must be warm or cold: ' + $RequestedCacheState)
    }
    if ($RequestedRepetitions -lt 3 -or $RequestedRepetitions -gt 20) {
        throw ('Benchmark repetitions must be in the range 3..20: ' + $RequestedRepetitions)
    }
    if (-not $RequestedEnvironmentId.Equals($benchmarkEnvironmentId, [StringComparison]::Ordinal)) {
        throw ('Benchmark environment ID mismatch. Required: ' + $benchmarkEnvironmentId)
    }

    return [pscustomobject]@{
        schema = 'r4os.benchmark.request'
        schema_version = 1
        suite = $normalizedSuite
        workload = $suiteWorkloads[$normalizedSuite]
        workload_version = $RequestedVersion
        cache_state = $normalizedCache
        repetitions = $RequestedRepetitions
        environment_id = $RequestedEnvironmentId
    }
}

function New-GuestRequestText($Request) {
    $workloadFlag = '/' + $Request.workload.ToUpperInvariant()
    $cacheFlag = '/' + $Request.cache_state.ToUpperInvariant()
    $requestJson = $Request | ConvertTo-Json -Compress
    $lines = @(
        '@ECHO OFF',
        'ECHO R4BENCH request begin',
        ('ECHO ' + $requestJson),
        'ECHO R4BENCH request end',
        ('C:\R4OS\SOFTWARE\TERMINAL\DIAG\PERFDIAG.R4X /BENCHMARK ' + $workloadFlag + ' /REPEAT:' + $Request.repetitions + ' ' + $cacheFlag),
        'ECHO R4BENCH guest poweroff',
        'POWEROFF'
    )
    return (($lines -join "`r`n") + "`r`n")
}

function Quote-Argument([string]$Value) {
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Get-QemuArgumentLine([string]$ConfigPath, [string]$LogPath) {
    return (@(
        '-readconfig', (Quote-Argument $ConfigPath),
        '-accel', 'tcg,thread=single',
        '-cpu', 'Haswell',
        '-m', '1G',
        '-smp', '1,sockets=1,cores=1,threads=1',
        '-boot', 'order=c,strict=on',
        '-nic', 'none',
        '-audiodev', 'driver=none,id=benchmark-audio',
        '-serial', (Quote-Argument ('file:' + $LogPath)),
        '-display', 'none',
        '-rtc', 'base=utc,clock=vm,driftfix=none',
        '-no-reboot',
        '-name', (Quote-Argument ('R4OS benchmark ' + $benchmarkEnvironmentId))
    ) -join ' ')
}

function Normalize-StartProcessEnvironment {
    $pathEntries = @([Environment]::GetEnvironmentVariables().GetEnumerator() |
        Where-Object { [string]$_.Key -ieq 'Path' })
    if ($pathEntries.Count -le 1) { return }
    $canonical = @($pathEntries | Where-Object { [string]$_.Key -ceq 'Path' } | Select-Object -First 1)
    $pathValue = if ($canonical.Count -eq 1) { [string]$canonical[0].Value } else { [string]$pathEntries[0].Value }
    [Environment]::SetEnvironmentVariable('PATH', $null, 'Process')
    [Environment]::SetEnvironmentVariable('Path', $pathValue, 'Process')
}

function Get-ExactCount([string[]]$Lines, [string]$Expected) {
    return @($Lines | Where-Object { $_.Trim().Equals($Expected, [StringComparison]::Ordinal) }).Count
}

function Read-BenchmarkRecords([string[]]$Lines, $Request, [int]$QemuExitCode) {
    if ($QemuExitCode -eq 124) { throw 'Benchmark timed out before regular guest poweroff.' }
    if ($QemuExitCode -ne 0) { throw ('QEMU benchmark failed with exit code ' + $QemuExitCode + '.') }
    foreach ($marker in @('R4BENCH request begin', 'R4BENCH request end', 'PERFDIAG machine-result begin', 'PERFDIAG machine-result end', 'PERFDIAG result: OK', 'R4BENCH guest poweroff')) {
        if ((Get-ExactCount $Lines $marker) -ne 1) {
            throw ('Benchmark log must contain exactly one marker: ' + $marker)
        }
    }
    if (@($Lines | Where-Object { $_ -match 'PERFDIAG result: FAILED|CPU Exception|PANIC' }).Count -ne 0) {
        throw 'Benchmark log contains a failure marker.'
    }

    $begin = [Array]::IndexOf($Lines, 'PERFDIAG machine-result begin')
    $end = [Array]::IndexOf($Lines, 'PERFDIAG machine-result end')
    if ($begin -lt 0 -or $end -le $begin + 1) { throw 'PERFDIAG machine-result block is incomplete.' }
    $records = [Collections.Generic.List[object]]::new()
    for ($index = $begin + 1; $index -lt $end; $index++) {
        try {
            $record = $Lines[$index] | ConvertFrom-Json
        } catch {
            throw ('Invalid JSON in PERFDIAG machine-result block: ' + $Lines[$index])
        }
        if ($record.schema -ne 'r4os.perfdiag.ndjson' -or [int]$record.schema_version -ne 6) {
            throw 'Unexpected PERFDIAG result schema.'
        }
        $records.Add($record)
    }
    $runRecords = @($records | Where-Object { $_.type -eq 'run' })
    if ($runRecords.Count -ne 1) { throw 'PERFDIAG machine-result block must contain exactly one run record.' }
    $run = $runRecords[0]
    if ($run.module_version -ne $Request.workload_version -or
        $run.mode -ne 'benchmark' -or
        $run.cache_state -ne $Request.cache_state -or
        $run.benchmark -ne $Request.workload -or
        [int]$run.repetitions -ne $Request.repetitions -or
        $run.result -ne 'ok') {
        throw 'PERFDIAG run record does not match the explicit benchmark request.'
    }
    return $records.ToArray()
}

function Assert-Throws([scriptblock]$Action, [string]$Label) {
    try {
        & $Action
    } catch {
        return
    }
    throw ('Self-test expected failure: ' + $Label)
}

function Invoke-SelfTest {
    $request = Get-ValidatedRequest 'perfdiag-clock' '0.3.7' 'warm' 5 $benchmarkEnvironmentId
    $guestText = New-GuestRequestText $request
    if (@($guestText -split "`r`n" | Where-Object { $_ -match 'PERFDIAG\.R4X' }).Count -ne 1) { throw 'Guest request does not contain exactly one workload.' }
    if (@($guestText -split "`r`n" | Where-Object { $_ -eq 'POWEROFF' }).Count -ne 1) { throw 'Guest request does not contain exactly one poweroff.' }
    $argumentLine = Get-QemuArgumentLine 'benchmark.conf' 'benchmark.log'
    foreach ($fixed in @('-accel tcg,thread=single', '-cpu Haswell', '-m 1G', '-smp 1,sockets=1,cores=1,threads=1', '-nic none', '-display none')) {
        if (-not $argumentLine.Contains($fixed)) { throw ('Fixed QEMU argument missing: ' + $fixed) }
    }

    $goodLog = @(
        'R4BENCH request begin',
        'R4BENCH request end',
        'PERFDIAG machine-result begin',
        '{"schema":"r4os.perfdiag.ndjson","schema_version":6,"type":"run","module_version":"0.3.7","mode":"benchmark","cache_state":"warm","benchmark":"clock","repetitions":5,"result":"ok"}',
        '{"schema":"r4os.perfdiag.ndjson","schema_version":6,"type":"observer"}',
        'PERFDIAG machine-result end',
        'PERFDIAG result: OK',
        'R4BENCH guest poweroff'
    )
    $records = Read-BenchmarkRecords $goodLog $request 0
    if ($records.Count -ne 2) { throw 'Complete machine block was not preserved.' }

    Assert-Throws { Get-ValidatedRequest '' '0.3.7' 'warm' 5 $benchmarkEnvironmentId } 'missing request'
    Assert-Throws { Get-ValidatedRequest 'perfdiag-clock' '0.3.7' 'warm' 5 'unknown-environment' } 'environment mismatch'
    Assert-Throws { Read-BenchmarkRecords $goodLog $request 124 } 'timeout'
    Assert-Throws { Read-BenchmarkRecords @($goodLog | Where-Object { $_ -ne 'R4BENCH guest poweroff' }) $request 0 } 'missing poweroff'
    Assert-Throws { Read-BenchmarkRecords @($goodLog | Where-Object { $_ -ne 'PERFDIAG machine-result end' }) $request 0 } 'incomplete machine block'
    Write-Host '[OK] Benchmark request, fixed QEMU environment and result gates.'
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

# Validation intentionally precedes every file lookup and process start. An
# incomplete or mismatching request therefore cannot launch QEMU.
$request = Get-ValidatedRequest $Suite $WorkloadVersion $CacheState $Repetitions $EnvironmentId

$qemu = $env:R4OS_BENCHMARK_QEMU_EXE
$config = $env:R4OS_BENCHMARK_QEMU_CONFIG
$imageCreator = $env:R4OS_BENCHMARK_IMAGE_CREATOR
$profileOutput = $env:R4OS_BENCHMARK_PROFILE_OUTPUT
$runOutput = $env:R4OS_BENCHMARK_RUN_OUTPUT
$dataMb = 0
if (-not [int]::TryParse($env:R4OS_BENCHMARK_DATA_MB, [ref]$dataMb) -or $dataMb -le 0) {
    throw 'Benchmark DATA_MB is invalid.'
}
$timeoutSeconds = 600
$parsedTimeout = 0
if ($env:QEMU_BENCHMARK_TIMEOUT_SECONDS -and [int]::TryParse($env:QEMU_BENCHMARK_TIMEOUT_SECONDS, [ref]$parsedTimeout) -and $parsedTimeout -gt 0) {
    $timeoutSeconds = $parsedTimeout
}

Assert-File $qemu 'QEMU executable'
Assert-File $config 'Benchmark QEMU config'
Assert-File $imageCreator 'ImageCreator'
Assert-Directory $profileOutput 'Benchmark profile output'
Assert-File (Join-Path $profileOutput 'disk.img') 'Benchmark disk image'
if (-not (Test-Path -LiteralPath $runOutput -PathType Container)) {
    New-Item -ItemType Directory -Path $runOutput | Out-Null
}

$requestBat = Join-Path $runOutput 'BENCHMARK.BAT'
$requestJson = Join-Path $runOutput 'request.json'
$dataImage = Join-Path $runOutput 'data.img'
$logPath = Join-Path $runOutput 'serial.log'
$errorPath = Join-Path $runOutput 'qemu.err'
$resultPath = Join-Path $runOutput 'benchmark-result.json'
foreach ($path in @($requestBat, $requestJson, $dataImage, $logPath, $errorPath, $resultPath)) {
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
}

Write-Utf8NoBom $requestBat (New-GuestRequestText $request)
Write-Utf8NoBom $requestJson (($request | ConvertTo-Json -Depth 4) + [Environment]::NewLine)
& $imageCreator --output $dataImage --size $dataMb --add ($requestBat + ':/BENCHMARK.BAT')
if ($LASTEXITCODE -ne 0) { throw ('Fresh benchmark data image failed with exit code ' + $LASTEXITCODE + '.') }

$argumentLine = Get-QemuArgumentLine $config $logPath
Write-Host ('=== QEMU benchmark ' + $request.suite + '; timeout ' + $timeoutSeconds + 's ===')
Write-Host ('    Environment: ' + $request.environment_id)
Write-Host ('    Run output:  ' + $runOutput)
Normalize-StartProcessEnvironment
$process = Start-Process -FilePath $qemu -ArgumentList $argumentLine -WorkingDirectory $runOutput -WindowStyle Hidden -RedirectStandardError $errorPath -PassThru
if ($process.WaitForExit($timeoutSeconds * 1000)) {
    $qemuExitCode = $process.ExitCode
} else {
    try {
        if (-not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit(5000) | Out-Null
        }
    } catch {
        Write-Host ('QEMU benchmark termination failed: ' + $_.Exception.Message)
    }
    $qemuExitCode = 124
}

Assert-File $logPath 'Benchmark serial log'
$logLines = [IO.File]::ReadAllLines($logPath)
$records = Read-BenchmarkRecords $logLines $request $qemuExitCode
$qemuVersion = @(& $qemu --version 2>$null | Select-Object -First 1)
$result = [ordered]@{
    schema = 'r4os.benchmark.run'
    schema_version = 1
    environment = [ordered]@{
        id = $benchmarkEnvironmentId
        machine = 'q35'
        accelerator = 'tcg-single-thread'
        cpu = 'Haswell'
        vcpu = 1
        memory_mb = 1024
        network = 'none'
        qemu = if ($qemuVersion.Count -eq 1) { [string]$qemuVersion[0] } else { 'unknown' }
    }
    request = $request
    outcome = [ordered]@{
        qemu_exit_code = $qemuExitCode
        regular_poweroff = $true
        machine_block_complete = $true
        result = 'ok'
    }
    records = $records
}
Write-Utf8NoBom $resultPath (($result | ConvertTo-Json -Depth 16) + [Environment]::NewLine)
Write-Host ('[OK] Benchmark result: ' + $resultPath)
