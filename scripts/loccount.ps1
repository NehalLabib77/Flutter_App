# scripts/loccount.ps1
# Walk the current git index and bucket tracked files by language.
# Auto-detects binary files by sniffing the first 8 KB for a NUL byte.

$ErrorActionPreference = 'Stop'

$repoRoot = (git -C $PSScriptRoot rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) { $repoRoot = $PSScriptRoot }

$buckets = [ordered]@{
    'dart'         = 'Dart'
    'py'           = 'Python'
    'json'         = 'JSON'
    'geojson'      = 'JSON'
    'yaml'         = 'YAML'
    'yml'          = 'YAML'
    'md'           = 'Markdown'
    'csv'          = 'CSV'
    'tsv'          = 'CSV'
    'xls'          = 'CSV (binary)'
    'xlsx'         = 'CSV (binary)'
    'xml'          = 'XML'
    'kts'          = 'Kotlin Gradle'
    'gradle'       = 'Groovy Gradle'
    'properties'   = 'Properties'
    'html'         = 'Web'
    'css'          = 'Web'
    'ipynb'        = 'Jupyter'
    'joblib'       = 'ML artifact (binary)'
    'pkl'          = 'ML artifact (binary)'
    'png'          = 'Image (binary)'
    'jpg'          = 'Image (binary)'
    'jpeg'         = 'Image (binary)'
    'webp'         = 'Image (binary)'
    'gif'          = 'Image (binary)'
    'svg'          = 'Image (text)'
    'txt'          = 'Text'
    'gitignore'    = 'Text'
    'gitkeep'      = 'Text'
    'code-workspace' = 'Workspace'
}

function Test-IsBinary {
    param([string]$Path)
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 8192
            $read = $stream.Read($buf, 0, $buf.Length)
            for ($i = 0; $i -lt $read; $i++) {
                if ($buf[$i] -eq 0) { return $true }
            }
            return $false
        } finally {
            $stream.Dispose()
        }
    } catch {
        return $true
    }
}

$gitRoot = $repoRoot
Push-Location $gitRoot
try {
    $rows = git ls-files |
        Where-Object { -not (Test-Path -LiteralPath $_ -PathType Container) } |
        ForEach-Object {
            $path = $_
            $ext = [System.IO.Path]::GetExtension($path).TrimStart('.').ToLower()
            if (-not $ext) { $bucket = 'Other text' }
            elseif ($buckets.Contains($ext)) { $bucket = $buckets[$ext] }
            else { $bucket = 'Other' }

            $isBinary = Test-IsBinary -Path $path
            $lineCount = 0
            if (-not $isBinary) {
                $lineCount = (Get-Content -LiteralPath $path -ReadCount 0 -TotalCount 1 -ErrorAction SilentlyContinue)
                if ($null -eq $lineCount) { $lineCount = 0 }
                # Cheap: count newlines in raw bytes
                $bytes = [System.IO.File]::ReadAllBytes($path)
                $lineCount = 0
                foreach ($b in $bytes) { if ($b -eq 10) { $lineCount++ } }
                # Account for trailing partial line
                if ($bytes.Length -gt 0 -and $bytes[$bytes.Length - 1] -ne 10) { $lineCount++ }
            }
            [pscustomobject]@{
                Bucket = $bucket
                Path   = $path
                Lines  = $lineCount
            }
        }
} finally {
    Pop-Location
}

Write-Host '=== Files by language bucket (tracked only) ==='
$rows | Group-Object Bucket |
    Sort-Object @{e={($_.Group | Measure-Object Lines -Sum).Sum}; Desc=$true} |
    Select-Object @{n='Bucket';e={$_.Name}},
                  @{n='Files';e={$_.Count}},
                  @{n='Lines (text)';e={($_.Group | Where-Object Lines | Measure-Object Lines -Sum).Sum}} |
    Format-Table -AutoSize

Write-Host '=== Totals ==='
$totalFiles = ($rows | Measure-Object).Count
$totalLines = ($rows | Where-Object Lines | Measure-Object Lines -Sum).Sum
Write-Host ("Total tracked files : {0}" -f $totalFiles)
Write-Host ("Total text lines    : {0:N0}" -f $totalLines)

Write-Host ''
Write-Host '=== Top-level directory line totals (text files) ==='
$rows | Where-Object Lines |
    ForEach-Object {
        $first = ($_.Path -split '/')[0]
        [pscustomobject]@{ Top = $first; Lines = $_.Lines }
    } |
    Group-Object Top |
    Select-Object @{n='Dir';e={$_.Name}},
                  @{n='Lines';e={($_.Group | Measure-Object Lines -Sum).Sum}} |
    Sort-Object Lines -Descending |
    Format-Table -AutoSize