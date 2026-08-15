[CmdletBinding(DefaultParameterSetName = 'Log')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Log')]
    [string]$LogPath,

    [Parameter(ParameterSetName = 'Log')]
    [string]$ErrorPath,

    [Parameter(ParameterSetName = 'Log')]
    [int]$QemuExitCode = 0,

    [Parameter(Mandatory, ParameterSetName = 'SelfTest')]
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$required = @(
    'Booted via Limine [OK]',
    'System poweroff.',
    'dirs=ok',
    'LOADERD result: OK',
    'RESDIAG result: OK',
    'EXPLORER selftest: OK',
    'APPEARANCE selftest: OK',
    'KLICKIFAX font selftest: OK family=R4 Sans faces=12',
    'KLICKIFAX image selftest: OK responsive=data+srcset css-background=resource SVG=nested-image-optional',
    'KLICKIFAX loading selftest: OK resource=container png=256x384 alpha=yes reuse=1 geometry=native+bounded tiles=6 missing=blank corrupt=blank',
    'KLICKIFAX font-cache selftest: OK demand=used-only storage=content-addressed warm=verified',
    'KLICKIFAX webfont-runtime selftest: OK cold=decoded warm=cache network=0 transport=alpha8',
    'KLICKIFAX selftest: OK',
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
$forbidden = @(
    'PANIC',
    'FATAL',
    'CPU EXCEPTION',
    'General Protection Fault',
    'Page Fault',
    'FSDIAG result: FAILED',
    'selftest FAILED',
    'SERVMAN LOAD: lines=0',
    'dirs=missing',
    '$MFT',
    'STORDIAG result: FAILED',
    'LOADERD result: FAILED',
    'RESDIAG result: FAILED',
    'EXPLORER selftest FAILED',
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
    Write-Host 'QEMU API marker self-test OK.'
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
