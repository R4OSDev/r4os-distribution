[CmdletBinding(DefaultParameterSetName = 'Log')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Log')]
    [string]$LogPath,

    [Parameter(ParameterSetName = 'Log')]
    [string]$ErrorPath,

    [Parameter(ParameterSetName = 'Log')]
    [string]$SubsystemImagePath,

    [Parameter(ParameterSetName = 'Log')]
    [string]$SubsystemImageMetadataPath,

    [Parameter(ParameterSetName = 'Log')]
    [int]$QemuExitCode = 0,

    [Parameter(Mandatory, ParameterSetName = 'SelfTest')]
    [switch]$SelfTest,

    [Parameter(ParameterSetName = 'Log')]
    [Parameter(ParameterSetName = 'SelfTest')]
    [switch]$Browser,

    [Parameter(ParameterSetName = 'Log')]
    [Parameter(ParameterSetName = 'SelfTest')]
    [switch]$ClockSmoke,

    [Parameter(ParameterSetName = 'Log')]
    [Parameter(ParameterSetName = 'SelfTest')]
    [ValidateRange(0, 32)]
    [int]$SmpCpuCount = 0,

    [Parameter(ParameterSetName = 'Log')]
    [Parameter(ParameterSetName = 'SelfTest')]
    [ValidateRange(0, 31)]
    [int]$SmpFailedCount = 0
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '../../Diagnostics/Spectra/Tools/StructuredOutput.ps1')
. (Join-Path $PSScriptRoot 'SubsystemReports.ps1')


function Test-HeapProbeContract {
    param([string]$Text)

    $pattern = '(?im)^\[HEAPPROBE\] result=OK iterations=(?<iterations>\d+) commit_calls=(?<commits>\d+) commit_pages=(?<pages>\d+) uncommit_calls=(?<uncommits>\d+) release_suppressed=(?<suppressed>\d+) poison_bytes=(?<poison>\d+) retained_pages=(?<retained>\d+) block_claims=(?<claims>\d+) extent_allocations=(?<extents>\d+) map_batches=(?<maps>\d+) unmap_batches=(?<unmaps>\d+) pressure=(?<pressure>yes|no)\r?$'
    $probe = [regex]::Match($Text, $pattern)
    if (-not $probe.Success) { return $false }
    $iterations = [uint64]$probe.Groups['iterations'].Value
    $commits = [uint64]$probe.Groups['commits'].Value
    $uncommits = [uint64]$probe.Groups['uncommits'].Value
    $suppressed = [uint64]$probe.Groups['suppressed'].Value
    $poison = [uint64]$probe.Groups['poison'].Value
    $pressure = $probe.Groups['pressure'].Value -eq 'yes'
    $pages = [uint64]$probe.Groups['pages'].Value
    $claims = [uint64]$probe.Groups['claims'].Value
    $extents = [uint64]$probe.Groups['extents'].Value
    $maps = [uint64]$probe.Groups['maps'].Value
    $unmaps = [uint64]$probe.Groups['unmaps'].Value
    if ($iterations -ne 16 -or $poison -lt (16 * 192 * 1024)) { return $false }
    if (($pages -eq 0 -and ($claims -ne 0 -or $extents -ne 0 -or $maps -ne 0)) -or
        ($pages -gt 0 -and ($claims -gt $pages -or $extents -eq 0 -or $maps -eq 0))) { return $false }
    if (($uncommits -eq 0 -and $unmaps -ne 0) -or ($uncommits -gt 0 -and $unmaps -eq 0)) { return $false }
    if ($pressure) { return $commits -le 16 -and $uncommits -le 16 }
    return $commits -le 2 -and $uncommits -le 1 -and
        ($suppressed + $uncommits) -ge $iterations -and
        [uint64]$probe.Groups['retained'].Value -gt 0
}

function Test-TlbProbeContract {
    param([string]$Text, [int]$ExpectedCpuCount)

    $pattern = '(?im)^\[TLBPROBE\] result=OK cpus=(?<cpus>\d+) ready_mask=0x(?<ready>[0-9A-F]+) updated_mask=0x(?<updated>[0-9A-F]+) stale_failures=0 timeout_rejected=1 frame_retained=1 requests=(?<requests>\d+) ipis=(?<ipis>\d+) acks=(?<acks>\d+) timeouts=(?<timeouts>\d+) expected_timeouts=(?<expected>\d+) generation=(?<generation>\d+) cleanup=yes\r?$'
    $probe = [regex]::Match($Text, $pattern)
    if (-not $probe.Success -or [int]$probe.Groups['cpus'].Value -ne $ExpectedCpuCount) { return $false }
    $ready = [Convert]::ToUInt64($probe.Groups['ready'].Value, 16)
    $updated = [Convert]::ToUInt64($probe.Groups['updated'].Value, 16)
    $readyCount = ([Convert]::ToString([int64]$ready, 2).Replace('0', '')).Length
    return $ready -eq $updated -and $readyCount -eq $ExpectedCpuCount -and
        [uint64]$probe.Groups['requests'].Value -ge 4 -and
        [uint64]$probe.Groups['ipis'].Value -gt 0 -and
        [uint64]$probe.Groups['acks'].Value -gt 0 -and
        [uint64]$probe.Groups['timeouts'].Value -eq 1 -and
        [uint64]$probe.Groups['expected'].Value -eq 1 -and
        [uint64]$probe.Groups['generation'].Value -gt 0
}

function Test-LockProbeContract {
    param([string]$Text, [int]$ExpectedCpuCount)

    $pattern = '(?im)^\[LOCKPROBE\] result=OK runtime_acquisitions=(?<runtime>\d+) nested=(?<nested>\d+) collisions=(?<collisions>\d+) cpu_collisions=(?<cpu>\d+) wait_spins=(?<spins>\d+) max_wait=(?<maxwait>\d+) max_hold_cycles=(?<hold>\d+) legacy_global=0 runtime_owner_classes=1 owner_classes=11 owner_acquisitions=(?<owner>\d+) owner_collisions=(?<owner_collisions>\d+) order_violations=0 stress_iterations=(?<iterations>\d+) stress_mask=0x(?<mask>[0-9A-F]+) stress_failures=0\r?$'
    $probe = [regex]::Match($Text, $pattern)
    if (-not $probe.Success) { return $false }
    $mask = [Convert]::ToUInt64($probe.Groups['mask'].Value, 16)
    $maskCount = ([Convert]::ToString([int64]$mask, 2).Replace('0', '')).Length
    # Hold times and spin counts are optional detail instrumentation. The
    # functional result, ownership, stress mask and failures remain required.
    return $probe.Success -and
        [uint64]$probe.Groups['runtime'].Value -gt 0 -and
        [uint64]$probe.Groups['owner'].Value -gt 0 -and
        [uint64]$probe.Groups['iterations'].Value -ge ([uint64]$ExpectedCpuCount * 64) -and
        $maskCount -eq $ExpectedCpuCount
}

function Test-SerialProbeContract {
    param([string]$Text)

    $pattern = '(?im)^\[SERIALPROBE\] result=OK write_calls=(?<writes>\d+) bulk_calls=(?<bulk>\d+) lock_acquisitions=(?<locks>\d+) status_reads=(?<reads>\d+) ring_bytes=(?<bytes>\d+) max_span=(?<span>\d+) dropped=0\r?$'
    $probe = [regex]::Match($Text, $pattern)
    if (-not $probe.Success) { return $false }
    return [uint64]$probe.Groups['writes'].Value -eq [uint64]$probe.Groups['locks'].Value -and
        [uint64]$probe.Groups['bulk'].Value -gt 0 -and
        [uint64]$probe.Groups['span'].Value -gt 1 -and
        [uint64]$probe.Groups['reads'].Value -lt [uint64]$probe.Groups['bytes'].Value
}

function Test-R4lPreemptionContract {
    param([string]$Text)

    $pattern = '(?im)^\[R4LPREEMPT\] result=OK cpu=(?<cpu>\d+) timer_switches=(?<timer>\d+) ipi_switches=(?<ipi>\d+) timer_exit=0 ipi_exit=0 generation=(?<generation>\d+)\r?$'
    $probe = [regex]::Match($Text, $pattern)
    if (-not $probe.Success) { return $false }
    return [uint64]$probe.Groups['cpu'].Value -gt 0 -and
        [uint64]$probe.Groups['timer'].Value -gt 0 -and
        [uint64]$probe.Groups['ipi'].Value -gt 0 -and
        [uint64]$probe.Groups['generation'].Value -gt 0
}

function Test-SmpProbeContract {
    param([string]$Text, [int]$ExpectedCpus, [uint64]$ExactMask = 0)

    $pattern = '(?im)^\[SMPPROBE\] result=OK cpus=(?<cpus>\d+) expected_mask=0x(?<expected>[0-9A-F]+) observed_mask=0x(?<observed>[0-9A-F]+) failures=0\r?$'
    $probe = [regex]::Match($Text, $pattern)
    if (-not $probe.Success) { return $false }
    $expected = [Convert]::ToUInt64($probe.Groups['expected'].Value, 16)
    $observed = [Convert]::ToUInt64($probe.Groups['observed'].Value, 16)
    return [int]$probe.Groups['cpus'].Value -eq $ExpectedCpus -and
        $expected -eq $observed -and ($expected -band 1) -ne 0 -and
        [System.Numerics.BitOperations]::PopCount([uint64]$expected) -eq $ExpectedCpus -and
        ($ExactMask -eq 0 -or $expected -eq $ExactMask)
}

function Test-ClockSmokeContract {
    param([string]$Text, [switch]$Quiet)

    $failures = 0
    $requiredClock = @(
        'Booted via Limine [OK]',
        'Scheduler [OK]',
        'SMP foundation [OK]',
        '[QUICKCHECK] BEGIN',
        'SPECTRA NETWORK limits: ok',
        'Limits: tests=1 cases=10',
        '[QUICKCHECK] END',
        '[QUICKPROBE] result=DONE'
    )
    $hpetEvent = $Text.IndexOf('Timer [HPET]', [StringComparison]::Ordinal) -ge 0
    $lapicEvent = $Text.IndexOf('Timer [LAPIC]', [StringComparison]::Ordinal) -ge 0
    $deadline = [regex]::Match($Text, '(?m)^\[TSCDEADLINE\] cpu=0 active=1 epoch=(?<epoch>\d+) generation=(?<generation>\d+) arms=(?<arms>\d+) irqs=\d+ stale=\d+ fallbacks=\d+ reason=0\r?$')
    $qualifiedDeadline = $deadline.Success -and
        [uint64]$deadline.Groups['epoch'].Value -gt 0 -and
        [uint32]$deadline.Groups['generation'].Value -gt 0 -and
        [uint32]$deadline.Groups['generation'].Value -lt [uint32]::MaxValue -and
        [uint64]$deadline.Groups['arms'].Value -gt 0
    if (($hpetEvent -and -not $lapicEvent) -or ($lapicEvent -and -not $hpetEvent -and $qualifiedDeadline)) {
        if (-not $Quiet) { Write-Host ('Clock-smoke event timer OK: ' + $(if ($lapicEvent) { 'qualified LAPIC TSC-deadline' } else { 'HPET fallback' })) }
    } else {
        if (-not $Quiet) { Write-Host 'Clock-smoke event timer FAILED: require HPET or actual qualified LAPIC deadline epoch/clock/arm receipt.' }
        $failures++
    }
    foreach ($marker in $requiredClock) {
        if ($Text.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            if (-not $Quiet) { Write-Host ('Clock-smoke marker FAILED missing: ' + $marker) }
            $failures++
        } elseif (-not $Quiet) {
            Write-Host ('Clock-smoke marker OK: ' + $marker)
        }
    }
    foreach ($marker in @('PANIC', 'FATAL', 'CPU EXCEPTION', 'General Protection Fault', 'Page Fault',
            '[SMP] switch boundary violation', '[SMPPROBE] result=FAILED', '[HEAPPROBE] result=FAILED',
            '[TLBPROBE] result=FAILED', '[LOCKPROBE] result=FAILED', '[SERIALPROBE] result=FAILED',
            '[NVMEIRQ] result=FAILED', '[NVMEIRQPROBE] result=FAILED',
            '[R4LPREEMPT] result=FAILED', '[CLOCKPROBE] result=FAILED',
            '[TSCDEADLINE-CHECK] result=FAILED',
            'SPECTRA NETWORK limits: FAILED')) {
        if ($Text.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            if (-not $Quiet) { Write-Host ('Clock-smoke marker FAILED forbidden: ' + $marker) }
            $failures++
        }
    }

    $activePattern = '(?im)^\[SMP\] stage=active discovered=4 started=3 online=4 failed=0 fallback=no\r?$'
    if (-not [regex]::IsMatch($Text, $activePattern)) {
        if (-not $Quiet) { Write-Host 'Clock-smoke SMP marker FAILED: four CPUs did not become active.' }
        $failures++
    } elseif (-not $Quiet) {
        Write-Host 'Clock-smoke SMP marker OK: 4 of 4 CPUs active.'
    }

    if (-not (Test-SmpProbeContract $Text 4 15)) {
        if (-not $Quiet) { Write-Host 'Clock-smoke SMPPROBE FAILED: CPU placement or computed work proof invalid.' }
        $failures++
    } elseif (-not $Quiet) {
        Write-Host 'Clock-smoke SMPPROBE OK: four CPU masks and functional work verified.'
    }

    $network = [regex]::Match($Text, '(?ms)^\[QUICKCHECK\] BEGIN\r?\n(?<body>.*?)^\[QUICKCHECK\] END\r?$')
    $networkOk = $network.Success
    if ($networkOk) {
        $body = $network.Groups['body'].Value
        $networkOk = $body.Contains('SPECTRA NETWORK limits: ok') -and
            $body.Contains('Limits: tests=1 cases=10') -and
            [regex]::IsMatch($body, '(?im)^ERRORLEVEL=0\r?$') -and
            -not [regex]::IsMatch($body, '(?im)^ERRORLEVEL=(?:-[0-9]+|[1-9][0-9]*)\r?$') -and
            -not [regex]::IsMatch($body, '(?im)^\s*exit_code\s*=\s*-?[1-9][0-9]*\b')
    }
    if (-not $networkOk) {
        if (-not $Quiet) { Write-Host 'Clock-smoke NETWORK limits FAILED: explicit Spectra work or exit status missing.' }
        $failures++
    } elseif (-not $Quiet) {
        Write-Host 'Clock-smoke NETWORK limits OK: explicit Spectra check completed.'
    }

    if (-not (Test-HeapProbeContract $Text)) {
        if (-not $Quiet) { Write-Host 'Clock-smoke HEAPPROBE FAILED: short churn, retention, or poison proof invalid.' }
        $failures++
    } elseif (-not $Quiet) {
        Write-Host 'Clock-smoke HEAPPROBE OK: 16 short churn iterations.'
    }

    if (-not (Test-TlbProbeContract $Text 4)) {
        if (-not $Quiet) { Write-Host 'Clock-smoke TLBPROBE FAILED: stale translation, Ack timeout, or safe retention proof invalid.' }
        $failures++
    } elseif (-not $Quiet) {
        Write-Host 'Clock-smoke TLBPROBE OK: cross-CPU invalidation and timeout retention proved.'
    }

    if (-not (Test-LockProbeContract $Text 4)) {
        if (-not $Quiet) { Write-Host 'Clock-smoke LOCKPROBE FAILED: ownership classification or lock order invalid.' }
        $failures++
    } elseif (-not $Quiet) {
        Write-Host 'Clock-smoke LOCKPROBE OK: global BKL retired and owner-lock order clean.'
    }

    if (-not (Test-SerialProbeContract $Text)) {
        if (-not $Quiet) { Write-Host 'Clock-smoke SERIALPROBE FAILED: bulk serial span or byte-completeness proof invalid.' }
        $failures++
    } elseif (-not $Quiet) {
        Write-Host 'Clock-smoke SERIALPROBE OK: strings use bounded bulk UART drains without loss.'
    }

    $nvmeIrqPattern = '(?im)^\[NVMEIRQ\] result=OK mode=(?<mode>msi|msix) irq=nonzero work=nonzero completions=nonzero poll_fallback=0\r?$'
    $nvmeIrq = [regex]::Match($Text, $nvmeIrqPattern)
    if (-not $nvmeIrq.Success) {
        if (-not $Quiet) { Write-Host 'Clock-smoke NVMEIRQ FAILED: MSI/MSI-X IRQ work without polling fallback was not proved.' }
        $failures++
    } elseif (-not $Quiet) {
        Write-Host ('Clock-smoke NVMEIRQ OK: mode=' + $nvmeIrq.Groups['mode'].Value + '.')
    }

    $nvmePattern = '(?im)^\[NVMEIRQPROBE\] result=OK worker_requests=(?<requests>\d+) worker_completions=(?<worker>\d+) async_submissions=(?<submissions>\d+) async_completions=(?<async>\d+)\r?$'
    $nvme = [regex]::Match($Text, $nvmePattern)
    $nvmeOk = $nvme.Success -and
        [uint64]$nvme.Groups['requests'].Value -gt 0 -and
        [uint64]$nvme.Groups['worker'].Value -gt 0 -and
        [uint64]$nvme.Groups['submissions'].Value -gt 0 -and
        [uint64]$nvme.Groups['async'].Value -gt 0
    if (-not $nvmeOk) {
        if (-not $Quiet) { Write-Host 'Clock-smoke NVMEIRQPROBE FAILED: short asynchronous MSI/MSI-X completion proof invalid.' }
        $failures++
    } elseif (-not $Quiet) {
        Write-Host 'Clock-smoke NVMEIRQPROBE OK: one short NVMe runtime read completed through MSI/MSI-X.'
    }

    if (-not (Test-R4lPreemptionContract $Text)) {
        if (-not $Quiet) { Write-Host 'Clock-smoke R4LPREEMPT FAILED: bounded R4L timer/IPI preemption proof invalid.' }
        $failures++
    } elseif (-not $Quiet) {
        Write-Host 'Clock-smoke R4LPREEMPT OK: bounded AP timer and reschedule-IPI paths proved.'
    }

    $clockPattern = '(?im)^\[CLOCKPROBE\] result=OK source=(?<source>TSC|HPET) cpus=4 registered_mask=0x(?<mask>[0-9A-F]+) regressions=0 irq_delta=(?<irq>\d+) generation=(?<generation>\d+) max_skew_ns=(?<skew>\d+) calibration_ppm=(?<ppm>\d+) fallback=(?<fallback>[a-z0-9-]+)\r?$'
    $clock = [regex]::Match($Text, $clockPattern)
    $clockOk = $clock.Success
    if ($clockOk) {
        $clockOk = [Convert]::ToUInt64($clock.Groups['mask'].Value, 16) -eq 15 -and
            [uint64]$clock.Groups['irq'].Value -gt 0 -and
            [uint64]$clock.Groups['generation'].Value -gt 0
    }
    if (-not $clockOk) {
        if (-not $Quiet) { Write-Host 'Clock-smoke CLOCKPROBE FAILED: monotonic CPU, IRQ, registration, or generation proof invalid.' }
        $failures++
    } elseif (-not $Quiet) {
        Write-Host ('Clock-smoke CLOCKPROBE OK: source=' + $clock.Groups['source'].Value +
            ' irq_delta=' + $clock.Groups['irq'].Value + ' skew_ns=' + $clock.Groups['skew'].Value + '.')
    }
    return $failures
}

if ($ClockSmoke) {
    if ($SmpCpuCount -ne 4 -or $SmpFailedCount -ne 0) {
        Write-Host 'Clock-smoke marker FAILED: this short acceptance requires exactly four CPUs without injected AP failure.'
        exit 1
    }
    if ($SelfTest) {
        $validClock = @(
            'Booted via Limine [OK]',
            '  Timer [HPET]',
            '  Scheduler [OK]',
            '  SMP foundation [OK]',
            '[SMP] stage=active discovered=4 started=3 online=4 failed=0 fallback=no',
            '[SMPPROBE] result=OK cpus=4 expected_mask=0x0000000F observed_mask=0x0000000F failures=0',
            '[HEAPPROBE] result=OK iterations=16 commit_calls=1 commit_pages=49 uncommit_calls=1 release_suppressed=15 poison_bytes=3145728 retained_pages=64 block_claims=1 extent_allocations=1 map_batches=1 unmap_batches=1 pressure=no',
            '[TLBPROBE] result=OK cpus=4 ready_mask=0x0000000F updated_mask=0x0000000F stale_failures=0 timeout_rejected=1 frame_retained=1 requests=22 ipis=66 acks=63 timeouts=1 expected_timeouts=1 generation=22 cleanup=yes',
            '[LOCKPROBE] result=OK runtime_acquisitions=40 nested=12 collisions=2 cpu_collisions=2 wait_spins=17 max_wait=9 max_hold_cycles=800 legacy_global=0 runtime_owner_classes=1 owner_classes=11 owner_acquisitions=90 owner_collisions=3 order_violations=0 stress_iterations=256 stress_mask=0x0000000F stress_failures=0',
            '[SERIALPROBE] result=OK write_calls=400 bulk_calls=120 lock_acquisitions=400 status_reads=360 ring_bytes=4000 max_span=80 dropped=0',
            '[NVMEIRQ] result=OK mode=msix irq=nonzero work=nonzero completions=nonzero poll_fallback=0',
            '[NVMEIRQPROBE] result=OK worker_requests=1 worker_completions=1 async_submissions=1 async_completions=1',
            '[R4LPREEMPT] result=OK cpu=1 timer_switches=1 ipi_switches=1 timer_exit=0 ipi_exit=0 generation=1',
            '[CLOCKPROBE] result=OK source=TSC cpus=4 registered_mask=0x0000000F regressions=0 irq_delta=42 generation=2 max_skew_ns=300 calibration_ppm=120 fallback=none',
            '[QUICKCHECK] BEGIN',
            'SPECTRA NETWORK limits: ok',
            'Limits: tests=1 cases=10',
            'ERRORLEVEL=0',
            '[QUICKCHECK] END',
            '[QUICKPROBE] result=DONE'
        ) -join "`r`n"
        if ((Test-ClockSmokeContract $validClock -Quiet) -ne 0) { throw 'valid clock-smoke marker set did not pass' }
        $deadlineMarker = '[TSCDEADLINE] cpu=0 active=1 epoch=1 generation=2 arms=5 irqs=4 stale=0 fallbacks=0 reason=0'
        $validDeadline = $validClock.Replace('Timer [HPET]', 'Timer [LAPIC]') + "`r`n" + $deadlineMarker
        if ((Test-ClockSmokeContract $validDeadline -Quiet) -ne 0) { throw 'qualified LAPIC deadline did not pass' }
        foreach ($invalidDeadline in @(
                $validDeadline.Replace($deadlineMarker, ''),
                $validDeadline.Replace('active=1 epoch=1', 'active=0 epoch=1'),
                $validDeadline.Replace('epoch=1 generation=2', 'epoch=0 generation=2'),
                $validDeadline.Replace('generation=2 arms=5', 'generation=0 arms=5'),
                $validDeadline.Replace('generation=2 arms=5', 'generation=4294967295 arms=5'),
                $validDeadline.Replace('arms=5 irqs=4', 'arms=0 irqs=4'),
                $validDeadline.Replace('fallbacks=0 reason=0', 'fallbacks=0 reason=4'),
                ($validDeadline + "`r`n[TSCDEADLINE-CHECK] result=FAILED"),
                ($validDeadline + "`r`nTimer [HPET]"))) {
            if ((Test-ClockSmokeContract $invalidDeadline -Quiet) -eq 0) { throw 'unqualified/failed LAPIC deadline accepted' }
        }
        $normalClock = $validClock.Replace('wait_spins=17 max_wait=9 max_hold_cycles=800', 'wait_spins=0 max_wait=0 max_hold_cycles=0')
        if ((Test-ClockSmokeContract $normalClock -Quiet) -ne 0) { throw 'normal instrumentation mode did not pass' }
        foreach ($invalidClock in @(
                $validClock.Replace('online=4', 'online=3'),
                $validClock.Replace('observed_mask=0x0000000F', 'observed_mask=0x00000007'),
                $validClock.Replace('poison_bytes=3145728', 'poison_bytes=0'),
                $validClock.Replace('timeout_rejected=1', 'timeout_rejected=0'),
                $validClock.Replace('legacy_global=0', 'legacy_global=1'),
                $validClock.Replace('owner_classes=11 ', 'owner_classes=10 '),
                $validClock.Replace('dropped=0', 'dropped=1'),
                $validClock.Replace('async_completions=1', 'async_completions=0'),
                $validClock.Replace('poll_fallback=0', 'poll_fallback=1'),
                $validClock.Replace('ipi_switches=1', 'ipi_switches=0'),
                $validClock.Replace('irq_delta=42', 'irq_delta=0'),
                $validClock.Replace('cases=10', 'cases=9'),
                $validClock.Replace('ERRORLEVEL=0', 'ERRORLEVEL=1'),
                ($validClock.Replace('Limits: tests=1 cases=10', '') + "`r`nLimits: tests=1 cases=10"),
                ($validClock + "`r`n[CLOCKPROBE] result=FAILED"))) {
            if ((Test-ClockSmokeContract $invalidClock -Quiet) -eq 0) { throw 'invalid clock-smoke marker set was accepted' }
        }
        Write-Host 'QEMU clock-smoke marker self-test OK (smp4).'
        exit 0
    }

    $fullClockPath = [IO.Path]::GetFullPath($LogPath)
    if (-not (Test-Path -LiteralPath $fullClockPath -PathType Leaf)) {
        Write-Host ('Clock-smoke marker FAILED: log missing: ' + $fullClockPath)
        exit 1
    }
    $clockFailures = Test-ClockSmokeContract ([IO.File]::ReadAllText($fullClockPath))
    if ($QemuExitCode -ne 0) {
        Write-Host ('QEMU exit FAILED: ' + $QemuExitCode)
        $clockFailures++
    }
    if ($ErrorPath -and (Test-Path -LiteralPath $ErrorPath -PathType Leaf)) {
        $errorPatterns = @('Parameter ', 'Could not', 'Invalid', "can't ", 'cannot ', 'failed', 'Unable', 'error:')
        foreach ($line in [IO.File]::ReadAllLines([IO.Path]::GetFullPath($ErrorPath))) {
            if ($line.IndexOf('warning: GLib-GIO: Failed to open application manifest', [StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }
            foreach ($pattern in $errorPatterns) {
                if ($line.IndexOf($pattern, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    Write-Host ('QEMU stderr FAILED: ' + $line)
                    $clockFailures++
                    break
                }
            }
        }
    }
    if ($clockFailures -ne 0) {
        Write-Host ('QEMU clock-smoke marker contract FAILED: ' + $clockFailures + ' issue(s).')
        exit 1
    }
    Write-Host 'QEMU clock-smoke marker contract OK.'
    exit 0
}

$required = @(
    'Booted via Limine [OK]',
    'System poweroff.',
    '[R4D] runtime load EXAMPLE [OK]',
    '[R4D] runtime load DISPBLIT [OK]',
    'dirs=ok',
    'RDPSVC nscodec selftest: ok negotiation=ns1 decode=visible cache=wait/publish/hit fallback=error/wire',
    'RDPSVC selftest: OK',
    'REG generation cache selftest: OK reads=64 publications=4',
    'REG commit failure selftest: OK generation=unchanged partial=none',
    'REG snapshot batch selftest: OK pages=5 restarts=1 operations=32',
    'REG api selftest: OK',
    'REG migrate batch selftest: OK documents=3 generations=3',
    'REG migrate selftest: OK',
    'REGEDIT snapshot batch selftest: OK',
    'REGEDIT selftest: OK',
    'R4OS_FAT_FIXTURE=PRIVATE_TEST',
    'SPECTRA FILESYSTEM ntfs metadata cache: OK',
    'SPECTRA FILESYSTEM pagecache policy: OK',
    'SPECTRA FILESYSTEM result: OK',
    'AUDIOD master: OK volume+mute streams=2 fanout=common persistence=restart',
    'AUDIOD lifecycle: OK cycles=4 restart=replay multi=2 stale=none',
    'AUDIOD HDA diagnostic: OK core=selection+transport+route+format runtime=irq+position counters=separate',
    '[AHCI] canonical preload R4D active; owner=preload',
    '[INSTALLBOOT] mapping=verified C=SYSTEM D=DATA BOOT=unlettered',
    'AUDIOD path: upstreamDropped=0 driverUnderruns=0 driverErrors=0 backendFail=0 silencePeriods=0',
    'AUDIOD idle: lazyOpens=1 silenceWrites=2',
    'AUDIOD deadline: submitted=',
    'misses=0 overruns=0 rejected=0',
    'Audio PCM continuity diagnostics: OK',
    'AUDIOD result: OK',
    'R4GB APU runtime: OK rate=48000 channels=2 frames=6000 submitted=',
    'drift=0 drops=0',
    'R4GB persistence runtime: OK sram=8192 rtc=1 lock=exclusive atomic=1 async=worker+drain',
    'R4SNES SELFTEST OK: OBC-1/S-RTC/S-DD1/SPC7110/Epson-RTC/Super FX GSU-1/GSU-2/SA-1/CX4/NEC-DSP-1/1A/1B/2/3/4/ST010/ST011/ST018-ARMv3, CPU, timed 5A22, byte-bounded DMA, complete PPU, SPC700/S-SMP and cycle-clocked S-DSP owners isolated; productive R4SUBSYS1 host uses bounded master-clock slices, physical port-1 input, native XRGB32, App-Audio and idempotent persistence teardown.',
    'R4SNES persistence runtime: OK sav=exact rtc=versioned lock=exclusive atomic=recover async=worker+drain',
    'R4GB host runtime: OK instances=model-2+window-1 slices=bounded input=physical+focus video=160x144+generation audio=app-audio lifecycle=pause+resume+reset+mute+close resources=closed',
    'R4GB E2E runtime: OK id=00000000000000A1 extension=.gb end=witness battery=0 rtc=0',
    'R4GB E2E runtime: OK id=00000000000000B2 extension=.gbc end=close battery=1 rtc=1',
    'R4GB E2E rejection: OK id=00000000000000C3 error=CgbOnly window=closed resources=closed',
    'R4GB explorer E2E: OK catalog=MODULES.JSON assoc=ids-only formats=.gb+.gbc probe=bounded instances=2 input=physical video=frames audio=app-audio save=sram+rtc rejection=cgb-only close=witness+separate',
    'R4GB long-run E2E: OK duration=60s instances=2 focus=alternating lifecycle=pause+resume+reset+mute endings=witness+close desktop=responsive',
    'R4SNES fixture generation: OK origin=R4OS-original formats=.sfc+.smc cases=rom-only+battery-rtc+invalid+firmware-required private-rom=excluded',
    'R4SNES E2E runtime: OK id=00000000000000D1 extension=.sfc end=witness battery=0 rtc=0',
    'R4SNES E2E runtime: OK id=00000000000000D2 extension=.smc end=close battery=1 rtc=1',
    'R4SNES E2E rejection: OK id=00000000000000D3 class=invalid error=NoValidHeader window=closed resources=closed',
    'R4SNES E2E rejection: OK id=00000000000000D4 class=firmware error=Missing window=closed resources=closed',
    'R4SNES explorer E2E: OK catalog=MODULES.JSON assoc=ids-only formats=.sfc+.smc probe=zero-byte instances=2 input=physical video=xrgb32 audio=app-audio save=sram+rtc rejection=invalid+firmware close=witness+separate',
    'R4SNES long-run E2E: OK duration=60s instances=2 focus=alternating lifecycle=pause+resume+reset+mute endings=witness+close desktop=responsive',
    'SPECTRA LOADER result: OK',
    'APPHEAPD allocator churn: OK small=64 direct=32',
    'APPHEAPD result: OK churn=bounded cleanup=trimmed',
    'SPECTRA RESOURCES result: OK',
    'DISPLAYD damage-present: OK regions=2 pixels=8',
    'DISPLAYD result: OK',
    'EXPLORER BAS source-probe: cases=3 info_calls=3 read_calls=0 read_bytes=0 limit_bytes=262144',
    'EXPLORER GB source-probe: cases=3 metadata_info_calls=3 metadata_read_calls=0 metadata_read_bytes=0 probe_info_calls=3 probe_read_calls=3 probe_read_bytes=98304 limit_bytes=262144',
    'EXPLORER SNES source-probe: cases=4 metadata_info_calls=4 metadata_read_calls=0 metadata_read_bytes=0 probe_info_calls=4 probe_read_calls=0 probe_read_bytes=0 limit_bytes=262144',
    'EXPLORER selftest: OK',
    'SUBSYSTEM host selftest: OK modes=640x350+320x200+256x224 formats=indexed8+xrgb32 damage=sparse indexed8=abi tiles=bounded input=sequenced+policy-filtered idle=no-frame fps>=20',
    'SUBSYSTEM runtime selftest: OK instances=2 slices=bounded time=monotonic audio=s16le-buffered lifecycle=pause+resume+reset+complete+close errors=isolated resources=closed',
    'R4BASIC source-probe: info_calls=1 read_calls=0 read_bytes=0 limit_bytes=262144',
    'R4BASIC source-load: info_calls=1 read_calls=1 read_bytes=29434 source_bytes=29434 limit_bytes=262144',
    'APPEARANCE selftest: OK',
    'NOTEPAD font size selftest: OK',
    'Invalid R4M0 entry section',
    'NOTEPAD - simple text editor',
    'R4XSTARTD result: OK',
    'CSTARTD result: OK',
    'APPZCON app entry: OK',
    'APPCCON app entry: OK',
    'R4CC result: OK',
    'R4PACK result: OK',
    'R4BUILD result: OK'
)
$browserRequired = @(
    'KLICKIFAX font selftest: OK family=R4 Sans faces=12',
    'KLICKIFAX image selftest: OK responsive=data+srcset css-background=resource SVG=nested-image-optional',
    'KLICKIFAX loading selftest: OK resource=container png=256x384 alpha=yes reuse=1 geometry=native+bounded tiles=6 missing=blank corrupt=blank',
    'KLICKIFAX font-cache selftest: OK demand=used-only storage=content-addressed warm=verified',
    'KLICKIFAX webfont-runtime selftest: OK cold=decoded warm=cache network=0 transport=alpha8',
    'KLICKIFAX selftest: OK'
)
if ($Browser) { $required += $browserRequired }
$forbidden = @(
    'PANIC',
    'FATAL',
    'CPU EXCEPTION',
    '[SMP] switch boundary violation',
    '[SMPPROBE] result=FAILED',
    '[HEAPPROBE] result=FAILED',
    '[TLBPROBE] result=FAILED',
    '[LOCKPROBE] result=FAILED',
    '[SERIALPROBE] result=FAILED',
    '[R4LPREEMPT] result=FAILED',
    '[CLOCKPROBE] result=FAILED',
    '[TSCDEADLINE-CHECK] result=FAILED',
    'SPECTRA NETWORK limits: FAILED',
    'General Protection Fault',
    'Page Fault',
    'REG: api-selftest',
    'REG: migrate-',
    'REGEDIT selftest failed:',
    'SPECTRA FILESYSTEM ntfs metadata cache: FAILED',
    'SPECTRA FILESYSTEM result: FAILED',
    'AUDIOD master: FAILED',
    'AUDIOD lifecycle: FAILED',
    'AUDIOD HDA diagnostic: FAILED',
    'selftest FAILED',
    'SERVMAN LOAD: lines=0',
    'dirs=missing',
    '$MFT',
    'STORDIAG result: FAILED',
    'Audio PCM continuity diagnostics: FAILED',
    'AUDIOD result: FAILED',
    'R4GB APU runtime: FAILED',
    'R4GB persistence runtime: FAILED',
    'R4SNES persistence runtime: FAILED',
    'R4GB host runtime: FAILED',
    'R4GB E2E runtime: FAILED',
    'R4GB E2E rejection: FAILED',
    'R4SNES fixture generation: FAILED',
    'R4SNES E2E runtime: FAILED',
    'R4SNES E2E rejection: FAILED',
    'R4SNES E2E diagnostic: FAILED',
    'SPECTRA LOADER result: FAILED',
    'APPHEAPD result: FAILED',
    'SPECTRA RESOURCES result: FAILED',
    '[R4D] runtime load DISPBLIT [FAILED]',
    'DISPLAYD damage-present: FAILED',
    'DISPLAYD result: FAILED',
    'EXPLORER selftest FAILED',
    'SUBSYSTEM host selftest FAILED',
    'SUBSYSTEM runtime selftest FAILED',
    'SUBSYSTEM runtime bootstrap FAILED',
    'R4BASIC baseline: FAILED',
    'DESKTOP tray selftest: FAILED',
    'DESKTOP volume selftest: FAILED',
    'DESKTOP present selftest: FAILED',
    'APPEARANCE selftest FAILED',
    'KLICKIFAX selftest FAILED',
    'NOTEPAD font size selftest FAILED',
    'R4XSTARTD result: FAILED',
    'CSTARTD result: FAILED',
    'APPZCON app entry: FAILED',
    'APPCCON app entry: FAILED',
    'R4CC result: FAILED',
    'R4PACK result: FAILED',
    'R4BUILD result: FAILED'
)

function Test-ApiMarkerContract {
    param([string]$Text, [switch]$Quiet, $SubsystemReports = $null)

    $failures = 0
    if ($SmpFailedCount -ge [Math]::Max(1, $SmpCpuCount)) {
        if (-not $Quiet) { Write-Host 'SMP marker FAILED: failed CPU count must be smaller than configured CPU count.' }
        return 1
    }
    $ownerText = if ($null -ne $SubsystemReports) { $SubsystemReports.OwnerText } else { $Text }
    $reportText = if ($null -ne $SubsystemReports) { $SubsystemReports.ReportText } else { $Text }
    $markerText = if ($null -ne $SubsystemReports) { $Text + "`n" + $reportText } else { $Text }
    if (-not (Test-SpectraDesktopOwnerContract $ownerText -OriginalFile:($null -ne $SubsystemReports))) {
        if (-not $Quiet) { Write-Host 'API diagnostic FAILED: canonical Spectra Desktop/subsystem result or exact child retirement missing.' }
        $failures++
    }
    foreach ($marker in $required) {
        if ($markerText.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            if (-not $Quiet) { Write-Host ('API diagnostic marker FAILED missing: ' + $marker) }
            $failures++
        } elseif (-not $Quiet) {
            Write-Host ('API diagnostic marker OK: ' + $marker)
        }
    }
    foreach ($marker in $forbidden) {
        if ($markerText.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            if (-not $Quiet) { Write-Host ('API diagnostic marker FAILED forbidden: ' + $marker) }
            $failures++
        }
    }

    $failures += Test-SubsystemReportContract $reportText -Quiet:$Quiet -BootText $(if ($null -ne $SubsystemReports) { $Text } else { '' })


    if ($SmpCpuCount -gt 1) {
        $expectedOnline = $SmpCpuCount - $SmpFailedCount
        $expectedStarted = $SmpCpuCount - 1 - $SmpFailedCount
        $expectedFallback = if ($expectedOnline -eq 1) { '1cpu' } else { 'no' }
        $activePattern = '(?im)^\[SMP\] stage=active discovered=' + $SmpCpuCount +
            ' started=' + $expectedStarted + ' online=' + $expectedOnline +
            ' failed=' + $SmpFailedCount + ' fallback=' + $expectedFallback + '\r?$'
        if (-not [regex]::IsMatch($Text, $activePattern)) {
            if (-not $Quiet) { Write-Host ('SMP marker FAILED: expected ' + $expectedOnline + ' of ' + $SmpCpuCount + ' CPUs online.') }
            $failures++
        } elseif (-not $Quiet) {
            Write-Host ('SMP online marker OK: ' + $expectedOnline + ' of ' + $SmpCpuCount + ' CPUs.')
        }
        if ($SmpFailedCount -gt 0 -and
            -not [regex]::IsMatch($Text, '(?im)^\[SMP\] ap=\d+ apic=\d+ failed=diagnostic-injection\r?$')) {
            if (-not $Quiet) { Write-Host 'SMP marker FAILED: injected AP failure was not reported.' }
            $failures++
        }
        if ($expectedOnline -gt 1 -and
            -not [regex]::IsMatch($Text, '(?im)^\[SMP\] productive cpu=([1-9]|[12][0-9]|3[01]) task=r4x-')) {
            if (-not $Quiet) { Write-Host 'SMP marker FAILED: no R4X task executed on an AP.' }
            $failures++
        } elseif (-not $Quiet) {
            Write-Host 'SMP productive AP marker OK.'
        }
        if (-not (Test-SmpProbeContract $Text $expectedOnline)) {
            if (-not $Quiet) { Write-Host 'SMP marker FAILED: CPU placement or computed work proof missing.' }
            $failures++
        } elseif (-not $Quiet) {
            Write-Host 'SMP kernel work marker OK: CPU masks and computed results verified.'
        }

        if (-not (Test-HeapProbeContract $Text)) {
            if (-not $Quiet) { Write-Host 'SMP heap marker FAILED: short churn, retention, or poison proof missing.' }
            $failures++
        } elseif (-not $Quiet) {
            Write-Host 'SMP heap marker OK: 16 short churn iterations.'
        }
        if (-not (Test-TlbProbeContract $Text $expectedOnline)) {
            if (-not $Quiet) { Write-Host 'SMP TLB marker FAILED: cross-CPU invalidation or timeout retention proof missing.' }
            $failures++
        } elseif (-not $Quiet) {
            Write-Host 'SMP TLB marker OK.'
        }
        if (-not (Test-LockProbeContract $Text $expectedOnline)) {
            if (-not $Quiet) { Write-Host 'SMP lock marker FAILED: ownership classification or lock order invalid.' }
            $failures++
        } elseif (-not $Quiet) {
            Write-Host 'SMP lock marker OK.'
        }
        if (-not (Test-SerialProbeContract $Text)) {
            if (-not $Quiet) { Write-Host 'SMP serial marker FAILED: bulk serial span or loss-free proof missing.' }
            $failures++
        } elseif (-not $Quiet) {
            Write-Host 'SMP serial marker OK.'
        }
        if ($expectedOnline -gt 1) {
            if (-not (Test-R4lPreemptionContract $Text)) {
                if (-not $Quiet) { Write-Host 'SMP R4L preemption marker FAILED: AP timer/IPI proof missing.' }
                $failures++
            } elseif (-not $Quiet) {
                Write-Host 'SMP R4L preemption marker OK.'
            }
        }
        $clockPattern = '(?im)^\[CLOCKPROBE\] result=OK source=(TSC|HPET) cpus=' + $expectedOnline +
            ' registered_mask=0x[0-9A-F]+ regressions=0 irq_delta=(\d+) generation=(\d+)' +
            ' max_skew_ns=\d+ calibration_ppm=\d+ fallback=[a-z0-9-]+\r?$'
        $clockMatch = [regex]::Match($Text, $clockPattern)
        if (-not $clockMatch.Success -or [uint64]$clockMatch.Groups[2].Value -eq 0 -or
            [uint64]$clockMatch.Groups[3].Value -eq 0) {
            if (-not $Quiet) { Write-Host 'SMP clock marker FAILED: monotonic CPU, IRQ, or generation proof missing.' }
            $failures++
        } elseif (-not $Quiet) {
            Write-Host ('SMP clock marker OK: source=' + $clockMatch.Groups[1].Value +
                ' irq_delta=' + $clockMatch.Groups[2].Value + '.')
        }
    } elseif (-not [regex]::IsMatch($Text, '(?im)^\[SMPPROBE\] result=SKIPPED cpus=1 reason=single-cpu\r?$')) {
        if (-not $Quiet) { Write-Host 'SMP marker FAILED: one-CPU fallback probe marker missing.' }
        $failures++
    }

    $pattern = '(?im)^APPPARITY lang=(zig|c) domain=(\d+) raw=(-?\d+) payload=(\d+) bytes=(\d+) mutated=(\d+) tail=(\d+) handle_before=(\d+) close=(-?\d+) handle_after=(\d+)\r?$'
    $parityMatches = [regex]::Matches($Text, $pattern)
    if ($parityMatches.Count -ne 2) {
        if (-not $Quiet) { Write-Host ('API parity marker FAILED: expected exactly two Zig/C records, found ' + $parityMatches.Count + '.') }
        $failures++
    } else {
        $records = @{}
        foreach ($match in $parityMatches) {
            $language = $match.Groups[1].Value.ToLowerInvariant()
            if ($records.ContainsKey($language)) {
                if (-not $Quiet) { Write-Host ('API parity marker FAILED: duplicate ' + $language + ' record.') }
                $failures++
                continue
            }
            $records[$language] = @($match.Groups[2..10] | ForEach-Object Value)
        }
        if (-not $records.ContainsKey('zig') -or -not $records.ContainsKey('c')) {
            if (-not $Quiet) { Write-Host 'API parity marker FAILED: Zig or C record missing.' }
            $failures++
        } else {
            $zig = $records['zig'] -join '|'
            $c = $records['c'] -join '|'
            if ($zig -cne $c) {
                if (-not $Quiet) { Write-Host ('API parity marker FAILED: Zig/C results differ: zig=' + $zig + ' c=' + $c) }
                $failures++
            }
            $fields = $records['zig']
            $validState = $fields[0] -eq '3' -and [int]$fields[1] -lt 0 -and [uint64]$fields[2] -ne 0 -and [uint64]$fields[3] -gt 0 -and
                $fields[4] -eq '1' -and $fields[5] -eq '1' -and $fields[6] -eq '1' -and $fields[7] -eq '0' -and $fields[8] -eq '0'
            if (-not $validState) {
                if (-not $Quiet) { Write-Host ('API parity marker FAILED: result invariants invalid: ' + $zig) }
                $failures++
            } elseif (-not $Quiet) {
                Write-Host ('API parity marker OK: Zig/C results match (' + $zig + ').')
            }
        }
    }
    return $failures
}

if ($SelfTest) {
    # The first three records are a captured canonical Desktop export; the
    # SUBSYSTEM record declares the current parser fixture, not a guest pass.
    $ownerFixture = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Fixtures/SpectraSubsystemOwner.jsonl'))
    if (-not (Test-SpectraDesktopOwnerContract $ownerFixture)) { throw 'current Spectra owner fixture was rejected' }
    $ownerLines = @($ownerFixture.Split("`n") | Where-Object { $_.Trim() })
    foreach ($index in 0..($ownerLines.Count - 1)) {
        $incomplete = @($ownerLines | Select-Object -Skip 0)
        $incomplete[$index] = ''
        if (Test-SpectraDesktopOwnerContract ($incomplete -join "`n")) { throw ('missing Spectra owner record was accepted: ' + $index) }
    }
    foreach ($badOwner in @(
        $ownerFixture.Replace('"cleanup_acknowledged":true', '"cleanup_acknowledged":false'),
        $ownerFixture.Replace('"success":true', '"success":"true"'),
        $ownerFixture.Replace('"reaped":true', '"reaped":"true"'),
        $ownerFixture.Replace('"scope":"all"', '"scope":"snes"'),
        $ownerFixture.Replace('"desktop_wire_version":{"value":"2"', '"desktop_wire_version":{"value":"1"'),
        $ownerFixture.Replace('"long_run_pair_seconds":{"value":"60"', '"long_run_pair_seconds":{"value":"59"'),
        $ownerFixture.Replace('"schema_version":1', '"schema_version":'),
        (($ownerLines[0],$ownerLines[0],$ownerLines[2],$ownerLines[3]) -join "`n")
    )) {
        if (Test-SpectraDesktopOwnerContract $badOwner) { throw 'invalid Spectra owner contract was accepted' }
    }
    $valid = ($required -join "`r`n") + "`r`n" +
        'APPPARITY lang=zig domain=3 raw=-5 payload=123 bytes=12 mutated=1 tail=1 handle_before=1 close=0 handle_after=0' + "`r`n" +
        'APPPARITY lang=c domain=3 raw=-5 payload=123 bytes=12 mutated=1 tail=1 handle_before=1 close=0 handle_after=0'
    $valid += "`r`n" + $ownerFixture
    $valid += "`r`n" +
        'R4GB E2E runtime: OK id=00000000000000A1 extension=.gb end=witness battery=0 rtc=0 guest_ns=60000000000 guest_cycles=251658240 drift_cycles=0 ppu_frames=3583 slices=8000 max_slice=32768 max_step_gap_ns=12000000 input=20 frames=2 dropped_presents=0 audio_writes=6000 audio_busy=0 audio_failures=0 audio_late=0 audio_discarded=0 audio_suppressed=0 apu_generated=2880000 apu_rendered=2880000 apu_dropped=0 apu_queued=0 save_async_started=0 save_async_completed=0 save_async_coalesced=0 save_async_errors=0 save_async_max_queued=0 pauses=1 resumes=1 resets=1 save_files=1 close=0 resources=closed' + "`r`n" +
        'R4GB E2E runtime: OK id=00000000000000B2 extension=.gbc end=close battery=1 rtc=1 guest_ns=60000000000 guest_cycles=251658240 drift_cycles=0 ppu_frames=3583 slices=8000 max_slice=32768 max_step_gap_ns=15000000 input=20 frames=2 dropped_presents=0 audio_writes=6000 audio_busy=0 audio_failures=0 audio_late=0 audio_discarded=0 audio_suppressed=0 apu_generated=2880240 apu_rendered=2880000 apu_dropped=0 apu_queued=240 save_async_started=30 save_async_completed=30 save_async_coalesced=0 save_async_errors=0 save_async_max_queued=2 pauses=0 resumes=0 resets=0 save_files=1 close=0 resources=closed' + "`r`n" +
        'R4BASIC baseline: OK id=0123456789ABCDEF mode=headless guest=C:\TEMP\GORILLA.BAS source_bytes=29434 bytecode=1234' + "`r`n" +
        'R4BASIC timeline: start_ns=100 probe_ns=110 resolve_ns=120 desktop_ns=130 app_ns=180 source_begin_ns=190 source_end_ns=200 compile_begin_ns=210 compile_visible_ns=215 compile_end_ns=220 compile_updates=6 vm_begin_ns=230 vm_end_ns=240 host_ready_ns=250 initial_frame_ns=0 runtime_begin_ns=270 first_instruction_ns=280 audio_open_ns=0 first_frame_ns=300' + "`r`n" +
        'R4BASIC compiler: tokens=4000 token_capacity=4000 keyword_lookups=1000 keyword_probes=1200 keyword_max_probe=4 name_lookups=2000 name_insertions=300 name_probes=2600 name_max_probe=7 index_rebuilds=12 constant_lookups=900 constant_reuses=200 constant_probes=1100 constant_max_probe=5 label_fixups=20 data_fixups=2 reused_bindings=500 expression_depth=8 progress_updates=24' + "`r`n" +
        'R4BASIC compiler-memory: token_bytes=80000 initial_list_bytes=160000 instruction_hot_bytes=14808 instruction_metadata_bytes=39488 allocations=40 reallocations=8 copy_bytes=12000 peak_bytes=800000 program_bytes=400000 adopted_source_bytes=29434 diagnostics_total=0 diagnostics_stored=0 diagnostics_truncated=0' + "`r`n" +
        'R4BASIC compiler-vm: allocations=40 frees=20 active_before=200000 active_after=600000 peak_active=900000 reserved_before=67108864 reserved_after=67108864 committed_before=524288 committed_after=1048576' + "`r`n" +
        'R4BASIC runtime: cycles=4 close_checks=4 host_polls=5 poll_budget_exhaustions=0 active_cycles=3 waiting_cycles=0 paused_cycles=0 requested_operations=524288 executed_operations=5000 slices=2 active_continues=2 yields=1 sleeps=0 event_waits=0 event_wakes=0 event_timeouts=0 wait_failures=0 zero_progress_waits=0 present_attempts=1 presents=1 unchanged_presents=0 hidden_presents=0 dropped_presents=0' + "`r`n" +
        'R4BASIC adapter: steps=2 instructions=5000 max_slice=4096 budget_limited=1 time_limited=1 frame_ready=1 display_prepares=0 clock_reads=22 max_clock_reads=18 max_clock_chunk=16384 active_vm_ns=9000000 ns_per_instruction=1800' + "`r`n" +
        'R4BASIC input: raw=4 translated=3 filtered=1 pending_created=0 pending_emitted=0 mouse_events=1 mouse_moves=1 mouse_mappings=0 window_info=4 input_window_info=0 viewport_calculations=4 adapter_events=2 accepted=1 controls=1 dropped=0 runtime_input=2 runtime_ignored=0 queue=0 queue_max=1 consumed=1 unfocused=0 invalid_codepoint=0 unsupported_key=0 unsupported_event=0 queue_full=0 oom=0' + "`r`n" +
        'R4BASIC input-correlation: last_raw_sequence=4 last_raw_tick=14 last_filter_sequence=4 last_filter_tick=14 last_filter_reason=pointer_ignored last_event_sequence=3 last_event_tick=13 last_accepted_sequence=1 last_accepted_tick=11 last_dropped_sequence=0 last_dropped_tick=0 last_drop_reason=none last_consumed_sequence=1 last_consumed_tick=11 visible_sequence=1 visible_tick=11 visible_reaction_ns=300' + "`r`n" +
        'R4BASIC frame-cycle: cadence_deferred=0 missed_deadlines=0 max_backlog=0 attempts=1 published=1 unchanged=0 hidden=0 dropped=0 failed=0 present_ns=2000000 max_present_ns=2000000 max_age_start_ns=1000000 max_age_end_ns=3000000' + "`r`n" +
        'R4BASIC vm: cancel_flag_checks=5020 cancel_callback_checks=20 group_lookups=5000 text_sync_checks=8 text_sync_renders=2 metadata_reads=900 cell_resolves=1200 alias_hops=4 same_type_store_moves=500 conversions=20 integer_comparisons=200 floating_comparisons=40 string_comparisons=0 timer_calls=2 timer_waits=1 timer_max_wake_lateness_ns=200000' + "`r`n" +
        'R4BASIC raster: mode_allocations=1 mode_reuses=0 mode_clear_bytes=224000 pixel_probes=224000 pixel_changes=0 spans=350 span_pixels=224000 damage_commits=2 text_cells=2000 text_rows=350 line_segments=0 line_pixels=0 fill_spans=0 paint_spans=0 paint_pixels=0 paint_probes=0 paint_pushes=0 paint_pops=0 paint_duplicate_pops=0 paint_grows=0 paint_queue_max=0 circle_requested=0 circle_segments=0 circle_skipped=0 capture_calls=0 capture_pixels=0 capture_bytes=0 put_calls=0 put_pixels=0 put_bytes=0' + "`r`n" +
        'R4BASIC damage: commits=2 regions=3 merges=1 overflow_merges=0 full_commits=1' + "`r`n" +
        'R4BASIC ownership: compile_borrowed=12 string_clones=80 string_clone_bytes=327680 builtin_borrowed=120 builtin_owned=30 procedure_calls=40 local_pool_grows=2 local_pool_reuses=38 local_initializations=60 local_initialization_bytes=3360 local_aggregate_initializations=4 format_stack_uses=20 str_result_allocations=5 val_direct=7 val_stack=2 val_scratch=2 val_scratch_grows=1' + "`r`n" +
        'R4BASIC storage: compact_array_resizes=4 generic_array_resizes=1 compact_array_elements=4096 generic_array_initializations=2 array_live_bytes=16384 array_live_peak_bytes=16384 array_resize_live_peak_bytes=24576 array_live_limit_bytes=134217728 array_resize_live_limit_bytes=201326592 vm_static_bytes=8192 file_index_bytes=256 file_capacity_grows=1 max_open_files=2' + "`r`n" +
        'R4BASIC file-host: reads=0 read_bytes=0 writes=0 write_bytes=0 failures=0' + "`r`n" +
        'R4BASIC file-io: batch_bytes=65536 read_submissions=0 write_submissions=0 status_polls=0 pending_polls=0 completions=0 path_normalizations=0 path_cache_hits=0 max_request_bytes=0 max_active_requests=0 input_refills=0 output_flushes=0 waits=0 input_compaction_bytes=0 output_compaction_bytes=0 input_buffer_peak_bytes=0 output_buffer_peak_bytes=0' + "`r`n" +
        'R4BASIC presenter: published_frames=3 skipped_frames=1 full_frames=1 damage_frames=1 replacement_frames=1 compacted_frames=0 damage_regions=4 indexed8_frames=3 indexed8_blocks=9 indexed8_resource_bytes=12000 xrgb_fallback_frames=0 raster_blocks=9 sampled_pixels=224500' + "`r`n" +
        'R4BASIC audio: state=ready muted=0 playback=unavailable lazy_opens=1 service_ops=4 service_ops_cycle_max=1 opens=1 writes=2 closes=1 active_cycles=4 silent_cycles=2 paused_cycles=0 muted_cycles=0 active_quanta=2 silent_quanta=1 generated_bytes=7680 accepted_bytes=3840 suppressed_bytes=1920 discarded_bytes=1920 paused_bytes=0 muted_bytes=0 busy=0 resyncs=0' + "`r`n" +
        'R4BASIC audio-guest: scheduled_frames=1920 accepted_frames=960 suppressed_frames=480 discarded_frames=480 resolved_frames=1920 unresolved_frames=0 foreground_waits=2 foreground_wakes=2 background=1 direct_events=4 reserve_grows=1 phase_lookups=3' + "`r`n" +
        '[R4XSTACK] highwater owner=42 detail=on thread=0 module=C:\R4OS\SUBSYSTEMS\r4os.basic\R4BASIC.R4X profile=desktop reserve=4194304 initial=131072 committed=196608 highwater=154464 create_cycles=2500000' + "`r`n" +
        '[R4XSTACK] release owner=42 detail=on profile=desktop reserve=4194304 initial=131072 committed=196608 highwater=154464 creates=4 releases=3 create_cycles=2500000 create_cycles_max=2700000 release_cycles=1700000 release_cycles_max=1800000 kernel_highwater_max=39800 kernel_create_cycles_max=3500000 kernel_release_cycles_max=2100000 kernel_cache_cached=8 kernel_cache_hits=20 kernel_cache_misses=12 critical_available=4 critical_in_use=0' + "`r`n" +
        '[R4BASIC-LAUNCH] id=0123456789ABCDEF mode=H phase=admission ns=140' + "`r`n" +
        '[R4BASIC-LAUNCH] id=0123456789ABCDEF mode=H phase=loader-complete ns=160 duration_ns=20 range_reads=12 fs_requests=13 gate_waits=0 fs_ticks=2 sections=4 imports=4 relocations=2110' + "`r`n" +
        '[R4BASIC-LAUNCH] id=0123456789ABCDEF mode=H phase=r4xstart ns=170'
    $valid += "`r`n" +
        'R4SNES E2E runtime: OK id=00000000000000D1 extension=.sfc end=witness battery=0 rtc=0 guest_ns=60000000000 guest_cycles=1288636320 master_hz=21477272 drift_cycles=0 pending_cycles=0 ppu_frames=3596 slices=40000 max_slice_grant=32768 max_slice_execution=32780 max_step_gap_ns=12000000 input=24 controller=0x0fff completion=1 frames=3596 dropped_presents=0 audio_writes=6000 audio_busy=0 audio_failures=0 audio_late=0 audio_discarded=0 audio_paused=0 audio_muted=0 audio_suppressed=1920 dsp_native=1920000 dsp_resampled=2880000 dsp_rendered=2880000 dsp_non_silent=2879000 dsp_dropped=0 dsp_queued=0 save_async_started=0 save_async_completed=0 save_async_coalesced=0 save_async_errors=0 save_async_max_queued=0 pauses=1 resumes=1 resets=1 save_files=1 close=0 resources=closed' + "`r`n" +
        'R4SNES E2E runtime: OK id=00000000000000D2 extension=.smc end=close battery=1 rtc=1 guest_ns=60000000000 guest_cycles=1288636320 master_hz=21477272 drift_cycles=0 pending_cycles=0 ppu_frames=3596 slices=40000 max_slice_grant=32768 max_slice_execution=32780 max_step_gap_ns=15000000 input=24 controller=0x0fff completion=0 frames=3596 dropped_presents=0 audio_writes=6000 audio_busy=0 audio_failures=0 audio_late=0 audio_discarded=0 audio_paused=0 audio_muted=0 audio_suppressed=0 dsp_native=1920000 dsp_resampled=2880240 dsp_rendered=2880000 dsp_non_silent=2879000 dsp_dropped=0 dsp_queued=240 save_async_started=30 save_async_completed=30 save_async_coalesced=0 save_async_errors=0 save_async_max_queued=2 pauses=0 resumes=0 resets=0 save_files=1 close=0 resources=closed'
    if ($SmpCpuCount -gt 1) {
        $expectedOnline = $SmpCpuCount - $SmpFailedCount
        $syntheticMask = if ($SmpFailedCount -gt 0) { '0000000B' } else { '0000000F' }
        $valid += "`r`n" + ('[SMP] stage=active discovered=' + $SmpCpuCount + ' started=' +
            ($SmpCpuCount - 1 - $SmpFailedCount) + ' online=' + $expectedOnline +
            ' failed=' + $SmpFailedCount + ' fallback=' + $(if ($expectedOnline -eq 1) { '1cpu' } else { 'no' })) +
            "`r`n[SMP] productive cpu=1 task=r4x-app class=r4x" +
            "`r`n[SMPPROBE] result=OK cpus=$expectedOnline expected_mask=0x$syntheticMask observed_mask=0x$syntheticMask failures=0" +
            "`r`n[HEAPPROBE] result=OK iterations=16 commit_calls=1 commit_pages=49 uncommit_calls=1 release_suppressed=15 poison_bytes=3145728 retained_pages=64 block_claims=1 extent_allocations=1 map_batches=1 unmap_batches=1 pressure=no" +
            "`r`n[TLBPROBE] result=OK cpus=$expectedOnline ready_mask=0x$syntheticMask updated_mask=0x$syntheticMask stale_failures=0 timeout_rejected=1 frame_retained=1 requests=22 ipis=66 acks=63 timeouts=1 expected_timeouts=1 generation=22 cleanup=yes" +
            "`r`n[LOCKPROBE] result=OK runtime_acquisitions=40 nested=12 collisions=2 cpu_collisions=2 wait_spins=17 max_wait=9 max_hold_cycles=800 legacy_global=0 runtime_owner_classes=1 owner_classes=11 owner_acquisitions=90 owner_collisions=3 order_violations=0 stress_iterations=$($expectedOnline * 64) stress_mask=0x$syntheticMask stress_failures=0" +
            "`r`n[SERIALPROBE] result=OK write_calls=400 bulk_calls=120 lock_acquisitions=400 status_reads=360 ring_bytes=4000 max_span=80 dropped=0" +
            "`r`n[R4LPREEMPT] result=OK cpu=1 timer_switches=1 ipi_switches=1 timer_exit=0 ipi_exit=0 generation=1" +
            "`r`n[CLOCKPROBE] result=OK source=TSC cpus=$expectedOnline registered_mask=0x0000000F regressions=0 irq_delta=42 generation=2 max_skew_ns=300 calibration_ppm=120 fallback=none"
        if ($SmpFailedCount -gt 0) {
            $valid += "`r`n[SMP] ap=2 apic=2 failed=diagnostic-injection"
        }
    } else {
        $valid += "`r`n[SMPPROBE] result=SKIPPED cpus=1 reason=single-cpu"
    }
    if ((Test-ApiMarkerContract $valid -Quiet) -ne 0) { throw 'valid marker set did not pass' }
    # Original image files are authoritative even when a serial repaint is
    # damaged or contains another copy. A valid serial copy must never mask
    # a malformed original export or a short original long-run report.
    $fileFixture = ($valid.Split("`n") | Where-Object { $_ -notmatch '^\[R4BASIC-LAUNCH\]|^\[R4XSTACK\]' }) -join "`n"
    $separate = [pscustomobject]@{OwnerText=$ownerFixture;ReportText=$fileFixture}
    if ((Test-ApiMarkerContract ($valid + "`n" + '{"schema":"r4os.spectra" corrupted serial row') -Quiet -SubsystemReports $separate) -ne 0) { throw 'original image reports were not independent of serial rows' }
    $separate.OwnerText = $ownerFixture + "`n{"
    if ((Test-ApiMarkerContract $valid -Quiet -SubsystemReports $separate) -eq 0) { throw 'valid serial data masked a malformed original export' }
    $separate.OwnerText = $ownerFixture
    $separate.ReportText = $fileFixture.Replace('guest_ns=60000000000','guest_ns=1000000000')
    if ((Test-ApiMarkerContract $valid -Quiet -SubsystemReports $separate) -eq 0) { throw 'valid serial data masked a short original guest report' }
    $replacementOnly = $valid.Replace('damage_frames=1 replacement_frames=1', 'damage_frames=0 replacement_frames=2')
    if ((Test-ApiMarkerContract $replacementOnly -Quiet) -ne 0) { throw 'valid replacement frame accounting did not pass' }
    $badReplacement = $valid.Replace('replacement_frames=1', 'replacement_frames=2')
    if ((Test-ApiMarkerContract $badReplacement -Quiet) -eq 0) { throw 'inconsistent replacement frame total was not rejected' }
    $pausedAudio = $valid.Replace('audio_discarded=0 audio_paused=0 audio_muted=0', 'audio_discarded=1920 audio_paused=1920 audio_muted=0')
    if ((Test-ApiMarkerContract $pausedAudio -Quiet) -ne 0) { throw 'accounted intentional audio pause was rejected' }
    $lostAudio = $pausedAudio.Replace('audio_discarded=1920', 'audio_discarded=1924')
    if ((Test-ApiMarkerContract $lostAudio -Quiet) -eq 0) { throw 'unexplained discarded audio was not rejected' }
    $baseMode = [regex]::Replace($valid, '(?m)^\[R4XSTACK\].*$', {
        param($match)
        $line = $match.Value.Replace('detail=on', 'detail=off')
        return [regex]::Replace($line, '(highwater|create_cycles|create_cycles_max|release_cycles|release_cycles_max|kernel_highwater_max|kernel_create_cycles_max|kernel_release_cycles_max)=\d+', '$1=0')
    })
    if ((Test-ApiMarkerContract $baseMode -Quiet) -ne 0) { throw 'base instrumentation marker set did not pass' }
    $badBase = $baseMode.Replace('highwater=0', 'highwater=1')
    if ((Test-ApiMarkerContract $badBase -Quiet) -eq 0) { throw 'disabled stack high-water measurement was not rejected' }

    foreach ($marker in $required) {
        $missing = (($required | Where-Object { $_ -ne $marker }) -join "`r`n")
        if ((Test-ApiMarkerContract $missing -Quiet) -eq 0) { throw ('missing marker was not rejected: ' + $marker) }
    }
    foreach ($marker in $forbidden) {
        if ((Test-ApiMarkerContract ($valid + "`r`n" + $marker) -Quiet) -eq 0) { throw ('FAILED marker was not rejected: ' + $marker) }
    }
    $mismatch = $valid.Replace('lang=c domain=3 raw=-5 payload=123', 'lang=c domain=3 raw=-5 payload=124')
    if ((Test-ApiMarkerContract $mismatch -Quiet) -eq 0) { throw 'cross-language parity mismatch was not rejected' }
    Write-Host ('QEMU API marker self-test OK (' + $(if ($Browser) { 'browser' } elseif ($SmpCpuCount -gt 1) { 'smp' } else { 'standard' }) + ').')
    exit 0
}

$fullPath = [IO.Path]::GetFullPath($LogPath)
if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    Write-Host ('API diagnostic marker FAILED: log missing: ' + $fullPath)
    exit 1
}
$subsystemReports = $null
if ($SubsystemImagePath -or $SubsystemImageMetadataPath) {
    if (!$SubsystemImagePath -or !$SubsystemImageMetadataPath) { throw 'Both subsystem image paths are required' }
    $subsystemReports = Read-R4SubsystemReportSet -ImagePath $SubsystemImagePath -ImageMetadataPath $SubsystemImageMetadataPath
}
$failures = Test-ApiMarkerContract ([IO.File]::ReadAllText($fullPath)) -SubsystemReports $subsystemReports
if ($QemuExitCode -ne 0) {
    Write-Host ('QEMU exit FAILED: ' + $QemuExitCode)
    $failures++
}
if ($ErrorPath -and (Test-Path -LiteralPath $ErrorPath -PathType Leaf)) {
    $errorPatterns = @('Parameter ', 'Could not', 'Invalid', "can't ", 'cannot ', 'failed', 'Unable', 'error:')
    foreach ($line in [IO.File]::ReadAllLines([IO.Path]::GetFullPath($ErrorPath))) {
        if ($line.IndexOf('warning: GLib-GIO: Failed to open application manifest', [StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }
        foreach ($pattern in $errorPatterns) {
            if ($line.IndexOf($pattern, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                Write-Host ('QEMU stderr FAILED: ' + $line)
                $failures++
                break
            }
        }
    }
}
if ($failures -ne 0) {
    Write-Host ('API diagnostic marker contract FAILED: ' + $failures + ' issue(s).')
    exit 1
}
Write-Host 'API diagnostic marker contract OK.'
exit 0
