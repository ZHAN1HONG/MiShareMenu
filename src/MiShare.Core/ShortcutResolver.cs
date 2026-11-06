using System.Runtime.InteropServices;

namespace MiShare.Core;

/// <summary>
/// 把 .lnk 快捷方式解析成它指向的真实目标（文件或目录）。
/// 官方互传菜单对快捷方式的行为是「取目标所在地再发送」，这里对齐同样行为；
/// 解析失败（断链、无权限等）时返回 null，由调用方回落为发送 .lnk 本身。
/// </summary>
public static unsafe class ShortcutResolver
{
    private static readonly Guid ClsidShellLink = new("00021401-0000-0000-C000-000000000046");
    private static readonly Guid IidShellLinkW = new("000214F9-0000-0000-C000-000000000046");
    private static readonly Guid IidPersistFile = new("0000010B-0000-0000-C000-000000000046");

    private const uint ClsCtxInprocServer = 0x1;
    private const uint CoinitApartmentThreaded = 0x2;
    private const int RpcEChangedMode = unchecked((int)0x80010106);
    private const uint SlgpUncPriority = 0x0002;   // 网络位置优先返回 UNC；非 Raw 模式下环境变量会被自动展开

    // IUnknown 之后 IShellLinkW 依次为 GetPath | GetIDList | SetIDList | ...
    private const int LinkGetPath = 3;
    private const int LinkGetIdList = 4;

    // IUnknown + IPersist::GetClassID 之后 IPersistFile 依次为 IsDirty | Load | ...
    private const int PersistLoad = 5;

    private const int QueryInterfaceSlot = 0;
    private const int ReleaseSlot = 2;
    private const int PathBufferChars = 1024;

    /// <summary>是快捷方式且成功解析时返回最终目标路径；否则返回 null。</summary>
    public static string? Resolve(string path)
    {
        if (!IsShortcut(path))
        {
            return null;
        }

        // 支持嵌套（快捷方式指向另一个快捷方式），限制层数防环
        var current = path;
        for (var depth = 0; depth < 5 && IsShortcut(current); depth++)
        {
            var next = ResolveOne(current);
            if (next is null)
            {
                return null;
            }

            current = next;
        }

        return IsShortcut(current) ? null : (IsValidTarget(current) ? current : null);
    }

    private static bool IsShortcut(string path)
        => !string.IsNullOrWhiteSpace(path) && path.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase);

    private static bool IsValidTarget(string? target)
        => !string.IsNullOrWhiteSpace(target)
           && Path.IsPathFullyQualified(target)
           && (File.Exists(target) || Directory.Exists(target));

    /// <summary>解析单个 .lnk，返回指向的目标路径；失败返回 null。</summary>
    private static string? ResolveOne(string lnkPath)
    {
        if (!File.Exists(lnkPath))
        {
            return null;
        }

        nint persistFile = 0;
        nint shellLink = 0;
        var ownedApartment = false;

        try
        {
            var hr = Native.CoInitializeEx(0, CoinitApartmentThreaded);
            if (hr == RpcEChangedMode)
            {
                // 已在另一种套间模型上初始化过，直接沿用，最后不做 CoUninitialize
            }
            else if (hr is 0 or 1)  // S_OK / S_FALSE
            {
                ownedApartment = true;
            }
            else
            {
                return null;
            }

            var clsid = ClsidShellLink;
            var iidPersist = IidPersistFile;
            if (Native.CoCreateInstance(ref clsid, 0, ClsCtxInprocServer, ref iidPersist, out persistFile) != 0
                || persistFile == 0)
            {
                return null;
            }

            var persistVtbl = *(nint**)persistFile;

            var load = (delegate* unmanaged<nint, char*, uint, int>)persistVtbl[PersistLoad];
            fixed (char* source = lnkPath)
            {
                if (load(persistFile, source, 0 /* STGM_READ */) != 0)
                {
                    return null;
                }
            }

            var queryInterface = (delegate* unmanaged<nint, Guid*, nint*, int>)persistVtbl[QueryInterfaceSlot];
            var iidLink = IidShellLinkW;
            if (queryInterface(persistFile, &iidLink, &shellLink) != 0 || shellLink == 0)
            {
                return null;
            }

            var linkVtbl = *(nint**)shellLink;

            // 优先取文本路径
            var getPath = (delegate* unmanaged<nint, char*, int, nint, uint, int>)linkVtbl[LinkGetPath];
            var buffer = stackalloc char[PathBufferChars];
            var findData = stackalloc byte[1024];
            if (getPath(shellLink, buffer, PathBufferChars, (nint)findData, SlgpUncPriority) == 0)
            {
                var target = new string(buffer);
                if (IsValidTarget(target))
                {
                    return target;
                }
            }

            // 文本路径不可用时退回 PIDL（例如指向虚拟位置、目标路径超长等）
            var getIdList = (delegate* unmanaged<nint, nint*, int>)linkVtbl[LinkGetIdList];
            nint pidl = 0;
            if (getIdList(shellLink, &pidl) == 0 && pidl != 0)
            {
                try
                {
                    var pidlBuffer = stackalloc char[PathBufferChars];
                    if (Native.SHGetPathFromIDListW(pidl, pidlBuffer))
                    {
                        var target = new string(pidlBuffer);
                        if (IsValidTarget(target))
                        {
                            return target;
                        }
                    }
                }
                finally
                {
                    Native.CoTaskMemFree(pidl);
                }
            }

            return null;
        }
        catch
        {
            return null;
        }
        finally
        {
            if (shellLink != 0)
            {
                var release = (delegate* unmanaged<nint, uint>)(*(nint**)shellLink)[ReleaseSlot];
                release(shellLink);
            }

            if (persistFile != 0)
            {
                var release = (delegate* unmanaged<nint, uint>)(*(nint**)persistFile)[ReleaseSlot];
                release(persistFile);
            }

            if (ownedApartment)
            {
                Native.CoUninitialize();
            }
        }
    }
}
