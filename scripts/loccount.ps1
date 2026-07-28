# scripts/loccount.ps1
# Walk the current git index and bucket tracked files by language/extension.

$ErrorActionPreference = 'SilentlyContinue'

# map extension (lowercase, no leading dot) -> bucket label
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
}

$repoRoot = (git -C $PSScriptRoot rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) { $repoRoot = $PSScriptRoot }

$rows = git -C $repoRoot ls-files |
    Where-Object { -not (Test-Path -Path $_ -PathType Container) } |
    ForEach-Object {
        $path = $_
        $ext = [System.IO.Path]::GetExtension($path).TrimStart('.').ToLower()
        if (-not $ext) { $bucket = 'Other text' }
        elseif ($buckets.Contains($ext)) { $bucket = $buckets[$ext] }
        else { $bucket = 'Other' }

        $lineCount = 0
        if ($bucket -notmatch 'binary') {
            $lineCount = (Get-Content -LiteralPath $path | Measure-Object -Line).Lines
        }
        [pscustomobject]@{
            Bucket = $bucket
            Ext    = $ext
            Path   = $path
            Lines  = $lineCount
        }
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