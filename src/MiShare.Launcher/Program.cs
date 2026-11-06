using System.Runtime.InteropServices;
using MiShare.Core;

namespace MiShare.Launcher;

internal static partial class Program
{
    private const string Caption = "小米互传";

    private static int Main(string[] args)
    {
        try
        {
            if (!TryParse(args, out var queueKey, out var directPaths))
            {
                ShowError("参数不正确。");
                return 2;
            }

            string[] files;

            if (queueKey is not null)
            {
                files = ShareQueue.Dequeue(queueKey);
            }
            else if (directPaths.Length > 0)
            {
                files = directPaths;
            }
            else
            {
                // 从开始菜单 / 应用列表冷启动：只负责把管家叫起来
                return ShareDispatcher.TryStartManager() ? 0 : FailNotInstalled();
            }

            if (files.Length == 0)
            {
                ShowError("要发送的文件已经不存在了，请重新从右键菜单发送。");
                return 3;
            }

            if (PcManagerLocator.Locate() is null)
            {
                return FailNotInstalled();
            }

            if (ShareDispatcher.Send(files))
            {
                return 0;
            }

            ShowError("连接小米电脑管家失败。\n请先在任务栏打开「小米电脑管家」，再重试一次。");
            return 4;
        }
        catch (Exception ex)
        {
            ShowError($"发送失败：{ex.Message}");
            return 1;
        }
    }

    private static int FailNotInstalled()
    {
        ShowError("没有检测到「小米电脑管家」。\n请先安装小米电脑管家（或小米互联服务），再使用此功能。");
        return 5;
    }

    private static bool TryParse(string[] args, out string? queueKey, out string[] directPaths)
    {
        queueKey = null;
        directPaths = [];

        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--queue" when i + 1 < args.Length:
                    queueKey = args[++i];
                    return true;

                case "--send" when i + 1 < args.Length:
                    directPaths = args[++i].Split('|', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                    return true;
            }
        }

        return args.Length == 0;
    }

    private static void ShowError(string message)
    {
        const uint MbIconWarning = 0x00000030;
        const uint MbTopMost = 0x00040000;
        MessageBoxW(0, message, Caption, MbIconWarning | MbTopMost);
    }

    [LibraryImport("user32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int MessageBoxW(nint hWnd, string text, string caption, uint type);
}
