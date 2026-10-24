/// PowerShell function `Get-YinweiProcesses`: the process list that
/// `Get-CimInstance Win32_Process` gives (ProcessId, ParentProcessId, Name,
/// ExecutablePath, CommandLine), read directly from Windows instead of WMI.
///
/// Why: on the owner's laptop (2026-10-24) every WMI query took about 21 s,
/// whatever it asked, while the same list read natively takes milliseconds.
/// Live start asks for processes several times, so it timed out on the iPad.
///
/// - EnumProcesses: process ids (a full snapshot copies every thread and was slow).
/// - QueryFullProcessImageName: exe path and name (`SodaMusic.exe`).
/// - NtQueryInformationProcess(ProcessBasicInformation): parent pid.
/// - NtQueryInformationProcess(ProcessCommandLineInformation): command line,
///   the same text WMI shows (used to tell 汽水's main process from its
///   `--type=` helpers).
/// Processes this user cannot open are left out. Music apps run as the user.
/// `-Match <regex>` returns only processes whose exe name matches (fast: the
/// caller's filter runs natively). `[YinweiProcList]::PathOf(pid)` and
/// `NameOf(pid)` read one process.
///
/// On any failure the function outputs nothing; callers then fall back to
/// their previous WMI query, so results are never worse than before.
/// The C# is compiled once into %TEMP% (versioned name) and loaded from there.
const kYinweiProcessListPs = r'''
$YinweiProcListCs = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
public class YinweiProcRow {
  public int ProcessId; public int ParentProcessId; public string Name;
  public string ExecutablePath; public string CommandLine;
}
public static class YinweiProcList {
  [DllImport("psapi.dll", SetLastError = true)] static extern bool EnumProcesses([Out] uint[] ids, int size, out int needed);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool QueryFullProcessImageNameW(IntPtr h, int flags, StringBuilder name, ref int size);
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int infoClass, IntPtr buffer, int length, out int returned);
  // A full process snapshot (Toolhelp, WMI) copies every thread and took ~1 s
  // (Toolhelp) to ~21 s (WMI) on the owner's laptop; EnumProcesses lists ids only.
  // Only rows whose exe name matches [match] (null: all), with path and command line.
  // Processes this user cannot open are left out (WMI lists them without path).
  public static YinweiProcRow[] All(string match) {
    Regex wanted = match == null ? null : new Regex(match, RegexOptions.IgnoreCase);
    uint[] ids = new uint[16384]; int needed;
    if (!EnumProcesses(ids, ids.Length * 4, out needed)) throw new InvalidOperationException("enum");
    var rows = new List<YinweiProcRow>();
    for (int i = 0; i < needed / 4; i++) {
      IntPtr h = OpenProcess(0x1000, false, ids[i]); // query limited information
      if (h == IntPtr.Zero) continue;
      try {
        string path = ImagePath(h);
        if (path == null) continue;
        string name = System.IO.Path.GetFileName(path);
        if (wanted != null && !wanted.IsMatch(name)) continue;
        var r = new YinweiProcRow();
        r.ProcessId = (int)ids[i]; r.Name = name; r.ExecutablePath = path;
        r.ParentProcessId = Parent(h); r.CommandLine = CommandLine(h);
        rows.Add(r);
      } finally { CloseHandle(h); }
    }
    return rows.ToArray();
  }
  static int Parent(IntPtr h) {
    int size = IntPtr.Size * 6, returned; // PROCESS_BASIC_INFORMATION
    IntPtr buffer = Marshal.AllocHGlobal(size);
    try {
      if (NtQueryInformationProcess(h, 0, buffer, size, out returned) != 0) return 0;
      return (int)Marshal.ReadIntPtr(buffer, IntPtr.Size * 5).ToInt64(); // InheritedFromUniqueProcessId
    } finally { Marshal.FreeHGlobal(buffer); }
  }
  public static string NameOf(int pid) {
    string path = PathOf(pid);
    return path == null ? null : System.IO.Path.GetFileName(path);
  }
  public static string PathOf(int pid) {
    IntPtr h = OpenProcess(0x1000, false, (uint)pid);
    if (h == IntPtr.Zero) return null;
    try { return ImagePath(h); } finally { CloseHandle(h); }
  }
  static string ImagePath(IntPtr h) {
    var b = new StringBuilder(1024); int n = b.Capacity;
    return QueryFullProcessImageNameW(h, 0, b, ref n) ? b.ToString(0, n) : null;
  }
  static string CommandLine(IntPtr h) {
    int length;
    NtQueryInformationProcess(h, 60, IntPtr.Zero, 0, out length); // ProcessCommandLineInformation
    if (length <= 0 || length > (1 << 20)) return null;
    IntPtr buffer = Marshal.AllocHGlobal(length);
    try {
      if (NtQueryInformationProcess(h, 60, buffer, length, out length) != 0) return null;
      int bytes = (ushort)Marshal.ReadInt16(buffer); // UNICODE_STRING.Length
      IntPtr text = Marshal.ReadIntPtr(buffer, IntPtr.Size); // UNICODE_STRING.Buffer
      return bytes == 0 || text == IntPtr.Zero ? "" : Marshal.PtrToStringUni(text, bytes / 2);
    } finally { Marshal.FreeHGlobal(buffer); }
  }
}
'@
# True when the native helper is loaded. False means: use the old WMI query.
function Use-YinweiProcList {
  if ('YinweiProcList' -as [type]) { return $true }
  $dll = Join-Path $env:TEMP 'yinwei_proc_list_v4.dll'
  try {
    if (Test-Path -LiteralPath $dll) {
      Add-Type -Path $dll -ErrorAction Stop
      return [bool]('YinweiProcList' -as [type])
    }
  } catch {}
  # No saved copy, or it could not load: compile a fresh one.
  try {
    $tmp = Join-Path $env:TEMP ('yinwei_proc_list_' + [Guid]::NewGuid().ToString('N') + '.dll')
    Add-Type -TypeDefinition $YinweiProcListCs -OutputAssembly $tmp -OutputType Library -ErrorAction Stop
    Add-Type -Path $tmp -ErrorAction Stop
    try { if (-not (Test-Path -LiteralPath $dll)) { Copy-Item -LiteralPath $tmp -Destination $dll -ErrorAction Stop } } catch {}
    return [bool]('YinweiProcList' -as [type])
  } catch { return $false }
}
# Processes whose exe name matches -Match (all when empty). Sets
# $script:YinweiProcFailed when the helper failed, so callers can fall back to
# WMI; an empty result is a real answer, not a failure.
function Get-YinweiProcesses([string]$Match = $null) {
  $script:YinweiProcFailed = $true
  if (-not (Use-YinweiProcList)) { return }
  try {
    if ($Match) { $rows = [YinweiProcList]::All($Match) } else { $rows = [YinweiProcList]::All($null) }
    $script:YinweiProcFailed = $false
    $rows
  } catch { return }
}
''';
