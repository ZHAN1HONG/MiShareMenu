using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace MiShare.ShellExt;

/// <summary>
/// 原生导出。dllhost.exe（COM 代理）加载本模块后就是从这里进门的。
/// </summary>
internal static unsafe class ModuleExports
{
#pragma warning disable CA2255
    [ModuleInitializer]
#pragma warning restore CA2255
    public static void Initialize()
    {
        ComVtables.Initialize();
    }

    [UnmanagedCallersOnly(EntryPoint = "DllGetClassObject")]
    public static int DllGetClassObject(Guid* rclsid, Guid* riid, nint* ppv)
    {
        if (rclsid == null || riid == null || ppv == null)
        {
            return ComConstants.E_POINTER;
        }

        *ppv = 0;

        if (*rclsid != ComConstants.Clsid)
        {
            return ComConstants.CLASS_E_CLASSNOTAVAILABLE;
        }

        ComVtables.Initialize();

        var factoryView = ComCore.AllocateFactory();
        var instance = ((ComView*)factoryView)->Owner;
        return ComCore.QueryInterface(instance, riid, ppv);
    }

    [UnmanagedCallersOnly(EntryPoint = "DllCanUnloadNow")]
    public static int DllCanUnloadNow()
    {
        return Volatile.Read(ref ComVtables.LiveObjects) == 0 && !ComCore.IsServerLocked
            ? ComConstants.S_OK
            : ComConstants.S_FALSE;
    }
}
