using System.Runtime.InteropServices;
using MiShare.Core;

namespace MiShare.ShellExt;

/// <summary>
/// COM 对象的实际逻辑。全部以普通托管方法实现，方便互相调用与单元验证；
/// 对外的原生入口在 <see cref="ComEntryPoints"/> 里做一层薄封装。
/// </summary>
internal static unsafe class ComCore
{
    private const string MenuTitle = "使用小米互传发送";

    private static int _factoryLocks;

    // ---------- 对象生命周期 ----------

    /// <summary>创建命令对象（IExplorerCommand + IObjectWithSite 两个视图共享一份状态）。</summary>
    public static nint AllocateCommandObject()
    {
        var instance = (ComInstance*)NativeMemory.AllocZeroed((nuint)sizeof(ComInstance));
        instance->RefCount = 1;

        var commandView = (ComView*)NativeMemory.AllocZeroed((nuint)sizeof(ComView));
        commandView->Vtable = ComVtables.CommandTable;
        commandView->Owner = instance;

        var siteView = (ComView*)NativeMemory.AllocZeroed((nuint)sizeof(ComView));
        siteView->Vtable = ComVtables.SiteTable;
        siteView->Owner = instance;

        instance->CommandView = commandView;
        instance->SiteView = siteView;

        Interlocked.Increment(ref ComVtables.LiveObjects);
        return (nint)commandView;
    }

    /// <summary>创建类工厂对象（单一 IClassFactory 视图）。</summary>
    public static nint AllocateFactory()
    {
        var instance = (ComInstance*)NativeMemory.AllocZeroed((nuint)sizeof(ComInstance));
        instance->RefCount = 1;

        var factoryView = (ComView*)NativeMemory.AllocZeroed((nuint)sizeof(ComView));
        factoryView->Vtable = ComVtables.FactoryTable;
        factoryView->Owner = instance;

        instance->CommandView = factoryView; // 工厂只有主视图
        instance->SiteView = null;

        Interlocked.Increment(ref ComVtables.LiveObjects);
        return (nint)factoryView;
    }

    public static uint AddRef(ComInstance* self)
    {
        return self == null ? 0u : (uint)Interlocked.Increment(ref self->RefCount);
    }

    public static uint Release(ComInstance* self)
    {
        if (self == null)
        {
            return 0;
        }

        var remaining = (uint)Interlocked.Decrement(ref self->RefCount);
        if (remaining != 0)
        {
            return remaining;
        }

        if (self->Site != 0)
        {
            ComHelpers.Release(self->Site);
            self->Site = 0;
        }

        if (self->CommandView != null)
        {
            NativeMemory.Free(self->CommandView);
            self->CommandView = null;
        }

        if (self->SiteView != null)
        {
            NativeMemory.Free(self->SiteView);
            self->SiteView = null;
        }

        NativeMemory.Free(self);
        Interlocked.Decrement(ref ComVtables.LiveObjects);
        return 0;
    }

    /// <summary>
    /// 按请求的接口返回对应的视图指针。
    /// 命令对象：IUnknown/IExplorerCommand → 命令视图，IObjectWithSite → Site 视图。
    /// 工厂对象：IUnknown/IClassFactory → 工厂视图。
    /// </summary>
    public static int QueryInterface(ComInstance* self, Guid* riid, nint* ppv)
    {
        if (self == null || riid == null || ppv == null)
        {
            return ComConstants.E_POINTER;
        }

        var iid = *riid;
        nint view;

        // 经典菜单宿主在 GetState 之前会探测这两个接口（一级菜单从不请求），
        // 记下来供 GetState 区分一级/二级调用。宿主只是探测，继续按不实现返回。
        if (self->SiteView != null
            && (iid == ComConstants.IID_ClassicMenuProbe1 || iid == ComConstants.IID_ClassicMenuProbe2))
        {
            self->ClassicHint = 1;
        }

        if (self->SiteView != null)
        {
            // 命令对象
            if (iid == ComConstants.IID_IUnknown
                || iid == ComConstants.IID_IExplorerCommand)
            {
                view = (nint)self->CommandView;
            }
            else if (iid == ComConstants.IID_IObjectWithSite)
            {
                view = (nint)self->SiteView;
            }
            else
            {
                *ppv = 0;
                return ComConstants.E_NOINTERFACE;
            }
        }
        else
        {
            // 工厂对象
            if (iid == ComConstants.IID_IUnknown
                || iid == ComConstants.IID_IClassFactory)
            {
                view = (nint)self->CommandView;
            }
            else
            {
                *ppv = 0;
                return ComConstants.E_NOINTERFACE;
            }
        }

        AddRef(self);
        *ppv = view;
        return ComConstants.S_OK;
    }

    // ---------- IExplorerCommand ----------

    public static int GetTitle(ComInstance* self, nint itemArray, nint* name)
    {
        if (name == null)
        {
            return ComConstants.E_POINTER;
        }

        *name = Marshal.StringToCoTaskMemUni(MenuTitle);
        return ComConstants.S_OK;
    }

    public static int GetIcon(ComInstance* self, nint itemArray, nint* icon)
    {
        if (icon == null)
        {
            return ComConstants.E_POINTER;
        }

        var path = PcManagerLocator.Locate()?.IconPath;
        if (string.IsNullOrEmpty(path))
        {
            *icon = 0;
            return ComConstants.S_FALSE;
        }

        *icon = Marshal.StringToCoTaskMemUni(path);
        return ComConstants.S_OK;
    }

    public static int GetToolTip(ComInstance* self, nint itemArray, nint* tip)
    {
        if (tip == null)
        {
            return ComConstants.E_POINTER;
        }

        *tip = Marshal.StringToCoTaskMemUni("把选中的文件发送到小米手机、平板或电脑");
        return ComConstants.S_OK;
    }

    public static int GetCanonicalName(ComInstance* self, Guid* name)
    {
        if (name == null)
        {
            return ComConstants.E_POINTER;
        }

        *name = ComConstants.Clsid;
        return ComConstants.S_OK;
    }

    public static int GetState(ComInstance* self, nint itemArray, int okToBeSlow, uint* state)
    {
        if (state == null)
        {
            return ComConstants.E_POINTER;
        }

        // 没装小米电脑管家就干脆不出现，避免点了没反应的死菜单。
        //
        // 一级 / 二级分开处理（这是官方 5.x「只进一级」的镜像实现）：
        // - 一级菜单（现代菜单）：始终显示，它是我们的主入口；
        // - 二级菜单（经典菜单，靠 ClassicHint 识别）：官方 MiDropExtMenu 已注册时隐藏自己，
        //   把「显示更多选项」让给官方那一条，避免两条同名项并存。
        // 判据失效（某些 Windows 版本不发那两个探测 QI）时退化为二级也显示，只多一条不重名。
        var installed = PcManagerLocator.IsInstalled();
        var classicMenu = self->ClassicHint != 0;
        var hideInClassic = classicMenu && PcManagerLocator.HasOfficialContextMenu();

        *state = installed && !hideInClassic ? ComConstants.ECS_ENABLED : ComConstants.ECS_HIDDEN;
        return ComConstants.S_OK;
    }

    public static int Invoke(ComInstance* self, nint itemArray, nint bindContext)
    {
        // 这里跑在 COM 代理进程（dllhost）里，必须尽快返回，否则资源管理器会判我们超时。
        // 因此只做「写信箱 + 拉起发送进程」，真正的等待与投递交给 Launcher。
        var paths = ShellItemArrayReader.ReadFileSystemPaths(itemArray);

        if (paths.Length == 0)
        {
            return ComConstants.E_FAIL;
        }

        var key = ShareQueue.Enqueue(paths);
        if (key is null)
        {
            return ComConstants.E_FAIL;
        }

        var ok = LauncherBridge.StartSender(key);
        return ok ? ComConstants.S_OK : ComConstants.E_FAIL;
    }

    public static int GetFlags(ComInstance* self, uint* flags)
    {
        if (flags == null)
        {
            return ComConstants.E_POINTER;
        }

        *flags = 0;
        return ComConstants.S_OK;
    }

    public static int EnumSubCommands(ComInstance* self, nint* enumerator)
    {
        if (enumerator != null)
        {
            *enumerator = 0;
        }

        return ComConstants.E_NOTIMPL;
    }

    // ---------- IObjectWithSite ----------

    public static int SetSite(ComInstance* self, nint site)
    {
        if (self == null)
        {
            return ComConstants.E_POINTER;
        }

        if (self->Site != 0)
        {
            ComHelpers.Release(self->Site);
        }

        self->Site = site;

        if (site != 0)
        {
            ComHelpers.AddRef(site);
        }

        return ComConstants.S_OK;
    }

    public static int GetSite(ComInstance* self, Guid* riid, nint* site)
    {
        if (self == null || riid == null || site == null)
        {
            return ComConstants.E_POINTER;
        }

        if (self->Site == 0)
        {
            *site = 0;
            return ComConstants.E_FAIL;
        }

        return ComHelpers.QueryInterface(self->Site, riid, site);
    }

    // ---------- IClassFactory ----------

    public static int CreateInstance(ComInstance* self, nint outer, Guid* riid, nint* ppv)
    {
        if (riid == null || ppv == null)
        {
            return ComConstants.E_POINTER;
        }

        *ppv = 0;

        if (outer != 0)
        {
            return ComConstants.CLASS_E_NOAGGREGATION;
        }

        ComVtables.Initialize();
        var commandView = AllocateCommandObject();
        return QueryInterface((ComInstance*)((ComView*)commandView)->Owner, riid, ppv);
    }

    public static int LockServer(ComInstance* self, int lockServer)
    {
        if (lockServer != 0)
        {
            Interlocked.Increment(ref _factoryLocks);
        }
        else
        {
            Interlocked.Decrement(ref _factoryLocks);
        }

        return ComConstants.S_OK;
    }

    public static bool IsServerLocked => Volatile.Read(ref _factoryLocks) > 0;
}
