//! Eco mode: freeze everything that isn't needed to keep the PC reachable, cut the power plan and turn the screen off.
//!  * Every process of the current user outside the keep-list is SUSPENDED (NtSuspendProcess), not killed: no CPU, no data
//!    lost, and turning eco off resumes each one exactly where it was. Elevated / system processes can't be touched and are left alone.
//!  * The power plan gets a 1-minute display timeout, max processor state 50 % and CPU boost off; the old values are restored.
//!  * Everything is written to eco-state.txt as it happens, so a crash can never leave apps frozen: the next start resumes them.
//! Turn it on/off from the phone, the tray menu, the PC app, or Ctrl+Alt+E. Windows only (stubs elsewhere).
use crate::control::{self, Cmd};
use crate::state::Shared;
use serde_json::json;
use std::sync::atomic::{AtomicBool, Ordering};

pub static ON: AtomicBool = AtomicBool::new(false);

#[cfg(target_os = "windows")]
const SCRIPT: &str = r#"
$mode = '__MODE__'
$state = '__STATE__'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class EcoNative {
  [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);
  [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);
  [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(int access, bool inherit, int pid);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
"@
# power plan values are read as the last two 0x........ numbers of powercfg's output: AC, then DC (works in any language)
function Acv($sub, $name) {
  $o = powercfg /q SCHEME_CURRENT $sub $name | Out-String
  $m = [regex]::Matches($o, '0x[0-9a-fA-F]{8}')
  if ($m.Count -ge 2) { [Convert]::ToInt32($m[$m.Count - 2].Value, 16) } else { $null }
}
function SetAc($sub, $name, $val) { if ($val -ne $null) { powercfg /setacvalueindex SCHEME_CURRENT $sub $name $val | Out-Null } }
function Touch($procId, $access) {
  $h = [EcoNative]::OpenProcess(0x800, $false, $procId)
  if ($h -eq [IntPtr]::Zero) { return $false }
  if ($access -eq 'suspend') { [void][EcoNative]::NtSuspendProcess($h) } else { [void][EcoNative]::NtResumeProcess($h) }
  [void][EcoNative]::CloseHandle($h)
  return $true
}

if ($mode -eq 'on') {
  $keep = @('explorer','mediagrid','tailscale','tailscale-ipn','tailscaled','powershell','pwsh','conhost','cmd','ctfmon','sihost','taskhostw',
            'runtimebroker','shellexperiencehost','startmenuexperiencehost','textinputhost','searchhost','securityhealthsystray','dllhost',
            'fontdrvhost','dwm','winlogon','csrss','lsass','services','svchost','smss','wininit','audiodg','applicationframehost',
            'msedgewebview2','wmiprvse','idle','system','registry')
  $keep += ('__KEEP__'.ToLower().Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $saved = @{ video = (Acv 'SUB_VIDEO' 'VIDEOIDLE'); max = (Acv 'SUB_PROCESSOR' 'PROCTHROTTLEMAX'); boost = (Acv 'SUB_PROCESSOR' 'PERFBOOSTMODE') }
  ($saved | ConvertTo-Json -Compress) | Set-Content -Path $state          # settings first, then one line per frozen process
  $sid = (Get-Process -Id $PID).SessionId
  foreach ($p in Get-Process) {
    if ($p.SessionId -ne $sid -or $p.Id -eq $PID) { continue }
    if ($keep -contains $p.ProcessName.ToLower()) { continue }
    $ticks = 0
    try { $ticks = $p.StartTime.Ticks } catch {}
    Add-Content -Path $state -Value ("{0},{1}" -f $p.Id, $ticks)           # write BEFORE freezing so a crash can still undo it
    if (-not (Touch $p.Id 'suspend')) { (Get-Content $state | Where-Object { $_ -ne ("{0},{1}" -f $p.Id, $ticks) }) | Set-Content -Path $state }
  }
  SetAc 'SUB_VIDEO' 'VIDEOIDLE' 60
  SetAc 'SUB_PROCESSOR' 'PROCTHROTTLEMAX' 50
  SetAc 'SUB_PROCESSOR' 'PERFBOOSTMODE' 0
  powercfg /setactive SCHEME_CURRENT | Out-Null
} else {
  if (-not (Test-Path $state)) { exit }
  $lines = @(Get-Content $state)
  foreach ($l in ($lines | Select-Object -Skip 1)) {
    $a = $l.Split(',')
    $proc = Get-Process -Id ([int]$a[0]) -ErrorAction SilentlyContinue
    if (-not $proc) { continue }
    $same = $true
    if ([int64]$a[1] -ne 0) { try { $same = ($proc.StartTime.Ticks -eq [int64]$a[1]) } catch {} }   # PID reused by another program? leave it
    if ($same) { [void](Touch $proc.Id 'resume') }
  }
  $s = $lines[0] | ConvertFrom-Json
  SetAc 'SUB_VIDEO' 'VIDEOIDLE' $s.video
  SetAc 'SUB_PROCESSOR' 'PROCTHROTTLEMAX' $s.max
  SetAc 'SUB_PROCESSOR' 'PERFBOOSTMODE' $s.boost
  powercfg /setactive SCHEME_CURRENT | Out-Null
  Remove-Item $state -Force
}
"#;

fn run_script(on: bool, extra: &[String]) {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        let dir = crate::config::data_dir();
        let q = |s: &str| s.replace('\'', "''");
        let script = SCRIPT
            .replace("__MODE__", if on { "on" } else { "off" })
            .replace("__STATE__", &q(&dir.join("eco-state.txt").to_string_lossy()))
            .replace("__KEEP__", &q(&extra.join(",")));
        let path = dir.join("eco.ps1");
        if std::fs::write(&path, script).is_err() {
            return;
        }
        let _ = std::process::Command::new("powershell")
            .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
            .arg(&path)
            .creation_flags(0x0800_0000)
            .status();
    }
    #[cfg(not(target_os = "windows"))]
    let _ = (on, extra);
}

/// Switch eco mode on or off (returns at once; the work runs in a thread).
pub fn set(app: &Shared, on: bool) {
    if ON.swap(on, Ordering::SeqCst) == on {
        return;
    }
    let keep = app.cfg.read().eco_keep.clone();
    let app = app.clone();
    std::thread::spawn(move || {
        run_script(on, &keep);
        if on {
            control::send(Cmd::Power { action: "screenoff".into() });
        }
        app.push(json!({ "event": "eco", "on": on }));
        app.ui("eco", json!({ "on": on }));
    });
}

pub fn toggle(app: &Shared) {
    set(app, !ON.load(Ordering::SeqCst));
}

/// At start-up: if a previous run died while eco was on, un-freeze everything.
pub fn recover() {
    if crate::config::data_dir().join("eco-state.txt").exists() {
        run_script(false, &[]);
    }
}
