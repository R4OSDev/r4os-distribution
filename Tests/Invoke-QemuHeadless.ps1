$ErrorActionPreference = 'Stop'

$qemu = $env:R4OS_QEMU_EXE
$config = $env:R4OS_QEMU_CONFIG
$logPath = $env:R4OS_QEMU_LOG
$errorPath = $env:R4OS_QEMU_ERROR_LOG
$workingDirectory = $env:R4OS_QEMU_WORKING_DIRECTORY

$timeoutSeconds = 240
if ($env:QEMU_TEST_TIMEOUT_SECONDS) {
    $parsed = 0
    if ([int]::TryParse($env:QEMU_TEST_TIMEOUT_SECONDS, [ref]$parsed) -and $parsed -gt 0) {
        $timeoutSeconds = $parsed
    }
}

function Assert-File([string]$Path, [string]$Label) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Host ($Label + ' not found: ' + $Path)
        exit 125
    }
}

function Quote-Argument([string]$Value) {
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
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

Assert-File $qemu 'QEMU executable'
Assert-File $config 'QEMU config'
if (-not $logPath -or -not $errorPath) {
    Write-Host 'QEMU headless helper: log paths are not configured.'
    exit 125
}
if (-not $workingDirectory -or -not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
    Write-Host ('QEMU working directory not found: ' + $workingDirectory)
    exit 125
}

$argumentLine = @(
    '-readconfig', (Quote-Argument $config),
    '-cpu', 'Haswell',
    '-m', '1G',
    '-smp', '1',
    '-nic', 'none',
    '-serial', (Quote-Argument ('file:' + $logPath)),
    '-display', 'none',
    '-no-reboot',
    '-name', (Quote-Argument 'R4OS test standard')
) -join ' '

Write-Host ('=== QEMU headless smoke; timeout ' + $timeoutSeconds + 's ===')
Normalize-StartProcessEnvironment
$process = Start-Process -FilePath $qemu -ArgumentList $argumentLine -WorkingDirectory $workingDirectory -WindowStyle Hidden -RedirectStandardError $errorPath -PassThru
if ($process.WaitForExit($timeoutSeconds * 1000)) {
    exit $process.ExitCode
}

Write-Host ('=== QEMU TIMEOUT after ' + $timeoutSeconds + 's; terminating process ===')
try {
    if (-not $process.HasExited) {
        $process.Kill()
        $process.WaitForExit(5000) | Out-Null
    }
} catch {
    Write-Host ('QEMU headless helper: termination failed: ' + $_.Exception.Message)
}
exit 124
