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
    'SUBSYSTEM host selftest: OK modes=640x350+320x200+256x224 formats=indexed8+xrgb32 damage=sparse indexed8=abi tiles=bounded input=sequenced+policy-filtered idle=no-frame fps>=20',
    'SUBSYSTEM runtime selftest: OK instances=2 slices=bounded time=monotonic audio=s16le-buffered lifecycle=pause+resume+reset+complete+close errors=isolated resources=closed',
    'DESKTOP present selftest: OK regions=2 cursorblink=regional fence=sync backend=DISPBLIT fallback=armed remote=on-demand',
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
        $presenter = [regex]::Match($Text, '(?im)^R4BASIC presenter: published_frames=(?<published_frames>\d+) skipped_frames=(?<skipped_frames>\d+) full_frames=(?<full_frames>\d+) damage_frames=(?<damage_frames>\d+) compacted_frames=(?<compacted_frames>\d+) damage_regions=(?<damage_regions>\d+) indexed8_frames=(?<indexed8_frames>\d+) indexed8_blocks=(?<indexed8_blocks>\d+) indexed8_resource_bytes=(?<indexed8_resource_bytes>\d+) xrgb_fallback_frames=(?<xrgb_fallback_frames>\d+) raster_blocks=(?<raster_blocks>\d+) sampled_pixels=(?<sampled_pixels>\d+)\r?$')
        $audio = [regex]::Match($Text, '(?im)^R4BASIC audio: state=(?<state>[a-z_]+) muted=(?<muted>[01]) playback=unavailable lazy_opens=(?<lazy_opens>\d+) service_ops=(?<service_ops>\d+) service_ops_cycle_max=(?<service_ops_cycle_max>\d+) opens=(?<opens>\d+) writes=(?<writes>\d+) closes=(?<closes>\d+) active_cycles=(?<active_cycles>\d+) silent_cycles=(?<silent_cycles>\d+) paused_cycles=(?<paused_cycles>\d+) muted_cycles=(?<muted_cycles>\d+) active_quanta=(?<active_quanta>\d+) silent_quanta=(?<silent_quanta>\d+) generated_bytes=(?<generated_bytes>\d+) accepted_bytes=(?<accepted_bytes>\d+) suppressed_bytes=(?<suppressed_bytes>\d+) discarded_bytes=(?<discarded_bytes>\d+) paused_bytes=(?<paused_bytes>\d+) muted_bytes=(?<muted_bytes>\d+) busy=(?<busy>\d+) resyncs=(?<resyncs>\d+)\r?$')
        $audioGuest = [regex]::Match($Text, '(?im)^R4BASIC audio-guest: scheduled_frames=(?<scheduled_frames>\d+) accepted_frames=(?<accepted_frames>\d+) suppressed_frames=(?<suppressed_frames>\d+) discarded_frames=(?<discarded_frames>\d+) resolved_frames=(?<resolved_frames>\d+) unresolved_frames=(?<unresolved_frames>\d+) foreground_waits=(?<foreground_waits>\d+) foreground_wakes=(?<foreground_wakes>\d+) background=(?<background>\d+) direct_events=(?<direct_events>\d+) reserve_grows=(?<reserve_grows>\d+) phase_lookups=(?<phase_lookups>\d+)\r?$')
        $stackHighWater = [regex]::Match($Text, '(?im)^\[R4XSTACK\] highwater owner=(?<owner>\d+) thread=0 module=C:\\R4OS\\SUBSYSTEMS\\r4os\.basic\\R4BASIC\.R4X profile=desktop reserve=(?<reserve>\d+) initial=(?<initial>\d+) committed=(?<committed>\d+) highwater=(?<highwater>\d+) create_cycles=(?<create_cycles>\d+)\r?$')
        $stackRelease = if ($stackHighWater.Success) {
            [regex]::Match($Text, '(?im)^\[R4XSTACK\] release owner=' + [regex]::Escape($stackHighWater.Groups['owner'].Value) + ' profile=desktop reserve=(?<reserve>\d+) initial=(?<initial>\d+) committed=(?<committed>\d+) highwater=(?<highwater>\d+) creates=(?<creates>\d+) releases=(?<releases>\d+) create_cycles=(?<create_cycles>\d+) create_cycles_max=(?<create_cycles_max>\d+) release_cycles=(?<release_cycles>\d+) release_cycles_max=(?<release_cycles_max>\d+) kernel_highwater_max=(?<kernel_highwater>\d+) kernel_create_cycles_max=(?<kernel_create_cycles>\d+) kernel_release_cycles_max=(?<kernel_release_cycles>\d+) kernel_cache_cached=(?<cache_cached>\d+) kernel_cache_hits=(?<cache_hits>\d+) kernel_cache_misses=(?<cache_misses>\d+) critical_available=(?<critical_available>\d+) critical_in_use=(?<critical_in_use>\d+)\r?$')
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
            [uint64]$compilerMemory.Groups['instruction_hot_bytes'].Value -gt 0 -and
            [uint64]$compilerMemory.Groups['instruction_metadata_bytes'].Value -eq
                ([uint64]$compilerMemory.Groups['instruction_hot_bytes'].Value * 2) -and
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
            [uint64]$adapter.Groups['max_clock_reads'].Value -le 20 -and
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
        $presenterOk = $presenter.Success -and
            [uint64]$presenter.Groups['published_frames'].Value -gt 0 -and
            [uint64]$presenter.Groups['full_frames'].Value -gt 0 -and
            [uint64]$presenter.Groups['damage_frames'].Value -gt 0 -and
            [uint64]$presenter.Groups['published_frames'].Value -eq
                ([uint64]$presenter.Groups['full_frames'].Value + [uint64]$presenter.Groups['damage_frames'].Value) -and
            [uint64]$presenter.Groups['damage_regions'].Value -ge [uint64]$presenter.Groups['published_frames'].Value -and
            [uint64]$presenter.Groups['indexed8_frames'].Value -eq [uint64]$presenter.Groups['published_frames'].Value -and
            [uint64]$presenter.Groups['indexed8_blocks'].Value -eq [uint64]$presenter.Groups['raster_blocks'].Value -and
            [uint64]$presenter.Groups['indexed8_resource_bytes'].Value -gt [uint64]$presenter.Groups['indexed8_blocks'].Value -and
            [uint64]$presenter.Groups['xrgb_fallback_frames'].Value -eq 0 -and
            [uint64]$presenter.Groups['sampled_pixels'].Value -gt 0 -and
            [uint64]$presenter.Groups['compacted_frames'].Value -le [uint64]$presenter.Groups['full_frames'].Value
        $audioOk = $audio.Success -and
            [uint64]$audio.Groups['service_ops_cycle_max'].Value -le 1 -and
            [uint64]$audio.Groups['service_ops'].Value -eq
                ([uint64]$audio.Groups['opens'].Value + [uint64]$audio.Groups['writes'].Value + [uint64]$audio.Groups['closes'].Value) -and
            [uint64]$audio.Groups['lazy_opens'].Value -le [uint64]$audio.Groups['opens'].Value -and
            [uint64]$audio.Groups['active_quanta'].Value -le [uint64]$audio.Groups['writes'].Value -and
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
        $stackOk = $stackHighWater.Success -and $stackRelease.Success -and
            [uint64]$stackHighWater.Groups['reserve'].Value -eq 4194304 -and
            [uint64]$stackHighWater.Groups['initial'].Value -eq 131072 -and
            [uint64]$stackHighWater.Groups['committed'].Value -ge [uint64]$stackHighWater.Groups['initial'].Value -and
            [uint64]$stackHighWater.Groups['committed'].Value -lt [uint64]$stackHighWater.Groups['reserve'].Value -and
            [uint64]$stackHighWater.Groups['highwater'].Value -gt 0 -and
            [uint64]$stackHighWater.Groups['highwater'].Value -le [uint64]$stackHighWater.Groups['committed'].Value -and
            [uint64]$stackHighWater.Groups['reserve'].Value -ge ([uint64]$stackHighWater.Groups['highwater'].Value * 16) -and
            [uint64]$stackHighWater.Groups['create_cycles'].Value -gt 0 -and
            [uint64]$stackRelease.Groups['reserve'].Value -eq [uint64]$stackHighWater.Groups['reserve'].Value -and
            [uint64]$stackRelease.Groups['initial'].Value -eq [uint64]$stackHighWater.Groups['initial'].Value -and
            [uint64]$stackRelease.Groups['committed'].Value -eq [uint64]$stackHighWater.Groups['committed'].Value -and
            [uint64]$stackRelease.Groups['highwater'].Value -eq [uint64]$stackHighWater.Groups['highwater'].Value -and
            [uint64]$stackRelease.Groups['creates'].Value -gt 0 -and
            [uint64]$stackRelease.Groups['releases'].Value -gt 0 -and
            [uint64]$stackRelease.Groups['create_cycles'].Value -eq [uint64]$stackHighWater.Groups['create_cycles'].Value -and
            [uint64]$stackRelease.Groups['create_cycles_max'].Value -ge [uint64]$stackRelease.Groups['create_cycles'].Value -and
            [uint64]$stackRelease.Groups['release_cycles'].Value -gt 0 -and
            [uint64]$stackRelease.Groups['release_cycles_max'].Value -ge [uint64]$stackRelease.Groups['release_cycles'].Value -and
            [uint64]$stackRelease.Groups['kernel_highwater'].Value -gt 0 -and
            [uint64]$stackRelease.Groups['kernel_highwater'].Value -le 65536 -and
            [uint64]$stackRelease.Groups['kernel_create_cycles'].Value -gt 0 -and
            [uint64]$stackRelease.Groups['kernel_release_cycles'].Value -gt 0 -and
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
        if (-not $timelineOk -or -not $compilerOk -or -not $compilerMemoryOk -or -not $compilerVmOk -or -not $runtimeOk -or -not $adapterOk -or -not $inputOk -or -not $frameCycleOk -or -not $vmOk -or -not $rasterOk -or -not $damageOk -or -not $ownershipOk -or -not $storageOk -or -not $fileHostOk -or -not $presenterOk -or -not $audioOk -or -not $audioGuestOk -or -not $stackOk -or -not $kernelOk) {
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
        'R4BASIC timeline: start_ns=100 probe_ns=110 resolve_ns=120 desktop_ns=130 app_ns=180 source_begin_ns=190 source_end_ns=200 compile_begin_ns=210 compile_visible_ns=215 compile_end_ns=220 compile_updates=6 vm_begin_ns=230 vm_end_ns=240 host_ready_ns=250 initial_frame_ns=0 runtime_begin_ns=270 first_instruction_ns=280 audio_open_ns=0 first_frame_ns=300' + "`r`n" +
        'R4BASIC compiler: tokens=4000 token_capacity=4000 keyword_lookups=1000 keyword_probes=1200 keyword_max_probe=4 name_lookups=2000 name_insertions=300 name_probes=2600 name_max_probe=7 index_rebuilds=12 constant_lookups=900 constant_reuses=200 constant_probes=1100 constant_max_probe=5 label_fixups=20 data_fixups=2 reused_bindings=500 expression_depth=8 progress_updates=24' + "`r`n" +
        'R4BASIC compiler-memory: token_bytes=80000 initial_list_bytes=160000 instruction_hot_bytes=14808 instruction_metadata_bytes=29616 allocations=40 reallocations=8 copy_bytes=12000 peak_bytes=800000 program_bytes=400000 adopted_source_bytes=29434 diagnostics_total=0 diagnostics_stored=0 diagnostics_truncated=0' + "`r`n" +
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
        'R4BASIC presenter: published_frames=3 skipped_frames=1 full_frames=1 damage_frames=2 compacted_frames=0 damage_regions=4 indexed8_frames=3 indexed8_blocks=9 indexed8_resource_bytes=12000 xrgb_fallback_frames=0 raster_blocks=9 sampled_pixels=224500' + "`r`n" +
        'R4BASIC audio: state=ready muted=0 playback=unavailable lazy_opens=1 service_ops=4 service_ops_cycle_max=1 opens=1 writes=2 closes=1 active_cycles=4 silent_cycles=2 paused_cycles=0 muted_cycles=0 active_quanta=2 silent_quanta=1 generated_bytes=7680 accepted_bytes=3840 suppressed_bytes=1920 discarded_bytes=1920 paused_bytes=0 muted_bytes=0 busy=0 resyncs=0' + "`r`n" +
        'R4BASIC audio-guest: scheduled_frames=1920 accepted_frames=960 suppressed_frames=480 discarded_frames=480 resolved_frames=1920 unresolved_frames=0 foreground_waits=2 foreground_wakes=2 background=1 direct_events=4 reserve_grows=1 phase_lookups=3' + "`r`n" +
        '[R4XSTACK] highwater owner=42 thread=0 module=C:\R4OS\SUBSYSTEMS\r4os.basic\R4BASIC.R4X profile=desktop reserve=4194304 initial=131072 committed=196608 highwater=154464 create_cycles=2500000' + "`r`n" +
        '[R4XSTACK] release owner=42 profile=desktop reserve=4194304 initial=131072 committed=196608 highwater=154464 creates=4 releases=3 create_cycles=2500000 create_cycles_max=2700000 release_cycles=1700000 release_cycles_max=1800000 kernel_highwater_max=39800 kernel_create_cycles_max=3500000 kernel_release_cycles_max=2100000 kernel_cache_cached=8 kernel_cache_hits=20 kernel_cache_misses=12 critical_available=4 critical_in_use=0' + "`r`n" +
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
