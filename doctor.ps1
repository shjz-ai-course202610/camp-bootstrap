#Requires -Version 5.1
<#
.SYNOPSIS
  shjz camp doctor for Windows PowerShell 5.1 (no Git Bash required).

.DESCRIPTION
  Finds or installs Git, finds Git Bash, then delegates the full diagnosis to
  doctor.sh. Default is -Check (read-only). -Fix may install Git via winget,
  repair the user-level PATH, and open the Git for Windows download page.

  Usage:
    doctor.ps1 [-Check] [-Fix] [-Project <path>] [-Org <org>] [-CampHome <path>]
               [-AllowGlobalSafeDirectory]
  -Check is the default; -Fix opts into installing Git and repairing PATH.

  Output contract (only for problems detected by this wrapper):
    CAMP_DOCTOR 1
    STATUS=OK|FIXED|ACTION_REQUIRED|BLOCKED
    CODE=<CODE or OK>
    SUMMARY=<one line>
    ACTION=<next step or NONE>
    PROJECT=<absolute path>
    ALSO=<comma separated or NONE>
  Exit codes: 0=OK 10=FIXED 20=ACTION_REQUIRED 30=BLOCKED

  Test-only environment variables (never set in production).
  All CAMP_TEST_* hooks below are ignored unless CAMP_TEST=1:
    CAMP_TEST=1                 enable hooks; skip fixed install paths
    CAMP_TEST_GIT=-             force git missing; or an explicit git.exe path
    CAMP_TEST_BASH=-            force bash missing; or an explicit bash path
                                (WSL System32/Sysnative/WindowsApps paths rejected)
    CAMP_TEST_GH=-              force gh missing; or an explicit gh.exe path
    CAMP_TEST_WINGET=-          force winget missing; or an explicit winget path
    CAMP_TEST_NET=0|1           skip real probes: unreachable / reachable
    CAMP_TEST_NET_CODE=<n>      simulated HTTP status (only 200-299 reachable)
    CAMP_TEST_NO_FETCH=1        do not download doctor.sh
    CAMP_TEST_FETCH_SRC=<f>     copy this file instead of downloading doctor.sh
    CAMP_TEST_NO_BROWSER=1      do not open a browser; append URL to log
    CAMP_TEST_BROWSER_LOG=<f>   log file used with CAMP_TEST_NO_BROWSER
    CAMP_TEST_NO_USER_PATH=1    do not write the user-level PATH
#>
[CmdletBinding()]
param(
  [switch]$Check,
  [switch]$Fix,
  [switch]$AllowGlobalSafeDirectory,
  [string]$Project,
  [string]$Org = 'shjz-ai-course202610',
  [string]$CampHome
)

$ErrorActionPreference = 'Stop'

try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# Older Windows/.NET defaults may still negotiate TLS 1.0; GitHub requires 1.2+.
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch { }

$Mode = 'check'
if ($Fix) { $Mode = 'fix' }

function Resolve-FullPath {
  param([string]$PathValue, [string]$Base)
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return $Base }
  if (-not [System.IO.Path]::IsPathRooted($PathValue)) {
    $PathValue = Join-Path $Base $PathValue
  }
  try { return [System.IO.Path]::GetFullPath($PathValue) } catch { return $PathValue }
}

$cwd = (Get-Location).Path
$ProjectSupplied = -not [string]::IsNullOrWhiteSpace($Project)
if ([string]::IsNullOrWhiteSpace($Project)) { $Project = $cwd }
$Project = Resolve-FullPath $Project $cwd

$baseHome = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($baseHome)) { $baseHome = $HOME }
if ([string]::IsNullOrWhiteSpace($CampHome)) {
  $CampHome = Join-Path $baseHome '.shjz'
}
$CampHome = Resolve-FullPath $CampHome $cwd

function Write-Line {
  param([string]$Text)
  Write-Output $Text
}

function Get-TestHook {
  param([string]$Name)
  if ([Environment]::GetEnvironmentVariable('CAMP_TEST') -ne '1') { return $null }
  return [Environment]::GetEnvironmentVariable($Name)
}

function Write-Contract {
  param(
    [string]$Status,
    [string]$Code,
    [string]$Summary,
    [string]$Action,
    [string]$Also = 'NONE'
  )
  Write-Output ''
  Write-Output 'CAMP_DOCTOR 1'
  Write-Output "STATUS=$Status"
  Write-Output "CODE=$Code"
  Write-Output "SUMMARY=$Summary"
  Write-Output "ACTION=$Action"
  Write-Output "PROJECT=$Project"
  Write-Output "ALSO=$Also"
}

function Find-Tool {
  param(
    [string]$OverrideName,
    [string]$CommandName,
    [string[]]$Candidates
  )
  $override = Get-TestHook $OverrideName
  if ($null -ne $override) {
    if ($override -eq '-') { return $null }
    if (Test-Path -LiteralPath $override -PathType Leaf) { return $override }
    return $null
  }

  $command = Get-Command $CommandName -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($command) {
    $path = $command.Source
    if (-not $path) { $path = $command.Path }
    if ($path) { return $path }
  }

  if ([Environment]::GetEnvironmentVariable('CAMP_TEST') -eq '1') { return $null }

  foreach ($candidate in $Candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return $candidate
    }
  }
  return $null
}

function Test-IsWslBash {
  param([string]$PathValue)
  if (-not $PathValue) { return $false }
  $normalized = ($PathValue.Trim().TrimEnd('\') -replace '/', '\')
  $wslSuffixes = @(
    '\System32\bash.exe',
    '\Sysnative\bash.exe',
    '\WindowsApps\bash.exe'
  )
  foreach ($suffix in $wslSuffixes) {
    if ($normalized -like ('*' + $suffix)) { return $true }
  }
  return $false
}

function Find-Bash {
  param([string[]]$Candidates)
  $override = Get-TestHook 'CAMP_TEST_BASH'
  if ($null -ne $override) {
    if ($override -eq '-') { return $null }
    if (Test-IsWslBash $override) {
      Write-Line 'Bash: 检测到 WSL bash，忽略（需要 Git Bash）'
      return $null
    }
    if (Test-Path -LiteralPath $override -PathType Leaf) { return $override }
    return $null
  }

  # Prefer known Git Bash locations over Get-Command, which may find WSL.
  if ([Environment]::GetEnvironmentVariable('CAMP_TEST') -ne '1') {
    foreach ($candidate in $Candidates) {
      if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        return $candidate
      }
    }
  }

  $commands = Get-Command 'bash.exe' -CommandType Application -ErrorAction SilentlyContinue
  foreach ($command in @($commands)) {
    $path = $command.Source
    if (-not $path) { $path = $command.Path }
    if (-not $path) { continue }
    if (Test-IsWslBash $path) {
      Write-Line 'Bash: 检测到 WSL bash，忽略（需要 Git Bash）'
      continue
    }
    return $path
  }
  return $null
}

function Test-DirOnPath {
  param([string]$Dir)
  if (-not $Dir) { return $false }
  $pathValue = $env:Path
  if ($null -eq $pathValue) { $pathValue = '' }
  $normalized = $Dir.Trim().TrimEnd('\')
  foreach ($entry in ($pathValue -split ';')) {
    if ($entry -and ($entry.Trim().TrimEnd('\') -ieq $normalized)) { return $true }
  }
  return $false
}

function Add-UserPathDir {
  param([string]$Dir)
  if (-not $Dir) { return }
  if ((Get-TestHook 'CAMP_TEST_NO_USER_PATH') -eq '1') { return }

  $alreadyOnProcessPath = Test-DirOnPath $Dir

  if (-not $alreadyOnProcessPath) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $userPath) { $userPath = '' }
    $presentInUserPath = $false
    $normalized = $Dir.Trim().TrimEnd('\')
    foreach ($entry in ($userPath -split ';')) {
      if ($entry -and ($entry.Trim().TrimEnd('\') -ieq $normalized)) {
        $presentInUserPath = $true
        break
      }
    }
    if (-not $presentInUserPath) {
      try {
        if ($userPath.Trim() -eq '') {
          $newPath = $Dir
        } else {
          $newPath = $userPath.TrimEnd(';') + ';' + $Dir
        }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Line "已把 $Dir 加入用户 PATH（重开终端后生效）"
      } catch {
        Write-Line "写入用户 PATH 失败：$($_.Exception.Message)"
      }
    }
  }

  if (-not $alreadyOnProcessPath) {
    $env:Path = $Dir + ';' + $env:Path
  }
}

function Test-HttpReachable {
  param([string]$Url)
  $testNet = Get-TestHook 'CAMP_TEST_NET'
  if ($testNet -eq '1') { return $true }
  if ($testNet -eq '0') { return $false }

  $testCode = Get-TestHook 'CAMP_TEST_NET_CODE'
  if ($testCode) {
    $code = 0
    if ([int]::TryParse($testCode, [ref]$code)) {
      return ($code -ge 200 -and $code -lt 300)
    }
    return $false
  }

  try {
    $response = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $statusCode = $null
    if ($response) {
      try { $statusCode = [int]$response.StatusCode } catch { }
    }
    return ($null -ne $statusCode -and $statusCode -ge 200 -and $statusCode -lt 300)
  } catch {
    $errorResponse = $null
    try { $errorResponse = $_.Exception.Response } catch { }
    if ($null -eq $errorResponse -and $_.Exception.InnerException) {
      try { $errorResponse = $_.Exception.InnerException.Response } catch { }
    }
    if ($errorResponse) {
      $statusCode = $null
      try { $statusCode = [int]$errorResponse.StatusCode } catch { }
      if ($null -ne $statusCode -and $statusCode -ge 200 -and $statusCode -lt 300) {
        return $true
      }
    }
    return $false
  }
}

function Format-Reach {
  param([bool]$Reachable)
  if ($Reachable) { return '可达' }
  return '不可达'
}

function Open-Page {
  param([string]$Url)
  if ((Get-TestHook 'CAMP_TEST_NO_BROWSER') -eq '1') {
    $log = Get-TestHook 'CAMP_TEST_BROWSER_LOG'
    if ($log) {
      try { Add-Content -LiteralPath $log -Value $Url -Encoding UTF8 } catch { }
    }
    return
  }
  try {
    Start-Process $Url
  } catch {
    Write-Line "请手动打开：$Url"
  }
}

function ConvertTo-BashPath {
  param([string]$PathValue)
  if (-not $PathValue) { return $PathValue }
  if ($PathValue -match '^([A-Za-z]):[\\/](.*)$') {
    $drive = $Matches[1].ToLowerInvariant()
    $rest = $Matches[2] -replace '\\', '/'
    return "/$drive/$rest"
  }
  if ($PathValue -match '^\\\\') {
    return ('//' + ($PathValue.Substring(2) -replace '\\', '/'))
  }
  return ($PathValue -replace '\\', '/')
}

function Save-DoctorScript {
  param(
    [string]$OrgName,
    [string]$ProjectPath
  )
  $tempDir = $null

  if ((Get-TestHook 'CAMP_TEST_NO_FETCH') -ne '1') {
    try {
      $tempRoot = $env:TEMP
      if ([string]::IsNullOrWhiteSpace($tempRoot)) {
        $tempRoot = [System.IO.Path]::GetTempPath()
      }
      $tempDir = Join-Path $tempRoot ('shjz-doctor-' + [Guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
      $tempFile = Join-Path $tempDir 'doctor.sh'

      $fetchSource = Get-TestHook 'CAMP_TEST_FETCH_SRC'
      if ($fetchSource) {
        Copy-Item -LiteralPath $fetchSource -Destination $tempFile -Force
      } else {
        $url = "https://api.github.com/repos/$OrgName/camp-bootstrap/contents/doctor.sh?ref=main"
        Invoke-WebRequest -Uri $url -Headers @{ Accept = 'application/vnd.github.raw' } `
          -UseBasicParsing -TimeoutSec 10 -OutFile $tempFile -ErrorAction Stop
      }

      if ((Test-Path -LiteralPath $tempFile) -and
          ((Get-Item -LiteralPath $tempFile).Length -gt 0)) {
        return [pscustomobject]@{ Path = $tempFile; TempDir = $tempDir }
      }
    } catch { }
    if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
      Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  $fallbacks = @()
  if ($PSScriptRoot) { $fallbacks += (Join-Path $PSScriptRoot 'doctor.sh') }
  if ($ProjectPath) { $fallbacks += (Join-Path $ProjectPath 'doctor.sh') }
  foreach ($candidate in $fallbacks) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return [pscustomobject]@{ Path = $candidate; TempDir = $null }
    }
  }
  return $null
}

# ---------- locate tools ----------
$gitCandidates = @('C:\Program Files\Git\cmd\git.exe')
if ($env:LOCALAPPDATA) {
  $gitCandidates += (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')
}
if ($env:ProgramFiles) {
  $gitCandidates += (Join-Path $env:ProgramFiles 'Git\cmd\git.exe')
}

$bashCandidates = @('C:\Program Files\Git\bin\bash.exe')
if ($env:LOCALAPPDATA) {
  $bashCandidates += (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
}
$bashCandidates += 'C:\Program Files\Git\usr\bin\bash.exe'

$ghCandidates = @()
if ($env:USERPROFILE) {
  $ghCandidates += (Join-Path $env:USERPROFILE '.local\bin\gh.exe')
}

$git = Find-Tool 'CAMP_TEST_GIT' 'git.exe' $gitCandidates
$bash = Find-Bash $bashCandidates
$gh = Find-Tool 'CAMP_TEST_GH' 'gh.exe' $ghCandidates

$apiReachable = Test-HttpReachable 'https://api.github.com/'
$webReachable = Test-HttpReachable 'https://github.com/'

if ($git) { Write-Line "Git: $git" } else { Write-Line 'Git: 缺失' }
if ($bash) { Write-Line "Bash: $bash" } else { Write-Line 'Bash: 缺失' }
if ($gh) { Write-Line "GitHub CLI: $gh" } else { Write-Line 'GitHub CLI: 缺失（交给 doctor.sh 检查）' }
Write-Line ("网络: api.github.com={0} github.com={1}" -f `
  (Format-Reach $apiReachable), (Format-Reach $webReachable))

# ---------- git ----------
if (-not $git) {
  if ($Mode -ne 'fix') {
    Write-Contract -Status 'ACTION_REQUIRED' -Code 'GIT-MISSING' `
      -Summary '缺少 Git' `
      -Action '运行 doctor.ps1 -Fix 自动安装 Git（winget，可能弹 UAC），或打开 https://git-scm.com/download/win 手动安装'
    exit 20
  }

  $winget = Find-Tool 'CAMP_TEST_WINGET' 'winget' @()
  if (-not $winget) {
    $winget = Find-Tool 'CAMP_TEST_WINGET' 'winget.exe' @()
  }
  if ($winget) {
    Write-Line '正在用 winget 安装 Git（如弹出 UAC，请点“是”）...'
    try {
      & $winget install --id Git.Git -e --source winget `
        --accept-package-agreements --accept-source-agreements
      if ($LASTEXITCODE -eq 0) {
        Write-Line 'winget 安装命令已完成，重新检测 Git...'
      } else {
        Write-Line "winget 返回退出码 $LASTEXITCODE，重新检测 Git..."
      }
    } catch {
      Write-Line "winget 安装失败：$($_.Exception.Message)"
    }
    $git = Find-Tool 'CAMP_TEST_GIT' 'git.exe' $gitCandidates
  } else {
    Write-Line '未找到 winget。'
  }

  if (-not $git) {
    Write-Line '未能自动安装 Git，打开官方下载页。'
    Open-Page 'https://git-scm.com/download/win'
    Write-Contract -Status 'ACTION_REQUIRED' -Code 'GIT-MISSING' `
      -Summary '缺少 Git' `
      -Action '安装 Git for Windows 后重开终端，再运行 doctor.ps1 -Fix'
    exit 20
  }

  Write-Line "Git: $git"
  # Git installation also provides Git Bash; re-detect it.
  $bash = Find-Bash $bashCandidates
}

# ---------- user-level PATH (fix only) ----------
if ($Mode -eq 'fix') {
  if ($git) { Add-UserPathDir (Split-Path -Parent $git) }
  if ($gh) { Add-UserPathDir (Split-Path -Parent $gh) }
}

# ---------- bash ----------
if (-not $bash) {
  if ($Mode -eq 'fix') {
    Write-Line '缺少 Git Bash，打开 Git for Windows 下载页。'
    Open-Page 'https://git-scm.com/download/win'
  }
  Write-Contract -Status 'ACTION_REQUIRED' -Code 'BASH-MISSING' `
    -Summary '缺少 Git Bash' `
    -Action '安装 Git for Windows（含 Git Bash），重开终端后重跑 doctor.ps1'
  exit 20
}

# ---------- delegate to doctor.sh ----------
$doctorResult = Save-DoctorScript -OrgName $Org -ProjectPath $Project
if (-not $doctorResult) {
  Write-Line '取不到 doctor.sh。'
  Write-Contract -Status 'BLOCKED' -Code 'DOCTOR-FETCH' `
    -Summary '取不到 doctor.sh' `
    -Action '检查网络后重试，或把 doctor.sh 放在 doctor.ps1 同目录（或项目目录）'
  exit 30
}

$doctor = $doctorResult.Path
Write-Line "doctor.sh: $doctor"

# Git Bash expects POSIX-style paths; Windows paths would fail doctor.sh's
# `case "$PROJECT" in /*)` normalization.
$doctorArgs = @(
  (ConvertTo-BashPath $doctor),
  ('--' + $Mode)
)
if ($ProjectSupplied) {
  $doctorArgs += @('--project', (ConvertTo-BashPath $Project))
}
$doctorArgs += @('--org', $Org, '--camp-home', (ConvertTo-BashPath $CampHome))
if ($AllowGlobalSafeDirectory) {
  $doctorArgs += '--allow-global-safe-directory'
}

$exitCode = $null
try {
  # Native stderr must pass through untouched even if the caller merges 2>&1.
  $ErrorActionPreference = 'Continue'
  & $bash @doctorArgs
  $exitCode = $LASTEXITCODE
} catch {
  Write-Line "运行 doctor.sh 失败：$($_.Exception.Message)"
  Write-Contract -Status 'BLOCKED' -Code 'BASH-MISSING' `
    -Summary 'Git Bash 无法运行 doctor.sh' `
    -Action '重装 Git for Windows，重开终端后重跑 doctor.ps1'
  $exitCode = 30
}

if ($doctorResult.TempDir) {
  Remove-Item -LiteralPath $doctorResult.TempDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($null -eq $exitCode) {
  Write-Contract -Status 'BLOCKED' -Code 'BASH-MISSING' `
    -Summary 'Git Bash 未返回退出码' `
    -Action '重装 Git for Windows，重开终端后重跑 doctor.ps1'
  exit 30
}
exit ([int]$exitCode)
