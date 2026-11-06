using System.Runtime.InteropServices;

namespace MiShare.Core;

/// <summary>
/// 与 shell / Win32 交互所需的极小互操作层（全部 source-generated，AOT 友好）。
/// </summary>
internal static unsafe partial class Native
{
    public const uint WM_COPYDATA = 0x004A;

    [StructLayout(LayoutKind.Sequential)]
    public struct COPYDATASTRUCT
    {
        public nint dwData;
        public int cbData;
        public nint lpData;
    }

    [LibraryImport("user32.dll", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    public static partial nint FindWindowW(string? lpClassName, string? lpWindowName);

    [LibraryImport("user32.dll", SetLastError = true)]
    public static partial nint SendMessageTimeoutW(
        nint hWnd, uint msg, nint wParam, nint lParam,
        uint fuFlags, uint uTimeout, out nint lpdwResult);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool IsWindow(nint hWnd);

    [LibraryImport("kernel32.dll")]
    public static partial uint GetCurrentPackagePath(uint* pathLength, char* path);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    public static partial int GetModuleHandleExW(uint flags, nint moduleName, out nint module);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    public static partial uint GetModuleFileNameW(nint module, char* fileName, uint size);

    [LibraryImport("kernel32.dll", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    public static partial nint CreateFileMappingW(
        nint hFile, nint lpAttributes, uint flProtect,
        uint maximumSizeHigh, uint maximumSizeLow, string lpName);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    public static partial nint MapViewOfFile(
        nint hFileMappingObject, uint desiredAccess,
        uint fileOffsetHigh, uint fileOffsetLow, UIntPtr numberOfBytesToMap);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool UnmapViewOfFile(nint lpBaseAddress);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool CloseHandle(nint hObject);

    // ---- 快捷方式解析（ShortcutResolver）所需 ----

    [LibraryImport("ole32.dll")]
    public static partial int CoInitializeEx(nint reserved, uint coInit);

    [LibraryImport("ole32.dll")]
    public static partial void CoUninitialize();

    [LibraryImport("ole32.dll")]
    public static partial int CoCreateInstance(
        ref Guid clsid, nint outer, uint classContext, ref Guid iid, out nint ppv);

    [LibraryImport("ole32.dll")]
    public static partial void CoTaskMemFree(nint pv);

    [LibraryImport("shell32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SHGetPathFromIDListW(nint pidl, char* pszPath);
}
