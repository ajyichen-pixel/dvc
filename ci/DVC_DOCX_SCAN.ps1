param(
  [Parameter(Mandatory=$true)]
  [string]$FilePath
)
$ErrorActionPreference='Stop'

function Build-Text([int[]]$codes) {
  $chars = foreach($c in $codes){ [char]$c }
  return -join $chars
}

$kw1 = Build-Text @(0x8B77,0x7167)
$kw2 = Build-Text @(0x570B,0x6C11,0x8EAB,0x5206,0x8B49)

try {
  $full = [IO.Path]::GetFullPath($FilePath)
  if(!(Test-Path -LiteralPath $full -PathType Leaf)){ exit 20 }

  $temp = Join-Path $env:TEMP ('DVC_DOCX_SCAN_' + [guid]::NewGuid().ToString('N'))
  $zip = $temp + '.zip'
  $dir = $temp + '_x'
  Copy-Item -LiteralPath $full -Destination $zip -Force
  Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force

  $xmlPath = Join-Path $dir 'word\document.xml'
  if(!(Test-Path -LiteralPath $xmlPath -PathType Leaf)){ exit 20 }

  $xml = [IO.File]::ReadAllText($xmlPath, [Text.Encoding]::UTF8)
  $h1 = ([regex]::Matches($xml, [regex]::Escape($kw1))).Count
  $h2 = ([regex]::Matches($xml, [regex]::Escape($kw2))).Count
  $hits = $h1 + $h2

  $logDir = Join-Path $env:ProgramData 'DVC\ContentAnalysis\logs'
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
  $log = Join-Path $logDir 'dvc_content_analysis.log'
  Add-Content -LiteralPath $log -Encoding UTF8 -Value ('SCAN_RESULT file=' + $full + ' hits=' + $hits + ' passport=' + $h1 + ' national_id=' + $h2)

  Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue

  if($hits -gt 0){ exit 10 }
  exit 0
}
catch {
  try {
    $logDir = Join-Path $env:ProgramData 'DVC\ContentAnalysis\logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    Add-Content -LiteralPath (Join-Path $logDir 'dvc_content_analysis.log') -Encoding UTF8 -Value ('SCAN_ERROR ' + $_.Exception.Message)
  } catch {}
  exit 20
}
