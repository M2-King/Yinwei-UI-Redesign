import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Windows per-app output routing (EarTrumpet / AudioPolicyConfig).
/// Pins the music app to **muted speakers** only when those speakers are
/// not the wet destination. Wet stays on Windows default (or an explicit
/// pick) so Sony `WH-` names do not lock the stream. Nahimic sharing of
/// the default mix is preserved when speakers *are* the wet device.
class AppAudioSplit {
  const AppAudioSplit({
    required this.headphonesName,
    required this.headphonesId,
    required this.speakersName,
    required this.speakersId,
  });

  final String headphonesName;
  final String headphonesId;
  final String speakersName;
  final String speakersId;
}

class AppAudioRouter {
  String? _speakersId;
  bool _unmuteSpeakersOnRestore = false;
  final List<int> _routedPids = [];
  int _routedRootPid = 0;

  bool get isRouted => _routedPids.isNotEmpty;

  /// Root pid last pinned to muted speakers (0 if none).
  int get routedRootPid => _routedRootPid;

  /// Same-app next-track must not re-run the slow PowerShell pin.
  static bool shouldSkipPin({
    required int rootPid,
    required int routedRootPid,
    required bool isRouted,
  }) =>
      isRouted && rootPid > 0 && rootPid == routedRootPid;

  Future<AppAudioSplit?> detectSplit() async {
    if (!Platform.isWindows) return null;
    final rows = await _run(['list']);
    AppAudioEndpoint? phones;
    AppAudioEndpoint? speakers;
    for (final line in rows) {
      final p = line.split('|');
      if (p.length < 3) continue;
      final kind = p[0];
      final name = p[1];
      final id = p[2];
      if (kind == 'headphones' && phones == null) {
        phones = AppAudioEndpoint(name, id);
      } else if (kind == 'speakers' && speakers == null) {
        speakers = AppAudioEndpoint(name, id);
      }
    }
    if (phones == null || speakers == null) return null;
    if (phones.id == speakers.id) return null;
    return AppAudioSplit(
      headphonesName: phones.name,
      headphonesId: phones.id,
      speakersName: speakers.name,
      speakersId: speakers.id,
    );
  }

  Future<String?> _detectSpeakersId() async {
    final rows = await _run(['list']);
    for (final line in rows) {
      final parts = line.split('|');
      if (parts.length >= 3 && parts[0] == 'speakers') return parts[2];
    }
    return null;
  }

  /// Route [rootPid] and same-exe children to [speakersId]. Remember for restore.
  ///
  /// [keepSpeakerMute] is the source-follow hop: unpin the previous app tree
  /// but do **not** unmute the speaker device (wet stays on headphones).
  Future<bool> routeToSpeakers({
    required int rootPid,
    required String speakersId,
    bool keepSpeakerMute = false,
  }) async {
    if (!Platform.isWindows || rootPid <= 0) return false;
    if (shouldSkipPin(
      rootPid: rootPid,
      routedRootPid: _routedRootPid,
      isRouted: isRouted,
    )) {
      return true;
    }
    final preserveUnmute = _unmuteSpeakersOnRestore;
    if (keepSpeakerMute && _speakersId == speakersId) {
      await _run(['clear', _routedPids.join(',')]);
      _routedPids.clear();
      _routedRootPid = 0;
    } else {
      await restore();
      keepSpeakerMute = false;
    }
    if (!keepSpeakerMute) {
      final rows = await _run(['mute-state', speakersId]);
      int? wasMuted;
      for (final line in rows) {
        if (line.startsWith('MUTED_WAS ')) {
          wasMuted = int.tryParse(line.substring('MUTED_WAS '.length));
          break;
        }
      }
      if (wasMuted != 0 && wasMuted != 1) return false;
      _unmuteSpeakersOnRestore = wasMuted == 0;
      _speakersId = speakersId;
      // The recovery record must exist before any persistent route or mute.
      await _setDirty(true,
          state: AudioRouteRecoveryState(
            speakersId,
            wasMuted == 0,
            rootPid: rootPid,
            routedPids: [rootPid],
          ));
    }
    late final List<String> rows;
    try {
      rows = await _run(['apply', '$rootPid', speakersId]);
    } catch (_) {
      await restore();
      rethrow;
    }
    final pids = <int>[];
    for (final line in rows) {
      if (line.startsWith('PID ')) {
        pids.add(int.tryParse(line.substring(4).trim()) ?? 0);
      }
    }
    _routedPids
      ..clear()
      ..addAll(pids.where((p) => p > 0));
    _speakersId = speakersId;
    _routedRootPid = _routedPids.isEmpty ? 0 : rootPid;
    if (keepSpeakerMute) {
      _unmuteSpeakersOnRestore = preserveUnmute;
    }
    if (_routedPids.isEmpty) {
      await restore();
      return false;
    }
    await _setDirty(true,
        state: AudioRouteRecoveryState(
          speakersId,
          _unmuteSpeakersOnRestore,
          rootPid: rootPid,
          routedPids: _routedPids,
        ));
    return _routedPids.isNotEmpty;
  }

  Future<void> restore() async {
    if (!Platform.isWindows) return;
    final dirty = await _readDirty();
    if (!isRouted && dirty == null) return;
    final state = AudioRouteRecoveryState.parse(dirty);
    if (state == null && dirty?.trim() == '1' && _speakersId == null) {
      await recoverIfDirty();
      return;
    }
    final speakers = _speakersId ?? state?.speakersId;
    final unmute = _unmuteSpeakersOnRestore || (state?.unmute ?? false);
    final pids = _routedPids.isNotEmpty
        ? _routedPids
        : (state?.routedPids ?? const <int>[]);
    Object? clearError;
    try {
      if (pids.isNotEmpty) {
        await _run(['clear', pids.join(',')]);
      } else if (dirty?.trim() == '1') {
        await _run(['clear-all']);
      }
    } catch (error) {
      clearError = error;
    }
    if (speakers != null && unmute) await _run(['unmute', speakers]);
    if (clearError != null) throw clearError;
    await _setDirty(false);
    _speakersId = null;
    _unmuteSpeakersOnRestore = false;
    _routedRootPid = 0;
    _routedPids.clear();
  }

  /// Undo a route left by a previous process, including its endpoint mute.
  Future<void> recoverIfDirty() async {
    if (!Platform.isWindows) return;
    final dirty = await _readDirty();
    if (dirty == null) return;
    final state = AudioRouteRecoveryState.parse(dirty);
    if (state == null && dirty.trim() != '1') {
      throw const FormatException('Invalid audio route recovery state');
    }
    Object? clearError;
    try {
      if (state != null) {
        await _run(['clear', state.routedPids.join(',')]);
      } else {
        await _run(['clear-all']);
      }
    } catch (error) {
      clearError = error;
    }
    if (state != null) {
      if (state.unmute) await _run(['unmute', state.speakersId]);
    } else if (dirty.trim() == '1') {
      // Older builds stored only '1'. They always muted the detected speaker
      // but did not record its previous state; repair the stuck-silent case.
      final speakersId = await _detectSpeakersId();
      if (speakersId == null) {
        throw StateError('Cannot find the speaker muted by an older Yinwei');
      }
      await _run(['unmute', speakersId]);
    }
    if (clearError != null) throw clearError;
    await _setDirty(false);
  }

  Future<List<String>> _run(List<String> args) async {
    final script = await _ensureScript();
    final proc = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script,
        ...args,
      ],
    );
    if (proc.exitCode != 0) {
      throw ProcessException('powershell.exe', args,
          (proc.stderr as String? ?? '').trim(), proc.exitCode);
    }
    final out = (proc.stdout as String? ?? '').trim();
    if (out.isEmpty) return const [];
    return const LineSplitter().convert(out);
  }

  Future<String> _ensureScript() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}\\yinwei_app_audio_route.ps1');
    await file.writeAsString(_kScript, flush: true);
    return file.path;
  }

  Future<File> _dirtyFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}\\yinwei_audio_route.dirty');
  }

  Future<String?> _readDirty() async {
    try {
      final file = await _dirtyFile();
      return await file.exists() ? await file.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _setDirty(bool dirty, {AudioRouteRecoveryState? state}) async {
    final file = await _dirtyFile();
    if (dirty) {
      if (state == null) throw StateError('Missing audio route recovery state');
      await file.writeAsString(state.encode(), flush: true);
    } else if (await file.exists()) {
      await file.delete();
    }
  }
}

class AudioRouteRecoveryState {
  const AudioRouteRecoveryState(this.speakersId, this.unmute,
      {required this.rootPid, required this.routedPids});

  final String speakersId;
  final bool unmute;
  final int rootPid;
  final List<int> routedPids;

  String encode() => jsonEncode({
        'speakersId': speakersId,
        'unmute': unmute,
        'rootPid': rootPid,
        'routedPids': routedPids,
      });

  static AudioRouteRecoveryState? parse(String? raw) {
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value['speakersId'] is! String ||
          (value['speakersId'] as String).isEmpty ||
          value['unmute'] is! bool ||
          value['rootPid'] is! int ||
          value['routedPids'] is! List) {
        return null;
      }
      final pids = (value['routedPids'] as List).whereType<int>().toList();
      if (pids.isEmpty || pids.any((pid) => pid <= 0)) return null;
      return AudioRouteRecoveryState(
        value['speakersId'] as String,
        value['unmute'] as bool,
        rootPid: value['rootPid'] as int,
        routedPids: pids,
      );
    } catch (_) {
      return null;
    }
  }
}

class AppAudioEndpoint {
  AppAudioEndpoint(this.name, this.id);
  final String name;
  final String id;
}

const _kScript = r'''
param(
  [Parameter(Position=0)][string]$Action,
  [Parameter(Position=1)][string]$Arg1,
  [Parameter(Position=2)][string]$Arg2,
  [Parameter(Position=3)][string]$Arg3,
  [Parameter(Position=4)][string]$Arg4
)
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null

$cs = @'
using System;
using System.Runtime.InteropServices;
public static class YinweiPolicy {
  [ComImport]
  [Guid("ab3d4648-e242-459f-b02f-541c70306324")]
  [InterfaceType(ComInterfaceType.InterfaceIsIInspectable)]
  interface IFactory21 {
    int i00(); int i01(); int i02(); int i03(); int i04();
    int i05(); int i06(); int i07(); int i08(); int i09();
    int i10(); int i11(); int i12(); int i13(); int i14();
    int i15(); int i16(); int i17(); int i18();
    [PreserveSig] int SetPersistedDefaultAudioEndpoint(uint pid, int flow, int role, IntPtr deviceId);
    [PreserveSig] int GetPersistedDefaultAudioEndpoint(uint pid, int flow, int role, out IntPtr deviceId);
    [PreserveSig] int ClearAllPersistedApplicationDefaultEndpoints();
  }
  [DllImport("combase.dll")] static extern int RoGetActivationFactory(IntPtr activatableClassId, ref Guid iid, out IntPtr factory);
  [DllImport("combase.dll")] static extern int WindowsCreateString([MarshalAs(UnmanagedType.LPWStr)] string s, int len, out IntPtr h);
  [DllImport("combase.dll")] static extern int WindowsDeleteString(IntPtr h);
  static IFactory21 Fac() {
    IntPtr hclass; string cls = "Windows.Media.Internal.AudioPolicyConfig";
    WindowsCreateString(cls, cls.Length, out hclass);
    Guid iid = new Guid("ab3d4648-e242-459f-b02f-541c70306324");
    IntPtr unk; RoGetActivationFactory(hclass, ref iid, out unk);
    WindowsDeleteString(hclass);
    return (IFactory21)Marshal.GetObjectForIUnknown(unk);
  }
  public static int Set(uint pid, string deviceId) {
    var fac = Fac();
    IntPtr hdev; WindowsCreateString(deviceId, deviceId.Length, out hdev);
    int hr = 0;
    hr |= fac.SetPersistedDefaultAudioEndpoint(pid, 0, 0, hdev);
    hr |= fac.SetPersistedDefaultAudioEndpoint(pid, 0, 1, hdev);
    hr |= fac.SetPersistedDefaultAudioEndpoint(pid, 0, 2, hdev);
    WindowsDeleteString(hdev);
    return hr;
  }

  public static int Clear(uint pid) {
    var fac = Fac();
    int hr = 0;
    hr |= fac.SetPersistedDefaultAudioEndpoint(pid, 0, 0, IntPtr.Zero);
    hr |= fac.SetPersistedDefaultAudioEndpoint(pid, 0, 1, IntPtr.Zero);
    hr |= fac.SetPersistedDefaultAudioEndpoint(pid, 0, 2, IntPtr.Zero);
    return hr;
  }

  static string ToMmId(string id) {
    if (string.IsNullOrEmpty(id)) return id;
    int start = id.IndexOf("{0.0.0.");
    if (start < 0) return id;
    int end = id.IndexOf("}#", start);
    if (end < 0) return id.Substring(start);
    return id.Substring(start, end - start + 1);
  }

  [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceEnumerator {
    int EnumAudioEndpoints();
    int GetDefaultAudioEndpoint();
    [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string pwstrId, out IMMDevice ppDevice);
  }
  [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDevice {
    [PreserveSig] int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, out IntPtr ppInterface);
  }
  [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioEndpointVolume {
    int a0(); int a1(); int a2(); int a3(); int a4(); int a5(); int a6(); int a7(); int a8(); int a9(); int a10();
    [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, IntPtr ctx);
    [PreserveSig] int GetMute(out int pbMute);
  }
  [DllImport("ole32.dll")]
  static extern int CoCreateInstance(ref Guid clsid, IntPtr unk, int ctx, ref Guid iid, out IMMDeviceEnumerator pp);

  static IAudioEndpointVolume Volume(string id) {
    var clsid = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
    var iidEn = new Guid("A95664D2-9614-4F35-A746-DE8DB63617E6");
    IMMDeviceEnumerator en;
    if (CoCreateInstance(ref clsid, IntPtr.Zero, 23, ref iidEn, out en) != 0) return null;
    IMMDevice dev;
    if (en.GetDevice(ToMmId(id), out dev) != 0 || dev == null) return null;
    var iidVol = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
    IntPtr p;
    if (dev.Activate(ref iidVol, 23, IntPtr.Zero, out p) != 0 || p == IntPtr.Zero) return null;
    return (IAudioEndpointVolume)Marshal.GetObjectForIUnknown(p);
  }

  public static int GetMuted(string id) {
    var vol = Volume(id);
    if (vol == null) return -1;
    int m; vol.GetMute(out m); return m;
  }

  public static int SetMuted(string id, bool mute) {
    var vol = Volume(id);
    if (vol == null) return -1;
    return vol.SetMute(mute, IntPtr.Zero);
  }

  public static int ClearAll() {
    var fac = Fac();
    return fac.ClearAllPersistedApplicationDefaultEndpoints();
  }
}
'@
Add-Type -TypeDefinition $cs -ErrorAction SilentlyContinue | Out-Null

function Get-RenderDevices {
  $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
  function Await($WinRtTask, $ResultType) {
    $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($WinRtTask))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
  }
  [void][Windows.Devices.Enumeration.DeviceInformation,Windows.Devices.Enumeration,ContentType=WindowsRuntime]
  $aqs = 'System.Devices.InterfaceClassGuid:="{e6327cad-dcec-4949-ae8a-991e976a79d2}" AND System.Devices.InterfaceEnabled:=System.StructuredQueryType.Boolean#True'
  $op = [Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($aqs)
  Await $op ([Windows.Devices.Enumeration.DeviceInformationCollection])
}

function Classify([string]$name) {
  $n = $name.ToLowerInvariant()
  # Keep in sync with WetOutputPolicy.classify (wet_output_policy.dart).
  # Nahimic / A-Volute Sound Sharing must not be ignored or muted as "virtual".
  if ($n -match 'nahimic|a-volute|avolute|sound sharing') { return 'nahimic' }
  if ($n -match 'todesk|steam|virtual|cable|vb-audio|nvidia|oculus|meta|vac ') { return 'ignore' }
  if ($n -match '耳机|headphone|headset|wh-|airpods|buds|earbuds') { return 'headphones' }
  if ($n -match '扬声器|speakers?') { return 'speakers' }
  return 'other'
}

if ($Action -eq 'list') {
  $col = Get-RenderDevices
  $phone = $null; $spk = $null; $nah = $null
  foreach ($d in $col) {
    $k = Classify $d.Name
    if ($k -eq 'headphones' -and -not $phone) { $phone = $d }
    if ($k -eq 'nahimic' -and -not $nah) { $nah = $d }
    if ($k -eq 'speakers') {
      if (-not $spk) { $spk = $d }
      elseif ($d.Name -match 'Realtek|Realtek') { $spk = $d }
    }
  }
  if ($phone) { Write-Output ("headphones|" + $phone.Name + "|" + $phone.Id) }
  if ($spk) { Write-Output ("speakers|" + $spk.Name + "|" + $spk.Id) }
  if ($nah) { Write-Output ("nahimic|" + $nah.Name + "|" + $nah.Id) }
  exit 0
}

function Pids-ForRoot([int]$root) {
  $rootProc = Get-CimInstance Win32_Process -Filter "ProcessId=$root" -ErrorAction SilentlyContinue
  if (-not $rootProc) { return @($root) }
  $exe = $rootProc.Name
  @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq $exe } | ForEach-Object { [int]$_.ProcessId })
}

if ($Action -eq 'apply') {
  $root = [int]$Arg1
  $dev = [string]$Arg2
  $routed = 0
  $applied = @()
  foreach ($p in (Pids-ForRoot $root)) {
    $hr = [YinweiPolicy]::Set([uint32]$p, $dev)
    if ($hr -eq 0) { Write-Output "PID $p"; $routed++; $applied += $p }
  }
  if ($routed -eq 0) { exit 2 }
  $hr = [YinweiPolicy]::SetMuted($dev, $true)
  if ($hr -ne 0) {
    foreach ($p in $applied) { [void][YinweiPolicy]::Clear([uint32]$p) }
    exit 3
  }
  exit 0
}

if ($Action -eq 'mute-state') {
  $was = [YinweiPolicy]::GetMuted([string]$Arg1)
  Write-Output "MUTED_WAS $was"
  if ($was -lt 0) { exit 4 }
  exit 0
}

if ($Action -eq 'clear') {
  $bad = 0
  foreach ($textPid in $Arg1.Split(',')) {
    $parsedPid = 0
    if (-not [int]::TryParse($textPid, [ref]$parsedPid) -or $parsedPid -le 0) { continue }
    $hr = [YinweiPolicy]::Clear([uint32]$parsedPid)
    if ($hr -ne 0) { $bad++ }
  }
  if ($bad -gt 0) { exit 5 }
  exit 0
}

if ($Action -eq 'clear-all') {
  $hr = [YinweiPolicy]::ClearAll()
  Write-Output ("CLEAR_HR $hr")
  if ($hr -ne 0) { exit 5 }
  exit 0
}

if ($Action -eq 'unmute') {
  $hr = [YinweiPolicy]::SetMuted([string]$Arg1, $false)
  if ($hr -ne 0) { exit 6 }
  exit 0
}

if ($Action -eq 'restore') {
  [void][YinweiPolicy]::ClearAll()
  $dev = [string]$Arg1
  $ids = @()
  if ($Arg2) { $ids = $Arg2.Split(',') | ForEach-Object { [int]$_ } }
  foreach ($p in $ids) {
    if ($p -gt 0) { [void][YinweiPolicy]::Set([uint32]$p, $dev) }
  }
  if ($Arg3 -eq '1' -and $Arg4) {
    [void][YinweiPolicy]::SetMuted($Arg4, $false)
  }
  exit 0
}
''';
