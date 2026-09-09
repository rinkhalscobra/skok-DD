param(
  [string]$Voice = 'Microsoft David Desktop',
  [int]$Rate = -1,
  [switch]$ReuseAssets
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$slidesPath = Join-Path $projectRoot 'docs\crm-training\slides.json'
$outputRoot = Join-Path $projectRoot 'docs\crm-training'
$slideDirectory = Join-Path $outputRoot 'assets\slides'
$audioDirectory = Join-Path $outputRoot 'assets\audio'
$clipDirectory = Join-Path $outputRoot 'assets\clips'
$videoPath = Join-Path $outputRoot 'SKOK-Bank-CRM-Complete-Walkthrough.mp4'
$guidePath = Join-Path $outputRoot 'CRM-Operator-Guide.md'

$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
$ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source

if (-not $ffmpeg -or -not $ffprobe) {
  $packageRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe'
  $ffmpeg = Get-ChildItem $packageRoot -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
  $ffprobe = Get-ChildItem $packageRoot -Recurse -Filter ffprobe.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}

if (-not $ffmpeg -or -not $ffprobe) {
  throw 'FFmpeg and FFprobe are required.'
}

New-Item -ItemType Directory -Force -Path $audioDirectory, $clipDirectory | Out-Null
node (Join-Path $PSScriptRoot 'render-crm-training-slides.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Slide rendering failed.' }

$slides = Get-Content $slidesPath -Raw -Encoding UTF8 | ConvertFrom-Json
Add-Type -AssemblyName System.Speech
$synthesizer = New-Object System.Speech.Synthesis.SpeechSynthesizer
$synthesizer.SelectVoice($Voice)
$synthesizer.Rate = $Rate
$synthesizer.Volume = 100

$guide = @(
  '# SKOK Bank CRM Operator Guide',
  '',
  'This guide is the complete narration and quick-reference companion for the walkthrough video.',
  ''
)
$concatLines = @()
$timeline = @()
$elapsed = 0.0

try {
  for ($index = 0; $index -lt $slides.Count; $index += 1) {
    $number = ($index + 1).ToString('00')
    $slide = $slides[$index]
    $audioPath = Join-Path $audioDirectory "slide-$number.wav"
    $imagePath = Join-Path $slideDirectory "slide-$number.png"
    $clipPath = Join-Path $clipDirectory "slide-$number.mp4"

    if (-not $ReuseAssets -or -not (Test-Path $audioPath) -or -not (Test-Path $clipPath)) {
      $synthesizer.SetOutputToWaveFile($audioPath)
      $synthesizer.Speak([string]$slide.narration)
      $synthesizer.SetOutputToNull()

      $audioDurationRaw = (& $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $audioPath).Trim()
      $audioDuration = [double]::Parse($audioDurationRaw, [System.Globalization.CultureInfo]::InvariantCulture)
      $duration = $audioDuration + 0.8
      $fadeOut = [Math]::Max(0.25, $duration - 0.35)
      $durationText = $duration.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
      $fadeOutText = $fadeOut.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)

      & $ffmpeg -y -loglevel error -loop 1 -framerate 30 -i $imagePath -i $audioPath `
        -filter_complex "[0:v]scale=1920:1080,fade=t=in:st=0:d=0.25,fade=t=out:st=$fadeOutText`:d=0.25[v];[1:a]apad=pad_dur=0.8,afade=t=in:st=0:d=0.12,afade=t=out:st=$fadeOutText`:d=0.25[a]" `
        -map '[v]' -map '[a]' -t $durationText -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 -c:a aac -b:a 160k -movflags +faststart $clipPath
      if ($LASTEXITCODE -ne 0) { throw "Failed to encode slide $number." }
    }

    $clipDurationRaw = (& $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $clipPath).Trim()
    $duration = [double]::Parse($clipDurationRaw, [System.Globalization.CultureInfo]::InvariantCulture)

    $escapedClipPath = $clipPath.Replace("'", "'\''")
    $concatLines += "file '$escapedClipPath'"
    $timeline += [pscustomobject]@{
      Slide = $index + 1
      Title = $slide.title
      StartSeconds = [Math]::Round($elapsed, 2)
      DurationSeconds = [Math]::Round($duration, 2)
    }
    $elapsed += $duration

    $guide += "## $($index + 1). $($slide.title)"
    $guide += ''
    $guide += [string]$slide.subtitle
    $guide += ''
    foreach ($bullet in $slide.bullets) { $guide += "- $bullet" }
    $guide += ''
    $guide += '**Narration**'
    $guide += ''
    $guide += [string]$slide.narration
    $guide += ''
  }
} finally {
  $synthesizer.Dispose()
}

$concatPath = Join-Path $clipDirectory 'concat.txt'
[System.IO.File]::WriteAllLines($concatPath, $concatLines, (New-Object System.Text.UTF8Encoding($false)))
& $ffmpeg -y -loglevel error -f concat -safe 0 -i $concatPath -c copy -movflags +faststart $videoPath
if ($LASTEXITCODE -ne 0) { throw 'Final video concatenation failed.' }

$guide | Set-Content -Path $guidePath -Encoding UTF8
$timeline | ConvertTo-Json | Set-Content -Path (Join-Path $outputRoot 'timeline.json') -Encoding UTF8

$finalDuration = & $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $videoPath
$finalSize = (Get-Item $videoPath).Length
Write-Output "VIDEO=$videoPath"
Write-Output "DURATION_SECONDS=$finalDuration"
Write-Output "SIZE_BYTES=$finalSize"
