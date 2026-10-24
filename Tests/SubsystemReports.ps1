# Current Spectra receipts and the original BASIC/GB/SNES report invariants.
# Shared by the full API marker gate and targeted owner qualification; no
# second scenario runner, synthetic guest result, or relaxed long-run gate.
function Read-R4SubsystemReportSet {
    param([Parameter(Mandatory)][string]$ImagePath,
          [Parameter(Mandatory)][string]$ImageMetadataPath)
    # The caller has joined QEMU. Read the original bounded files from that
    # exact disposable working disk; terminal repaint/serial rows are not a
    # lossless byte transport for long NDJSON or report lines.
    if (!('R4GuestNtfs' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot '../Tools/ReadGuestFile.cs')
    }
    $metadata = Get-Content -Raw -LiteralPath $ImageMetadataPath | ConvertFrom-Json
    $offset = [long]$metadata.installation.partitions.SYSTEM.firstLba * 512
    if ($offset -le 0) { throw 'Subsystem report SYSTEM partition missing' }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $reports = [Collections.Generic.List[string]]::new()
    foreach ($name in @('SUBSYS.OK','R4BASIC.BASELINE','R4GB.HOST',
            'R4GB-00000000000000A1.REPORT','R4GB-00000000000000B2.REPORT',
            'R4GB-00000000000000C3.REPORT','R4SNES.HOST',
            'R4SNES-00000000000000D1.REPORT','R4SNES-00000000000000D2.REPORT',
            'R4SNES-00000000000000D3.REPORT','R4SNES-00000000000000D4.REPORT')) {
        $bytes = [R4GuestNtfs]::ReadFile($ImagePath, $offset, ('/TEMP/' + $name), 256KB)
        if ($bytes.Length -eq 0) { throw ('Empty original subsystem report: ' + $name) }
        $reports.Add($utf8.GetString($bytes))
    }
    $ownerBytes = [R4GuestNtfs]::ReadFile($ImagePath, $offset, '/TEMP/SUBSYS86.JSONL', 1MB)
    if ($ownerBytes.Length -eq 0) { throw 'Empty original Spectra subsystem export' }
    return [pscustomobject]@{OwnerText=$utf8.GetString($ownerBytes);ReportText=($reports -join "`n")}
}

function Test-SpectraDesktopOwnerContract {
    param([string]$Text, [switch]$OriginalFile)
    try {
        $jsonLines = [Collections.Generic.List[string]]::new()
        foreach ($line in $Text.Split("`n")) {
            $offset = $line.IndexOf('{"schema":"r4os.spectra"', [StringComparison]::Ordinal)
            if ($offset -ge 0) { $jsonLines.Add($line.Substring($offset)) }
        }
        if ($jsonLines.Count -eq 0) { return $false }
        $records = Read-SpectraStructuredOutput -Text $(if ($OriginalFile) { $Text } else { $jsonLines -join "`n" })
        $desktopResults = @($records | Where-Object { $_.group -ceq 'DESKTOP' -and $_.kind -ceq 'result' })
        $subsystemResults = @($records | Where-Object { $_.group -ceq 'SUBSYSTEM' -and $_.kind -ceq 'result' })
        if ($desktopResults.Count -eq 0 -or $subsystemResults.Count -eq 0) { return $false }
        foreach ($record in @($desktopResults + $subsystemResults)) {
            $data = $record.data
            $code = [int]0
            if ($data.success -isnot [bool] -or !$data.success -or
                $data.cleanup_acknowledged -isnot [bool] -or !$data.cleanup_acknowledged -or
                ![int]::TryParse([string](Get-SpectraScalar $data.exit_code), [ref]$code) -or $code -ne 0) { return $false }
        }
        foreach ($record in $subsystemResults) {
            if ($record.data.scope -cne 'all' -or
                (Get-SpectraScalar $record.data.desktop_wire_version) -cne '2' -or
                (Get-SpectraScalar $record.data.long_run_pair_seconds) -cne '60') { return $false }
        }
        if (@($records | Where-Object { $_.kind -ceq 'unavailable' -and
            $_.group -cin @('DESKTOP','SUBSYSTEM','REMOTEFRAME') }).Count -ne 0) { return $false }
        $children = [Collections.Generic.HashSet[string]]::new()
        foreach ($record in @($records | Where-Object { $_.group -ceq 'DESKTOP' -and $_.kind -ceq 'completion' })) {
            $data = $record.data
            $id = [ulong]0; $generation = [ulong]0; $sequence = [ulong]0; $code = [int]0
            if ($data.reaped -isnot [bool] -or !$data.reaped -or
                ![ulong]::TryParse([string](Get-SpectraScalar $data.handle.instance_id), [ref]$id) -or $id -eq 0 -or
                ![ulong]::TryParse([string](Get-SpectraScalar $data.handle.generation), [ref]$generation) -or $generation -eq 0 -or
                ![ulong]::TryParse([string](Get-SpectraScalar $data.sequence), [ref]$sequence) -or $sequence -eq 0 -or
                ![int]::TryParse([string](Get-SpectraScalar $data.exit_code), [ref]$code) -or $code -ne 0) { return $false }
            $null = $children.Add(('{0}/{1}/{2}' -f $id,$generation,$sequence))
        }
        # Serial mirroring and later TYPE may contain the same full export.
        # Duplicate copies cannot manufacture a second owned generation.
        return $children.Count -ge 2
    } catch { return $false }
}

function Test-R4GbReportContract {
    param([string]$Text, [switch]$Quiet)
    $failures = 0
    $r4gbPattern = '(?im)^R4GB E2E runtime: OK id=(?<id>[0-9A-F]{16}) extension=(?<extension>\.gbc?) end=(?<end>witness|close) battery=(?<battery>[01]) rtc=(?<rtc>[01]) guest_ns=(?<guest_ns>\d+) guest_cycles=(?<guest_cycles>\d+) drift_cycles=(?<drift_cycles>\d+) ppu_frames=(?<ppu_frames>\d+) slices=(?<slices>\d+) max_slice=(?<max_slice>\d+) max_step_gap_ns=(?<max_step_gap_ns>\d+) input=(?<input>\d+) frames=(?<frames>\d+) dropped_presents=(?<dropped_presents>\d+) audio_writes=(?<audio_writes>\d+) audio_busy=(?<audio_busy>\d+) audio_failures=(?<audio_failures>\d+) audio_late=(?<audio_late>\d+) audio_discarded=(?<audio_discarded>\d+) audio_suppressed=(?<audio_suppressed>\d+) apu_generated=(?<apu_generated>\d+) apu_rendered=(?<apu_rendered>\d+) apu_dropped=(?<apu_dropped>\d+) apu_queued=(?<apu_queued>\d+) save_async_started=(?<save_async_started>\d+) save_async_completed=(?<save_async_completed>\d+) save_async_coalesced=(?<save_async_coalesced>\d+) save_async_errors=(?<save_async_errors>\d+) save_async_max_queued=(?<save_async_max_queued>\d+) pauses=(?<pauses>\d+) resumes=(?<resumes>\d+) resets=(?<resets>\d+) save_files=(?<save_files>[01]) close=(?<close>-?\d+) resources=closed\r?$'
    $r4gbReports = [regex]::Matches($Text, $r4gbPattern)
    $r4gbA = @($r4gbReports | Where-Object { $_.Groups['id'].Value -eq '00000000000000A1' })
    $r4gbB = @($r4gbReports | Where-Object { $_.Groups['id'].Value -eq '00000000000000B2' })
    $r4gbOk = $r4gbReports.Count -eq 2 -and $r4gbA.Count -eq 1 -and $r4gbB.Count -eq 1
    if ($r4gbOk) {
        $a = $r4gbA[0].Groups
        $b = $r4gbB[0].Groups
        $r4gbOk = $a['extension'].Value -eq '.gb' -and $a['end'].Value -eq 'witness' -and
            $a['battery'].Value -eq '0' -and $a['rtc'].Value -eq '0' -and
            $b['extension'].Value -eq '.gbc' -and $b['end'].Value -eq 'close' -and
            $b['battery'].Value -eq '1' -and $b['rtc'].Value -eq '1'
        foreach ($report in @($a, $b)) {
            $r4gbOk = $r4gbOk -and
                [uint64]$report['guest_ns'].Value -ge 59000000000 -and
                [uint64]$report['guest_cycles'].Value -gt 0 -and
                [uint64]$report['drift_cycles'].Value -le 32792 -and
                [uint64]$report['ppu_frames'].Value -ge 3400 -and
                [uint64]$report['slices'].Value -gt 0 -and
                [uint64]$report['max_slice'].Value -le 32792 -and
                [uint64]$report['max_step_gap_ns'].Value -le 250000000 -and
                [uint64]$report['input'].Value -ge 2 -and
                [uint64]$report['frames'].Value -gt 0 -and
                [uint64]$report['dropped_presents'].Value -eq 0 -and
                [uint64]$report['audio_writes'].Value -ge 5000 -and
                [uint64]$report['audio_busy'].Value -eq 0 -and
                [uint64]$report['audio_failures'].Value -eq 0 -and
                [uint64]$report['audio_late'].Value -eq 0 -and
                [uint64]$report['apu_generated'].Value -gt 0 -and
                [uint64]$report['apu_rendered'].Value -gt 0 -and
                [uint64]$report['apu_dropped'].Value -eq 0 -and
                [uint64]$report['apu_queued'].Value -le 7680 -and
                [uint64]$report['save_async_errors'].Value -eq 0 -and
                [uint64]$report['save_async_max_queued'].Value -le 3 -and
                $report['save_files'].Value -eq '1' -and
                [int]$report['close'].Value -eq 0
        }
        $r4gbOk = $r4gbOk -and [uint64]$a['apu_queued'].Value -eq 0 -and
            [uint64]$a['save_async_started'].Value -eq 0 -and
            [uint64]$a['save_async_completed'].Value -eq 0 -and
            [uint64]$b['save_async_started'].Value -gt 0 -and
            [uint64]$b['save_async_started'].Value -eq [uint64]$b['save_async_completed'].Value
        $r4gbOk = $r4gbOk -and [uint64]$a['pauses'].Value -ge 1 -and
            [uint64]$a['resumes'].Value -ge 1 -and [uint64]$a['resets'].Value -ge 1
    }
    if (-not $r4gbOk) {
        if (-not $Quiet) { Write-Host 'R4GB long-run reports FAILED: exact duration, drift, frame, audio or lifecycle invariants missing.' }
        $failures++
    } elseif (-not $Quiet) {
        Write-Host 'R4GB long-run reports OK: 60-second witness/close instances satisfy timing and lifecycle invariants.'
    }
    return $failures
}

function Test-R4SnesReportContract {
    param([string]$Text, [switch]$Quiet)
    $failures = 0

    $r4snesPattern = '(?im)^R4SNES E2E runtime: OK id=(?<id>[0-9A-F]{16}) extension=(?<extension>\.sfc|\.smc) end=(?<end>witness|close) battery=(?<battery>[01]) rtc=(?<rtc>[01]) guest_ns=(?<guest_ns>\d+) guest_cycles=(?<guest_cycles>\d+) master_hz=(?<master_hz>\d+) drift_cycles=(?<drift_cycles>\d+) pending_cycles=(?<pending_cycles>\d+) ppu_frames=(?<ppu_frames>\d+) slices=(?<slices>\d+) max_slice_grant=(?<max_slice_grant>\d+) max_slice_execution=(?<max_slice_execution>\d+) max_step_gap_ns=(?<max_step_gap_ns>\d+) input=(?<input>\d+) controller=0x(?<controller>[0-9a-fA-F]{4}) completion=(?<completion>[01]) frames=(?<frames>\d+) dropped_presents=(?<dropped_presents>\d+) audio_writes=(?<audio_writes>\d+) audio_busy=(?<audio_busy>\d+) audio_failures=(?<audio_failures>\d+) audio_late=(?<audio_late>\d+) audio_discarded=(?<audio_discarded>\d+) audio_paused=(?<audio_paused>\d+) audio_muted=(?<audio_muted>\d+) audio_suppressed=(?<audio_suppressed>\d+) dsp_native=(?<dsp_native>\d+) dsp_resampled=(?<dsp_resampled>\d+) dsp_rendered=(?<dsp_rendered>\d+) dsp_non_silent=(?<dsp_non_silent>\d+) dsp_dropped=(?<dsp_dropped>\d+) dsp_queued=(?<dsp_queued>\d+) save_async_started=(?<save_async_started>\d+) save_async_completed=(?<save_async_completed>\d+) save_async_coalesced=(?<save_async_coalesced>\d+) save_async_errors=(?<save_async_errors>\d+) save_async_max_queued=(?<save_async_max_queued>\d+) pauses=(?<pauses>\d+) resumes=(?<resumes>\d+) resets=(?<resets>\d+) save_files=(?<save_files>[01]) close=(?<close>-?\d+) resources=closed\r?$'
    $r4snesReports = [regex]::Matches($Text, $r4snesPattern)
    $r4snesA = @($r4snesReports | Where-Object { $_.Groups['id'].Value -eq '00000000000000D1' })
    $r4snesB = @($r4snesReports | Where-Object { $_.Groups['id'].Value -eq '00000000000000D2' })
    $r4snesOk = $r4snesReports.Count -eq 2 -and $r4snesA.Count -eq 1 -and $r4snesB.Count -eq 1
    if ($r4snesOk) {
        $snesA = $r4snesA[0].Groups
        $snesB = $r4snesB[0].Groups
        $r4snesOk = $snesA['extension'].Value -eq '.sfc' -and $snesA['end'].Value -eq 'witness' -and
            $snesA['battery'].Value -eq '0' -and $snesA['rtc'].Value -eq '0' -and $snesA['completion'].Value -eq '1' -and
            $snesB['extension'].Value -eq '.smc' -and $snesB['end'].Value -eq 'close' -and
            $snesB['battery'].Value -eq '1' -and $snesB['rtc'].Value -eq '1'
        foreach ($report in @($snesA, $snesB)) {
            $r4snesOk = $r4snesOk -and
                [uint64]$report['guest_ns'].Value -ge 59000000000 -and
                [uint64]$report['guest_cycles'].Value -gt 0 -and
                [uint64]$report['master_hz'].Value -eq 21477272 -and
                [uint64]$report['drift_cycles'].Value -le 32832 -and
                [uint64]$report['pending_cycles'].Value -le 32768 -and
                [uint64]$report['ppu_frames'].Value -ge 3400 -and
                [uint64]$report['slices'].Value -gt 0 -and
                [uint64]$report['max_slice_grant'].Value -le 32768 -and
                [uint64]$report['max_slice_execution'].Value -le 32832 -and
                [uint64]$report['max_step_gap_ns'].Value -le 250000000 -and
                [uint64]$report['input'].Value -ge 2 -and
                [Convert]::ToUInt32($report['controller'].Value, 16) -ne 0 -and
                [uint64]$report['frames'].Value -gt 0 -and
                [uint64]$report['dropped_presents'].Value -eq 0 -and
                [uint64]$report['audio_writes'].Value -ge 5000 -and
                [uint64]$report['audio_busy'].Value -eq 0 -and
                [uint64]$report['audio_failures'].Value -eq 0 -and
                [uint64]$report['audio_late'].Value -eq 0 -and
                [uint64]$report['audio_discarded'].Value -eq
                    ([uint64]$report['audio_paused'].Value + [uint64]$report['audio_muted'].Value) -and
                [uint64]$report['dsp_native'].Value -gt 0 -and
                [uint64]$report['dsp_resampled'].Value -gt 0 -and
                [uint64]$report['dsp_rendered'].Value -gt 0 -and
                [uint64]$report['dsp_non_silent'].Value -gt 0 -and
                [uint64]$report['dsp_dropped'].Value -eq 0 -and
                [uint64]$report['dsp_queued'].Value -le 8192 -and
                [uint64]$report['save_async_errors'].Value -eq 0 -and
                [uint64]$report['save_async_max_queued'].Value -le 3 -and
                $report['save_files'].Value -eq '1' -and [int]$report['close'].Value -eq 0
        }
        $r4snesOk = $r4snesOk -and [uint64]$snesA['dsp_queued'].Value -eq 0 -and
            [uint64]$snesA['save_async_started'].Value -eq 0 -and
            [uint64]$snesA['save_async_completed'].Value -eq 0 -and
            [uint64]$snesA['pauses'].Value -ge 1 -and [uint64]$snesA['resumes'].Value -ge 1 -and
            [uint64]$snesA['resets'].Value -ge 1 -and
            [uint64]$snesB['save_async_started'].Value -gt 0 -and
            [uint64]$snesB['save_async_started'].Value -eq [uint64]$snesB['save_async_completed'].Value
    }
    if (-not $r4snesOk) {
        if (-not $Quiet) { Write-Host 'R4SNES long-run reports FAILED: duration, clock debt, frame, audio, persistence or lifecycle invariants missing.' }
        $failures++
    } elseif (-not $Quiet) {
        Write-Host 'R4SNES long-run reports OK: 60-second witness/close instances satisfy timing and lifecycle invariants.'
    }
    return $failures
}

function Test-R4BasicReportContract {
    param([string]$Text, [switch]$Quiet)
    $failures = 0

    $baselineMatch = [regex]::Match($Text, '(?im)^R4BASIC baseline: OK id=([0-9A-F]{16}) mode=headless guest=C:\\TEMP\\GORILLA\.BAS source_bytes=29434 bytecode=(\d+)\r?$')
    if (-not $baselineMatch.Success -or [uint64]$baselineMatch.Groups[2].Value -eq 0) {
        if (-not $Quiet) { Write-Host 'R4BASIC baseline marker FAILED: canonical app/frame result missing.' }
        $failures++
    } else {
        $traceId = $baselineMatch.Groups[1].Value
        $timelinePattern = '(?im)^R4BASIC timeline: start_ns=(?<start>\d+) probe_ns=(?<probe>\d+) resolve_ns=(?<resolve>\d+) desktop_ns=(?<desktop>\d+) app_ns=(?<app>\d+) source_begin_ns=(?<source_begin>\d+) source_end_ns=(?<source_end>\d+) compile_begin_ns=(?<compile_begin>\d+) compile_visible_ns=(?<compile_visible>\d+) compile_end_ns=(?<compile_end>\d+) compile_updates=(?<compile_updates>\d+) vm_begin_ns=(?<vm_begin>\d+) vm_end_ns=(?<vm_end>\d+) host_ready_ns=(?<host_ready>\d+) initial_frame_ns=(?<initial_frame>\d+) runtime_begin_ns=(?<runtime_begin>\d+) first_instruction_ns=(?<first_instruction>\d+) audio_open_ns=(?<audio_open>\d+) first_frame_ns=(?<first_frame>\d+)\r?$'
        $timeline = [regex]::Match($Text, $timelinePattern)
        $compiler = [regex]::Match($Text, '(?im)^R4BASIC compiler: tokens=(?<tokens>\d+) token_capacity=(?<token_capacity>\d+) keyword_lookups=(?<keyword_lookups>\d+) keyword_probes=(?<keyword_probes>\d+) keyword_max_probe=(?<keyword_max_probe>\d+) name_lookups=(?<name_lookups>\d+) name_insertions=(?<name_insertions>\d+) name_probes=(?<name_probes>\d+) name_max_probe=(?<name_max_probe>\d+) index_rebuilds=(?<index_rebuilds>\d+) constant_lookups=(?<constant_lookups>\d+) constant_reuses=(?<constant_reuses>\d+) constant_probes=(?<constant_probes>\d+) constant_max_probe=(?<constant_max_probe>\d+) label_fixups=(?<label_fixups>\d+) data_fixups=(?<data_fixups>\d+) reused_bindings=(?<reused_bindings>\d+) expression_depth=(?<expression_depth>\d+) progress_updates=(?<progress_updates>\d+)\r?$')
        $compilerMemory = [regex]::Match($Text, '(?im)^R4BASIC compiler-memory: token_bytes=(?<token_bytes>\d+) initial_list_bytes=(?<initial_list_bytes>\d+) instruction_hot_bytes=(?<instruction_hot_bytes>\d+) instruction_metadata_bytes=(?<instruction_metadata_bytes>\d+) allocations=(?<allocations>\d+) reallocations=(?<reallocations>\d+) copy_bytes=(?<copy_bytes>\d+) peak_bytes=(?<peak_bytes>\d+) program_bytes=(?<program_bytes>\d+) adopted_source_bytes=(?<adopted_source_bytes>\d+) diagnostics_total=(?<diagnostics_total>\d+) diagnostics_stored=(?<diagnostics_stored>\d+) diagnostics_truncated=(?<diagnostics_truncated>[01])\r?$')
        $compilerVm = [regex]::Match($Text, '(?im)^R4BASIC compiler-vm: allocations=(?<allocations>\d+) frees=(?<frees>\d+) active_before=(?<active_before>\d+) active_after=(?<active_after>\d+) peak_active=(?<peak_active>\d+) reserved_before=(?<reserved_before>\d+) reserved_after=(?<reserved_after>\d+) committed_before=(?<committed_before>\d+) committed_after=(?<committed_after>\d+)\r?$')
        $runtime = [regex]::Match($Text, '(?im)^R4BASIC runtime: cycles=(?<cycles>\d+) close_checks=(?<close_checks>\d+) host_polls=(?<host_polls>\d+) poll_budget_exhaustions=(?<poll_budget_exhaustions>\d+) active_cycles=(?<active_cycles>\d+) waiting_cycles=(?<waiting_cycles>\d+) paused_cycles=(?<paused_cycles>\d+) requested_operations=(?<requested>\d+) executed_operations=(?<executed>\d+) slices=(?<slices>\d+) active_continues=(?<active_continues>\d+) yields=(?<yields>\d+) sleeps=(?<sleeps>\d+) event_waits=(?<event_waits>\d+) event_wakes=(?<event_wakes>\d+) event_timeouts=(?<event_timeouts>\d+) wait_failures=(?<wait_failures>\d+) zero_progress_waits=(?<zero_progress_waits>\d+) present_attempts=(?<present_attempts>\d+) presents=(?<presents>\d+) unchanged_presents=(?<unchanged_presents>\d+) hidden_presents=(?<hidden_presents>\d+) dropped_presents=(?<dropped_presents>\d+)\r?$')
        $adapter = [regex]::Match($Text, '(?im)^R4BASIC adapter: steps=(?<steps>\d+) instructions=(?<instructions>\d+) max_slice=(?<max_slice>\d+) budget_limited=(?<budget_limited>\d+) time_limited=(?<time_limited>\d+) frame_ready=(?<frame_ready>\d+) display_prepares=(?<display_prepares>\d+) clock_reads=(?<clock_reads>\d+) max_clock_reads=(?<max_clock_reads>\d+) max_clock_chunk=(?<max_clock_chunk>\d+) active_vm_ns=(?<active_vm_ns>\d+) ns_per_instruction=(?<ns_per_instruction>\d+)\r?$')
        $input = [regex]::Match($Text, '(?im)^R4BASIC input: raw=(?<raw>\d+) translated=(?<translated>\d+) filtered=(?<filtered>\d+) pending_created=(?<pending_created>\d+) pending_emitted=(?<pending_emitted>\d+) mouse_events=(?<mouse_events>\d+) mouse_moves=(?<mouse_moves>\d+) mouse_mappings=(?<mouse_mappings>\d+) window_info=(?<window_info>\d+) input_window_info=(?<input_window_info>\d+) viewport_calculations=(?<viewport_calculations>\d+) adapter_events=(?<adapter_events>\d+) accepted=(?<accepted>\d+) controls=(?<controls>\d+) dropped=(?<dropped>\d+) runtime_input=(?<runtime_input>\d+) runtime_ignored=(?<runtime_ignored>\d+) queue=(?<queue>\d+) queue_max=(?<queue_max>\d+) consumed=(?<consumed>\d+) unfocused=(?<unfocused>\d+) invalid_codepoint=(?<invalid_codepoint>\d+) unsupported_key=(?<unsupported_key>\d+) unsupported_event=(?<unsupported_event>\d+) queue_full=(?<queue_full>\d+) oom=(?<oom>\d+)\r?$')
        $inputCorrelation = [regex]::Match($Text, '(?im)^R4BASIC input-correlation: last_raw_sequence=(?<last_raw_sequence>\d+) last_raw_tick=(?<last_raw_tick>\d+) last_filter_sequence=(?<last_filter_sequence>\d+) last_filter_tick=(?<last_filter_tick>\d+) last_filter_reason=(?<last_filter_reason>[a-z_]+) last_event_sequence=(?<last_event_sequence>\d+) last_event_tick=(?<last_event_tick>\d+) last_accepted_sequence=(?<last_accepted_sequence>\d+) last_accepted_tick=(?<last_accepted_tick>\d+) last_dropped_sequence=(?<last_dropped_sequence>\d+) last_dropped_tick=(?<last_dropped_tick>\d+) last_drop_reason=(?<last_drop_reason>[a-z_]+) last_consumed_sequence=(?<last_consumed_sequence>\d+) last_consumed_tick=(?<last_consumed_tick>\d+) visible_sequence=(?<visible_sequence>\d+) visible_tick=(?<visible_tick>\d+) visible_reaction_ns=(?<visible_reaction_ns>\d+)\r?$')
        $frameCycle = [regex]::Match($Text, '(?im)^R4BASIC frame-cycle: cadence_deferred=(?<cadence_deferred>\d+) missed_deadlines=(?<missed_deadlines>\d+) max_backlog=(?<max_backlog>\d+) attempts=(?<attempts>\d+) published=(?<published>\d+) unchanged=(?<unchanged>\d+) hidden=(?<hidden>\d+) dropped=(?<dropped>\d+) failed=(?<failed>\d+) present_ns=(?<present_ns>\d+) max_present_ns=(?<max_present_ns>\d+) max_age_start_ns=(?<max_age_start_ns>\d+) max_age_end_ns=(?<max_age_end_ns>\d+)\r?$')
        $vm = [regex]::Match($Text, '(?im)^R4BASIC vm: cancel_flag_checks=(?<cancel_flag_checks>\d+) cancel_callback_checks=(?<cancel_callback_checks>\d+) group_lookups=(?<group_lookups>\d+) text_sync_checks=(?<text_sync_checks>\d+) text_sync_renders=(?<text_sync_renders>\d+) metadata_reads=(?<metadata_reads>\d+) cell_resolves=(?<cell_resolves>\d+) alias_hops=(?<alias_hops>\d+) same_type_store_moves=(?<same_type_store_moves>\d+) conversions=(?<conversions>\d+) integer_comparisons=(?<integer_comparisons>\d+) floating_comparisons=(?<floating_comparisons>\d+) string_comparisons=(?<string_comparisons>\d+) timer_calls=(?<timer_calls>\d+) timer_waits=(?<timer_waits>\d+) timer_max_wake_lateness_ns=(?<timer_late>\d+)\r?$')
        $raster = [regex]::Match($Text, '(?im)^R4BASIC raster: mode_allocations=(?<mode_allocations>\d+) mode_reuses=(?<mode_reuses>\d+) mode_clear_bytes=(?<mode_clear_bytes>\d+) pixel_probes=(?<pixel_probes>\d+) pixel_changes=(?<pixel_changes>\d+) spans=(?<spans>\d+) span_pixels=(?<span_pixels>\d+) damage_commits=(?<damage_commits>\d+) text_cells=(?<text_cells>\d+) text_rows=(?<text_rows>\d+) line_segments=(?<line_segments>\d+) line_pixels=(?<line_pixels>\d+) fill_spans=(?<fill_spans>\d+) paint_spans=(?<paint_spans>\d+) paint_pixels=(?<paint_pixels>\d+) paint_probes=(?<paint_probes>\d+) paint_pushes=(?<paint_pushes>\d+) paint_pops=(?<paint_pops>\d+) paint_duplicate_pops=(?<paint_duplicate_pops>\d+) paint_grows=(?<paint_grows>\d+) paint_queue_max=(?<paint_queue_max>\d+) circle_requested=(?<circle_requested>\d+) circle_segments=(?<circle_segments>\d+) circle_skipped=(?<circle_skipped>\d+) capture_calls=(?<capture_calls>\d+) capture_pixels=(?<capture_pixels>\d+) capture_bytes=(?<capture_bytes>\d+) put_calls=(?<put_calls>\d+) put_pixels=(?<put_pixels>\d+) put_bytes=(?<put_bytes>\d+)\r?$')
        $damage = [regex]::Match($Text, '(?im)^R4BASIC damage: commits=(?<commits>\d+) regions=(?<regions>\d+) merges=(?<merges>\d+) overflow_merges=(?<overflow_merges>\d+) full_commits=(?<full_commits>\d+)\r?$')
        $ownership = [regex]::Match($Text, '(?im)^R4BASIC ownership: compile_borrowed=(?<compile_borrowed>\d+) string_clones=(?<string_clones>\d+) string_clone_bytes=(?<string_clone_bytes>\d+) builtin_borrowed=(?<builtin_borrowed>\d+) builtin_owned=(?<builtin_owned>\d+) procedure_calls=(?<procedure_calls>\d+) local_pool_grows=(?<local_pool_grows>\d+) local_pool_reuses=(?<local_pool_reuses>\d+) local_initializations=(?<local_initializations>\d+) local_initialization_bytes=(?<local_initialization_bytes>\d+) local_aggregate_initializations=(?<local_aggregate_initializations>\d+) format_stack_uses=(?<format_stack_uses>\d+) str_result_allocations=(?<str_result_allocations>\d+) val_direct=(?<val_direct>\d+) val_stack=(?<val_stack>\d+) val_scratch=(?<val_scratch>\d+) val_scratch_grows=(?<val_scratch_grows>\d+)\r?$')
        $storage = [regex]::Match($Text, '(?im)^R4BASIC storage: compact_array_resizes=(?<compact_array_resizes>\d+) generic_array_resizes=(?<generic_array_resizes>\d+) compact_array_elements=(?<compact_array_elements>\d+) generic_array_initializations=(?<generic_array_initializations>\d+) array_live_bytes=(?<array_live_bytes>\d+) array_live_peak_bytes=(?<array_live_peak_bytes>\d+) array_resize_live_peak_bytes=(?<array_resize_live_peak_bytes>\d+) array_live_limit_bytes=(?<array_live_limit_bytes>\d+) array_resize_live_limit_bytes=(?<array_resize_live_limit_bytes>\d+) vm_static_bytes=(?<vm_static_bytes>\d+) file_index_bytes=(?<file_index_bytes>\d+) file_capacity_grows=(?<file_capacity_grows>\d+) max_open_files=(?<max_open_files>\d+)\r?$')
        $fileHost = [regex]::Match($Text, '(?im)^R4BASIC file-host: reads=(?<reads>\d+) read_bytes=(?<read_bytes>\d+) writes=(?<writes>\d+) write_bytes=(?<write_bytes>\d+) failures=(?<failures>\d+)\r?$')
        $fileIo = [regex]::Match($Text, '(?im)^R4BASIC file-io: batch_bytes=(?<batch_bytes>\d+) read_submissions=(?<read_submissions>\d+) write_submissions=(?<write_submissions>\d+) status_polls=(?<status_polls>\d+) pending_polls=(?<pending_polls>\d+) completions=(?<completions>\d+) path_normalizations=(?<path_normalizations>\d+) path_cache_hits=(?<path_cache_hits>\d+) max_request_bytes=(?<max_request_bytes>\d+) max_active_requests=(?<max_active_requests>\d+) input_refills=(?<input_refills>\d+) output_flushes=(?<output_flushes>\d+) waits=(?<waits>\d+) input_compaction_bytes=(?<input_compaction_bytes>\d+) output_compaction_bytes=(?<output_compaction_bytes>\d+) input_buffer_peak_bytes=(?<input_buffer_peak_bytes>\d+) output_buffer_peak_bytes=(?<output_buffer_peak_bytes>\d+)\r?$')
        $presenter = [regex]::Match($Text, '(?im)^R4BASIC presenter: published_frames=(?<published_frames>\d+) skipped_frames=(?<skipped_frames>\d+) full_frames=(?<full_frames>\d+) damage_frames=(?<damage_frames>\d+) replacement_frames=(?<replacement_frames>\d+) compacted_frames=(?<compacted_frames>\d+) damage_regions=(?<damage_regions>\d+) indexed8_frames=(?<indexed8_frames>\d+) indexed8_blocks=(?<indexed8_blocks>\d+) indexed8_resource_bytes=(?<indexed8_resource_bytes>\d+) xrgb_fallback_frames=(?<xrgb_fallback_frames>\d+) raster_blocks=(?<raster_blocks>\d+) sampled_pixels=(?<sampled_pixels>\d+)\r?$')
        $audio = [regex]::Match($Text, '(?im)^R4BASIC audio: state=(?<state>[a-z_]+) muted=(?<muted>[01]) playback=unavailable lazy_opens=(?<lazy_opens>\d+) service_ops=(?<service_ops>\d+) service_ops_cycle_max=(?<service_ops_cycle_max>\d+) opens=(?<opens>\d+) writes=(?<writes>\d+) closes=(?<closes>\d+) active_cycles=(?<active_cycles>\d+) silent_cycles=(?<silent_cycles>\d+) paused_cycles=(?<paused_cycles>\d+) muted_cycles=(?<muted_cycles>\d+) active_quanta=(?<active_quanta>\d+) silent_quanta=(?<silent_quanta>\d+) generated_bytes=(?<generated_bytes>\d+) accepted_bytes=(?<accepted_bytes>\d+) suppressed_bytes=(?<suppressed_bytes>\d+) discarded_bytes=(?<discarded_bytes>\d+) paused_bytes=(?<paused_bytes>\d+) muted_bytes=(?<muted_bytes>\d+) busy=(?<busy>\d+) resyncs=(?<resyncs>\d+)\r?$')
        $audioGuest = [regex]::Match($Text, '(?im)^R4BASIC audio-guest: scheduled_frames=(?<scheduled_frames>\d+) accepted_frames=(?<accepted_frames>\d+) suppressed_frames=(?<suppressed_frames>\d+) discarded_frames=(?<discarded_frames>\d+) resolved_frames=(?<resolved_frames>\d+) unresolved_frames=(?<unresolved_frames>\d+) foreground_waits=(?<foreground_waits>\d+) foreground_wakes=(?<foreground_wakes>\d+) background=(?<background>\d+) direct_events=(?<direct_events>\d+) reserve_grows=(?<reserve_grows>\d+) phase_lookups=(?<phase_lookups>\d+)\r?$')
        $stackHighWater = [regex]::Match($Text, '(?im)^\[R4XSTACK\] highwater owner=(?<owner>\d+) detail=(?<detail>on|off) thread=0 module=C:\\R4OS\\SUBSYSTEMS\\r4os\.basic\\R4BASIC\.R4X profile=desktop reserve=(?<reserve>\d+) initial=(?<initial>\d+) committed=(?<committed>\d+) highwater=(?<highwater>\d+) create_cycles=(?<create_cycles>\d+)\r?$')
        $stackRelease = if ($stackHighWater.Success) {
            [regex]::Match($Text, '(?im)^\[R4XSTACK\] release owner=' + [regex]::Escape($stackHighWater.Groups['owner'].Value) + ' detail=(?<detail>on|off) profile=desktop reserve=(?<reserve>\d+) initial=(?<initial>\d+) committed=(?<committed>\d+) highwater=(?<highwater>\d+) creates=(?<creates>\d+) releases=(?<releases>\d+) create_cycles=(?<create_cycles>\d+) create_cycles_max=(?<create_cycles_max>\d+) release_cycles=(?<release_cycles>\d+) release_cycles_max=(?<release_cycles_max>\d+) kernel_highwater_max=(?<kernel_highwater>\d+) kernel_create_cycles_max=(?<kernel_create_cycles>\d+) kernel_release_cycles_max=(?<kernel_release_cycles>\d+) kernel_cache_cached=(?<cache_cached>\d+) kernel_cache_hits=(?<cache_hits>\d+) kernel_cache_misses=(?<cache_misses>\d+) critical_available=(?<critical_available>\d+) critical_in_use=(?<critical_in_use>\d+)\r?$')
        } else {
            [System.Text.RegularExpressions.Match]::Empty
        }
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
            [uint64]$timeline.Groups['initial_frame'].Value -eq 0 -and
            [uint64]$timeline.Groups['runtime_begin'].Value -ge [uint64]$timeline.Groups['host_ready'].Value -and
            [uint64]$timeline.Groups['first_instruction'].Value -ge [uint64]$timeline.Groups['runtime_begin'].Value -and
            [uint64]$timeline.Groups['first_frame'].Value -ge [uint64]$timeline.Groups['first_instruction'].Value
        $compilerOk = $compiler.Success -and
            [uint64]$compiler.Groups['tokens'].Value -gt 0 -and
            [uint64]$compiler.Groups['token_capacity'].Value -eq [uint64]$compiler.Groups['tokens'].Value -and
            [uint64]$compiler.Groups['keyword_lookups'].Value -gt 0 -and
            [uint64]$compiler.Groups['keyword_probes'].Value -ge [uint64]$compiler.Groups['keyword_lookups'].Value -and
            [uint64]$compiler.Groups['keyword_max_probe'].Value -le 16 -and
            [uint64]$compiler.Groups['name_lookups'].Value -gt 0 -and
            [uint64]$compiler.Groups['name_insertions'].Value -gt 0 -and
            [uint64]$compiler.Groups['name_max_probe'].Value -le 64 -and
            [uint64]$compiler.Groups['name_probes'].Value -le
                (([uint64]$compiler.Groups['name_lookups'].Value + [uint64]$compiler.Groups['name_insertions'].Value) * 64) -and
            [uint64]$compiler.Groups['index_rebuilds'].Value -gt 0 -and
            [uint64]$compiler.Groups['constant_lookups'].Value -gt 0 -and
            [uint64]$compiler.Groups['constant_reuses'].Value -gt 0 -and
            ([uint64]$compiler.Groups['constant_probes'].Value + 1) -ge [uint64]$compiler.Groups['constant_lookups'].Value -and
            [uint64]$compiler.Groups['constant_max_probe'].Value -le 32 -and
            [uint64]$compiler.Groups['label_fixups'].Value -gt 0 -and
            [uint64]$compiler.Groups['reused_bindings'].Value -gt 0 -and
            [uint64]$compiler.Groups['expression_depth'].Value -gt 0 -and
            [uint64]$compiler.Groups['expression_depth'].Value -le 128 -and
            [uint64]$compiler.Groups['progress_updates'].Value -gt 0
        $compilerMemoryOk = $compilerMemory.Success -and
            [uint64]$compilerMemory.Groups['token_bytes'].Value -gt 0 -and
            [uint64]$compilerMemory.Groups['initial_list_bytes'].Value -gt 0 -and
            [uint64]$compilerMemory.Groups['instruction_hot_bytes'].Value -eq
                ([uint64]$baselineMatch.Groups[2].Value * 12) -and
            [uint64]$compilerMemory.Groups['instruction_metadata_bytes'].Value -eq
                ([uint64]$baselineMatch.Groups[2].Value * 32) -and
            [uint64]$compilerMemory.Groups['allocations'].Value -gt 0 -and
            [uint64]$compilerMemory.Groups['peak_bytes'].Value -ge [uint64]$compilerMemory.Groups['program_bytes'].Value -and
            [uint64]$compilerMemory.Groups['peak_bytes'].Value -ge [uint64]$compilerMemory.Groups['token_bytes'].Value -and
            [uint64]$compilerMemory.Groups['program_bytes'].Value -gt 0 -and
            [uint64]$compilerMemory.Groups['adopted_source_bytes'].Value -eq 29434 -and
            [uint64]$compilerMemory.Groups['diagnostics_total'].Value -eq 0 -and
            [uint64]$compilerMemory.Groups['diagnostics_stored'].Value -eq 0 -and
            [uint64]$compilerMemory.Groups['diagnostics_truncated'].Value -eq 0
        $compilerVmOk = $compilerVm.Success -and
            [uint64]$compilerVm.Groups['allocations'].Value -gt 0 -and
            [uint64]$compilerVm.Groups['frees'].Value -gt 0 -and
            [uint64]$compilerVm.Groups['active_after'].Value -gt [uint64]$compilerVm.Groups['active_before'].Value -and
            [uint64]$compilerVm.Groups['peak_active'].Value -gt 0 -and
            [uint64]$compilerVm.Groups['reserved_before'].Value -ge [uint64]$compilerVm.Groups['committed_before'].Value -and
            [uint64]$compilerVm.Groups['reserved_after'].Value -ge [uint64]$compilerVm.Groups['committed_after'].Value -and
            [uint64]$compilerVm.Groups['committed_after'].Value -ge [uint64]$compilerVm.Groups['active_after'].Value
        $runtimeOk = $runtime.Success -and
            [uint64]$runtime.Groups['cycles'].Value -gt 0 -and
            [uint64]$runtime.Groups['close_checks'].Value -eq [uint64]$runtime.Groups['cycles'].Value -and
            [uint64]$runtime.Groups['host_polls'].Value -ge [uint64]$runtime.Groups['cycles'].Value -and
            [uint64]$runtime.Groups['host_polls'].Value -le ([uint64]$runtime.Groups['cycles'].Value * 65) -and
            [uint64]$runtime.Groups['poll_budget_exhaustions'].Value -eq 0 -and
            [uint64]$runtime.Groups['requested'].Value -ge [uint64]$runtime.Groups['executed'].Value -and
            [uint64]$runtime.Groups['executed'].Value -gt 0 -and
            [uint64]$runtime.Groups['slices'].Value -gt 0 -and
            [uint64]$runtime.Groups['active_continues'].Value -gt 0 -and
            [uint64]$runtime.Groups['yields'].Value -le [uint64]$runtime.Groups['active_continues'].Value -and
            [uint64]$runtime.Groups['wait_failures'].Value -eq 0 -and
            [uint64]$runtime.Groups['present_attempts'].Value -ge [uint64]$runtime.Groups['presents'].Value -and
            [uint64]$runtime.Groups['presents'].Value -gt 0
        $adapterOk = $adapter.Success -and
            [uint64]$adapter.Groups['steps'].Value -gt 0 -and
            [uint64]$adapter.Groups['instructions'].Value -gt 0 -and
            [uint64]$adapter.Groups['max_slice'].Value -le 262144 -and
            [uint64]$adapter.Groups['clock_reads'].Value -gt 0 -and
            # The mixed GORILLA workload crosses instruction-cost phases
            # within one slice. Its cumulative adaptive estimate can need a
            # few more probes than the homogeneous <=20-read microbench while
            # the independent 8 ms time limit and 262144-operation cap remain
            # authoritative.
            [uint64]$adapter.Groups['max_clock_reads'].Value -le 32 -and
            [uint64]$adapter.Groups['max_clock_chunk'].Value -le 16384 -and
            [uint64]$adapter.Groups['active_vm_ns'].Value -gt 0 -and
            [uint64]$adapter.Groups['ns_per_instruction'].Value -gt 0
        $inputOk = $input.Success -and $inputCorrelation.Success -and
            [uint64]$input.Groups['raw'].Value -eq
                ([uint64]$input.Groups['translated'].Value + [uint64]$input.Groups['filtered'].Value) -and
            [uint64]$input.Groups['pending_created'].Value -eq 0 -and
            [uint64]$input.Groups['pending_emitted'].Value -eq 0 -and
            [uint64]$input.Groups['mouse_moves'].Value -le [uint64]$input.Groups['mouse_events'].Value -and
            [uint64]$input.Groups['mouse_mappings'].Value -eq 0 -and
            [uint64]$input.Groups['input_window_info'].Value -le [uint64]$input.Groups['window_info'].Value -and
            [uint64]$input.Groups['viewport_calculations'].Value -le [uint64]$input.Groups['window_info'].Value -and
            [uint64]$input.Groups['adapter_events'].Value -eq
                ([uint64]$input.Groups['accepted'].Value + [uint64]$input.Groups['controls'].Value + [uint64]$input.Groups['dropped'].Value) -and
            [uint64]$input.Groups['adapter_events'].Value -le [uint64]$input.Groups['translated'].Value -and
            [uint64]$input.Groups['runtime_ignored'].Value -eq [uint64]$input.Groups['dropped'].Value -and
            [uint64]$input.Groups['queue'].Value -le [uint64]$input.Groups['queue_max'].Value -and
            ([uint64]$input.Groups['consumed'].Value + [uint64]$input.Groups['queue'].Value) -eq [uint64]$input.Groups['accepted'].Value -and
            [uint64]$input.Groups['dropped'].Value -eq
                ([uint64]$input.Groups['unfocused'].Value + [uint64]$input.Groups['invalid_codepoint'].Value + [uint64]$input.Groups['unsupported_key'].Value + [uint64]$input.Groups['unsupported_event'].Value + [uint64]$input.Groups['queue_full'].Value + [uint64]$input.Groups['oom'].Value) -and
            (([uint64]$input.Groups['filtered'].Value -eq 0 -and $inputCorrelation.Groups['last_filter_reason'].Value -eq 'none') -or
                ([uint64]$input.Groups['filtered'].Value -gt 0 -and [uint64]$inputCorrelation.Groups['last_filter_sequence'].Value -gt 0 -and $inputCorrelation.Groups['last_filter_reason'].Value -ne 'none')) -and
            (([uint64]$input.Groups['dropped'].Value -eq 0 -and $inputCorrelation.Groups['last_drop_reason'].Value -eq 'none') -or
                ([uint64]$input.Groups['dropped'].Value -gt 0 -and [uint64]$inputCorrelation.Groups['last_dropped_sequence'].Value -gt 0 -and $inputCorrelation.Groups['last_drop_reason'].Value -ne 'none'))
        $frameCycleOk = $frameCycle.Success -and
            [uint64]$frameCycle.Groups['attempts'].Value -ge [uint64]$frameCycle.Groups['published'].Value -and
            [uint64]$frameCycle.Groups['published'].Value -gt 0 -and
            [uint64]$frameCycle.Groups['failed'].Value -eq 0 -and
            [uint64]$frameCycle.Groups['max_backlog'].Value -le 4 -and
            [uint64]$frameCycle.Groups['max_present_ns'].Value -le 250000000 -and
            [uint64]$frameCycle.Groups['max_age_end_ns'].Value -le 250000000
        $vmOk = $vm.Success -and
            [uint64]$vm.Groups['cancel_flag_checks'].Value -gt [uint64]$vm.Groups['group_lookups'].Value -and
            [uint64]$vm.Groups['cancel_callback_checks'].Value -gt 0 -and
            [uint64]$vm.Groups['group_lookups'].Value -eq [uint64]$adapter.Groups['instructions'].Value -and
            [uint64]$vm.Groups['text_sync_checks'].Value -gt 0 -and
            [uint64]$vm.Groups['metadata_reads'].Value -gt 0 -and
            [uint64]$vm.Groups['metadata_reads'].Value -lt [uint64]$vm.Groups['group_lookups'].Value -and
            [uint64]$vm.Groups['cell_resolves'].Value -gt 0
        $rasterOk = $raster.Success -and
            ([uint64]$raster.Groups['mode_allocations'].Value + [uint64]$raster.Groups['mode_reuses'].Value) -gt 0 -and
            [uint64]$raster.Groups['mode_clear_bytes'].Value -gt 0 -and
            [uint64]$raster.Groups['pixel_probes'].Value -ge [uint64]$raster.Groups['pixel_changes'].Value -and
            [uint64]$raster.Groups['span_pixels'].Value -ge [uint64]$raster.Groups['spans'].Value -and
            [uint64]$raster.Groups['damage_commits'].Value -gt 0 -and
            [uint64]$raster.Groups['paint_pushes'].Value -ge [uint64]$raster.Groups['paint_pops'].Value -and
            [uint64]$raster.Groups['circle_requested'].Value -eq
                ([uint64]$raster.Groups['circle_segments'].Value + [uint64]$raster.Groups['circle_skipped'].Value) -and
            [uint64]$raster.Groups['capture_pixels'].Value -ge [uint64]$raster.Groups['capture_calls'].Value -and
            [uint64]$raster.Groups['put_pixels'].Value -ge [uint64]$raster.Groups['put_calls'].Value
        $damageOk = $damage.Success -and
            [uint64]$damage.Groups['commits'].Value -gt 0 -and
            [uint64]$damage.Groups['regions'].Value -ge [uint64]$damage.Groups['commits'].Value -and
            [uint64]$damage.Groups['merges'].Value -ge [uint64]$damage.Groups['overflow_merges'].Value -and
            [uint64]$damage.Groups['full_commits'].Value -gt 0
        $ownershipOk = $ownership.Success -and
            ([uint64]$ownership.Groups['local_pool_grows'].Value + [uint64]$ownership.Groups['local_pool_reuses'].Value) -eq
                [uint64]$ownership.Groups['procedure_calls'].Value -and
            [uint64]$ownership.Groups['local_aggregate_initializations'].Value -le [uint64]$ownership.Groups['local_initializations'].Value -and
            [uint64]$ownership.Groups['local_initialization_bytes'].Value -ge [uint64]$ownership.Groups['local_initializations'].Value -and
            [uint64]$ownership.Groups['str_result_allocations'].Value -le [uint64]$ownership.Groups['format_stack_uses'].Value -and
            [uint64]$ownership.Groups['val_scratch_grows'].Value -le [uint64]$ownership.Groups['val_scratch'].Value
        $storageOk = $storage.Success -and
            [uint64]$storage.Groups['compact_array_resizes'].Value -gt 0 -and
            [uint64]$storage.Groups['compact_array_elements'].Value -gt 0 -and
            [uint64]$storage.Groups['array_live_peak_bytes'].Value -ge [uint64]$storage.Groups['array_live_bytes'].Value -and
            [uint64]$storage.Groups['array_resize_live_peak_bytes'].Value -ge [uint64]$storage.Groups['array_live_peak_bytes'].Value -and
            [uint64]$storage.Groups['array_live_limit_bytes'].Value -eq 134217728 -and
            [uint64]$storage.Groups['array_resize_live_limit_bytes'].Value -eq 201326592 -and
            [uint64]$storage.Groups['array_live_peak_bytes'].Value -le [uint64]$storage.Groups['array_live_limit_bytes'].Value -and
            [uint64]$storage.Groups['array_resize_live_peak_bytes'].Value -le [uint64]$storage.Groups['array_resize_live_limit_bytes'].Value -and
            [uint64]$storage.Groups['vm_static_bytes'].Value -lt 16384 -and
            [uint64]$storage.Groups['file_index_bytes'].Value -eq 256
        $fileHostOk = $fileHost.Success -and
            [uint64]$fileHost.Groups['failures'].Value -eq 0
        $fileIoOk = $fileIo.Success -and
            [uint64]$fileIo.Groups['batch_bytes'].Value -eq 65536 -and
            [uint64]$fileIo.Groups['max_request_bytes'].Value -le [uint64]$fileIo.Groups['batch_bytes'].Value -and
            [uint64]$fileIo.Groups['max_active_requests'].Value -le 1 -and
            [uint64]$fileIo.Groups['pending_polls'].Value -le [uint64]$fileIo.Groups['status_polls'].Value -and
            [uint64]$fileIo.Groups['completions'].Value -eq
                ([uint64]$fileIo.Groups['read_submissions'].Value + [uint64]$fileIo.Groups['write_submissions'].Value) -and
            [uint64]$fileIo.Groups['input_refills'].Value -le [uint64]$fileIo.Groups['read_submissions'].Value -and
            [uint64]$fileIo.Groups['output_flushes'].Value -le [uint64]$fileIo.Groups['write_submissions'].Value -and
            [uint64]$fileIo.Groups['input_buffer_peak_bytes'].Value -le 4194305 -and
            [uint64]$fileIo.Groups['output_buffer_peak_bytes'].Value -le [uint64]$fileIo.Groups['batch_bytes'].Value
        $presenterOk = $presenter.Success -and
            [uint64]$presenter.Groups['published_frames'].Value -gt 0 -and
            [uint64]$presenter.Groups['full_frames'].Value -gt 0 -and
            ([uint64]$presenter.Groups['damage_frames'].Value + [uint64]$presenter.Groups['replacement_frames'].Value) -gt 0 -and
            [uint64]$presenter.Groups['published_frames'].Value -eq
                ([uint64]$presenter.Groups['full_frames'].Value + [uint64]$presenter.Groups['damage_frames'].Value + [uint64]$presenter.Groups['replacement_frames'].Value) -and
            [uint64]$presenter.Groups['damage_regions'].Value -ge [uint64]$presenter.Groups['published_frames'].Value -and
            [uint64]$presenter.Groups['indexed8_frames'].Value -eq [uint64]$presenter.Groups['published_frames'].Value -and
            [uint64]$presenter.Groups['indexed8_blocks'].Value -eq [uint64]$presenter.Groups['raster_blocks'].Value -and
            [uint64]$presenter.Groups['indexed8_resource_bytes'].Value -gt [uint64]$presenter.Groups['indexed8_blocks'].Value -and
            [uint64]$presenter.Groups['xrgb_fallback_frames'].Value -eq 0 -and
            [uint64]$presenter.Groups['sampled_pixels'].Value -gt 0 -and
            [uint64]$presenter.Groups['compacted_frames'].Value -le [uint64]$presenter.Groups['full_frames'].Value
        $audioOk = $audio.Success -and
            $audio.Groups['state'].Value -eq 'ready' -and
            [uint64]$audio.Groups['service_ops_cycle_max'].Value -le 1 -and
            [uint64]$audio.Groups['service_ops'].Value -eq
                ([uint64]$audio.Groups['opens'].Value + [uint64]$audio.Groups['writes'].Value + [uint64]$audio.Groups['closes'].Value) -and
            [uint64]$audio.Groups['lazy_opens'].Value -gt 0 -and
            [uint64]$audio.Groups['lazy_opens'].Value -le [uint64]$audio.Groups['opens'].Value -and
            [uint64]$audio.Groups['writes'].Value -gt 0 -and
            [uint64]$audio.Groups['closes'].Value -gt 0 -and
            [uint64]$audio.Groups['active_quanta'].Value -gt 0 -and
            [uint64]$audio.Groups['active_quanta'].Value -le [uint64]$audio.Groups['writes'].Value -and
            [uint64]$audio.Groups['generated_bytes'].Value -gt 0 -and
            [uint64]$audio.Groups['accepted_bytes'].Value -gt 0 -and
            [uint64]$audio.Groups['accepted_bytes'].Value -le [uint64]$audio.Groups['generated_bytes'].Value -and
            [uint64]$audio.Groups['suppressed_bytes'].Value -le [uint64]$audio.Groups['generated_bytes'].Value
        $audioGuestOk = $audioGuest.Success -and
            [uint64]$audioGuest.Groups['resolved_frames'].Value -eq
                ([uint64]$audioGuest.Groups['accepted_frames'].Value + [uint64]$audioGuest.Groups['suppressed_frames'].Value + [uint64]$audioGuest.Groups['discarded_frames'].Value) -and
            [uint64]$audioGuest.Groups['resolved_frames'].Value -le [uint64]$audioGuest.Groups['scheduled_frames'].Value -and
            [uint64]$audioGuest.Groups['unresolved_frames'].Value -eq
                ([uint64]$audioGuest.Groups['scheduled_frames'].Value - [uint64]$audioGuest.Groups['resolved_frames'].Value) -and
            [uint64]$audioGuest.Groups['foreground_wakes'].Value -le [uint64]$audioGuest.Groups['foreground_waits'].Value -and
            [uint64]$audioGuest.Groups['phase_lookups'].Value -le [uint64]$audioGuest.Groups['direct_events'].Value
        $stackDetail = $stackHighWater.Groups['detail'].Value -eq 'on'
        $stackTimingOk = $stackHighWater.Groups['detail'].Value -eq $stackRelease.Groups['detail'].Value
        foreach ($pair in @(@($stackHighWater, 'highwater'), @($stackHighWater, 'create_cycles'), @($stackRelease, 'release_cycles'), @($stackRelease, 'kernel_highwater'), @($stackRelease, 'kernel_create_cycles'), @($stackRelease, 'kernel_release_cycles'))) {
            $value = [uint64]$pair[0].Groups[$pair[1]].Value
            $stackTimingOk = $stackTimingOk -and $(if ($stackDetail) { $value -gt 0 } else { $value -eq 0 })
        }
        $stackOk = $stackHighWater.Success -and $stackRelease.Success -and $stackTimingOk -and
            [uint64]$stackHighWater.Groups['reserve'].Value -eq 4194304 -and
            [uint64]$stackHighWater.Groups['initial'].Value -eq 131072 -and
            [uint64]$stackHighWater.Groups['committed'].Value -ge [uint64]$stackHighWater.Groups['initial'].Value -and
            [uint64]$stackHighWater.Groups['committed'].Value -lt [uint64]$stackHighWater.Groups['reserve'].Value -and
            [uint64]$stackHighWater.Groups['highwater'].Value -le [uint64]$stackHighWater.Groups['committed'].Value -and
            [uint64]$stackHighWater.Groups['reserve'].Value -ge ([uint64]$stackHighWater.Groups['highwater'].Value * 16) -and
            [uint64]$stackRelease.Groups['reserve'].Value -eq [uint64]$stackHighWater.Groups['reserve'].Value -and
            [uint64]$stackRelease.Groups['initial'].Value -eq [uint64]$stackHighWater.Groups['initial'].Value -and
            [uint64]$stackRelease.Groups['committed'].Value -eq [uint64]$stackHighWater.Groups['committed'].Value -and
            [uint64]$stackRelease.Groups['highwater'].Value -eq [uint64]$stackHighWater.Groups['highwater'].Value -and
            [uint64]$stackRelease.Groups['creates'].Value -gt 0 -and
            [uint64]$stackRelease.Groups['releases'].Value -gt 0 -and
            [uint64]$stackRelease.Groups['create_cycles'].Value -eq [uint64]$stackHighWater.Groups['create_cycles'].Value -and
            [uint64]$stackRelease.Groups['create_cycles_max'].Value -ge [uint64]$stackRelease.Groups['create_cycles'].Value -and
            [uint64]$stackRelease.Groups['release_cycles_max'].Value -ge [uint64]$stackRelease.Groups['release_cycles'].Value -and
            [uint64]$stackRelease.Groups['kernel_highwater'].Value -le 65536 -and
            [uint64]$stackRelease.Groups['cache_cached'].Value -le 8 -and
            [uint64]$stackRelease.Groups['cache_hits'].Value -gt 0 -and
            [uint64]$stackRelease.Groups['cache_misses'].Value -gt 0 -and
            ([uint64]$stackRelease.Groups['critical_available'].Value + [uint64]$stackRelease.Groups['critical_in_use'].Value) -eq 4
        $kernelOk = $timeline.Success -and $admission.Success -and $loader.Success -and $r4xstart.Success -and
            [uint64]$loader.Groups[3].Value -gt 0 -and
            [uint64]$loader.Groups[7].Value -gt 0 -and
            [uint64]$loader.Groups[9].Value -gt 0 -and
            [uint64]$admission.Groups[1].Value -le [uint64]$loader.Groups[1].Value -and
            [uint64]$loader.Groups[1].Value -le [uint64]$r4xstart.Groups[1].Value -and
            [uint64]$r4xstart.Groups[1].Value -le [uint64]$timeline.Groups['app'].Value
        if (-not $timelineOk -or -not $compilerOk -or -not $compilerMemoryOk -or -not $compilerVmOk -or -not $runtimeOk -or -not $adapterOk -or -not $inputOk -or -not $frameCycleOk -or -not $vmOk -or -not $rasterOk -or -not $damageOk -or -not $ownershipOk -or -not $storageOk -or -not $fileHostOk -or -not $fileIoOk -or -not $presenterOk -or -not $audioOk -or -not $audioGuestOk -or -not $stackOk -or -not $kernelOk) {
            if (-not $Quiet) { Write-Host 'R4BASIC launch timeline FAILED: phase order, real work, or loader evidence invalid.' }
            $failures++
        } elseif (-not $Quiet) {
            Write-Host ('R4BASIC launch timeline OK: id=' + $traceId)
        }
    }
    return $failures
}

function Test-SubsystemReportContract {
    param([string]$Text, [switch]$Quiet, [string]$BootText = '')
    return ((Test-R4GbReportContract $Text -Quiet:$Quiet) +
        (Test-R4SnesReportContract $Text -Quiet:$Quiet) +
        # BASIC binds its original guest trace to the real kernel's loader
        # and stack records. Those remain in the same run's serial boot log.
        (Test-R4BasicReportContract ($Text + "`n" + $BootText) -Quiet:$Quiet))
}
