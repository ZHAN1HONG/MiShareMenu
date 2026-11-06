using System.Runtime.InteropServices;

namespace MiShare.ShellExt;

/// <summary>
/// 原生入口层。dllhost 通过 vtable 直接调用到这些方法，
/// 每个方法只做「视图指针 → 对象状态」的解包和签名适配后转交给 <see cref="ComCore"/>。
/// </summary>
internal static unsafe class ComEntryPoints
{
    // ---- IUnknown（所有视图共用一套，按视图所属对象转发）----

    [UnmanagedCallersOnly]
    public static int ViewQueryInterface(ComView* self, Guid* riid, nint* ppv)
        => ComCore.QueryInterface(self->Owner, riid, ppv);

    [UnmanagedCallersOnly]
    public static uint ViewAddRef(ComView* self) => ComCore.AddRef(self->Owner);

    [UnmanagedCallersOnly]
    public static uint ViewRelease(ComView* self) => ComCore.Release(self->Owner);

    // ---- IExplorerCommand ----

    [UnmanagedCallersOnly]
    public static int GetTitle(ComView* self, nint itemArray, nint* name)
        => ComCore.GetTitle(self->Owner, itemArray, name);

    [UnmanagedCallersOnly]
    public static int GetIcon(ComView* self, nint itemArray, nint* icon)
        => ComCore.GetIcon(self->Owner, itemArray, icon);

    [UnmanagedCallersOnly]
    public static int GetToolTip(ComView* self, nint itemArray, nint* tip)
        => ComCore.GetToolTip(self->Owner, itemArray, tip);

    [UnmanagedCallersOnly]
    public static int GetCanonicalName(ComView* self, Guid* name)
        => ComCore.GetCanonicalName(self->Owner, name);

    [UnmanagedCallersOnly]
    public static int GetState(ComView* self, nint itemArray, int okToBeSlow, uint* state)
        => ComCore.GetState(self->Owner, itemArray, okToBeSlow, state);

    [UnmanagedCallersOnly]
    public static int GetFlags(ComView* self, uint* flags)
        => ComCore.GetFlags(self->Owner, flags);

    [UnmanagedCallersOnly]
    public static int EnumSubCommands(ComView* self, nint* enumerator)
        => ComCore.EnumSubCommands(self->Owner, enumerator);

    // IExplorerCommand::Invoke(IShellItemArray*, IBindCtx*)
    [UnmanagedCallersOnly]
    public static int Invoke(ComView* self, nint itemArray, nint bindContext)
        => ComCore.Invoke(self->Owner, itemArray, bindContext);

    // ---- IObjectWithSite ----

    [UnmanagedCallersOnly]
    public static int SetSite(ComView* self, nint site)
        => ComCore.SetSite(self->Owner, site);

    [UnmanagedCallersOnly]
    public static int GetSite(ComView* self, Guid* riid, nint* site)
        => ComCore.GetSite(self->Owner, riid, site);

    // ---- IClassFactory ----

    [UnmanagedCallersOnly]
    public static int CreateInstance(ComView* self, nint outer, Guid* riid, nint* ppv)
        => ComCore.CreateInstance(self->Owner, outer, riid, ppv);

    [UnmanagedCallersOnly]
    public static int LockServer(ComView* self, int lockServer)
        => ComCore.LockServer(self->Owner, lockServer);
}
