param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('import', 'validate', 'compare', 'migrate-legacy', 'selftest')]
    [string]$Action,

    [string]$InputPath,
    [string]$HistoryPath,
    [string]$Suite,
    [string]$WorkloadId,
    [string]$EnvironmentId,
    [string]$CacheState,
    [string]$Metric
)

$ErrorActionPreference = 'Stop'

$historySchema = 'r4os.benchmark.metric'
$historySchemaVersion = 1
$runSchema = 'r4os.benchmark.run'
$runSchemaVersion = 2
$perfdiagSchema = 'r4os.perfdiag.ndjson'
$perfdiagSchemaVersion = 7
$standardEnvironmentId = 'r4os-q35-haswell-1vcpu-1g-tcg-v1'
$legacyEnvironmentId = 'legacy-qemu-1vcpu-unversioned-v1'
$allowedRecordFields = @(
    'schema',
    'schema_version',
    'run_id',
    'release',
    'suite',
    'workload_id',
    'environment_id',
    'image_sha256',
    'cache_state',
    'metric',
    'unit',
    'direction',
    'samples',
    'min',
    'p50',
    'p95',
    'p99',
    'max',
    'mean'
)

$metricCatalog = @{
    'perfdiag.blit.throughput' = [pscustomobject]@{ suite = 'perfdiag-blit'; unit = 'KB/s'; direction = 'higher' }
    'perfdiag.clock.latency' = [pscustomobject]@{ suite = 'perfdiag-clock'; unit = 'ns/call'; direction = 'lower' }
    'perfdiag.service_registry.service_info.latency' = [pscustomobject]@{ suite = 'perfdiag-service-registry'; unit = 'ns/enumeration'; direction = 'lower' }
    'perfdiag.service_registry.service_detail.latency' = [pscustomobject]@{ suite = 'perfdiag-service-registry'; unit = 'ns/enumeration'; direction = 'lower' }
    'perfdiag.service_registry.servman_diag.latency' = [pscustomobject]@{ suite = 'perfdiag-service-registry'; unit = 'ns/enumeration'; direction = 'lower' }
    'perfdiag.kernel_ipc.caller.latency' = [pscustomobject]@{ suite = 'perfdiag-kernel-ipc'; unit = 'ns/request'; direction = 'lower' }
    'perfdiag.kernel_ipc.handler_queue.latency' = [pscustomobject]@{ suite = 'perfdiag-kernel-ipc'; unit = 'ns/request'; direction = 'lower' }
    'perfdiag.kernel_ipc.handler_run.latency' = [pscustomobject]@{ suite = 'perfdiag-kernel-ipc'; unit = 'ns/request'; direction = 'lower' }
    'perfdiag.kernel_ipc.handler_e2e.latency' = [pscustomobject]@{ suite = 'perfdiag-kernel-ipc'; unit = 'ns/request'; direction = 'lower' }
    'perfdiag.driver_work.queue.latency' = [pscustomobject]@{ suite = 'perfdiag-driver-work'; unit = 'ns/work'; direction = 'lower' }
    'perfdiag.driver_work.run.latency' = [pscustomobject]@{ suite = 'perfdiag-driver-work'; unit = 'ns/work'; direction = 'lower' }
    'perfdiag.driver_work.e2e.latency' = [pscustomobject]@{ suite = 'perfdiag-driver-work'; unit = 'ns/work'; direction = 'lower' }
    'perfdiag.pci_inventory.latency' = [pscustomobject]@{ suite = 'perfdiag-pci-inventory'; unit = 'ns/inventory'; direction = 'lower' }
    'perfdiag.memory_metadata.reserve_commit.latency' = [pscustomobject]@{ suite = 'perfdiag-memory-metadata'; unit = 'ns/page'; direction = 'lower' }
    'perfdiag.memory_metadata.fault.latency' = [pscustomobject]@{ suite = 'perfdiag-memory-metadata'; unit = 'ns/page'; direction = 'lower' }
    'perfdiag.memory_metadata.page_state.latency' = [pscustomobject]@{ suite = 'perfdiag-memory-metadata'; unit = 'ns/page'; direction = 'lower' }
    'perfdiag.memory_metadata.reclaim.latency' = [pscustomobject]@{ suite = 'perfdiag-memory-metadata'; unit = 'ns/frame'; direction = 'lower' }
}
$suiteWorkloads = @{
    'perfdiag-blit' = 'blit'
    'perfdiag-clock' = 'clock'
    'perfdiag-service-registry' = 'service-registry'
    'perfdiag-kernel-ipc' = 'kernel-ipc'
    'perfdiag-driver-work' = 'driver-work'
    'perfdiag-pci-inventory' = 'pci-inventory'
    'perfdiag-memory-metadata' = 'memory-metadata'
}

function Assert-File([string]$Path, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ($Label + ' not found: ' + $Path)
    }
}

function Get-RequiredProperty($Object, [string]$Name, [string]$Context) {
    if ($null -eq $Object) { throw ($Context + ' is missing.') }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw ($Context + ' is missing field ' + $Name + '.') }
    return $property.Value
}

function Assert-NonEmptyString($Value, [string]$Label, [string]$Pattern = '') {
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw ($Label + ' must be a non-empty string.')
    }
    if ($Pattern -and $Value -notmatch $Pattern) {
        throw ($Label + ' has an invalid value: ' + $Value)
    }
}

function Test-JsonNumber($Value) {
    return $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64] -or
        $Value -is [single] -or
        $Value -is [double] -or
        $Value -is [decimal]
}

function Assert-NonNegativeNumber($Value, [string]$Label) {
    if (-not (Test-JsonNumber $Value)) { throw ($Label + ' must be numeric.') }
    $number = [double]$Value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0) {
        throw ($Label + ' must be finite and non-negative.')
    }
}

function Get-NearestRank([object[]]$Sorted, [int]$Percent) {
    $rank = [int][Math]::Ceiling($Sorted.Count * ($Percent / 100.0))
    if ($rank -lt 1) { $rank = 1 }
    return $Sorted[$rank - 1]
}

function Get-Distribution([object[]]$Values) {
    if ($Values.Count -lt 3 -or $Values.Count -gt 20) {
        throw ('A metric needs 3..20 raw samples, got ' + $Values.Count + '.')
    }
    $normalized = [Collections.Generic.List[decimal]]::new()
    $sum = [decimal]0
    foreach ($value in $Values) {
        Assert-NonNegativeNumber $value 'sample'
        $number = [decimal]$value
        if ($number -le 0) { throw 'Trend metric samples must be greater than zero.' }
        $normalized.Add($number)
        $sum += $number
    }
    $sorted = @($normalized.ToArray() | Sort-Object)
    return [pscustomobject]@{
        min = $sorted[0]
        p50 = Get-NearestRank $sorted 50
        p95 = Get-NearestRank $sorted 95
        p99 = Get-NearestRank $sorted 99
        max = $sorted[$sorted.Count - 1]
        mean = [Math]::Floor($sum / $sorted.Count)
    }
}

function Assert-SameNumber($Actual, $Expected, [string]$Label) {
    Assert-NonNegativeNumber $Actual $Label
    if ([decimal]$Actual -ne [decimal]$Expected) {
        throw ($Label + ' does not match raw samples: expected ' + $Expected + ', got ' + $Actual + '.')
    }
}

function New-MetricRecord(
    [string]$RunId,
    [string]$Release,
    [string]$SuiteName,
    [string]$Workload,
    [string]$Environment,
    $ImageSha256,
    [string]$Cache,
    [string]$MetricName,
    [object[]]$RawSamples
) {
    if (-not $metricCatalog.ContainsKey($MetricName)) { throw ('Unknown metric: ' + $MetricName) }
    $catalog = $metricCatalog[$MetricName]
    if ($catalog.suite -ne $SuiteName) { throw ('Metric does not belong to suite ' + $SuiteName + ': ' + $MetricName) }
    $distribution = Get-Distribution $RawSamples
    $samples = @($RawSamples | ForEach-Object { [long]$_ })
    return [pscustomobject][ordered]@{
        schema = $historySchema
        schema_version = $historySchemaVersion
        run_id = $RunId
        release = $Release
        suite = $SuiteName
        workload_id = $Workload
        environment_id = $Environment
        image_sha256 = $ImageSha256
        cache_state = $Cache
        metric = $MetricName
        unit = $catalog.unit
        direction = $catalog.direction
        samples = $samples
        min = $distribution.min
        p50 = $distribution.p50
        p95 = $distribution.p95
        p99 = $distribution.p99
        max = $distribution.max
        mean = $distribution.mean
    }
}

function Assert-MetricRecord($Record) {
    $fieldNames = @($Record.PSObject.Properties.Name)
    if ($fieldNames.Count -ne $allowedRecordFields.Count) {
        throw ('Metric record has unexpected field count: ' + $fieldNames.Count + '.')
    }
    foreach ($field in $allowedRecordFields) {
        if ($fieldNames -notcontains $field) { throw ('Metric record is missing field ' + $field + '.') }
    }
    foreach ($field in $fieldNames) {
        if ($allowedRecordFields -notcontains $field) { throw ('Metric record has unknown field ' + $field + '.') }
    }

    if ($Record.schema -ne $historySchema -or [int]$Record.schema_version -ne $historySchemaVersion) {
        throw 'Metric record has an unsupported schema.'
    }
    Assert-NonEmptyString $Record.run_id 'run_id' '^[a-z0-9][a-z0-9._-]+$'
    Assert-NonEmptyString $Record.release 'release' '^\d+\.\d+\.\d+$'
    Assert-NonEmptyString $Record.suite 'suite' '^perfdiag-[a-z0-9-]+$'
    Assert-NonEmptyString $Record.workload_id 'workload_id' '^[a-z0-9][a-z0-9._-]+$'
    Assert-NonEmptyString $Record.environment_id 'environment_id' '^[a-z0-9][a-z0-9._-]+$'
    if ($null -eq $Record.image_sha256) {
        if (-not $Record.run_id.StartsWith('legacy-', [StringComparison]::Ordinal)) {
            throw 'image_sha256 may be null only for one-time legacy migration records.'
        }
    } else {
        Assert-NonEmptyString $Record.image_sha256 'image_sha256' '^[a-f0-9]{64}$'
    }
    if ($Record.cache_state -notin @('warm', 'cold')) { throw 'cache_state must be warm or cold.' }
    if (-not $metricCatalog.ContainsKey($Record.metric)) { throw ('Unknown metric: ' + $Record.metric) }
    $catalog = $metricCatalog[$Record.metric]
    if ($catalog.suite -ne $Record.suite -or $catalog.unit -ne $Record.unit -or $catalog.direction -ne $Record.direction) {
        throw ('Metric catalog mismatch for ' + $Record.metric + '.')
    }
    $samples = @($Record.samples)
    $distribution = Get-Distribution $samples
    foreach ($field in @('min', 'p50', 'p95', 'p99', 'max', 'mean')) {
        Assert-SameNumber $Record.$field $distribution.$field $field
    }
}

function Assert-HistoryRecords([object[]]$Records) {
    $keys = @{}
    $runIdentity = @{}
    foreach ($record in $Records) {
        Assert-MetricRecord $record
        $key = $record.run_id + [char]0 + $record.metric
        if ($keys.ContainsKey($key)) { throw ('Duplicate run_id/metric: ' + $record.run_id + ' / ' + $record.metric) }
        $keys[$key] = $true

        $image = if ($null -eq $record.image_sha256) { '<null>' } else { [string]$record.image_sha256 }
        $identity = @($record.release, $record.suite, $record.workload_id, $record.environment_id, $image, $record.cache_state) -join [char]0
        if ($runIdentity.ContainsKey($record.run_id) -and $runIdentity[$record.run_id] -ne $identity) {
            throw ('Mixed identity inside run_id ' + $record.run_id + '.')
        }
        $runIdentity[$record.run_id] = $identity
    }
}

function Read-History([string]$Path, [switch]$AllowMissing) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($AllowMissing) { return @() }
        throw ('Benchmark history not found: ' + $Path)
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'Benchmark history must be UTF-8 without BOM.'
    }
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    $text = $encoding.GetString($bytes)
    if ($text.Contains("`r")) { throw 'Benchmark history must use LF line endings.' }
    if ($text.Length -gt 0 -and -not $text.EndsWith("`n", [StringComparison]::Ordinal)) {
        throw 'Benchmark history must end with LF.'
    }
    $records = [Collections.Generic.List[object]]::new()
    $lineNumber = 0
    foreach ($line in $text.Split([char]10)) {
        $lineNumber += 1
        if ($line.Length -eq 0) {
            if ($lineNumber -eq $text.Split([char]10).Count) { continue }
            throw ('Benchmark history contains an empty line at ' + $lineNumber + '.')
        }
        try {
            $record = $line | ConvertFrom-Json
        } catch {
            throw ('Invalid JSONL at line ' + $lineNumber + ': ' + $_.Exception.Message)
        }
        if ($record -is [array]) { throw ('JSONL line ' + $lineNumber + ' must contain one object.') }
        $records.Add($record)
    }
    $result = $records.ToArray()
    Assert-HistoryRecords $result
    return $result
}

function Write-HistoryAtomic([string]$Path, [object[]]$Records) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'HistoryPath is required.' }
    Assert-HistoryRecords $Records
    $absolutePath = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($absolutePath)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }
    $lines = @($Records | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 })
    $content = if ($lines.Count -eq 0) { '' } else { ($lines -join "`n") + "`n" }
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.tmp-' + [Guid]::NewGuid().ToString('N'))
    $backup = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.bak-' + [Guid]::NewGuid().ToString('N'))
    $encoding = New-Object Text.UTF8Encoding($false)
    try {
        [IO.File]::WriteAllText($temporary, $content, $encoding)
        if (Test-Path -LiteralPath $absolutePath -PathType Leaf) {
            [IO.File]::Replace($temporary, $absolutePath, $backup)
            [IO.File]::Delete($backup)
        } else {
            [IO.File]::Move($temporary, $absolutePath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { [IO.File]::Delete($temporary) }
        if (Test-Path -LiteralPath $backup -PathType Leaf) { [IO.File]::Delete($backup) }
    }
}

function Add-HistoryRecords([string]$Path, [object[]]$NewRecords) {
    $existing = @(Read-History $Path -AllowMissing)
    $combined = @($existing) + @($NewRecords)
    Assert-HistoryRecords $combined
    Write-HistoryAtomic $Path $combined
}

function Get-RecordsOfType([object[]]$Records, [string]$Type) {
    return @($Records | Where-Object { $_.type -eq $Type })
}

function Get-UniformPositiveInteger([object[]]$Records, [string]$Field, [string]$Label) {
    if ($Records.Count -eq 0) { throw ($Label + ' has no records.') }
    $value = $null
    foreach ($record in $Records) {
        $current = Get-RequiredProperty $record $Field $Label
        Assert-NonNegativeNumber $current ($Label + '.' + $Field)
        if ([decimal]$current -ne [Math]::Floor([decimal]$current) -or [decimal]$current -le 0) {
            throw ($Label + '.' + $Field + ' must be a positive integer.')
        }
        if ($null -eq $value) { $value = [long]$current }
        if ([long]$current -ne $value) { throw ($Label + '.' + $Field + ' is not stable across samples.') }
    }
    return $value
}

function Get-SourceDistribution(
    [object[]]$Records,
    [string]$Type,
    [string]$SelectorField = '',
    [string]$SelectorValue = ''
) {
    $matches = @(Get-RecordsOfType $Records $Type)
    if ($SelectorField) { $matches = @($matches | Where-Object { [string]$_.$SelectorField -eq $SelectorValue }) }
    if ($matches.Count -ne 1) {
        throw ('Expected exactly one ' + $Type + ' distribution, got ' + $matches.Count + '.')
    }
    return $matches[0]
}

function Get-SourceSamples(
    [object[]]$Records,
    [string]$Type,
    [string]$ValueField,
    [int]$ExpectedCount,
    [string]$SelectorField = '',
    [string]$SelectorValue = ''
) {
    $matches = @(Get-RecordsOfType $Records $Type)
    if ($SelectorField) { $matches = @($matches | Where-Object { [string]$_.$SelectorField -eq $SelectorValue }) }
    if ($matches.Count -ne $ExpectedCount) {
        throw ('Expected ' + $ExpectedCount + ' ' + $Type + ' samples, got ' + $matches.Count + '.')
    }
    $seen = @{}
    $values = [Collections.Generic.List[object]]::new()
    foreach ($sample in $matches) {
        $index = [int](Get-RequiredProperty $sample 'sample' $Type)
        if ($index -lt 1 -or $index -gt $ExpectedCount -or $seen.ContainsKey($index)) {
            throw ($Type + ' sample numbering is incomplete or duplicated.')
        }
        $seen[$index] = $true
        $value = Get-RequiredProperty $sample $ValueField $Type
        Assert-NonNegativeNumber $value ($Type + '.' + $ValueField)
        $values.Add($value)
    }
    if ($seen.Count -ne $ExpectedCount) { throw ($Type + ' sample numbering is incomplete.') }
    return @($matches | Sort-Object { [int]$_.sample } | ForEach-Object { $_.$ValueField })
}

function Assert-SourceDistribution($Distribution, [object[]]$Samples, [string]$ExpectedUnit) {
    if ($Distribution.unit -ne $ExpectedUnit) {
        throw ('Unexpected source unit: expected ' + $ExpectedUnit + ', got ' + $Distribution.unit + '.')
    }
    if ([int]$Distribution.count -ne $Samples.Count) { throw 'Source distribution count does not match samples.' }
    $expected = Get-Distribution $Samples
    foreach ($field in @('min', 'p50', 'p95', 'p99', 'max', 'mean')) {
        Assert-SameNumber $Distribution.$field $expected.$field ('source.' + $field)
    }
}

function Get-WorkloadId([string]$SuiteName, [object[]]$Records) {
    switch ($SuiteName) {
        'perfdiag-blit' {
            $samples = @(Get-RecordsOfType $Records 'blit_sample')
            if ($samples.Count -eq 0) { throw 'blit has no records.' }
            $frameBytes = $null
            foreach ($sample in $samples) {
                $iterations = Get-RequiredProperty $sample 'iterations' 'blit'
                $bytes = Get-RequiredProperty $sample 'bytes' 'blit'
                Assert-NonNegativeNumber $iterations 'blit.iterations'
                Assert-NonNegativeNumber $bytes 'blit.bytes'
                if ([decimal]$iterations -ne [Math]::Floor([decimal]$iterations) -or [decimal]$iterations -le 0) {
                    throw 'blit.iterations must be a positive integer.'
                }
                if ([decimal]$bytes -ne [Math]::Floor([decimal]$bytes) -or [decimal]$bytes -le 0) {
                    throw 'blit.bytes must be a positive integer.'
                }
                if ([long]$bytes % [long]$iterations -ne 0) {
                    throw 'blit.bytes must contain a whole number of equal frames.'
                }
                $currentFrameBytes = [long]([long]$bytes / [long]$iterations)
                if ($null -eq $frameBytes) { $frameBytes = $currentFrameBytes }
                if ($currentFrameBytes -ne $frameBytes) {
                    throw 'blit frame size is not stable across samples.'
                }
            }
            # PERF-DIAG runs this fixed-size frame for a time-bounded 250 ms
            # window. Iterations and therefore total bytes are measurements,
            # not workload identity and are expected to vary per sample.
            return ('perfdiag.blit.window-250ms.frame-bytes-' + $frameBytes + '.v1')
        }
        'perfdiag-clock' {
            $samples = @(Get-RecordsOfType $Records 'clock_sample')
            $calls = Get-UniformPositiveInteger $samples 'calls' 'clock'
            return ('perfdiag.clock.calls-' + $calls + '.v1')
        }
        'perfdiag-service-registry' {
            $samples = @(Get-RecordsOfType $Records 'service_registry_sample')
            $iterations = Get-UniformPositiveInteger $samples 'iterations' 'service-registry'
            $services = Get-UniformPositiveInteger $samples 'services_per_enumeration' 'service-registry'
            return ('perfdiag.service-registry.iterations-' + $iterations + '.services-' + $services + '.v1')
        }
        'perfdiag-kernel-ipc' {
            $samples = @(Get-RecordsOfType $Records 'kernel_ipc_sample')
            $iterations = Get-UniformPositiveInteger $samples 'iterations' 'kernel-ipc'
            $requests = Get-UniformPositiveInteger $samples 'requests' 'kernel-ipc'
            return ('perfdiag.kernel-ipc.iterations-' + $iterations + '.requests-' + $requests + '.v1')
        }
        'perfdiag-driver-work' {
            $samples = @(Get-RecordsOfType $Records 'driver_work_sample')
            $writes = Get-UniformPositiveInteger $samples 'audio_writes' 'driver-work'
            $bytes = Get-UniformPositiveInteger $samples 'audio_bytes' 'driver-work'
            return ('perfdiag.driver-work.audio-writes-' + $writes + '.audio-bytes-' + $bytes + '.v1')
        }
        'perfdiag-pci-inventory' {
            $samples = @(Get-RecordsOfType $Records 'pci_inventory_sample')
            $iterations = Get-UniformPositiveInteger $samples 'iterations' 'pci-inventory'
            $records = Get-UniformPositiveInteger $samples 'records' 'pci-inventory'
            return ('perfdiag.pci-inventory.iterations-' + $iterations + '.records-' + $records + '.v1')
        }
        'perfdiag-memory-metadata' {
            $samples = @(Get-RecordsOfType $Records 'memory_metadata_sample')
            $pages = Get-UniformPositiveInteger $samples 'pages' 'memory-metadata'
            return ('perfdiag.memory-metadata.pages-' + $pages + '.v1')
        }
        default { throw ('Unknown benchmark suite: ' + $SuiteName) }
    }
}

function Get-SuiteMetricSpecs([string]$SuiteName) {
    switch ($SuiteName) {
        'perfdiag-blit' {
            return ,([pscustomobject]@{ metric = 'perfdiag.blit.throughput'; distribution_type = 'blit_distribution'; sample_type = 'blit_sample'; sample_field = 'kb_per_second'; selector_field = ''; selector_value = '' })
        }
        'perfdiag-clock' {
            return ,([pscustomobject]@{ metric = 'perfdiag.clock.latency'; distribution_type = 'clock_distribution'; sample_type = 'clock_sample'; sample_field = 'ns_per_call'; selector_field = ''; selector_value = '' })
        }
        'perfdiag-service-registry' {
            return @(
                [pscustomobject]@{ metric = 'perfdiag.service_registry.service_info.latency'; distribution_type = 'service_registry_distribution'; sample_type = 'service_registry_sample'; sample_field = 'ns_per_enumeration'; selector_field = 'phase'; selector_value = 'service-info' },
                [pscustomobject]@{ metric = 'perfdiag.service_registry.service_detail.latency'; distribution_type = 'service_registry_distribution'; sample_type = 'service_registry_sample'; sample_field = 'ns_per_enumeration'; selector_field = 'phase'; selector_value = 'service-detail' },
                [pscustomobject]@{ metric = 'perfdiag.service_registry.servman_diag.latency'; distribution_type = 'service_registry_distribution'; sample_type = 'service_registry_sample'; sample_field = 'ns_per_enumeration'; selector_field = 'phase'; selector_value = 'servman-diag' }
            )
        }
        'perfdiag-kernel-ipc' {
            return @(
                [pscustomobject]@{ metric = 'perfdiag.kernel_ipc.caller.latency'; distribution_type = 'kernel_ipc_distribution'; sample_type = 'kernel_ipc_sample'; sample_field = 'caller_ns_per_request'; selector_field = 'metric'; selector_value = 'caller' },
                [pscustomobject]@{ metric = 'perfdiag.kernel_ipc.handler_queue.latency'; distribution_type = 'kernel_ipc_distribution'; sample_type = 'kernel_ipc_sample'; sample_field = 'handler_queue_ns_per_request'; selector_field = 'metric'; selector_value = 'handler-queue' },
                [pscustomobject]@{ metric = 'perfdiag.kernel_ipc.handler_run.latency'; distribution_type = 'kernel_ipc_distribution'; sample_type = 'kernel_ipc_sample'; sample_field = 'handler_run_ns_per_request'; selector_field = 'metric'; selector_value = 'handler-run' },
                [pscustomobject]@{ metric = 'perfdiag.kernel_ipc.handler_e2e.latency'; distribution_type = 'kernel_ipc_distribution'; sample_type = 'kernel_ipc_sample'; sample_field = 'handler_e2e_ns_per_request'; selector_field = 'metric'; selector_value = 'handler-e2e' }
            )
        }
        'perfdiag-driver-work' {
            return @(
                [pscustomobject]@{ metric = 'perfdiag.driver_work.queue.latency'; distribution_type = 'driver_work_distribution'; sample_type = 'driver_work_sample'; sample_field = 'queue_ns_per_started'; selector_field = 'metric'; selector_value = 'queue' },
                [pscustomobject]@{ metric = 'perfdiag.driver_work.run.latency'; distribution_type = 'driver_work_distribution'; sample_type = 'driver_work_sample'; sample_field = 'run_ns_per_completed'; selector_field = 'metric'; selector_value = 'run' },
                [pscustomobject]@{ metric = 'perfdiag.driver_work.e2e.latency'; distribution_type = 'driver_work_distribution'; sample_type = 'driver_work_sample'; sample_field = 'e2e_ns_per_completed'; selector_field = 'metric'; selector_value = 'e2e' }
            )
        }
        'perfdiag-pci-inventory' {
            return ,([pscustomobject]@{ metric = 'perfdiag.pci_inventory.latency'; distribution_type = 'pci_inventory_distribution'; sample_type = 'pci_inventory_sample'; sample_field = 'ns_per_inventory'; selector_field = ''; selector_value = '' })
        }
        'perfdiag-memory-metadata' {
            return @(
                [pscustomobject]@{ metric = 'perfdiag.memory_metadata.reserve_commit.latency'; distribution_type = 'memory_metadata_distribution'; sample_type = 'memory_metadata_sample'; sample_field = 'reserve_commit_ns_per_page'; selector_field = 'metric'; selector_value = 'reserve-commit' },
                [pscustomobject]@{ metric = 'perfdiag.memory_metadata.fault.latency'; distribution_type = 'memory_metadata_distribution'; sample_type = 'memory_metadata_sample'; sample_field = 'fault_ns_per_page'; selector_field = 'metric'; selector_value = 'fault' },
                [pscustomobject]@{ metric = 'perfdiag.memory_metadata.page_state.latency'; distribution_type = 'memory_metadata_distribution'; sample_type = 'memory_metadata_sample'; sample_field = 'page_state_ns_per_page'; selector_field = 'metric'; selector_value = 'page-state' },
                [pscustomobject]@{ metric = 'perfdiag.memory_metadata.reclaim.latency'; distribution_type = 'memory_metadata_distribution'; sample_type = 'memory_metadata_sample'; sample_field = 'reclaim_ns_per_vm_frame'; selector_field = 'metric'; selector_value = 'reclaim' }
            )
        }
        default { throw ('Unknown benchmark suite: ' + $SuiteName) }
    }
}

function Get-MetricRecordsFromRunResult($Result) {
    if ($Result.schema -ne $runSchema -or [int]$Result.schema_version -ne $runSchemaVersion) {
        throw 'Unsupported benchmark run schema.'
    }
    $identity = Get-RequiredProperty $Result 'identity' 'run result'
    $runId = Get-RequiredProperty $identity 'run_id' 'run identity'
    $release = Get-RequiredProperty $identity 'release' 'run identity'
    $imageSha256 = Get-RequiredProperty $identity 'image_sha256' 'run identity'
    Assert-NonEmptyString $runId 'identity.run_id' '^[a-z0-9][a-z0-9._-]+$'
    Assert-NonEmptyString $release 'identity.release' '^\d+\.\d+\.\d+$'
    Assert-NonEmptyString $imageSha256 'identity.image_sha256' '^[a-f0-9]{64}$'

    $request = Get-RequiredProperty $Result 'request' 'run result'
    $suiteName = Get-RequiredProperty $request 'suite' 'request'
    $workloadName = Get-RequiredProperty $request 'workload' 'request'
    $workloadVersion = Get-RequiredProperty $request 'workload_version' 'request'
    $cache = Get-RequiredProperty $request 'cache_state' 'request'
    $repetitions = [int](Get-RequiredProperty $request 'repetitions' 'request')
    $requestedEnvironment = Get-RequiredProperty $request 'environment_id' 'request'
    if ($request.schema -ne 'r4os.benchmark.request' -or [int]$request.schema_version -ne 1) { throw 'Unsupported benchmark request schema.' }
    if (-not $suiteWorkloads.ContainsKey($suiteName) -or $suiteWorkloads[$suiteName] -ne $workloadName) {
        throw ('Benchmark suite/workload mismatch: ' + $suiteName + ' / ' + $workloadName)
    }
    Assert-NonEmptyString $workloadVersion 'request.workload_version' '^\d+\.\d+\.\d+$'
    if ($cache -notin @('warm', 'cold')) { throw 'Run request cache state is invalid.' }
    if ($repetitions -lt 3 -or $repetitions -gt 20) { throw 'Run request repetitions are invalid.' }
    if ($requestedEnvironment -ne $standardEnvironmentId) { throw ('Unsupported benchmark environment: ' + $requestedEnvironment) }

    $environment = Get-RequiredProperty $Result 'environment' 'run result'
    if ($environment.id -ne $requestedEnvironment) { throw 'Run environment does not match request.' }
    $outcome = Get-RequiredProperty $Result 'outcome' 'run result'
    $qemuExitCode = Get-RequiredProperty $outcome 'qemu_exit_code' 'run outcome'
    Assert-NonNegativeNumber $qemuExitCode 'outcome.qemu_exit_code'
    if ([decimal]$qemuExitCode -ne [Math]::Floor([decimal]$qemuExitCode) -or [int]$qemuExitCode -ne 0 -or
        $outcome.regular_poweroff -ne $true -or
        $outcome.machine_block_complete -ne $true -or
        $outcome.result -ne 'ok') {
        throw 'Incomplete or failed benchmark result cannot be imported.'
    }

    $records = @($Result.records)
    if ($records.Count -eq 0) { throw 'Benchmark result contains no machine records.' }
    foreach ($record in $records) {
        if ($record.schema -ne $perfdiagSchema -or [int]$record.schema_version -ne $perfdiagSchemaVersion) {
            throw 'Benchmark result contains an unsupported PERFDIAG record.'
        }
    }
    $runRecords = @(Get-RecordsOfType $records 'run')
    if ($runRecords.Count -ne 1) { throw 'Benchmark result must contain exactly one run record.' }
    $run = $runRecords[0]
    if ($run.result -ne 'ok' -or $run.mode -ne 'benchmark' -or $run.benchmark -ne $request.workload -or
        $run.cache_state -ne $cache -or [int]$run.repetitions -ne $repetitions -or
        $run.module_version -ne $request.workload_version) {
        throw 'PERFDIAG run record does not match the benchmark request.'
    }
    if ($run.clock_available -ne $true -or [int64]$run.clock_resolution_ns -le 0 -or
        [string]::IsNullOrWhiteSpace([string]$run.clock_source) -or
        [int64]$run.event_frequency_numerator -le 0 -or [int64]$run.event_frequency_denominator -le 0) {
        throw 'Benchmark run has no valid clock basis.'
    }
    foreach ($check in @(Get-RecordsOfType $records 'check')) {
        if ($check.ok -ne $true) { throw ('Benchmark correctness check failed: ' + $check.name) }
    }

    $specs = @(Get-SuiteMetricSpecs $suiteName)
    $allowedDistributionTypes = @($specs | ForEach-Object { $_.distribution_type } | Select-Object -Unique)
    foreach ($record in @($records | Where-Object { $_.type -match '_distribution$' })) {
        if ($allowedDistributionTypes -notcontains $record.type) {
            throw ('Unknown distribution record for suite ' + $suiteName + ': ' + $record.type)
        }
    }
    if (@($records | Where-Object { $_.type -match '_distribution$' }).Count -ne $specs.Count) {
        throw ('Suite ' + $suiteName + ' has an incomplete metric set.')
    }

    $workload = Get-WorkloadId $suiteName $records
    $metrics = [Collections.Generic.List[object]]::new()
    foreach ($spec in $specs) {
        $distribution = Get-SourceDistribution $records $spec.distribution_type $spec.selector_field $spec.selector_value
        $sampleSelectorField = $spec.selector_field
        $sampleSelectorValue = $spec.selector_value
        if ($spec.sample_type -in @('kernel_ipc_sample', 'driver_work_sample', 'memory_metadata_sample')) {
            $sampleSelectorField = ''
            $sampleSelectorValue = ''
        }
        $samples = @(Get-SourceSamples $records $spec.sample_type $spec.sample_field $repetitions $sampleSelectorField $sampleSelectorValue)
        $catalog = $metricCatalog[$spec.metric]
        Assert-SourceDistribution $distribution $samples $catalog.unit
        $metricRecord = New-MetricRecord $runId $release $suiteName $workload $requestedEnvironment $imageSha256 $cache $spec.metric $samples
        $metrics.Add($metricRecord)
    }
    $resultRecords = $metrics.ToArray()
    Assert-HistoryRecords $resultRecords
    return $resultRecords
}

function Get-MarkdownTableRows([string]$Text, [string]$Heading) {
    $lines = @($Text -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
    $headingIndex = [Array]::IndexOf($lines, $Heading)
    if ($headingIndex -lt 0) { return @() }
    $headerIndex = $headingIndex + 1
    while ($headerIndex -lt $lines.Count -and -not $lines[$headerIndex].StartsWith('|', [StringComparison]::Ordinal)) { $headerIndex += 1 }
    if ($headerIndex + 1 -ge $lines.Count) { throw ('Incomplete Markdown table: ' + $Heading) }
    $rows = [Collections.Generic.List[object]]::new()
    $index = $headerIndex + 2
    while ($index -lt $lines.Count -and $lines[$index].StartsWith('|', [StringComparison]::Ordinal)) {
        $cells = @($lines[$index].Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        $rows.Add([pscustomobject]@{ cells = $cells })
        $index += 1
    }
    return $rows.ToArray()
}

function Get-LegacyCell($Row, [int]$Index, [string]$Label) {
    $cells = @($Row.cells)
    if ($Index -lt 0 -or $Index -ge $cells.Count) { throw ($Label + ' is missing column ' + $Index + '.') }
    return $cells[$Index]
}

function Convert-LegacyInteger([string]$Value, [string]$Label) {
    $number = [long]0
    if (-not [long]::TryParse($Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or $number -lt 0) {
        throw ($Label + ' is not a non-negative integer: ' + $Value)
    }
    return $number
}

function Add-LegacyMetric(
    [Collections.Generic.List[object]]$Target,
    [string]$Release,
    [string]$SuiteName,
    [string]$Workload,
    [string]$Environment,
    [string]$MetricName,
    [object[]]$Samples
) {
    $runId = 'legacy-' + $Release + '-' + $SuiteName + '-warm'
    $Target.Add((New-MetricRecord $runId $Release $SuiteName $Workload $Environment $null 'warm' $MetricName $Samples))
}

function Get-LegacyMetricRecords([string]$Path) {
    Assert-File $Path 'Legacy Diagnose.txt'
    $text = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false, $true)))
    $metrics = [Collections.Generic.List[object]]::new()

    foreach ($definition in @(
        [pscustomobject]@{ heading = '## BLIT-Rohwerte'; suite = 'perfdiag-blit'; workload = 'perfdiag.blit.window-250ticks.v1'; environment = $legacyEnvironmentId; metric = 'perfdiag.blit.throughput'; value_column = 3 },
        [pscustomobject]@{ heading = '## CLOCK-Rohwerte'; suite = 'perfdiag-clock'; workload = 'perfdiag.clock.calls-10000.v1'; environment = $standardEnvironmentId; metric = 'perfdiag.clock.latency'; value_column = 4 },
        [pscustomobject]@{ heading = '### PCI-INVENTORY-Verbraucher-Rohwerte'; suite = 'perfdiag-pci-inventory'; workload = 'perfdiag.pci-inventory.iterations-100.records-4100.v1'; environment = $legacyEnvironmentId; metric = 'perfdiag.pci_inventory.latency'; value_column = 5 },
        [pscustomobject]@{ heading = '### BENCHMARK-IMAGE-CLOCK-Rohwerte'; suite = 'perfdiag-clock'; workload = 'perfdiag.clock.calls-10000.v1'; environment = $standardEnvironmentId; metric = 'perfdiag.clock.latency'; value_column = 4 }
    )) {
        $rows = @(Get-MarkdownTableRows $text $definition.heading)
        foreach ($group in @($rows | Group-Object { Get-LegacyCell $_ 0 $definition.heading })) {
            $samples = @($group.Group | ForEach-Object { Convert-LegacyInteger (Get-LegacyCell $_ $definition.value_column $definition.heading) $definition.heading })
            Add-LegacyMetric $metrics $group.Name $definition.suite $definition.workload $definition.environment $definition.metric $samples
        }
    }

    $registryRows = @(Get-MarkdownTableRows $text '### SERVICE-REGISTRY-Rohwerte')
    $registryMetric = @{
        'service-info' = 'perfdiag.service_registry.service_info.latency'
        'service-detail' = 'perfdiag.service_registry.service_detail.latency'
        'servman-diag' = 'perfdiag.service_registry.servman_diag.latency'
    }
    foreach ($group in @($registryRows | Group-Object { (Get-LegacyCell $_ 0 'SERVICE-REGISTRY') + [char]0 + (Get-LegacyCell $_ 1 'SERVICE-REGISTRY') })) {
        $parts = $group.Name.Split([char]0)
        if (-not $registryMetric.ContainsKey($parts[1])) { throw ('Unknown legacy service-registry phase: ' + $parts[1]) }
        $samples = @($group.Group | ForEach-Object { Convert-LegacyInteger (Get-LegacyCell $_ 11 'SERVICE-REGISTRY') 'SERVICE-REGISTRY' })
        Add-LegacyMetric $metrics $parts[0] 'perfdiag-service-registry' 'perfdiag.service-registry.iterations-100.services-11.v1' $legacyEnvironmentId $registryMetric[$parts[1]] $samples
    }

    $ipcRows = @(Get-MarkdownTableRows $text '### KERNEL-IPC-Latenz-Rohwerte')
    foreach ($group in @($ipcRows | Group-Object { Get-LegacyCell $_ 0 'KERNEL-IPC' })) {
        foreach ($definition in @(
            [pscustomobject]@{ metric = 'perfdiag.kernel_ipc.caller.latency'; column = 4 },
            [pscustomobject]@{ metric = 'perfdiag.kernel_ipc.handler_queue.latency'; column = 6 },
            [pscustomobject]@{ metric = 'perfdiag.kernel_ipc.handler_run.latency'; column = 10 },
            [pscustomobject]@{ metric = 'perfdiag.kernel_ipc.handler_e2e.latency'; column = 14 }
        )) {
            $samples = @($group.Group | ForEach-Object { Convert-LegacyInteger (Get-LegacyCell $_ $definition.column 'KERNEL-IPC') 'KERNEL-IPC' })
            Add-LegacyMetric $metrics $group.Name 'perfdiag-kernel-ipc' 'perfdiag.kernel-ipc.iterations-64.requests-576.v1' $legacyEnvironmentId $definition.metric $samples
        }
    }

    $driverRows = @(Get-MarkdownTableRows $text '### DRIVER-WORK-Latenz-Rohwerte')
    foreach ($group in @($driverRows | Group-Object { Get-LegacyCell $_ 0 'DRIVER-WORK' })) {
        foreach ($definition in @(
            [pscustomobject]@{ metric = 'perfdiag.driver_work.queue.latency'; column = 3 },
            [pscustomobject]@{ metric = 'perfdiag.driver_work.run.latency'; column = 5 },
            [pscustomobject]@{ metric = 'perfdiag.driver_work.e2e.latency'; column = 7 }
        )) {
            $samples = @($group.Group | ForEach-Object { Convert-LegacyInteger (Get-LegacyCell $_ $definition.column 'DRIVER-WORK') 'DRIVER-WORK' })
            Add-LegacyMetric $metrics $group.Name 'perfdiag-driver-work' 'perfdiag.driver-work.audio-writes-8.audio-bytes-32768.v1' $legacyEnvironmentId $definition.metric $samples
        }
    }

    $result = $metrics.ToArray()
    if ($result.Count -eq 0) { throw 'Legacy Diagnose.txt contains no reconstructable primary metrics.' }
    Assert-HistoryRecords $result
    return $result
}

function Get-ComparisonRows(
    [object[]]$Records,
    [string]$SuiteName,
    [string]$Workload,
    [string]$Environment,
    [string]$Cache,
    [string]$MetricName
) {
    foreach ($value in @($SuiteName, $Workload, $Environment, $Cache, $MetricName)) {
        if ([string]::IsNullOrWhiteSpace($value)) { throw 'compare requires Suite, WorkloadId, EnvironmentId, CacheState and Metric.' }
    }
    if ($Cache -notin @('warm', 'cold')) { throw 'compare CacheState must be warm or cold.' }
    $matches = @($Records | Where-Object {
        $_.suite -eq $SuiteName -and
        $_.workload_id -eq $Workload -and
        $_.environment_id -eq $Environment -and
        $_.cache_state -eq $Cache -and
        $_.metric -eq $MetricName
    } | Sort-Object { [version]$_.release })
    if ($matches.Count -lt 2) {
        throw ('At least two identical suite/workload/environment/metric records are required; got ' + $matches.Count + '.')
    }
    $catalog = $metricCatalog[$MetricName]
    $rows = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $matches.Count; $index++) {
        $current = $matches[$index]
        $delta = $null
        $deltaPercent = $null
        $improvement = $null
        $improvementPercent = $null
        $change = 'baseline'
        if ($index -gt 0) {
            $previous = $matches[$index - 1]
            $delta = [double]$current.mean - [double]$previous.mean
            if ([double]$previous.mean -ne 0) { $deltaPercent = ($delta / [double]$previous.mean) * 100.0 }
            $sign = if ($catalog.direction -eq 'lower') { -1.0 } else { 1.0 }
            $improvement = $delta * $sign
            if ($null -ne $deltaPercent) { $improvementPercent = $deltaPercent * $sign }
            if ($improvement -gt 0) { $change = 'improved' } elseif ($improvement -lt 0) { $change = 'degraded' } else { $change = 'unchanged' }
        }
        $rows.Add([pscustomobject][ordered]@{
            release = $current.release
            run_id = $current.run_id
            mean = $current.mean
            unit = $current.unit
            direction = $current.direction
            delta = $delta
            delta_percent = $deltaPercent
            improvement = $improvement
            improvement_percent = $improvementPercent
            change = $change
        })
    }
    return $rows.ToArray()
}

function Assert-Throws([scriptblock]$Operation, [string]$Label) {
    try {
        & $Operation
    } catch {
        return
    }
    throw ('Self-test expected failure: ' + $Label)
}

function New-SelfTestSourceRecord([string]$Type, [hashtable]$Fields) {
    $record = [ordered]@{
        schema = $perfdiagSchema
        schema_version = $perfdiagSchemaVersion
        type = $Type
    }
    foreach ($key in $Fields.Keys) { $record[$key] = $Fields[$key] }
    return [pscustomobject]$record
}

function New-SelfTestDistributionRecord(
    [string]$Type,
    [string]$Unit,
    [object[]]$Values,
    [string]$SelectorField = '',
    [string]$SelectorValue = ''
) {
    $distribution = Get-Distribution $Values
    $fields = [ordered]@{}
    if ($SelectorField) { $fields[$SelectorField] = $SelectorValue }
    $fields['unit'] = $Unit
    $fields['count'] = $Values.Count
    $fields['min'] = $distribution.min
    $fields['p50'] = $distribution.p50
    $fields['p95'] = $distribution.p95
    $fields['p99'] = $distribution.p99
    $fields['max'] = $distribution.max
    $fields['mean'] = $distribution.mean
    return New-SelfTestSourceRecord $Type $fields
}

function New-SelfTestRunCase($Fixture, [string]$SuiteName, [string]$WorkloadName, [object[]]$PayloadRecords) {
    $case = ($Fixture | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
    $case.identity.run_id = 'r4os-0.69.99-' + $SuiteName + '-warm-fixture'
    $case.request.suite = $SuiteName
    $case.request.workload = $WorkloadName
    $run = @($case.records | Where-Object { $_.type -eq 'run' })[0]
    $run.benchmark = $WorkloadName
    $check = @($case.records | Where-Object { $_.type -eq 'check' })[0]
    $case.records = @($run, $check) + @($PayloadRecords)
    return $case
}

function Invoke-SelfTest {
    $distributionRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $workspaceRoot = (Resolve-Path -LiteralPath (Join-Path $distributionRoot '..\..')).Path
    $workspaceTemp = Join-Path $workspaceRoot 'Temp'
    if (-not (Test-Path -LiteralPath $workspaceTemp -PathType Container)) { New-Item -ItemType Directory -Path $workspaceTemp | Out-Null }
    $tempRoot = Join-Path $workspaceTemp ('BenchmarkHistorySelfTest-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    try {
        $fixturePath = Join-Path $distributionRoot 'Tests\Fixtures\BenchmarkHistory\valid-result.json'
        $legacyPath = Join-Path $distributionRoot 'Tests\Fixtures\BenchmarkHistory\Diagnose.txt'
        Assert-File $fixturePath 'Benchmark result fixture'
        Assert-File $legacyPath 'Legacy migration fixture'
        $fixture = [IO.File]::ReadAllText($fixturePath) | ConvertFrom-Json
        $metrics = @(Get-MetricRecordsFromRunResult $fixture)
        if ($metrics.Count -ne 1 -or $metrics[0].metric -ne 'perfdiag.clock.latency') { throw 'Valid fixture did not produce the catalog metric.' }

        $values = @(10, 20, 30, 40, 50)
        $suiteCases = [Collections.Generic.List[object]]::new()

        $payload = [Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt $values.Count; $index++) {
            $iterations = 4 + $index
            $payload.Add((New-SelfTestSourceRecord 'blit_sample' @{ sample = $index + 1; iterations = $iterations; bytes = $iterations * 1024; kb_per_second = $values[$index] }))
        }
        $payload.Add((New-SelfTestDistributionRecord 'blit_distribution' 'KB/s' $values))
        $suiteCases.Add([pscustomobject]@{ expected = 1; result = New-SelfTestRunCase $fixture 'perfdiag-blit' 'blit' $payload.ToArray() })

        $payload = [Collections.Generic.List[object]]::new()
        foreach ($phase in @('service-info', 'service-detail', 'servman-diag')) {
            for ($index = 0; $index -lt $values.Count; $index++) {
                $payload.Add((New-SelfTestSourceRecord 'service_registry_sample' @{ phase = $phase; sample = $index + 1; iterations = 100; services_per_enumeration = 11; ns_per_enumeration = $values[$index] }))
            }
            $payload.Add((New-SelfTestDistributionRecord 'service_registry_distribution' 'ns/enumeration' $values 'phase' $phase))
        }
        $suiteCases.Add([pscustomobject]@{ expected = 3; result = New-SelfTestRunCase $fixture 'perfdiag-service-registry' 'service-registry' $payload.ToArray() })

        $payload = [Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt $values.Count; $index++) {
            $payload.Add((New-SelfTestSourceRecord 'kernel_ipc_sample' @{
                sample = $index + 1
                iterations = 64
                requests = 576
                caller_ns_per_request = $values[$index]
                handler_queue_ns_per_request = $values[$index] + 1
                handler_run_ns_per_request = $values[$index] + 2
                handler_e2e_ns_per_request = $values[$index] + 3
            }))
        }
        foreach ($definition in @(
            [pscustomobject]@{ selector = 'caller'; offset = 0 },
            [pscustomobject]@{ selector = 'handler-queue'; offset = 1 },
            [pscustomobject]@{ selector = 'handler-run'; offset = 2 },
            [pscustomobject]@{ selector = 'handler-e2e'; offset = 3 }
        )) {
            $metricValues = @($values | ForEach-Object { $_ + $definition.offset })
            $payload.Add((New-SelfTestDistributionRecord 'kernel_ipc_distribution' 'ns/request' $metricValues 'metric' $definition.selector))
        }
        $suiteCases.Add([pscustomobject]@{ expected = 4; result = New-SelfTestRunCase $fixture 'perfdiag-kernel-ipc' 'kernel-ipc' $payload.ToArray() })

        $payload = [Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt $values.Count; $index++) {
            $payload.Add((New-SelfTestSourceRecord 'driver_work_sample' @{
                sample = $index + 1
                audio_writes = 8
                audio_bytes = 32768
                queue_ns_per_started = $values[$index]
                run_ns_per_completed = $values[$index] + 1
                e2e_ns_per_completed = $values[$index] + 2
            }))
        }
        foreach ($definition in @(
            [pscustomobject]@{ selector = 'queue'; offset = 0 },
            [pscustomobject]@{ selector = 'run'; offset = 1 },
            [pscustomobject]@{ selector = 'e2e'; offset = 2 }
        )) {
            $metricValues = @($values | ForEach-Object { $_ + $definition.offset })
            $payload.Add((New-SelfTestDistributionRecord 'driver_work_distribution' 'ns/work' $metricValues 'metric' $definition.selector))
        }
        $suiteCases.Add([pscustomobject]@{ expected = 3; result = New-SelfTestRunCase $fixture 'perfdiag-driver-work' 'driver-work' $payload.ToArray() })

        $payload = [Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt $values.Count; $index++) {
            $payload.Add((New-SelfTestSourceRecord 'pci_inventory_sample' @{ sample = $index + 1; iterations = 100; records = 4100; ns_per_inventory = $values[$index] }))
        }
        $payload.Add((New-SelfTestDistributionRecord 'pci_inventory_distribution' 'ns/inventory' $values))
        $suiteCases.Add([pscustomobject]@{ expected = 1; result = New-SelfTestRunCase $fixture 'perfdiag-pci-inventory' 'pci-inventory' $payload.ToArray() })

        $payload = [Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt $values.Count; $index++) {
            $payload.Add((New-SelfTestSourceRecord 'memory_metadata_sample' @{
                sample = $index + 1
                pages = 8
                reserve_commit_ns_per_page = $values[$index]
                fault_ns_per_page = $values[$index] + 1
                page_state_ns_per_page = $values[$index] + 2
                reclaim_ns_per_vm_frame = $values[$index] + 3
            }))
        }
        foreach ($definition in @(
            [pscustomobject]@{ selector = 'reserve-commit'; unit = 'ns/page'; offset = 0 },
            [pscustomobject]@{ selector = 'fault'; unit = 'ns/page'; offset = 1 },
            [pscustomobject]@{ selector = 'page-state'; unit = 'ns/page'; offset = 2 },
            [pscustomobject]@{ selector = 'reclaim'; unit = 'ns/frame'; offset = 3 }
        )) {
            $metricValues = @($values | ForEach-Object { $_ + $definition.offset })
            $payload.Add((New-SelfTestDistributionRecord 'memory_metadata_distribution' $definition.unit $metricValues 'metric' $definition.selector))
        }
        $suiteCases.Add([pscustomobject]@{ expected = 4; result = New-SelfTestRunCase $fixture 'perfdiag-memory-metadata' 'memory-metadata' $payload.ToArray() })

        foreach ($suiteCase in $suiteCases) {
            $caseMetrics = @(Get-MetricRecordsFromRunResult $suiteCase.result)
            if ($caseMetrics.Count -ne $suiteCase.expected) {
                throw ('Suite import produced ' + $caseMetrics.Count + ' metrics; expected ' + $suiteCase.expected + '.')
            }
            if ($suiteCase.result.request.suite -eq 'perfdiag-blit' -and
                $caseMetrics[0].workload_id -ne 'perfdiag.blit.window-250ms.frame-bytes-1024.v1') {
                throw 'Time-bounded blit workload identity is incorrect.'
            }
        }

        $history = Join-Path $tempRoot 'Benchmarks.jsonl'
        Add-HistoryRecords $history $metrics
        $validated = @(Read-History $history)
        if ($validated.Count -ne 1) { throw 'Imported history count mismatch.' }
        $secondMetric = ($metrics[0] | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
        $secondMetric.run_id = 'r4os-0.69.100-perfdiag-clock-warm-fixture'
        $secondMetric.release = '0.69.100'
        Add-HistoryRecords $history @($secondMetric)
        $validated = @(Read-History $history)
        if ($validated.Count -ne 2) { throw 'Atomic append to existing history failed.' }
        $beforeFailure = [Convert]::ToBase64String([IO.File]::ReadAllBytes($history))
        Assert-Throws { Add-HistoryRecords $history $metrics } 'duplicate run_id/metric'
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($history)) -ne $beforeFailure) { throw 'Duplicate import changed the history.' }

        $badEnvironment = ($fixture | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
        $badEnvironment.environment.id = 'different-environment'
        Assert-Throws { Get-MetricRecordsFromRunResult $badEnvironment } 'environment mismatch'
        $badSchema = ($fixture | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
        $badSchema.schema_version = 99
        Assert-Throws { Get-MetricRecordsFromRunResult $badSchema } 'run schema mismatch'
        $badWorkload = ($fixture | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
        $badWorkload.request.workload = 'blit'
        ($badWorkload.records | Where-Object { $_.type -eq 'run' }).benchmark = 'blit'
        Assert-Throws { Get-MetricRecordsFromRunResult $badWorkload } 'suite/workload mismatch'
        $aborted = ($fixture | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
        $aborted.outcome.regular_poweroff = $false
        Assert-Throws { Get-MetricRecordsFromRunResult $aborted } 'aborted run'
        $failed = ($fixture | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
        $failed.outcome.result = 'failed'
        Assert-Throws { Get-MetricRecordsFromRunResult $failed } 'failed result'
        $missingClock = ($fixture | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
        ($missingClock.records | Where-Object { $_.type -eq 'run' }).clock_available = $false
        Assert-Throws { Get-MetricRecordsFromRunResult $missingClock } 'missing clock basis'
        $badUnit = ($fixture | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
        ($badUnit.records | Where-Object { $_.type -eq 'clock_distribution' }).unit = 'ticks'
        Assert-Throws { Get-MetricRecordsFromRunResult $badUnit } 'invalid unit'
        $missingSample = ($fixture | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
        $missingSample.records = @($missingSample.records | Where-Object { -not ($_.type -eq 'clock_sample' -and [int]$_.sample -eq 5) })
        Assert-Throws { Get-MetricRecordsFromRunResult $missingSample } 'missing sample'
        $unknownMetric = ($fixture | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
        $unknownMetric.records += [pscustomobject]@{ schema = $perfdiagSchema; schema_version = $perfdiagSchemaVersion; type = 'unknown_distribution'; unit = 'ns/call'; count = 5; min = 1; p50 = 1; p95 = 1; p99 = 1; max = 1; mean = 1 }
        Assert-Throws { Get-MetricRecordsFromRunResult $unknownMetric } 'unknown metric'
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($history)) -ne $beforeFailure) { throw 'Rejected imports changed the history.' }

        $legacyMetrics = @(Get-LegacyMetricRecords $legacyPath)
        if ($legacyMetrics.Count -ne 2) { throw ('Legacy migration fixture produced ' + $legacyMetrics.Count + ' records.') }
        $legacyHistory = Join-Path $tempRoot 'Legacy.jsonl'
        Add-HistoryRecords $legacyHistory $legacyMetrics
        $legacyValidated = @(Read-History $legacyHistory)
        $comparison = @(Get-ComparisonRows $legacyValidated 'perfdiag-clock' 'perfdiag.clock.calls-10000.v1' $standardEnvironmentId 'warm' 'perfdiag.clock.latency')
        if ($comparison.Count -ne 2 -or $comparison[1].change -ne 'improved' -or [double]$comparison[1].improvement -ne 12) {
            throw 'Direction-aware comparison is incorrect.'
        }
        Assert-Throws { Get-ComparisonRows $legacyValidated 'perfdiag-clock' 'perfdiag.clock.calls-10000.v1' 'other-environment' 'warm' 'perfdiag.clock.latency' } 'incomparable environment'
        Write-Host '[OK] Benchmark history schema, import, atomic rejection, migration and comparison gates.'
    } finally {
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
        $resolvedRoot = [IO.Path]::GetFullPath($workspaceTemp) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedTemp.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw ('Refusing to remove unexpected self-test path: ' + $resolvedTemp)
        }
        if (Test-Path -LiteralPath $resolvedTemp -PathType Container) { [IO.Directory]::Delete($resolvedTemp, $true) }
    }
}

switch ($Action.ToLowerInvariant()) {
    'selftest' {
        Invoke-SelfTest
    }
    'validate' {
        if ([string]::IsNullOrWhiteSpace($HistoryPath)) { throw 'HistoryPath is required.' }
        $records = @(Read-History $HistoryPath)
        Write-Host ('[OK] Benchmark history valid: records=' + $records.Count + ' path=' + $HistoryPath)
    }
    'import' {
        Assert-File $InputPath 'Benchmark run result'
        if ([string]::IsNullOrWhiteSpace($HistoryPath)) { throw 'HistoryPath is required.' }
        $result = [IO.File]::ReadAllText($InputPath) | ConvertFrom-Json
        $records = @(Get-MetricRecordsFromRunResult $result)
        Add-HistoryRecords $HistoryPath $records
        Write-Host ('[OK] Imported benchmark metrics: count=' + $records.Count + ' run_id=' + $records[0].run_id)
    }
    'migrate-legacy' {
        if ([string]::IsNullOrWhiteSpace($HistoryPath)) { throw 'HistoryPath is required.' }
        $records = @(Get-LegacyMetricRecords $InputPath)
        Add-HistoryRecords $HistoryPath $records
        Write-Host ('[OK] Migrated legacy benchmark metrics: count=' + $records.Count)
    }
    'compare' {
        if ([string]::IsNullOrWhiteSpace($HistoryPath)) { throw 'HistoryPath is required.' }
        $records = @(Read-History $HistoryPath)
        $rows = @(Get-ComparisonRows $records $Suite $WorkloadId $EnvironmentId $CacheState $Metric)
        $rows | ConvertTo-Json -Depth 6
    }
}
