# scripts/loccount.ps1
# Walk the git index, bucket tracked files by language extension, and report
# line counts for text files. Binary files are excluded from line counts.

$ErrorActionPreference = 'Stop'

$repoRoot = (git -C $PSScriptRoot rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) { $repoRoot = $PSScriptRoot }
Push-Location $repoRoot
try {
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
        'xml'          = 'XML'
        'kts'          = 'Kotlin Gradle'
        'gradle'       = 'Groovy Gradle'
        'properties'   = 'Properties'
        'html'         = 'Web'
        'css'          = 'Web'
        'ipynb'        = 'Jupyter'
    }
    $binaryExts = @('pkl', 'joblib', 'xls', 'xlsx', 'png', 'jpg', 'jpeg', 'webp', 'gif', 'ico', 'db', 'wal', 'shm')

    $rows = foreach ($path in (git ls-files)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $ext = [System.IO.Path]::GetExtension($path).TrimStart('.').ToLower()
        $bucket = if ($buckets.Contains($ext)) { $buckets[$ext] } elseif (-not $ext) { 'Other text' } else { 'Other' }
        $isBinary = $binaryExts -contains $ext
        $lineCount = 0
        if (-not $isBinary) {
            $lc = (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
            if ($null -eq $lc) { $lc = 0 }
            $lineCount = $lc
        }
        [pscustomobject]@{ Bucket = $bucket; Path = $path; Lines = $lineCount }
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