$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = Join-Path $env:ProgramData 'DVC\UploadGuard\Browser'
$exe = Join-Path $root 'chrome-win64\chrome.exe'
if (Test-Path -LiteralPath $exe) {
    Write-Host 'CHROME_FOR_TESTING_READY'
    exit 0
}

New-Item -ItemType Directory -Path $root -Force | Out-Null
$metaUrl = 'https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json'
Write-Host 'Downloading Chrome for Testing metadata...'
$meta = Invoke-RestMethod -Uri $metaUrl -UseBasicParsing
$download = $meta.channels.Stable.downloads.chrome | Where-Object { $_.platform -eq 'win64' } | Select-Object -First 1
if (-not $download -or -not $download.url) {
    throw 'Chrome for Testing win64 URL was not found.'
}

$zip = Join-Path $root 'chrome-for-testing.zip'
Write-Host ('Downloading Chrome for Testing Stable ' + $meta.channels.Stable.version + '...')
Invoke-WebRequest -Uri $download.url -OutFile $zip -UseBasicParsing

$temp = Join-Path $root '_extract'
if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
New-Item -ItemType Directory -Path $temp -Force | Out-Null
Expand-Archive -LiteralPath $zip -DestinationPath $temp -Force

$source = Join-Path $temp 'chrome-win64'
if (-not (Test-Path -LiteralPath (Join-Path $source 'chrome.exe'))) {
    throw 'Downloaded Chrome for Testing package does not contain chrome.exe.'
}

$target = Join-Path $root 'chrome-win64'
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
Move-Item -LiteralPath $source -Destination $target
Remove-Item -LiteralPath $temp -Recurse -Force
Remove-Item -LiteralPath $zip -Force

if (-not (Test-Path -LiteralPath $exe)) {
    throw 'Chrome for Testing installation failed.'
}

Write-Host 'CHROME_FOR_TESTING_READY'
Write-Host $exe
exit 0
