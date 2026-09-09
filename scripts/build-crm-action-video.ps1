param(
  [string]$Voice = 'Microsoft David Desktop',
  [int]$Rate = 1
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$trainingRoot = Join-Path $projectRoot 'docs\crm-training'
$actionRoot = Join-Path $trainingRoot 'action-video'
$audioRoot = Join-Path $actionRoot 'audio'
$scenesPath = Join-Path $trainingRoot 'action-scenes.json'
$durationPath = Join-Path $actionRoot 'action-durations.json'
$recordedScenesPath = Join-Path $actionRoot 'recorded-scenes.json'
$rawVideoPath = Join-Path $actionRoot 'crm-action-demo-raw.webm'
$finalVideoPath = Join-Path $trainingRoot 'SKOK-Bank-CRM-Hands-On-Actions.mp4'
$quickGuidePath = Join-Path $trainingRoot 'BALANCE-UPDATE-QUICK-GUIDE.md'

$packageRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe'
$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
$ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
if (-not $ffmpeg) { $ffmpeg = Get-ChildItem -LiteralPath $packageRoot -Recurse -Filter ffmpeg.exe | Select-Object -First 1 -ExpandProperty FullName }
if (-not $ffprobe) { $ffprobe = Get-ChildItem -LiteralPath $packageRoot -Recurse -Filter ffprobe.exe | Select-Object -First 1 -ExpandProperty FullName }
if (-not $ffmpeg -or -not $ffprobe) { throw 'FFmpeg and FFprobe are required.' }

New-Item -ItemType Directory -Force -Path $actionRoot, $audioRoot | Out-Null
$scenes = Get-Content -LiteralPath $scenesPath -Raw -Encoding UTF8 | ConvertFrom-Json

Add-Type -AssemblyName System.Speech
$speaker = New-Object System.Speech.Synthesis.SpeechSynthesizer
$speaker.SelectVoice($Voice)
$speaker.Rate = $Rate
$speaker.Volume = 100
$durations = @()

try {
  for ($index = 0; $index -lt $scenes.Count; $index += 1) {
    $number = ($index + 1).ToString('00')
    $audioPath = Join-Path $audioRoot "scene-$number.wav"
    $speaker.SetOutputToWaveFile($audioPath)
    $speaker.Speak([string]$scenes[$index].narration)
    $speaker.SetOutputToNull()

    $rawDuration = (& $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $audioPath).Trim()
    $audioDuration = [double]::Parse($rawDuration, [System.Globalization.CultureInfo]::InvariantCulture)
    $durations += [pscustomobject]@{
      scene = $index + 1
      durationSeconds = [Math]::Ceiling(($audioDuration + 1.2) * 10) / 10
    }
  }
} finally {
  $speaker.Dispose()
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($durationPath, (($durations | ConvertTo-Json) + "`n"), $utf8NoBom)

node (Join-Path $PSScriptRoot 'prepare-crm-action-demo.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the isolated training customer.' }

if (-not $env:CRM_DEMO_EMAIL -or -not $env:CRM_DEMO_PASSWORD) {
  throw 'CRM_DEMO_EMAIL and CRM_DEMO_PASSWORD are required.'
}
node (Join-Path $PSScriptRoot 'record-crm-action-demo.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Browser action recording failed.' }
if (-not (Test-Path $rawVideoPath)) { throw 'The raw browser recording was not created.' }

$recordedScenes = Get-Content -LiteralPath $recordedScenesPath -Raw -Encoding UTF8 | ConvertFrom-Json
$concatLines = @()
for ($index = 0; $index -lt $recordedScenes.Count; $index += 1) {
  $number = ($index + 1).ToString('00')
  $sourceAudio = Join-Path $audioRoot "scene-$number.wav"
  $paddedAudio = Join-Path $audioRoot "scene-$number-padded.wav"
  $durationText = ([double]$recordedScenes[$index].durationSeconds).ToString('0.000', [System.Globalization.CultureInfo]::InvariantCulture)
  & $ffmpeg -y -loglevel error -i $sourceAudio -af 'apad' -t $durationText -c:a pcm_s16le $paddedAudio
  if ($LASTEXITCODE -ne 0) { throw "Could not pad narration scene $number." }
  $concatLines += "file '$($paddedAudio.Replace("'", "'\''"))'"
}

$audioConcatPath = Join-Path $audioRoot 'concat.txt'
$narrationPath = Join-Path $actionRoot 'narration.wav'
[System.IO.File]::WriteAllLines($audioConcatPath, $concatLines, $utf8NoBom)
& $ffmpeg -y -loglevel error -f concat -safe 0 -i $audioConcatPath -c copy $narrationPath
if ($LASTEXITCODE -ne 0) { throw 'Could not join narration.' }

& $ffmpeg -y -loglevel error -i $rawVideoPath -itsoffset 0.8 -i $narrationPath `
  -filter_complex '[0:v]scale=1920:1080:flags=lanczos,fade=t=in:st=0:d=0.2[v];[1:a]afade=t=in:st=0:d=0.15[a]' `
  -map '[v]' -map '[a]' -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -r 30 `
  -c:a aac -b:a 160k -shortest -movflags +faststart $finalVideoPath
if ($LASTEXITCODE -ne 0) { throw 'Could not encode the final action video.' }

$quickGuide = @(
  '# CRM Balance Update - Quick Guide',
  '',
  '1. Open `/crm-admin` and search for the customer.',
  '2. Confirm the customer name and email, then choose **Open profile**.',
  '3. In **Table Manager**, open **Balances**.',
  '4. To add an asset: **Add balance** -> choose Fiat or Crypto -> enter code, name, amount, and status -> **Create balance**.',
  '5. To change an amount: locate the asset -> **Edit balance** -> replace **New balance** -> choose its status -> **Save balance**.',
  '6. To change every balance status: use **Set customer balance status** -> **Apply to all balances**.',
  '7. Use the arrow buttons to change asset display order.',
  '8. Click **Refresh balances**, then sign in as the customer and verify **Dashboard -> Overview**.',
  '',
  '> Important: adding a transaction creates history; it does not automatically change a displayed balance.'
)
[System.IO.File]::WriteAllLines($quickGuidePath, $quickGuide, $utf8NoBom)

$finalDuration = (& $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $finalVideoPath).Trim()
$finalSize = (Get-Item -LiteralPath $finalVideoPath).Length
Write-Output "VIDEO=$finalVideoPath"
Write-Output "DURATION_SECONDS=$finalDuration"
Write-Output "SIZE_BYTES=$finalSize"
