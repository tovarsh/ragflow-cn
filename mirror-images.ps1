#requires -version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Parse-DotEnv([string]$path) {
  $map = @{}
  if (!(Test-Path $path)) { return $map }
  Get-Content $path | ForEach-Object {
    $line = $_.Trim()
    if (-not $line) { return }
    if ($line.StartsWith("#")) { return }
    if ($line -notmatch "=") { return }

    $k, $v = $line.Split("=", 2)
    $k = $k.Trim()
    $v = $v.Trim()

    if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
      $v = $v.Substring(1, $v.Length - 2)
    }
    $map[$k] = $v
  }
  return $map
}

function Get-Bool([string]$s, [bool]$default=$false) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $default }
  switch ($s.Trim().ToLowerInvariant()) {
    "1" { return $true }
    "true" { return $true }
    "yes" { return $true }
    "y" { return $true }
    "0" { return $false }
    "false" { return $false }
    "no" { return $false }
    "n" { return $false }
    default { return $default }
  }
}

function Get-Int([string]$s, [int]$default) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $default }
  $n = 0
  if ([int]::TryParse($s.Trim(), [ref]$n)) { return $n }
  return $default
}

function Expand-TemplateDefault([string]$src) {
  # handle: ${VAR:-default}
  if ($src -match '^\$\{[A-Za-z0-9_]+:-([^}]+)\}$') { return $Matches[1] }
  return $src
}

function Get-NameOnlyRepo([string]$src) {
  $ref = $src.Split('@')[0]
  if ($ref.Contains(':')) { $ref = $ref.Substring(0, $ref.LastIndexOf(':')) }
  return $ref.Split('/')[-1]
}

function Get-FlattenRepo([string]$src) {
  $ref = $src.Split('@')[0]
  if ($ref.Contains(':')) { $ref = $ref.Substring(0, $ref.LastIndexOf(':')) }

  $parts = $ref.Split('/')
  if ($parts.Count -ge 3 -and ($parts[0].Contains('.') -or $parts[0].Contains(':'))) {
    $parts = $parts[1..($parts.Count-1)]
  }
  return ($parts -join '-')
}

function Get-Tag([string]$src) {
  if ($src -match '@sha256:(?<d>[0-9a-f]+)$') {
    return ("digest-sha256-" + $Matches['d'].Substring(0, [Math]::Min(12, $Matches['d'].Length)))
  }
  if ($src -match ':(?<t>[^/:@]+)$') { return $Matches['t'] }
  return "latest"
}

function Write-Log([string]$msg, [string]$logFile) {
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  $line = "[$ts] $msg"
  Write-Host $line
  if ($logFile) { Add-Content -Path $logFile -Value $line }
}

function Invoke-DockerWithTimeout([string[]]$dockerArgs, [int]$timeoutMinutes, [string]$logFile) {
  # 过滤空参数
  $clean = @($dockerArgs | Where-Object { $_ -ne $null -and $_.Trim().Length -gt 0 })
  if ($clean.Count -eq 0) {
    Write-Log "[ERROR] docker args empty" $logFile
    return 2
  }

  $outFile = [System.IO.Path]::GetTempFileName()
  $errFile = [System.IO.Path]::GetTempFileName()

  try {
    $p = Start-Process -FilePath "docker" `
      -ArgumentList $clean `
      -NoNewWindow -PassThru `
      -RedirectStandardOutput $outFile `
      -RedirectStandardError $errFile

    $ms = [Math]::Max(1, $timeoutMinutes) * 60 * 1000
    $ok = $p.WaitForExit($ms)

    if (-not $ok) {
      try { Stop-Process -Id $p.Id -Force } catch {}
      Write-Log "[WARN] timeout after ${timeoutMinutes}m; killed docker (pid=$($p.Id))" $logFile
      return 124
    }

    $out = (Get-Content $outFile -ErrorAction SilentlyContinue) -join "`n"
    $err = (Get-Content $errFile -ErrorAction SilentlyContinue) -join "`n"

    if ($out.Trim()) { Write-Log $out.Trim() $logFile }
    if ($err.Trim()) { Write-Log $err.Trim() $logFile }

    return $p.ExitCode
  }
  finally {
    Remove-Item $outFile -Force -ErrorAction SilentlyContinue
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue
  }
}

# ---------------- main ----------------
$root = Get-Location
$cfg = Parse-DotEnv (Join-Path $root ".env")

$REG = $cfg["MIRROR_REGISTRY"]
$NS  = $cfg["MIRROR_NAMESPACE"]
if ([string]::IsNullOrWhiteSpace($REG) -or [string]::IsNullOrWhiteSpace($NS)) {
  throw "Missing MIRROR_REGISTRY or MIRROR_NAMESPACE in .env"
}

$ImagesJson = $cfg["MIRROR_IMAGES_JSON"]
if ([string]::IsNullOrWhiteSpace($ImagesJson)) { $ImagesJson = "upstream/images.json" }

$MultiArch = $cfg["MIRROR_MULTI_ARCH"]
if ([string]::IsNullOrWhiteSpace($MultiArch)) { $MultiArch = "system" }

$RetryTimes = Get-Int $cfg["MIRROR_RETRY_TIMES"] 5
$TimeoutMin = Get-Int $cfg["MIRROR_COPY_TIMEOUT_MINUTES"] 90
$UseProxy   = Get-Bool $cfg["MIRROR_USE_PROXY"] $true
$LogFile    = $cfg["MIRROR_LOG_FILE"]
if ([string]::IsNullOrWhiteSpace($LogFile)) { $LogFile = "" }

if (!(Test-Path $ImagesJson)) { throw "Not found: $ImagesJson" }

$dockerCfg = Join-Path $env:USERPROFILE ".docker\config.json"
if (!(Test-Path $dockerCfg)) {
  throw "Docker config not found: $dockerCfg. Please run: docker login $REG"
}

# Windows 路径挂载更稳：反斜杠 -> 正斜杠
$dockerCfgMount = ($dockerCfg -replace '\\','/')

$images = Get-Content $ImagesJson -Raw | ConvertFrom-Json
if (!$images -or $images.Count -eq 0) { throw "No images in $ImagesJson" }

Write-Log "[INFO] Mirror start: REG=$REG NS=$NS multi-arch=$MultiArch retry=$RetryTimes timeout=${TimeoutMin}m images=$($images.Count)" $LogFile

# 冲突预扫描：nameOnlyRepo:tag
$firstSrc = @{}
$needFlatten = @{}
foreach ($src0 in $images) {
  $src = Expand-TemplateDefault ([string]$src0)
  if ($src -like '*${*') { continue }

  $repo = Get-NameOnlyRepo $src
  $tag  = Get-Tag $src
  $key  = "$repo`:$tag"

  if (!$firstSrc.ContainsKey($key)) { $firstSrc[$key] = $src }
  elseif ($firstSrc[$key] -ne $src) { $needFlatten[$key] = $true }
}
if ($needFlatten.Count -gt 0) {
  Write-Log "[WARN] Detected $($needFlatten.Count) conflict(s); conflicted repo:tag will fallback to flatten mapping." $LogFile
}

# 代理参数（仅把你当前会话的代理透传给容器）
$proxyArgs = @()
if ($UseProxy) {
  if ($env:HTTP_PROXY)  { $proxyArgs += @("-e", "HTTP_PROXY=$env:HTTP_PROXY") }
  if ($env:HTTPS_PROXY) { $proxyArgs += @("-e", "HTTPS_PROXY=$env:HTTPS_PROXY") }
  if ($env:NO_PROXY)    { $proxyArgs += @("-e", "NO_PROXY=$env:NO_PROXY") }
}

foreach ($src0 in $images) {
  $src = Expand-TemplateDefault ([string]$src0)
  if ($src -like '*${*') { Write-Log "[SKIP] unexpanded: $src" $LogFile; continue }

  $tag = Get-Tag $src
  $nameOnlyRepo = Get-NameOnlyRepo $src
  $key = "$nameOnlyRepo`:$tag"

  if ($needFlatten.ContainsKey($key)) {
    $repo = Get-FlattenRepo $src
    Write-Log "[INFO] fallback flatten for $key : $src -> repo=$repo" $LogFile
  } else {
    $repo = $nameOnlyRepo
  }

  $dst = "$REG/$NS/$repo`:$tag"
  Write-Log "[COPY] $src -> $dst" $LogFile

  $dockerArgs = @("run","--rm") +
    $proxyArgs +
    @(
      "-v", "${dockerCfgMount}:/root/.docker/config.json:ro",
      "quay.io/skopeo/stable:latest",
      "copy",
      "--retry-times", "$RetryTimes",
      "--multi-arch", "$MultiArch",
      "docker://$src",
      "docker://$dst"
    )

  $code = Invoke-DockerWithTimeout -dockerArgs $dockerArgs -timeoutMinutes $TimeoutMin -logFile $LogFile
  if ($code -ne 0) {
    Write-Log "[WARN] copy failed (exit=$code): $src -> $dst" $LogFile
  }
}

Write-Log "[DONE] Mirror finished." $LogFile
