using System.Runtime.InteropServices;

namespace MiShare.ShellExt;

/// <summary>
/// 从资源管理器传进来的 IShellItemArray 里抠出文件系统路径。
/// 纯裸指针调用，避免在 AOT 下产生 COM 封送开销。
/// </summary>
internal static unsafe class ShellItemArrayReader
{
    private const int MaxItems = 4096;

    // IShellItemArray : IUnknown 之后依次为
    // 3 BindToHandler | 4 GetPropertyStore | 5 GetPropertyDescriptionList
    // 6 GetAttributes | 7 GetCount | 8 GetItemAt | 9 EnumItems
    private const int ArrayGetCount = 7;
    private const int ArrayGetItemAt = 8;

    // IShellItem 的 vtable 槽位
    private const int ItemGetDisplayName = 5;

    public static string[] ReadFileSystemPaths(nint shellItemArray)
    {
        if (shellItemArray == 0)
        {
            return [];
        }

        var results = new List<string>();

        try
        {
            var arrayVtbl = *(nint**)shellItemArray;

            var getCount = (delegate* unmanaged<nint, uint*, int>)arrayVtbl[ArrayGetCount];
            var getItemAt = (delegate* unmanaged<nint, uint, nint*, int>)arrayVtbl[ArrayGetItemAt];

            uint count;
            if (getCount(shellItemArray, &count) != 0 || count == 0)
            {
                return [];
            }

            var limit = Math.Min(count, MaxItems);

            for (uint index = 0; index < limit; index++)
            {
                nint item = 0;
                if (getItemAt(shellItemArray, index, &item) != 0 || item == 0)
                {
                    continue;
                }

                try
                {
                    var path = GetFileSystemPath(item);
                    if (!string.IsNullOrEmpty(path))
                    {
                        results.Add(path);
                    }
                }
                finally
                {
                    ComHelpers.Release(item);
                }
            }
        }
        catch
        {
            return results.ToArray();
        }

        return results.ToArray();
    }

    private static string? GetFileSystemPath(nint shellItem)
    {
        var vtbl = *(nint**)shellItem;
        var getDisplayName = (delegate* unmanaged<nint, uint, nint*, int>)vtbl[ItemGetDisplayName];

        nint raw = 0;
        if (getDisplayName(shellItem, ComConstants.SIGDN_FILESYSPATH, &raw) != 0 || raw == 0)
        {
            return null;
        }

        try
        {
            return Marshal.PtrToStringUni(raw);
        }
        finally
        {
            Marshal.FreeCoTaskMem(raw);
        }
    }
}
