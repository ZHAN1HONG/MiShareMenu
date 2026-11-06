using System.Runtime.InteropServices;

namespace MiShare.ShellExt;

/// <summary>COM / Shell 相关的常量与接口标识。</summary>
internal static class ComConstants
{
    // HRESULT
    public const int S_OK = 0;
    public const int S_FALSE = 1;
    public const int E_NOTIMPL = unchecked((int)0x80004001);
    public const int E_NOINTERFACE = unchecked((int)0x80004002);
    public const int E_POINTER = unchecked((int)0x80004003);
    public const int E_FAIL = unchecked((int)0x80004005);
    public const int E_INVALIDARG = unchecked((int)0x80070057);
    public const int CLASS_E_NOAGGREGATION = unchecked((int)0x80040110);
    public const int CLASS_E_CLASSNOTAVAILABLE = unchecked((int)0x80040111);

    public static readonly Guid IID_IUnknown = new("00000000-0000-0000-C000-000000000046");
    public static readonly Guid IID_IClassFactory = new("00000001-0000-0000-C000-000000000046");
    public static readonly Guid IID_IExplorerCommand = new("A08CE4D0-FA25-44AB-B57C-C7B1C323E0B9");
    public static readonly Guid IID_IObjectWithSite = new("FC4801A3-2BA9-11CF-A229-00AA003D7352");

    // 经典菜单（显示更多选项）宿主在 GetState 之前探测的两个私有接口；
    // 一级菜单（Win11 现代菜单）从不请求它们。实测 6.0.0.39 / Win11，其余版本未验证，
    // 探测不到时 GetState 会退回「始终显示」，最坏只是二级菜单多一条，不会丢菜单。
    public static readonly Guid IID_ClassicMenuProbe1 = new("D51836B4-8B5A-4E11-8F97-D489BD4B28C0");
    public static readonly Guid IID_ClassicMenuProbe2 = new("1C9CD5BB-98E9-4491-A60F-31AACC72B83C");

    /// <summary>本扩展自身的 COM 类标识（与 AppxManifest 中登记的一致）。</summary>
    public static readonly Guid Clsid = new("8F3A6B21-4C7D-4E9A-9F52-1D6E7B0C3A84");

    /// <summary>EXPCMDSTATE</summary>
    public const uint ECS_ENABLED = 0x00000000;
    public const uint ECS_HIDDEN = 0x00000002;

    /// <summary>SIGDN_FILESYSPATH</summary>
    public const uint SIGDN_FILESYSPATH = 0x80058000;
}

/// <summary>共享的引用计数与状态。每个 COM 对象一份。</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct ComInstance
{
    public int RefCount;
    public nint Site;
    public ComView* CommandView; // IExplorerCommand 视图
    public ComView* SiteView;    // IObjectWithSite 视图

    /// <summary>
    /// 经典菜单线索：经典菜单（显示更多选项）宿主在调用 GetState 之前，
    /// 会先向对象 QI 两个一级菜单从不请求的私有接口（见 ComCore 里的 IID 常量）。
    /// 探测到即视为二级菜单调用，用于「二级让位给官方、一级保持自己」。
    /// </summary>
    public int ClassicHint;
}

/// <summary>
/// 接口视图：COM 的接口指针就是「以 vtable 指针开头的一块内存」，
/// 同一个对象暴露不同接口时必须返回指向不同 vtable 的不同指针，
/// 否则调用方会按错误的槽位取函数（这正是 Invoke 槽位错乱的根源之一）。
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct ComView
{
    public nint* Vtable;
    public ComInstance* Owner;
}

/// <summary>
/// 所有 COM 对象的函数表。三张：IExplorerCommand 视图、IObjectWithSite 视图、IClassFactory。
/// </summary>
internal static unsafe class ComVtables
{
    /// <summary>IUnknown(3) + IExplorerCommand(8)：GetTitle/GetIcon/GetToolTip/GetCanonicalName/GetState/GetFlags/EnumSubCommands/Invoke</summary>
    public const int CommandSlotCount = 11;

    /// <summary>IUnknown(3) + IObjectWithSite(2)：SetSite/GetSite</summary>
    public const int SiteSlotCount = 5;

    /// <summary>IUnknown(3) + IClassFactory(2)：CreateInstance/LockServer</summary>
    public const int FactorySlotCount = 5;

    public static nint* CommandTable { get; private set; }
    public static nint* SiteTable { get; private set; }
    public static nint* FactoryTable { get; private set; }

    public static int LiveObjects;

    public static void Initialize()
    {
        if (CommandTable != null)
        {
            return;
        }

        BuildCommandTable();
        BuildSiteTable();
        BuildFactoryTable();
    }

    private static void BuildCommandTable()
    {
        // IExplorerCommand 槽位顺序（shobjidl_core.h，务必按此顺序，错一位点击就没反应）：
        // 3 GetTitle | 4 GetIcon | 5 GetToolTip | 6 GetCanonicalName
        // 7 GetState | 8 Invoke | 9 GetFlags | 10 EnumSubCommands
        var table = (nint*)NativeMemory.AllocZeroed((nuint)(sizeof(nint) * CommandSlotCount));

        table[0] = (nint)(delegate* unmanaged<ComView*, Guid*, nint*, int>)&ComEntryPoints.ViewQueryInterface;
        table[1] = (nint)(delegate* unmanaged<ComView*, uint>)&ComEntryPoints.ViewAddRef;
        table[2] = (nint)(delegate* unmanaged<ComView*, uint>)&ComEntryPoints.ViewRelease;
        table[3] = (nint)(delegate* unmanaged<ComView*, nint, nint*, int>)&ComEntryPoints.GetTitle;
        table[4] = (nint)(delegate* unmanaged<ComView*, nint, nint*, int>)&ComEntryPoints.GetIcon;
        table[5] = (nint)(delegate* unmanaged<ComView*, nint, nint*, int>)&ComEntryPoints.GetToolTip;
        table[6] = (nint)(delegate* unmanaged<ComView*, Guid*, int>)&ComEntryPoints.GetCanonicalName;
        table[7] = (nint)(delegate* unmanaged<ComView*, nint, int, uint*, int>)&ComEntryPoints.GetState;
        table[8] = (nint)(delegate* unmanaged<ComView*, nint, nint, int>)&ComEntryPoints.Invoke;
        table[9] = (nint)(delegate* unmanaged<ComView*, uint*, int>)&ComEntryPoints.GetFlags;
        table[10] = (nint)(delegate* unmanaged<ComView*, nint*, int>)&ComEntryPoints.EnumSubCommands;

        CommandTable = table;
    }

    private static void BuildSiteTable()
    {
        var table = (nint*)NativeMemory.AllocZeroed((nuint)(sizeof(nint) * SiteSlotCount));

        table[0] = (nint)(delegate* unmanaged<ComView*, Guid*, nint*, int>)&ComEntryPoints.ViewQueryInterface;
        table[1] = (nint)(delegate* unmanaged<ComView*, uint>)&ComEntryPoints.ViewAddRef;
        table[2] = (nint)(delegate* unmanaged<ComView*, uint>)&ComEntryPoints.ViewRelease;
        table[3] = (nint)(delegate* unmanaged<ComView*, nint, int>)&ComEntryPoints.SetSite;
        table[4] = (nint)(delegate* unmanaged<ComView*, Guid*, nint*, int>)&ComEntryPoints.GetSite;

        SiteTable = table;
    }

    private static void BuildFactoryTable()
    {
        var table = (nint*)NativeMemory.AllocZeroed((nuint)(sizeof(nint) * FactorySlotCount));

        table[0] = (nint)(delegate* unmanaged<ComView*, Guid*, nint*, int>)&ComEntryPoints.ViewQueryInterface;
        table[1] = (nint)(delegate* unmanaged<ComView*, uint>)&ComEntryPoints.ViewAddRef;
        table[2] = (nint)(delegate* unmanaged<ComView*, uint>)&ComEntryPoints.ViewRelease;
        table[3] = (nint)(delegate* unmanaged<ComView*, nint, Guid*, nint*, int>)&ComEntryPoints.CreateInstance;
        table[4] = (nint)(delegate* unmanaged<ComView*, int, int>)&ComEntryPoints.LockServer;

        FactoryTable = table;
    }
}
