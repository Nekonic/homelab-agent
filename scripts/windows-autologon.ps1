# Windows 자동 로그온 설정 (Windows-MCP처럼 데스크톱 세션이 필요한 도구용)
#
# 비밀번호를 레지스트리(DefaultPassword)에 평문으로 두지 않고, LSA 비밀 저장소에 넣습니다.
# Sysinternals Autologon과 같은 방식입니다. Winlogon은 LSA 비밀 "DefaultPassword"를 읽습니다.
#
# 주의: Windows PowerShell 5에서 쓰려면 이 파일을 UTF-8 BOM으로 저장해야 합니다(저장소 파일은 BOM 포함).
#
# 사용법 (관리자 PowerShell, 비밀번호는 표준 입력 첫 줄로 전달):
#   Get-Content pw.txt | powershell -File windows-autologon.ps1 -User Admin
#   ssh 로 실행할 때:  <비밀번호를 출력하는 명령> | ssh Admin@<WIN_IP> "powershell -File C:\...\windows-autologon.ps1"
#
# 해제:  powershell -File windows-autologon.ps1 -Disable

param(
  [string]$User = "Admin",
  [switch]$Disable
)
$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Lsa {
  [StructLayout(LayoutKind.Sequential)] public struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
  [StructLayout(LayoutKind.Sequential)] public struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
  [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr SystemName, ref LSA_OBJECT_ATTRIBUTES ObjectAttributes, uint DesiredAccess, out IntPtr PolicyHandle);
  [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr PolicyHandle, ref LSA_UNICODE_STRING KeyName, IntPtr PrivateData);
  [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr PolicyHandle, ref LSA_UNICODE_STRING KeyName, ref LSA_UNICODE_STRING PrivateData);
  [DllImport("advapi32.dll")] static extern uint LsaNtStatusToWinError(uint status);
  [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr h);
  static LSA_UNICODE_STRING Str(string s) { var u = new LSA_UNICODE_STRING(); u.Buffer = Marshal.StringToHGlobalUni(s); u.Length = (ushort)(s.Length * 2); u.MaximumLength = (ushort)(s.Length * 2 + 2); return u; }
  public static void Store(string key, string value) {
    var attr = new LSA_OBJECT_ATTRIBUTES(); IntPtr h;
    uint st = LsaOpenPolicy(IntPtr.Zero, ref attr, 0x00000020 /*POLICY_CREATE_SECRET*/, out h);
    if (st != 0) throw new Exception("LsaOpenPolicy failed: " + LsaNtStatusToWinError(st));
    try {
      var k = Str(key);
      if (value == null) { st = LsaStorePrivateData(h, ref k, IntPtr.Zero); }
      else { var v = Str(value); st = LsaStorePrivateData(h, ref k, ref v); Marshal.ZeroFreeGlobalAllocUnicode(v.Buffer); }
      Marshal.FreeHGlobal(k.Buffer);
      if (st != 0) throw new Exception("LsaStorePrivateData failed: " + LsaNtStatusToWinError(st));
    } finally { LsaClose(h); }
  }
}
"@

$wl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

if ($Disable) {
  Set-ItemProperty $wl -Name AutoAdminLogon -Value "0"
  Remove-ItemProperty $wl -Name DefaultPassword -ErrorAction SilentlyContinue
  [Lsa]::Store("DefaultPassword", $null)
  "autologon disabled"
  exit 0
}

$pw = [Console]::In.ReadLine()
if ([string]::IsNullOrEmpty($pw)) { throw "password not provided on stdin" }

# 비밀번호가 맞는지 먼저 확인 (틀리면 부팅 때 로그온 실패 화면에 멈춤)
Add-Type -AssemblyName System.DirectoryServices.AccountManagement
$ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext("Machine")
if (-not $ctx.ValidateCredentials($User, $pw)) { throw "password for $User is wrong" }

[Lsa]::Store("DefaultPassword", $pw)
Remove-ItemProperty $wl -Name DefaultPassword -ErrorAction SilentlyContinue   # 평문 값이 남아 있으면 제거
Set-ItemProperty $wl -Name AutoAdminLogon -Value "1"
Set-ItemProperty $wl -Name DefaultUserName -Value $User
Set-ItemProperty $wl -Name DefaultDomainName -Value $env:COMPUTERNAME
Remove-ItemProperty $wl -Name AutoLogonCount -ErrorAction SilentlyContinue      # 횟수 제한 없음

# 화면 보호기 잠금 끄기 (잠긴 데스크톱에서는 UI 자동화가 동작하지 않음)
$cp = "HKCU:\Control Panel\Desktop"
Set-ItemProperty $cp -Name ScreenSaveActive -Value "0" -ErrorAction SilentlyContinue
Set-ItemProperty $cp -Name ScreenSaverIsSecure -Value "0" -ErrorAction SilentlyContinue

# RDP 접속 후 창을 닫을 때 쓰는 바로가기: 세션을 잠그지 않고 콘솔로 돌려보냄
$cmd = @'
@echo off
rem Disconnect RDP but hand the session back to the console so the desktop stays unlocked (for Windows-MCP)
for /f "skip=1 tokens=3" %%s in ('query user %USERNAME%') do (
  %windir%\System32\tscon.exe %%s /dest:console
)
'@
Set-Content -Path "C:\Users\Public\Desktop\RDP-disconnect-to-console.cmd" -Value $cmd -Encoding Ascii

"autologon enabled for $env:COMPUTERNAME\$User"
