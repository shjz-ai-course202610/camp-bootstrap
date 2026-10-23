#Requires -Version 5.1
# doctor.ps1 test skeleton for Windows PowerShell 5.1.
#
# NOT RUN YET: the authoring machine (macOS) has no pwsh/powershell.
# Run on a Windows machine:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_doctor_ps1.ps1
#
# Cases 1-9 isolate PATH to a fake bin directory and use doctor.ps1's
# test-only CAMP_TEST_* hooks (all gated by CAMP_TEST=1). Case 10 deliberately
# runs the production path to prove a stale hook is ignored, so it may perform
# real network probes. No real winget install or GitHub write is performed.

$ErrorActionPreference = 'Continue'

$Root = Split-Path -Parent $PSScriptRoot
$DoctorPs1 = Join-Path $Root 'doctor.ps1'
$PowerShellExe = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $PowerShellExe)) {
  $PowerShellExe = (Get-Process -Id $PID).Path
}

$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('doctor ps1 tests ' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null

$script:Tests = 0
$script:Fails = 0

function Check-True {
  param([string]$Name, [bool]$Condition)
  $script:Tests++
  if (-not $Condition) {
    $script:Fails++
    Write-Host "FAIL: $Name" -ForegroundColor Red
  }
}

function Check-Equal {
  param([string]$Name, $Expected, $Actual)
  $script:Tests++
  if ("$Expected" -ne "$Actual") {
    $script:Fails++
    Write-Host "FAIL: $Name" -ForegroundColor Red
    Write-Host "  expected: [$Expected]" -ForegroundColor Red
    Write-Host "  actual:   [$Actual]" -ForegroundColor Red
  }
}

function Check-Contains {
  param([string]$Name, [string]$Needle, [string]$Haystack)
  $script:Tests++
  if (-not $Haystack.Contains($Needle)) {
    $script:Fails++
    Write-Host "FAIL: $Name" -ForegroundColor Red
    Write-Host "  expected to contain: [$Needle]" -ForegroundColor Red
    Write-Host "  actual output:" -ForegroundColor Red
    Write-Host $Haystack
  }
}

function Check-NotContains {
  param([string]$Name, [string]$Needle, [string]$Haystack)
  $script:Tests++
  if ($Haystack.Contains($Needle)) {
    $script:Fails++
    Write-Host "FAIL: $Name (unexpected [$Needle])" -ForegroundColor Red
  }
}

function Get-Exists {
  param([string]$PathValue)
  if (Test-Path -LiteralPath $PathValue) { return 'present' }
  return 'absent'
}

function Get-Text {
  param([string]$PathValue)
  if (Test-Path -LiteralPath $PathValue) {
    return (Get-Content -LiteralPath $PathValue -Raw)
  }
  return ''
}

$HookNames = @(
  'CAMP_TEST',
  'CAMP_TEST_GIT',
  'CAMP_TEST_BASH',
  'CAMP_TEST_GH',
  'CAMP_TEST_WINGET',
  'CAMP_TEST_NET',
  'CAMP_TEST_NET_CODE',
  'CAMP_TEST_NO_FETCH',
  'CAMP_TEST_FETCH_SRC',
  'CAMP_TEST_NO_BROWSER',
  'CAMP_TEST_BROWSER_LOG',
  'CAMP_TEST_NO_USER_PATH',
  'FAKE_BASH_LOG',
  'FAKE_BASH_EXIT',
  'FAKE_WINGET_LOG',
  'FAKE_WINGET_EXIT'
)

function Invoke-Doctor {
  param(
    [string]$ScriptPath,
    [string[]]$Arguments,
    [hashtable]$Environment
  )
  $saved = @{}
  foreach ($name in $HookNames) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
  }
  $savedPath = $env:Path
  try {
    foreach ($name in $HookNames) {
      [Environment]::SetEnvironmentVariable($name, $null)
    }
    foreach ($name in $Environment.Keys) {
      [Environment]::SetEnvironmentVariable([string]$name, [string]$Environment[$name])
    }
    $output = & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1 | Out-String
    $code = $LASTEXITCODE
  } finally {
    foreach ($name in $HookNames) {
      [Environment]::SetEnvironmentVariable($name, $saved[$name])
    }
    $env:Path = $savedPath
  }
  return [pscustomobject]@{ Output = $output; Code = $code }
}

function New-Case {
  param([string]$Name)
  $dir = Join-Path $Tmp $Name
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  return $dir
}

function New-FakeBin {
  param([string]$CaseDir, [string]$Name)
  $dir = Join-Path $CaseDir ('bin ' + $Name)
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  return $dir
}

function New-FakeExe {
  param([string]$Dir, [string]$Name)
  $path = Join-Path $Dir $Name
  New-Item -ItemType File -Force -Path $path | Out-Null
  return $path
}

function New-BashStub {
  param([string]$Path)
  $content = @'
@echo off
if not "%FAKE_BASH_LOG%"=="" echo %*>>"%FAKE_BASH_LOG%"
if "%FAKE_BASH_EXIT%"=="" exit /b 0
exit /b %FAKE_BASH_EXIT%
'@
  Set-Content -LiteralPath $Path -Value $content -Encoding ASCII
}

function New-WingetStub {
  param([string]$Path)
  $content = @'
@echo off
if not "%FAKE_WINGET_LOG%"=="" echo %*>>"%FAKE_WINGET_LOG%"
if "%FAKE_WINGET_EXIT%"=="" exit /b 0
exit /b %FAKE_WINGET_EXIT%
'@
  Set-Content -LiteralPath $Path -Value $content -Encoding ASCII
}

function New-BaseEnv {
  param([string]$PathValue)
  return @{
    CAMP_TEST = '1'
    CAMP_TEST_NET = '0'
    CAMP_TEST_NO_USER_PATH = '1'
    PATH = $PathValue
  }
}

try {
  # =====================================================================
  # 1. No Git, -Check: ACTION_REQUIRED / GIT-MISSING / exit 20.
  # =====================================================================
  Write-Host ''
  Write-Host '== 1. no git, check =='
  $case = New-Case 'no-git-check'
  $project = Join-Path $case 'project with space'
  $camp = Join-Path $case 'camp home'
  New-Item -ItemType Directory -Force -Path $project, $camp | Out-Null
  $bin = New-FakeBin $case 'empty'
  $envMap = New-BaseEnv $bin
  $envMap['CAMP_TEST_GIT'] = '-'
  $envMap['CAMP_TEST_BASH'] = '-'
  $envMap['CAMP_TEST_WINGET'] = '-'
  $browserLog = Join-Path $case 'browser.log'
  $envMap['CAMP_TEST_NO_BROWSER'] = '1'
  $envMap['CAMP_TEST_BROWSER_LOG'] = $browserLog

  $r = Invoke-Doctor -ScriptPath $DoctorPs1 `
    -Arguments @('-Check', '-Project', $project, '-CampHome', $camp, '-Org', 'shjz-ai-course202610') `
    -Environment $envMap
  Check-Equal '1.1 exit 20' 20 $r.Code
  Check-Contains '1.2 contract header' 'CAMP_DOCTOR 1' $r.Output
  Check-Contains '1.3 STATUS' 'STATUS=ACTION_REQUIRED' $r.Output
  Check-Contains '1.4 CODE' 'CODE=GIT-MISSING' $r.Output
  Check-Contains '1.5 ALSO' 'ALSO=NONE' $r.Output
  $projectLine = $r.Output -split "`n" | Where-Object { $_ -like 'PROJECT=*' } | Select-Object -First 1
  $projectActual = ''
  if ($projectLine) { $projectActual = (($projectLine -replace '^PROJECT=', '')).Trim() }
  Check-Equal '1.6 PROJECT is absolute' ([System.IO.Path]::GetFullPath($project)) $projectActual
  Check-Equal '1.7 check does not open browser' 'absent' (Get-Exists $browserLog)
  $idxVersion = $r.Output.IndexOf('CAMP_DOCTOR 1')
  $idxStatus = $r.Output.IndexOf('STATUS=')
  $idxCode = $r.Output.IndexOf('CODE=')
  $idxSummary = $r.Output.IndexOf('SUMMARY=')
  $idxAction = $r.Output.IndexOf('ACTION=')
  $idxProject = $r.Output.IndexOf('PROJECT=')
  $idxAlso = $r.Output.IndexOf('ALSO=')
  Check-True '1.8 contract field order' (
    $idxVersion -ge 0 -and $idxStatus -gt $idxVersion -and $idxCode -gt $idxStatus -and
    $idxSummary -gt $idxCode -and $idxAction -gt $idxSummary -and
    $idxProject -gt $idxAction -and $idxAlso -gt $idxProject
  )

  # =====================================================================
  # 2. No Git, -Fix, winget unavailable: opens official download page.
  # =====================================================================
  Write-Host '== 2. no git, fix, no winget =='
  $case = New-Case 'no-git-fix-no-winget'
  $project = Join-Path $case 'project'
  $camp = Join-Path $case 'camp'
  New-Item -ItemType Directory -Force -Path $project, $camp | Out-Null
  $bin = New-FakeBin $case 'empty'
  $envMap = New-BaseEnv $bin
  $envMap['CAMP_TEST_GIT'] = '-'
  $envMap['CAMP_TEST_BASH'] = '-'
  $envMap['CAMP_TEST_WINGET'] = '-'
  $envMap['CAMP_TEST_NO_BROWSER'] = '1'
  $browserLog = Join-Path $case 'browser.log'
  $envMap['CAMP_TEST_BROWSER_LOG'] = $browserLog

  $r = Invoke-Doctor -ScriptPath $DoctorPs1 `
    -Arguments @('-Fix', '-Project', $project, '-CampHome', $camp) `
    -Environment $envMap
  Check-Equal '2.1 exit 20' 20 $r.Code
  Check-Contains '2.2 CODE' 'CODE=GIT-MISSING' $r.Output
  Check-Contains '2.3 browser opened' 'https://git-scm.com/download/win' (Get-Text $browserLog)
  Check-NotContains '2.4 no token printed' 'token' $r.Output

  # =====================================================================
  # 3. No Git, -Fix, winget present but install fails: download page.
  # =====================================================================
  Write-Host '== 3. no git, fix, winget fails =='
  $case = New-Case 'no-git-fix-winget-fails'
  $project = Join-Path $case 'project'
  $camp = Join-Path $case 'camp'
  New-Item -ItemType Directory -Force -Path $project, $camp | Out-Null
  $bin = New-FakeBin $case 'empty'
  $winget = Join-Path $case 'fake winget.cmd'
  New-WingetStub $winget
  $wingetLog = Join-Path $case 'winget.log'
  $browserLog = Join-Path $case 'browser.log'
  $envMap = New-BaseEnv $bin
  $envMap['CAMP_TEST_GIT'] = '-'
  $envMap['CAMP_TEST_BASH'] = '-'
  $envMap['CAMP_TEST_WINGET'] = $winget
  $envMap['FAKE_WINGET_LOG'] = $wingetLog
  $envMap['FAKE_WINGET_EXIT'] = '1'
  $envMap['CAMP_TEST_NO_BROWSER'] = '1'
  $envMap['CAMP_TEST_BROWSER_LOG'] = $browserLog

  $r = Invoke-Doctor -ScriptPath $DoctorPs1 `
    -Arguments @('-Fix', '-Project', $project, '-CampHome', $camp) `
    -Environment $envMap
  Check-Equal '3.1 exit 20' 20 $r.Code
  Check-Contains '3.2 CODE' 'CODE=GIT-MISSING' $r.Output
  Check-Contains '3.3 winget command' 'install --id Git.Git' (Get-Text $wingetLog)
  Check-Contains '3.4 winget flags' '--accept-package-agreements' (Get-Text $wingetLog)
  Check-Contains '3.5 browser fallback' 'https://git-scm.com/download/win' (Get-Text $browserLog)

  # =====================================================================
  # 4. Git present, bash missing (MinGit / incomplete install).
  # =====================================================================
  Write-Host '== 4. git without bash =='
  $case = New-Case 'git-no-bash'
  $project = Join-Path $case 'project'
  $camp = Join-Path $case 'camp'
  New-Item -ItemType Directory -Force -Path $project, $camp | Out-Null
  $bin = New-FakeBin $case 'git'
  $git = New-FakeExe $bin 'git.exe'
  $browserLog = Join-Path $case 'browser.log'
  $envMap = New-BaseEnv $bin
  $envMap['CAMP_TEST_GIT'] = $git
  $envMap['CAMP_TEST_BASH'] = '-'
  $envMap['CAMP_TEST_GH'] = '-'
  $envMap['CAMP_TEST_NO_BROWSER'] = '1'
  $envMap['CAMP_TEST_BROWSER_LOG'] = $browserLog

  $r = Invoke-Doctor -ScriptPath $DoctorPs1 `
    -Arguments @('-Check', '-Project', $project, '-CampHome', $camp) `
    -Environment $envMap
  Check-Equal '4.1 check exit 20' 20 $r.Code
  Check-Contains '4.2 check CODE' 'CODE=BASH-MISSING' $r.Output
  Check-Equal '4.3 check does not open browser' 'absent' (Get-Exists $browserLog)

  $r = Invoke-Doctor -ScriptPath $DoctorPs1 `
    -Arguments @('-Fix', '-Project', $project, '-CampHome', $camp) `
    -Environment $envMap
  Check-Equal '4.4 fix exit 20' 20 $r.Code
  Check-Contains '4.5 fix CODE' 'CODE=BASH-MISSING' $r.Output
  Check-Contains '4.6 fix opens download page' 'https://git-scm.com/download/win' (Get-Text $browserLog)

  # =====================================================================
  # 5. Bash present: delegate to doctor.sh, preserving args + exit code.
  #    gh is missing on purpose: gh handling belongs to doctor.sh.
  # =====================================================================
  Write-Host '== 5. delegate to doctor.sh =='
  $case = New-Case 'delegate'
  $project = Join-Path $case 'project with space'
  $camp = Join-Path $case 'camp home'
  New-Item -ItemType Directory -Force -Path $project | Out-Null
  Set-Content -LiteralPath (Join-Path $project 'doctor.sh') -Value '#!/usr/bin/env bash' -Encoding ASCII
  $bin = New-FakeBin $case 'fake'
  $git = New-FakeExe $bin 'git.exe'
  $fakeBash = Join-Path $case 'fake bash.cmd'
  New-BashStub $fakeBash
  $bashLog = Join-Path $case 'bash.log'
  $envMap = New-BaseEnv $bin
  $envMap['CAMP_TEST_GIT'] = $git
  $envMap['CAMP_TEST_BASH'] = $fakeBash
  $envMap['CAMP_TEST_GH'] = '-'
  $envMap['CAMP_TEST_NO_FETCH'] = '1'
  $envMap['FAKE_BASH_LOG'] = $bashLog
  $envMap['FAKE_BASH_EXIT'] = '0'

  $r = Invoke-Doctor -ScriptPath $DoctorPs1 `
    -Arguments @('-Check', '-Project', $project, '-CampHome', $camp, '-Org', 'shjz-ai-course202610') `
    -Environment $envMap
  $bashArgs = Get-Text $bashLog
  Check-Equal '5.1 check exit 0 passthrough' 0 $r.Code
  Check-Equal '5.1a -Check does not create CampHome' 'absent' (Get-Exists $camp)
  Check-Contains '5.2 --check passed' '--check' $bashArgs
  Check-Contains '5.3 --project passed' '--project' $bashArgs
  $driveLetter = $project.Substring(0, 1).ToLowerInvariant()
  $windowsDrive = $project.Substring(0, 3)
  Check-Contains '5.4 project basename with spaces preserved' 'project with space' $bashArgs
  Check-Contains '5.5 project converted to POSIX path' ("/$driveLetter/") $bashArgs
  Check-NotContains '5.6 no Windows drive path reaches bash' $windowsDrive $bashArgs
  Check-Contains '5.7 --org passed' '--org shjz-ai-course202610' $bashArgs
  Check-Contains '5.8 --camp-home passed' '--camp-home' $bashArgs
  Check-Contains '5.9 camp basename with spaces preserved' 'camp home' $bashArgs
  Check-NotContains '5.10 no duplicate GH-MISSING in wrapper' 'CODE=GH-MISSING' $r.Output
  Check-NotContains '5.11 wrapper does not print its own contract' 'CAMP_DOCTOR 1' $r.Output

  $envMap['FAKE_BASH_EXIT'] = '23'
  $r = Invoke-Doctor -ScriptPath $DoctorPs1 `
    -Arguments @('-Fix', '-Project', $project, '-CampHome', $camp) `
    -Environment $envMap
  Check-Equal '5.12 exit code passthrough' 23 $r.Code
  Check-Contains '5.13 --fix passed' '--fix' (Get-Text $bashLog)

  # Without -Project, doctor.sh must receive no --project so its
  # $CAMP_HOME/repo fallback stays effective.
  Remove-Item -LiteralPath $bashLog -Force -ErrorAction SilentlyContinue
  $envMap['FAKE_BASH_EXIT'] = '0'
  $r = Invoke-Doctor -ScriptPath $DoctorPs1 `
    -Arguments @('-Check', '-CampHome', $camp, '-AllowGlobalSafeDirectory') `
    -Environment $envMap
  $noProjectArgs = Get-Text $bashLog
  Check-Equal '5.14 exit 0 without -Project' 0 $r.Code
  Check-NotContains '5.15 --project omitted when not supplied' '--project' $noProjectArgs
  Check-Contains '5.16 --allow-global-safe-directory passed' '--allow-global-safe-directory' $noProjectArgs

  # =====================================================================
  # 6. Bash present but doctor.sh cannot be fetched or found.
  #    Run an isolated copy so $PSScriptRoot has no doctor.sh.
  # =====================================================================
  Write-Host '== 6. doctor.sh unavailable =='
  $case = New-Case 'no-doctor'
  $isolated = Join-Path $case 'isolated'
  $project = Join-Path $case 'project'
  $camp = Join-Path $case 'camp'
  New-Item -ItemType Directory -Force -Path $isolated, $project, $camp | Out-Null
  $isolatedPs1 = Join-Path $isolated 'doctor.ps1'
  Copy-Item -LiteralPath $DoctorPs1 -Destination $isolatedPs1
  $bin = New-FakeBin $case 'fake'
  $git = New-FakeExe $bin 'git.exe'
  $fakeBash = Join-Path $case 'fake bash.cmd'
  New-BashStub $fakeBash
  $envMap = New-BaseEnv $bin
  $envMap['CAMP_TEST_GIT'] = $git
  $envMap['CAMP_TEST_BASH'] = $fakeBash
  $envMap['CAMP_TEST_GH'] = '-'
  $envMap['CAMP_TEST_NO_FETCH'] = '1'
  $envMap['FAKE_BASH_LOG'] = (Join-Path $case 'bash.log')
  $envMap['FAKE_BASH_EXIT'] = '0'

  $r = Invoke-Doctor -ScriptPath $isolatedPs1 `
    -Arguments @('-Check', '-Project', $project, '-CampHome', $camp) `
    -Environment $envMap
  Check-Equal '6.1 exit 30' 30 $r.Code
  Check-Contains '6.2 STATUS' 'STATUS=BLOCKED' $r.Output
  Check-Contains '6.3 CODE' 'CODE=DOCTOR-FETCH' $r.Output
  Check-Contains '6.4 contract header' 'CAMP_DOCTOR 1' $r.Output
  Check-Equal '6.5 doctor.sh not run' 'absent' (Get-Exists $envMap['FAKE_BASH_LOG'])

  # =====================================================================
  # 7. Successful fetch goes to TEMP and is cleaned up; CampHome untouched.
  #    CAMP_TEST_FETCH_SRC copies a local file instead of hitting GitHub.
  # =====================================================================
  Write-Host '== 7. fetch to TEMP, not CampHome =='
  $case = New-Case 'fetch-temp'
  $project = Join-Path $case 'project'
  $camp = Join-Path $case 'camp not created'
  New-Item -ItemType Directory -Force -Path $project | Out-Null
  $srcDoctor = Join-Path $case 'src doctor.sh'
  Set-Content -LiteralPath $srcDoctor -Value '#!/usr/bin/env bash' -Encoding ASCII
  $bin = New-FakeBin $case 'fake'
  $git = New-FakeExe $bin 'git.exe'
  $fakeBash = Join-Path $case 'fake bash.cmd'
  New-BashStub $fakeBash
  $bashLog = Join-Path $case 'bash.log'
  $envMap = New-BaseEnv $bin
  $envMap['CAMP_TEST_GIT'] = $git
  $envMap['CAMP_TEST_BASH'] = $fakeBash
  $envMap['CAMP_TEST_GH'] = '-'
  $envMap['CAMP_TEST_FETCH_SRC'] = $srcDoctor
  $envMap['FAKE_BASH_LOG'] = $bashLog
  $envMap['FAKE_BASH_EXIT'] = '0'

  $r = Invoke-Doctor -ScriptPath $DoctorPs1 `
    -Arguments @('-Check', '-Project', $project, '-CampHome', $camp) `
    -Environment $envMap
  $bashArgs = Get-Text $bashLog
  Check-Equal '7.1 exit 0' 0 $r.Code
  Check-Contains '7.2 fetched to temp dir' 'shjz-doctor-' $bashArgs
  Check-Equal '7.3 CampHome not created' 'absent' (Get-Exists $camp)
  Check-NotContains '7.4 CampHome not passed as doctor path' $camp $bashArgs

  $tempDirWin = $null
  if ($bashArgs -match '(/[A-Za-z]/[^"]*?shjz-doctor-[0-9a-f]+)/doctor\.sh') {
    $tempDirPosix = $Matches[1]
    $tempDirWin = ($tempDirPosix -replace '^/([A-Za-z])/', '$1:\') -replace '/', '\'
  }
  Check-True '7.5 temp dir path parsed' ($null -ne $tempDirWin)
  if ($tempDirWin) {
    Check-Equal '7.6 temp dir cleaned after run' 'absent' (Get-Exists $tempDirWin)
  }

  # =====================================================================
  # 8. WSL-only bash (C:\Windows\System32\bash.exe) must be rejected.
  # =====================================================================
  Write-Host '== 8. WSL-only bash rejected =='
  $case = New-Case 'wsl-bash'
  $project = Join-Path $case 'project'
  $camp = Join-Path $case 'camp'
  New-Item -ItemType Directory -Force -Path $project, $camp | Out-Null
  $bin = New-FakeBin $case 'git'
  $git = New-FakeExe $bin 'git.exe'
  $wslBash = 'C:\Windows\System32\bash.exe'
  if ($env:SystemRoot) {
    $wslBash = Join-Path $env:SystemRoot 'System32\bash.exe'
  }
  $browserLog = Join-Path $case 'browser.log'
  $envMap = New-BaseEnv $bin
  $envMap['CAMP_TEST_GIT'] = $git
  $envMap['CAMP_TEST_BASH'] = $wslBash
  $envMap['CAMP_TEST_GH'] = '-'
  $envMap['CAMP_TEST_NO_BROWSER'] = '1'
  $envMap['CAMP_TEST_BROWSER_LOG'] = $browserLog

  $r = Invoke-Doctor -ScriptPath $DoctorPs1 `
    -Arguments @('-Check', '-Project', $project, '-CampHome', $camp) `
    -Environment $envMap
  Check-Equal '8.1 check exit 20' 20 $r.Code
  Check-Contains '8.2 check STATUS' 'STATUS=ACTION_REQUIRED' $r.Output
  Check-Contains '8.3 check CODE' 'CODE=BASH-MISSING' $r.Output
  Check-Contains '8.4 WSL rejection logged' 'WSL bash' $r.Output
  Check-Equal '8.5 check does not open browser' 'absent' (Get-Exists $browserLog)

  $r = Invoke-Doctor -ScriptPath $DoctorPs1 `
    -Arguments @('-Fix', '-Project', $project, '-CampHome', $camp) `
    -Environment $envMap
  Check-Equal '8.6 fix exit 20' 20 $r.Code
  Check-Contains '8.7 fix opens download page' 'https://git-scm.com/download/win' (Get-Text $browserLog)

  # =====================================================================
  # 9. WindowsApps (Store) and Sysnative WSL aliases are rejected too.
  # =====================================================================
  Write-Host '== 9. WSL aliases rejected =='
  $aliasCases = @(
    @{ Name = 'WindowsApps'; Path = 'C:\Users\test\AppData\Local\Microsoft\WindowsApps\bash.exe' },
    @{ Name = 'Sysnative'; Path = 'C:\WINDOWS\SYSNATIVE\BASH.EXE' }
  )
  foreach ($aliasCase in $aliasCases) {
    $case = New-Case ('wsl-' + $aliasCase.Name)
    $project = Join-Path $case 'project'
    $camp = Join-Path $case 'camp'
    New-Item -ItemType Directory -Force -Path $project, $camp | Out-Null
    $bin = New-FakeBin $case 'git'
    $git = New-FakeExe $bin 'git.exe'
    $envMap = New-BaseEnv $bin
    $envMap['CAMP_TEST_GIT'] = $git
    $envMap['CAMP_TEST_BASH'] = $aliasCase.Path
    $envMap['CAMP_TEST_GH'] = '-'

    $r = Invoke-Doctor -ScriptPath $DoctorPs1 `
      -Arguments @('-Check', '-Project', $project, '-CampHome', $camp) `
      -Environment $envMap
    Check-Equal ("9.{0}.1 exit 20" -f $aliasCase.Name) 20 $r.Code
    Check-Contains ("9.{0}.2 CODE" -f $aliasCase.Name) 'CODE=BASH-MISSING' $r.Output
    Check-Contains ("9.{0}.3 WSL logged" -f $aliasCase.Name) 'WSL bash' $r.Output
  }

  # =====================================================================
  # 10. A stale CAMP_TEST_GIT without CAMP_TEST=1 must be ignored.
  #     This runs the production path (hooks disabled), so it may perform
  #     real network probes; git discovery is isolated through PATH.
  # =====================================================================
  Write-Host '== 10. stale CAMP_TEST_GIT ignored without CAMP_TEST =='
  $case = New-Case 'stale-hook'
  $isolated = Join-Path $case 'isolated'
  $project = Join-Path $case 'project'
  $camp = Join-Path $case 'camp'
  New-Item -ItemType Directory -Force -Path $isolated, $project, $camp | Out-Null
  $isolatedPs1 = Join-Path $isolated 'doctor.ps1'
  Copy-Item -LiteralPath $DoctorPs1 -Destination $isolatedPs1
  $dummyDoctor = "#!/usr/bin/env bash`nexit 0`n"
  Set-Content -LiteralPath (Join-Path $isolated 'doctor.sh') -Value $dummyDoctor -Encoding ASCII
  $bin = New-FakeBin $case 'path'
  $decoyGit = Join-Path $bin 'git.exe'
  Copy-Item -LiteralPath $env:ComSpec -Destination $decoyGit -Force
  $staleDir = Join-Path $case 'stale'
  New-Item -ItemType Directory -Force -Path $staleDir | Out-Null
  $staleGit = Join-Path $staleDir 'git.exe'
  Copy-Item -LiteralPath $env:ComSpec -Destination $staleGit -Force
  $envMap = @{
    PATH = $bin
    CAMP_TEST_GIT = $staleGit
  }

  $r = Invoke-Doctor -ScriptPath $isolatedPs1 `
    -Arguments @('-Check', '-Project', $project, '-CampHome', $camp, '-Org', 'shjz-invalid-test-org') `
    -Environment $envMap
  Check-Contains '10.1 git found from PATH, not hook' $decoyGit $r.Output
  Check-NotContains '10.2 stale CAMP_TEST_GIT ignored' $staleGit $r.Output
  Check-True '10.3 script completed with output' ($r.Output.Length -gt 0)

  # =====================================================================
  # 11. Only HTTP 200-299 count as reachable; 403/404 must be unreachable.
  # =====================================================================
  Write-Host '== 11. non-2xx is unreachable =='
  foreach ($statusCode in @('200', '403', '404')) {
    $case = New-Case ('net-' + $statusCode)
    $project = Join-Path $case 'project'
    $camp = Join-Path $case 'camp'
    New-Item -ItemType Directory -Force -Path $project, $camp | Out-Null
    $bin = New-FakeBin $case 'empty'
    $envMap = New-BaseEnv $bin
    $envMap['CAMP_TEST_GIT'] = '-'
    $envMap['CAMP_TEST_BASH'] = '-'
    $envMap['CAMP_TEST_WINGET'] = '-'
    $envMap['CAMP_TEST_NET_CODE'] = $statusCode

    $r = Invoke-Doctor -ScriptPath $DoctorPs1 `
      -Arguments @('-Check', '-Project', $project, '-CampHome', $camp) `
      -Environment $envMap

    $expected = '不可达'
    if ($statusCode -eq '200') { $expected = '可达' }
    Check-Equal ("11.{0}.1 exit 20" -f $statusCode) 20 $r.Code
    Check-Contains ("11.{0}.2 api status" -f $statusCode) ("api.github.com=" + $expected) $r.Output
    Check-Contains ("11.{0}.3 web status" -f $statusCode) ("github.com=" + $expected) $r.Output
  }

  Write-Host ''
  Write-Host ("RESULT: {0} checks, {1} failed" -f $script:Tests, $script:Fails)
  if ($script:Fails -gt 0) { exit 1 }
  exit 0
} finally {
  Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}
