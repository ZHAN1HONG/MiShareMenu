using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace MiShare.Core;

/// <summary>
/// 真正把文件交给小米电脑管家的地方。
/// 6.0+：把“以 | 分隔的绝对路径列表”写入共享内存 Local\MiDropFileMappingObject，
///       再以 --contextmenu_dropfile=1 启动管家，由它弹出「小米互传 · 发送」窗口。
/// 5.x：找到管家的消息窗口，用 WM_COPYDATA 投递同格式路径列表。
/// </summary>
public static unsafe class ShareDispatcher
{
    /// <summary>wParam 固定为 1，表示「发送文件」这条指令（5.x 旧通道）。</summary>
    private const nint ShareCommandId = 1;

    /// <summary>6.0+ 用于传递文件列表的共享内存名。</summary>
    private const string MappingName = @"Local\MiDropFileMappingObject";

    /// <summary>6.0+ 启动管家时携带的命令行参数。</summary>
    private const string MappingArgument = "--contextmenu_dropfile=1";

    /// <summary>6.0+ 发送窗口的固定标题。</summary>
    private const string ShareWindowTitle = "小米互传 · 发送";

    private static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan WindowWait = TimeSpan.FromSeconds(12);

    /// <summary>发送文件；返回是否成功把指令送达管家。</summary>
    public static bool Send(IReadOnlyList<string> paths, TimeSpan? timeout = null)
    {
        var payload = BuildPayload(paths);
        if (payload.Length == 0)
        {
            return false;
        }

        // 6.0+ 优先走共享内存通道；失败时回落到 5.x 的 WM_COPYDATA
        if (TrySendViaMapping(payload))
        {
            return true;
        }

        var window = PcManagerLocator.FindMessageWindow();

        if (window == 0)
        {
            if (!TryStartManager())
            {
                return false;
            }

            window = WaitForMessageWindow(WindowWait);
            if (window == 0)
            {
                return false;
            }
        }

        return SendPayload(window, payload, timeout ?? DefaultTimeout);
    }

    /// <summary>静默拉起管家主程序（用户没开着的时候）。</summary>
    public static bool TryStartManager()
    {
        var install = PcManagerLocator.Locate();
        if (install is null)
        {
            return false;
        }

        try
        {
            Process.Start(new ProcessStartInfo(install.Executable) { UseShellExecute = true });
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// 6.0+ 通道：共享内存传路径 + 命令行参数启动管家。
    /// 管家启动后读取 Local\MiDropFileMappingObject，弹出「小米互传 · 发送」并带上文件。
    /// </summary>
    private static bool TrySendViaMapping(string payload)
    {
        var install = PcManagerLocator.Locate();
        if (install is null || !SupportsMappingChannel(install.Executable))
        {
            return false;
        }

        nint mapping = 0;
        nint view = 0;

        try
        {
            var bytes = Encoding.Unicode.GetBytes(payload);
            mapping = Native.CreateFileMappingW(
                new IntPtr(-1), 0, 0x04 /* PAGE_READWRITE */, 0,
                (uint)Math.Max(0x10000, bytes.Length + 2), MappingName);
            if (mapping == 0)
            {
                return false;
            }

            view = Native.MapViewOfFile(mapping, 0x000F001F /* FILE_MAP_ALL_ACCESS */, 0, 0, UIntPtr.Zero);
            if (view == 0)
            {
                return false;
            }

            Marshal.Copy(bytes, 0, view, bytes.Length);
            Marshal.WriteInt16(view, bytes.Length, 0);

            Process.Start(new ProcessStartInfo(install.Executable)
            {
                Arguments = MappingArgument,
                UseShellExecute = true,
            });

            // 等管家创建发送窗口（窗口出现说明参数与映射都已被处理）
            if (!WaitForShareWindow(WindowWait))
            {
                return false;
            }

            // 留一点时间让管家把映射内容读走
            Thread.Sleep(1000);
            return true;
        }
        catch
        {
            return false;
        }
        finally
        {
            if (view != 0)
            {
                Native.UnmapViewOfFile(view);
            }

            if (mapping != 0)
            {
                Native.CloseHandle(mapping);
            }
        }
    }

    /// <summary>管家主程序大版本 ≥ 6 才支持共享内存通道。</summary>
    private static bool SupportsMappingChannel(string executable)
    {
        try
        {
            var info = FileVersionInfo.GetVersionInfo(executable);
            return info.FileMajorPart >= 6;
        }
        catch
        {
            return false;
        }
    }

    private static bool WaitForShareWindow(TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;

        while (DateTime.UtcNow < deadline)
        {
            if (Native.FindWindowW(null, ShareWindowTitle) != 0)
            {
                return true;
            }

            Thread.Sleep(200);
        }

        return false;
    }

    private static nint WaitForMessageWindow(TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;

        while (DateTime.UtcNow < deadline)
        {
            var window = PcManagerLocator.FindMessageWindow();
            if (window != 0)
            {
                return window;
            }

            Thread.Sleep(250);
        }

        return 0;
    }

    private static bool SendPayload(nint window, string payload, TimeSpan timeout)
    {
        var milliseconds = (uint)Math.Clamp(timeout.TotalMilliseconds, 0, 15_000);

        fixed (char* buffer = payload)
        {
            var data = new Native.COPYDATASTRUCT
            {
                dwData = 0,
                cbData = payload.Length * sizeof(char),
                lpData = (nint)buffer,
            };

            var result = Native.SendMessageTimeoutW(
                window,
                Native.WM_COPYDATA,
                ShareCommandId,
                (nint)(&data),
                0,
                milliseconds,
                out _);

            return result != 0;
        }
    }

    /// <summary>过滤出真实存在的绝对路径，快捷方式解析为指向的目标，拼成管家认识的格式。</summary>
    private static string BuildPayload(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0)
        {
            return string.Empty;
        }

        var builder = new System.Text.StringBuilder();

        foreach (var path in paths)
        {
            if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
            {
                continue;
            }

            if (!File.Exists(path) && !Directory.Exists(path))
            {
                continue;
            }

            // 对齐官方行为：快捷方式取「文件所在地」发送；解析失败回落为发送 .lnk 本身
            var effective = ShortcutResolver.Resolve(path) ?? path;

            if (builder.Length > 0)
            {
                builder.Append('|');
            }

            builder.Append(effective);
        }

        return builder.ToString();
    }
}
