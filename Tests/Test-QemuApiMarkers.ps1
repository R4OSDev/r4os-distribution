[CmdletBinding(DefaultParameterSetName = 'Log')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Log')]
    [string]$LogPath,

    [Parameter(ParameterSetName = 'Log')]
    [string]$ErrorPath,

    [Parameter(ParameterSetName = 'Log')]
    [int]$QemuExitCode = 0,

    [Parameter(Mandatory, ParameterSetName = 'SelfTest')]
    [switch]$SelfTest,

    [Parameter(ParameterSetName = 'Log')]
    [Parameter(ParameterSetName = 'SelfTest')]
    [switch]$Browser,

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
    'FSDIAG ntfs metadata cache: OK',
    'FSDIAG pagecache policy: OK',
    'FSDIAG result: OK',
    '[AHCI] canonical preload R4D active; owner=preload',
    '[NVME] canonical preload R4D active; owner=preload',
    'storage D: OK driver=R4D status=mounted-D note=NVME.R4D source=preload; namespace read/write blockdevice',
    'AUDIOD path: upstreamDropped=0 driverUnderruns=0 driverErrors=0 backendFail=0 silencePeriods=0',
    'AUDIOD idle: lazyOpens=1 silenceWrites=2',
    'AUDIOD deadline: submitted=',
    'misses=0 overruns=0 rejected=0',
    'Audio PCM continuity diagnostics: OK',
    'AUDIOD result: OK',
    'LOADERD result: OK',
    'RESDIAG result: OK',
    'DISPLAYD damage-present: OK regions=2 pixels=8',
    'DISPLAYD result: OK',
    'EXPLORER selftest: OK',
    'SUBSYSTEM host selftest: OK modes=640x350+320x200+256x224 formats=indexed8+xrgb32 tiles=bounded input=translated idle=no-frame fps>=20',
    'SUBSYSTEM runtime selftest: OK instances=2 slices=bounded time=monotonic audio=s16le-buffered lifecycle=pause+resume+reset+complete+close errors=isolated resources=closed',
    'DESKTOP present selftest: OK regions=2 fence=sync backend=DISPBLIT fallback=armed remote=on-demand',
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
    'General Protection Fault',
    'Page Fault',
    'REG: api-selftest',
    'REG: migrate-',
    'REGEDIT selftest failed:',
    'FSDIAG ntfs metadata cache: FAILED',
    'FSDIAG result: FAILED',
    'selftest FAILED',
    'SERVMAN LOAD: lines=0',
    'dirs=missing',
    '$MFT',
    'STORDIAG result: FAILED',
    'Audio PCM continuity diagnostics: FAILED',
    'AUDIOD result: FAILED',
    'LOADERD result: FAILED',
    'RESDIAG result: FAILED',
    '[R4D] runtime load DISPBLIT [FAILED]',
    'DISPLAYD damage-present: FAILED',
    'DISPLAYD result: FAILED',
    'EXPLORER selftest FAILED',
    'SUBSYSTEM host selftest FAILED',
    'SUBSYSTEM runtime selftest FAILED',
    'SUBSYSTEM runtime bootstrap FAILED',
    'R4BASIC baseline: FAILED',
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
    param([string]$Text, [switch]$Quiet)

    $failures = 0
    if ($SmpFailedCount -ge [Math]::Max(1, $SmpCpuCount)) {
        if (-not $Quiet) { Write-Host 'SMP marker FAILED: failed CPU count must be smaller than configured CPU count.' }
        return 1
    }
    foreach ($marker in $required) {
        if ($Text.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            if (-not $Quiet) { Write-Host ('API diagnostic marker FAILED missing: ' + $marker) }
            $failures++
        } elseif (-not $Quiet) {
            Write-Host ('API diagnostic marker OK: ' + $marker)
        }
    }
    foreach ($marker in $forbidden) {
        if ($Text.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            if (-not $Quiet) { Write-Host ('API diagnostic marker FAILED forbidden: ' + $marker) }
            $failures++
        }
    }

    $baselineMatch = [regex]::Match($Text, '(?im)^R4BASIC baseline: OK id=([0-9A-F]{16}) mode=headless guest=C:\\TEMP\\GORILLA\.BAS source_bytes=29434 bytecode=(\d+)\r?$')
    if (-not $baselineMatch.Success -or [uint64]$baselineMatch.Groups[2].Value -eq 0) {
        if (-not $Quiet) { Write-Host 'R4BASIC baseline marker FAILED: canonical app/frame result missing.' }
        $failures++
    } else {
        $traceId = $baselineMatch.Groups[1].Value
        $timelinePattern = '(?im)^R4BASIC timeline: start_ns=(?<start>\d+) probe_ns=(?<probe>\d+) resolve_ns=(?<resolve>\d+) desktop_ns=(?<desktop>\d+) app_ns=(?<app>\d+) source_begin_ns=(?<source_begin>\d+) source_end_ns=(?<source_end>\d+) compile_begin_ns=(?<compile_begin>\d+) compile_visible_ns=(?<compile_visible>\d+) compile_end_ns=(?<compile_end>\d+) compile_updates=(?<compile_updates>\d+) vm_begin_ns=(?<vm_begin>\d+) vm_end_ns=(?<vm_end>\d+) host_ready_ns=(?<host_ready>\d+) initial_frame_ns=(?<initial_frame>\d+) runtime_begin_ns=(?<runtime_begin>\d+) first_instruction_ns=(?<first_instruction>\d+) audio_open_ns=(?<audio_open>\d+) first_frame_ns=(?<first_frame>\d+)\r?$'
        $timeline = [regex]::Match($Text, $timelinePattern)
        $compiler = [regex]::Match($Text, '(?im)^R4BASIC compiler: tokens=(?<tokens>\d+) keyword_lookups=(?<keyword_lookups>\d+) keyword_probes=(?<keyword_probes>\d+) keyword_max_probe=(?<keyword_max_probe>\d+) name_lookups=(?<name_lookups>\d+) name_insertions=(?<name_insertions>\d+) name_probes=(?<name_probes>\d+) name_max_probe=(?<name_max_probe>\d+) index_rebuilds=(?<index_rebuilds>\d+) label_fixups=(?<label_fixups>\d+) data_fixups=(?<data_fixups>\d+) reused_bindings=(?<reused_bindings>\d+) progress_updates=(?<progress_updates>\d+)\r?$')
        $runtime = [regex]::Match($Text, '(?im)^R4BASIC runtime: requested_operations=(\d+) executed_operations=(\d+) slices=(\d+) yields=(\d+) sleeps=(\d+) present_attempts=(\d+) presents=(\d+) skipped_presents=(\d+)\r?$')
        $admission = [regex]::Match($Text, '(?im)^\[R4BASIC-LAUNCH\] id=' + $traceId + ' mode=H phase=admission ns=(\d+)\r?$')
        $loader = [regex]::Match($Text, '(?im)^\[R4BASIC-LAUNCH\] id=' + $traceId + ' mode=H phase=loader-complete ns=(\d+) duration_ns=(\d+) range_reads=(\d+) fs_requests=(\d+) gate_waits=(\d+) fs_ticks=(\d+) sections=(\d+) imports=(\d+) relocations=(\d+)\r?$')
        $r4xstart = [regex]::Match($Text, '(?im)^\[R4BASIC-LAUNCH\] id=' + $traceId + ' mode=H phase=r4xstart ns=(\d+)\r?$')
        $timelineOk = $timeline.Success -and
            [uint64]$timeline.Groups['start'].Value -gt 0 -and
            [uint64]$timeline.Groups['probe'].Value -ge [uint64]$timeline.Groups['start'].Value -and
            [uint64]$timeline.Groups['resolve'].Value -ge [uint64]$timeline.Groups['probe'].Value -and
            [uint64]$timeline.Groups['desktop'].Value -ge [uint64]$timeline.Groups['resolve'].Value -and
            [uint64]$timeline.Groups['app'].Value -ge [uint64]$timeline.Groups['desktop'].Value -and
            [uint64]$timeline.Groups['source_begin'].Value -ge [uint64]$timeline.Groups['app'].Value -and
            [uint64]$timeline.Groups['source_end'].Value -ge [uint64]$timeline.Groups['source_begin'].Value -and
            [uint64]$timeline.Groups['compile_begin'].Value -ge [uint64]$timeline.Groups['source_end'].Value -and
            [uint64]$timeline.Groups['compile_visible'].Value -ge [uint64]$timeline.Groups['compile_begin'].Value -and
            [uint64]$timeline.Groups['compile_end'].Value -ge [uint64]$timeline.Groups['compile_visible'].Value -and
            [uint64]$timeline.Groups['compile_updates'].Value -gt 0 -and
            [uint64]$timeline.Groups['compile_end'].Value -ge [uint64]$timeline.Groups['compile_begin'].Value -and
            [uint64]$timeline.Groups['vm_begin'].Value -ge [uint64]$timeline.Groups['compile_end'].Value -and
            [uint64]$timeline.Groups['vm_end'].Value -ge [uint64]$timeline.Groups['vm_begin'].Value -and
            [uint64]$timeline.Groups['host_ready'].Value -ge [uint64]$timeline.Groups['vm_end'].Value -and
            [uint64]$timeline.Groups['initial_frame'].Value -ge [uint64]$timeline.Groups['host_ready'].Value -and
            [uint64]$timeline.Groups['runtime_begin'].Value -ge [uint64]$timeline.Groups['initial_frame'].Value -and
            [uint64]$timeline.Groups['first_instruction'].Value -ge [uint64]$timeline.Groups['runtime_begin'].Value -and
            [uint64]$timeline.Groups['first_frame'].Value -ge [uint64]$timeline.Groups['first_instruction'].Value
        $compilerOk = $compiler.Success -and
            [uint64]$compiler.Groups['tokens'].Value -gt 0 -and
            [uint64]$compiler.Groups['keyword_lookups'].Value -gt 0 -and
            [uint64]$compiler.Groups['keyword_probes'].Value -ge [uint64]$compiler.Groups['keyword_lookups'].Value -and
            [uint64]$compiler.Groups['keyword_max_probe'].Value -le 16 -and
            [uint64]$compiler.Groups['name_lookups'].Value -gt 0 -and
            [uint64]$compiler.Groups['name_insertions'].Value -gt 0 -and
            [uint64]$compiler.Groups['name_max_probe'].Value -le 64 -and
            [uint64]$compiler.Groups['name_probes'].Value -le
                (([uint64]$compiler.Groups['name_lookups'].Value + [uint64]$compiler.Groups['name_insertions'].Value) * 64) -and
            [uint64]$compiler.Groups['index_rebuilds'].Value -gt 0 -and
            [uint64]$compiler.Groups['label_fixups'].Value -gt 0 -and
            [uint64]$compiler.Groups['reused_bindings'].Value -gt 0 -and
            [uint64]$compiler.Groups['progress_updates'].Value -gt 0
        $runtimeOk = $runtime.Success -and
            [uint64]$runtime.Groups[1].Value -ge [uint64]$runtime.Groups[2].Value -and
            [uint64]$runtime.Groups[2].Value -gt 0 -and
            [uint64]$runtime.Groups[3].Value -gt 0 -and
            ([uint64]$runtime.Groups[4].Value + [uint64]$runtime.Groups[5].Value) -gt 0 -and
            [uint64]$runtime.Groups[6].Value -ge [uint64]$runtime.Groups[7].Value -and
            [uint64]$runtime.Groups[7].Value -gt 0
        $kernelOk = $timeline.Success -and $admission.Success -and $loader.Success -and $r4xstart.Success -and
            [uint64]$loader.Groups[3].Value -gt 0 -and
            [uint64]$loader.Groups[7].Value -gt 0 -and
            [uint64]$loader.Groups[9].Value -gt 0 -and
            [uint64]$admission.Groups[1].Value -le [uint64]$loader.Groups[1].Value -and
            [uint64]$loader.Groups[1].Value -le [uint64]$r4xstart.Groups[1].Value -and
            [uint64]$r4xstart.Groups[1].Value -le [uint64]$timeline.Groups['app'].Value
        if (-not $timelineOk -or -not $compilerOk -or -not $runtimeOk -or -not $kernelOk) {
            if (-not $Quiet) { Write-Host 'R4BASIC launch timeline FAILED: phase order, real work, or loader evidence invalid.' }
            $failures++
        } elseif (-not $Quiet) {
            Write-Host ('R4BASIC launch timeline OK: id=' + $traceId)
        }
    }

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
        $probePattern = '(?im)^\[SMPPROBE\] result=OK cpus=' + $expectedOnline +
            ' sequential_ns=\d+ parallel_ns=\d+ speedup_milli=(\d+)' +
            ' expected_mask=0x[0-9A-F]+ observed_mask=0x[0-9A-F]+ failures=0\r?$'
        $probeMatch = [regex]::Match($Text, $probePattern)
        if (-not $probeMatch.Success -or [uint64]$probeMatch.Groups[1].Value -lt 1050) {
            if (-not $Quiet) { Write-Host 'SMP marker FAILED: kernel work scaling probe missing or below 1.050x.' }
            $failures++
        } elseif (-not $Quiet) {
            Write-Host ('SMP kernel scaling marker OK: ' + $probeMatch.Groups[1].Value + ' milli.')
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
    $valid = ($required -join "`r`n") + "`r`n" +
        'APPPARITY lang=zig domain=3 raw=-5 payload=123 bytes=12 mutated=1 tail=1 handle_before=1 close=0 handle_after=0' + "`r`n" +
        'APPPARITY lang=c domain=3 raw=-5 payload=123 bytes=12 mutated=1 tail=1 handle_before=1 close=0 handle_after=0'
    $valid += "`r`n" +
        'R4BASIC baseline: OK id=0123456789ABCDEF mode=headless guest=C:\TEMP\GORILLA.BAS source_bytes=29434 bytecode=1234' + "`r`n" +
        'R4BASIC timeline: start_ns=100 probe_ns=110 resolve_ns=120 desktop_ns=130 app_ns=180 source_begin_ns=190 source_end_ns=200 compile_begin_ns=210 compile_visible_ns=215 compile_end_ns=220 compile_updates=6 vm_begin_ns=230 vm_end_ns=240 host_ready_ns=250 initial_frame_ns=260 runtime_begin_ns=270 first_instruction_ns=280 audio_open_ns=0 first_frame_ns=300' + "`r`n" +
        'R4BASIC compiler: tokens=4000 keyword_lookups=1000 keyword_probes=1200 keyword_max_probe=4 name_lookups=2000 name_insertions=300 name_probes=2600 name_max_probe=7 index_rebuilds=12 label_fixups=20 data_fixups=2 reused_bindings=500 progress_updates=24' + "`r`n" +
        'R4BASIC runtime: requested_operations=8192 executed_operations=5000 slices=2 yields=1 sleeps=0 present_attempts=1 presents=1 skipped_presents=0' + "`r`n" +
        '[R4BASIC-LAUNCH] id=0123456789ABCDEF mode=H phase=admission ns=140' + "`r`n" +
        '[R4BASIC-LAUNCH] id=0123456789ABCDEF mode=H phase=loader-complete ns=160 duration_ns=20 range_reads=12 fs_requests=13 gate_waits=0 fs_ticks=2 sections=4 imports=4 relocations=2110' + "`r`n" +
        '[R4BASIC-LAUNCH] id=0123456789ABCDEF mode=H phase=r4xstart ns=170'
    if ($SmpCpuCount -gt 1) {
        $expectedOnline = $SmpCpuCount - $SmpFailedCount
        $valid += "`r`n" + ('[SMP] stage=active discovered=' + $SmpCpuCount + ' started=' +
            ($SmpCpuCount - 1 - $SmpFailedCount) + ' online=' + $expectedOnline +
            ' failed=' + $SmpFailedCount + ' fallback=' + $(if ($expectedOnline -eq 1) { '1cpu' } else { 'no' })) +
            "`r`n[SMP] productive cpu=1 task=r4x-app class=r4x" +
            "`r`n[SMPPROBE] result=OK cpus=$expectedOnline sequential_ns=200 parallel_ns=100 speedup_milli=2000 expected_mask=0x0000000F observed_mask=0x0000000F failures=0"
        if ($SmpFailedCount -gt 0) {
            $valid += "`r`n[SMP] ap=2 apic=2 failed=diagnostic-injection"
        }
    } else {
        $valid += "`r`n[SMPPROBE] result=SKIPPED cpus=1 reason=single-cpu"
    }
    if ((Test-ApiMarkerContract $valid -Quiet) -ne 0) { throw 'valid marker set did not pass' }
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
$failures = Test-ApiMarkerContract ([IO.File]::ReadAllText($fullPath))
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
