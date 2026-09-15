$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null

$cs = @'
using System;
using System.Runtime.InteropServices;
public static class YinweiPolicyClear {
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
  public static int Clear() {
    IntPtr hclass; string cls = "Windows.Media.Internal.AudioPolicyConfig";
    WindowsCreateString(cls, cls.Length, out hclass);
    Guid iid = new Guid("ab3d4648-e242-459f-b02f-541c70306324");
    IntPtr unk; int hr = RoGetActivationFactory(hclass, ref iid, out unk);
    WindowsDeleteString(hclass);
    if (hr != 0 || unk == IntPtr.Zero) return hr != 0 ? hr : -1;
    var fac = (IFactory21)Marshal.GetObjectForIUnknown(unk);
    return fac.ClearAllPersistedApplicationDefaultEndpoints();
  }
}
'@
Add-Type -TypeDefinition $cs -ErrorAction Stop
$hr = [YinweiPolicyClear]::Clear()
Write-Output ("CLEAR_HR 0x{0:X8}" -f $hr)

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
$col = Await $op ([Windows.Devices.Enumeration.DeviceInformationCollection])
Write-Output '--- render devices ---'
foreach ($d in $col) { Write-Output $d.Name }
