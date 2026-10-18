[CmdletBinding()]
param(
    [ValidateSet('Diagnose','Repair','Restore','SelfTest')][string]$Mode='Diagnose',
    [string]$ExePath,
    [string]$BackupDirectory,
    [switch]$DisableAutoUpdate,
    [string]$ReportPath,
    [switch]$NativeWorker
)
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This skill supports Windows only.' }
if (-not ('TyporaBetaNative' -as [type])) {
    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class TyporaBetaNative {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
    public static extern int GetCurrentPackageFullName(ref uint length, StringBuilder name);
}
'@
}
function Test-PackageIdentity {
    [uint32]$length=0
    $code=[TyporaBetaNative]::GetCurrentPackageFullName([ref]$length,$null)
    if ($code -eq 15700) { return $false }
    if ($code -eq 122 -or $code -eq 0) { return $true }
    throw "Cannot establish process package identity: $code"
}
function Quote-PsLiteral([string]$Value) { return "'"+$Value.Replace("'","''")+"'" }
function Get-KeyAcl([string]$SubKey) {
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree,
        [Security.AccessControl.RegistryRights]::ReadPermissions)
    if (!$key) { throw "Registry key not found: HKCU\$SubKey" }
    try { return $key.GetAccessControl([Security.AccessControl.AccessControlSections]::Access) }
    finally { $key.Dispose() }
}
function Set-KeyAcl([string]$SubKey,[Security.AccessControl.RegistrySecurity]$Acl) {
    $rights=[Security.AccessControl.RegistryRights]::ReadPermissions -bor
        [Security.AccessControl.RegistryRights]::ChangePermissions
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,$rights)
    if (!$key) { throw "Registry key not found: HKCU\$SubKey" }
    try { $key.SetAccessControl($Acl) } finally { $key.Dispose() }
}
function Get-AclSddl([Security.AccessControl.RegistrySecurity]$Acl) {
    return $Acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
}
function Get-DaclFingerprint([Security.AccessControl.RegistrySecurity]$Acl) {
    $raw=New-Object Security.AccessControl.RawSecurityDescriptor((Get-AclSddl $Acl))
    $bytes=New-Object byte[] $raw.DiscretionaryAcl.BinaryLength
    $raw.DiscretionaryAcl.GetBinaryForm($bytes,0)
    # Windows may set the informational auto-inherited flag when saving an ACL.
    return [string]$Acl.AreAccessRulesProtected+':'+[Convert]::ToBase64String($bytes)
}
function Restore-KeyAcl([string]$SubKey,[string]$Sddl) {
    if ([string]::IsNullOrWhiteSpace($Sddl)) { throw 'Refusing empty backup DACL.' }
    $acl=Get-KeyAcl $SubKey
    $acl.SetSecurityDescriptorSddlForm($Sddl,[Security.AccessControl.AccessControlSections]::Access)
    Set-KeyAcl $SubKey $acl
}
function Add-BetaRule([Security.AccessControl.RegistrySecurity]$Acl) {
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    # 0xF = QueryValues | SetValue | CreateSubKey | EnumerateSubKeys.
    $rule=New-Object Security.AccessControl.RegistryAccessRule($sid,
        [Security.AccessControl.RegistryRights]15,
        [Security.AccessControl.InheritanceFlags]::None,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Deny)
    $Acl.AddAccessRule($rule)
}
function Test-BetaRule([Security.AccessControl.RegistrySecurity]$Acl) {
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($rule in $Acl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier])) {
        if ($rule.IdentityReference.Value -eq $sid -and
            $rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Deny -and
            (([int]$rule.RegistryRights -band 15) -eq 15)) { return $true }
    }
    return $false
}
function Read-Profile([string]$Path) {
    $hex=[IO.File]::ReadAllText($Path).Trim()
    if (!$hex -or $hex.Length % 2 -or $hex -notmatch '\A[0-9a-fA-F]+\z') {
        throw 'Unexpected Typora profile format; no preferences were written.'
    }
    $bytes=New-Object byte[] ($hex.Length/2)
    for ($i=0;$i -lt $bytes.Length;$i++) {
        $bytes[$i]=[Convert]::ToByte($hex.Substring($i*2,2),16)
    }
    $preferences=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json
    if ($preferences -isnot [pscustomobject]) { throw 'Expected a JSON object in Typora profile.' }
    return $preferences
}
function Write-Profile([string]$Path,$Preferences) {
    $json=ConvertTo-Json -InputObject $Preferences -Depth 50 -Compress
    $hex=([BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($json))).Replace('-','').ToLowerInvariant()
    $temporary=$Path+'.typora-beta-'+[guid]::NewGuid().ToString('N')+'.tmp'
    $replacementBackup=$temporary+'.previous'
    try {
        [IO.File]::WriteAllText($temporary,$hex,[Text.Encoding]::ASCII)
        [IO.File]::Replace($temporary,$Path,$replacementBackup)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $replacementBackup) { Remove-Item -LiteralPath $replacementBackup -ErrorAction SilentlyContinue }
    }
}
function Assert-NoTypora {
    if (Get-Process -Name Typora -ErrorAction SilentlyContinue) {
        throw 'Typora is running. Close its windows normally to preserve unsaved work, then retry.'
    }
}
function Resolve-Typora {
    if ($ExePath) { $candidate=[IO.Path]::GetFullPath($ExePath) }
    else {
        $locations=@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
        $candidates=@(Get-ItemProperty $locations -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'Typora*' -and $_.InstallLocation } |
            ForEach-Object { Join-Path $_.InstallLocation 'Typora.exe' })
        $candidates+=@(Join-Path $env:ProgramFiles 'Typora\Typora.exe')
        $candidates=@($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object -Unique)
        if ($candidates.Count -ne 1) { throw 'Cannot identify one Typora executable. Supply -ExePath.' }
        $candidate=$candidates[0]
    }
    $info=(Get-Item -LiteralPath $candidate).VersionInfo
    if ($info.ProductName -ne 'Typora') { throw 'Selected executable is not Typora.' }
    return [pscustomobject]@{path=$candidate;version=$info.ProductVersion}
}
function Invoke-SelfTest {
    $fixture='Software\CodexSkillTests\TyporaBetaRepair-'+[guid]::NewGuid().ToString('N')
    $folder=Join-Path $env:USERPROFILE ('.codex\tmp\typora-beta-test-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder | Out-Null
    $preferencesPath=Join-Path $folder 'profile.data'
    $original=$null
    try {
        $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($fixture)
        try { $key.SetValue('sentinel','unchanged') } finally { $key.Dispose() }
        $acl=Get-KeyAcl $fixture
        $original=Get-AclSddl $acl
        $originalFingerprint=Get-DaclFingerprint $acl
        Add-BetaRule $acl
        if (!(Test-BetaRule $acl)) { throw 'Rule detection failed.' }
        Set-KeyAcl $fixture $acl
        $denied=$false
        try {
            $read=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($fixture)
            if ($read) { $read.Dispose() }
        } catch [System.Security.SecurityException] { $denied=$true }
          catch [System.UnauthorizedAccessException] { $denied=$true }
        if (!$denied) { throw 'Fixture data remained readable.' }
        Restore-KeyAcl $fixture $original
        if ((Get-DaclFingerprint (Get-KeyAcl $fixture)) -ne $originalFingerprint) {
            throw 'DACL rules or inheritance protection changed after restoration.'
        }
        $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($fixture)
        try { if ($key.GetValue('sentinel') -ne 'unchanged') { throw 'Fixture data changed.' } }
        finally { $key.Dispose() }
        $initial='{"enableAutoUpdate":true,"sentinel":"保留配置","nested":{"value":3}}'
        $hex=([BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($initial))).Replace('-','')
        [IO.File]::WriteAllText($preferencesPath,$hex,[Text.Encoding]::ASCII)
        $preferences=Read-Profile $preferencesPath
        $preferences.enableAutoUpdate=$false
        Write-Profile $preferencesPath $preferences
        $preferences=Read-Profile $preferencesPath
        if ($preferences.enableAutoUpdate -ne $false -or $preferences.sentinel -ne '保留配置' -or $preferences.nested.value -ne 3) {
            throw 'Profile roundtrip failed.'
        }
        [IO.File]::WriteAllText($preferencesPath,'invalid')
        $rejected=$false
        try { $null=Read-Profile $preferencesPath } catch { $rejected=$true }
        if (!$rejected) { throw 'Invalid profile was accepted.' }
        return @{success=$true;checks=@('native-routing','DACL-deny','DACL-restore','registry-values-preserved',
            'hex-profile-unicode-roundtrip','unrelated-preferences-preserved','invalid-profile-rejected')}
    } finally {
        if ($original) { Restore-KeyAcl $fixture $original }
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($fixture,$false)
        if (Test-Path -LiteralPath $preferencesPath) { Remove-Item -LiteralPath $preferencesPath }
        Remove-Item -LiteralPath $folder
    }
}

$packaged=Test-PackageIdentity
if ($NativeWorker -and $packaged) { throw 'WMI worker still has package identity; no settings changed.' }
if (!$NativeWorker) {
    if ($PSCommandPath -like ($env:LOCALAPPDATA+'\*') -or $PSCommandPath -like ($env:APPDATA+'\*')) {
        throw 'Move the skill outside AppData before native dispatch.'
    }
    $jobDir=Join-Path $env:USERPROFILE ('.codex\tmp\typora-beta-jobs\'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
    $workerReport=Join-Path $jobDir 'result.json'
    $invocation='& '+(Quote-PsLiteral $PSCommandPath)+' -NativeWorker -Mode '+(Quote-PsLiteral $Mode)+
        ' -ReportPath '+(Quote-PsLiteral $workerReport)
    if ($ExePath) { $invocation+=' -ExePath '+(Quote-PsLiteral $ExePath) }
    if ($BackupDirectory) { $invocation+=' -BackupDirectory '+(Quote-PsLiteral $BackupDirectory) }
    if ($DisableAutoUpdate) { $invocation+=' -DisableAutoUpdate' }
    $invocation='try { '+$invocation+' } catch { if (!(Test-Path -LiteralPath '+
        (Quote-PsLiteral $workerReport)+')) { @{success=$false;error=$_.Exception.Message} | '+
        'ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath '+(Quote-PsLiteral $workerReport)+' } }'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($invocation))
    $command='"'+$env:SystemRoot+'\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand '+$encoded
    $created=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command}
    if ($created.ReturnValue -ne 0) { throw "Native process creation failed: $($created.ReturnValue)" }
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while (!(Test-Path -LiteralPath $workerReport)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw "Worker report timed out; inspect PID $($created.ProcessId) and $jobDir before retrying." }
        Start-Sleep -Milliseconds 200
    }
    $json=[IO.File]::ReadAllText($workerReport)
    Write-Output $json
    $result=$json|ConvertFrom-Json
    if (!$result.success) { throw "Native $Mode failed: $($result.error)" }
    return
}

$subKey='Software\Typora'
$preferencesPath=Join-Path $env:APPDATA 'Typora\profile.data'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$result=$null
try {
    if ($Mode -eq 'SelfTest') { $result=Invoke-SelfTest }
    elseif ($Mode -eq 'Diagnose') {
        $exe=Resolve-Typora
        $acl=$null; $aclError=$null
        try { $acl=Get-KeyAcl $subKey } catch { $aclError=$_.Exception.Message }
        $association=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.md\UserChoice' -ErrorAction SilentlyContinue
        $processes=@(Get-CimInstance Win32_Process -Filter "Name='Typora.exe'" |
            Where-Object { $_.CommandLine -notmatch '--type=' } |
            Select-Object ProcessId,ExecutablePath,CommandLine)
        $result=@{success=$true;exe=$exe;supported=($exe.version -eq '0.11.18');
            processes=$processes;mdProgId=$association.ProgId;profilePath=$preferencesPath;
            betaRulePresent=($acl -and (Test-BetaRule $acl));aclError=$aclError}
    }
    elseif ($Mode -eq 'Repair') {
        if ($BackupDirectory) { throw '-BackupDirectory is only accepted for Restore.' }
        $exe=Resolve-Typora
        if ($exe.version -ne '0.11.18') { throw "Unsupported Typora version: $($exe.version)" }
        Assert-NoTypora
        $acl=Get-KeyAcl $subKey
        if (Test-BetaRule $acl) {
            $result=@{success=$true;status='already_applied';message='No changes made; verify the real Explorer entry point.'}
        } else {
            $backup=Join-Path $env:USERPROFILE ('.codex\backups\typora-beta\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $backup -Force | Out-Null
            $original=Get-AclSddl $acl
            if (!$original) { throw 'Cannot capture original DACL.' }
            [IO.File]::WriteAllText((Join-Path $backup 'original-acl.sddl'),$original,[Text.Encoding]::ASCII)
            & reg.exe export 'HKCU\Software\Typora' (Join-Path $backup 'original-values.reg') /y | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Registry value backup failed; repair aborted.' }
            $preferences=$null
            $manifest=@{schema=1;userSid=$sid;registrySubKey=$subKey;exe=$exe;profileChanged=$false;
                created=(Get-Date).ToString('o');profilePath=$preferencesPath}
            if ($DisableAutoUpdate -and (Test-Path -LiteralPath $preferencesPath)) {
                $preferences=Read-Profile $preferencesPath
                Copy-Item -LiteralPath $preferencesPath -Destination (Join-Path $backup 'original-profile.data')
                $manifest.profileChanged=$true
                $manifest.hadAutoUpdate=($null -ne $preferences.PSObject.Properties['enableAutoUpdate'])
                $manifest.autoUpdateValue=$preferences.enableAutoUpdate
            }
            $manifest|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $backup 'manifest.json') -Encoding UTF8
            try {
                Add-BetaRule $acl
                Set-KeyAcl $subKey $acl
                if ($manifest.profileChanged) {
                    $preferences|Add-Member -NotePropertyName enableAutoUpdate -NotePropertyValue $false -Force
                    Write-Profile $preferencesPath $preferences
                }
            } catch {
                $failure=$_.Exception.Message
                Restore-KeyAcl $subKey $original
                throw "Repair aborted and DACL restored: $failure"
            }
            $result=@{success=$true;status='configuration_applied';backupDirectory=$backup;
                autoUpdateDisabled=$manifest.profileChanged;uiVerified=$false}
        }
    }
    elseif ($Mode -eq 'Restore') {
        if (!$BackupDirectory) { throw 'Restore requires -BackupDirectory from a prior repair.' }
        Assert-NoTypora
        $manifest=Get-Content -LiteralPath (Join-Path $BackupDirectory 'manifest.json') -Raw|ConvertFrom-Json
        if ($manifest.schema -ne 1 -or $manifest.userSid -ne $sid -or $manifest.registrySubKey -ne $subKey -or $manifest.profilePath -ne $preferencesPath) {
            throw 'Backup does not belong to this desktop user and Typora key.'
        }
        $original=[IO.File]::ReadAllText((Join-Path $BackupDirectory 'original-acl.sddl'))
        $preferences=$null
        if ($manifest.profileChanged) { $preferences=Read-Profile $preferencesPath }
        Restore-KeyAcl $subKey $original
        if ($preferences) {
            if ($manifest.hadAutoUpdate) {
                $preferences|Add-Member -NotePropertyName enableAutoUpdate -NotePropertyValue $manifest.autoUpdateValue -Force
            } else { $preferences.PSObject.Properties.Remove('enableAutoUpdate') }
            Write-Profile $preferencesPath $preferences
        }
        $result=@{success=$true;status='restored';backupDirectory=$BackupDirectory}
    }
} catch { $result=@{success=$false;error=$_.Exception.Message} }
$result.mode=$Mode
$result.nativePackageIdentity=$false
$result.userSid=$sid
$json=$result|ConvertTo-Json -Depth 20
if ($ReportPath) {
    $pending=$ReportPath+'.pending'
    [IO.File]::WriteAllText($pending,$json,[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($pending,$ReportPath)
}
Write-Output $json
if (!$result.success) { throw "$Mode failed: $($result.error)" }
