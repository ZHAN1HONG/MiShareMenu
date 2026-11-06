using System.Diagnostics;
using System.Runtime.InteropServices;
using MiShare.Core;

namespace MiShare.ShellExt;

/// <summary>
/// 负责从 COM 代理进程里把真正的发送进程拉起来。
/// 采用「自我定位包目录」的策略，不依赖任何宿主的当前工作目录。
/// </summary>
internal static unsafe class LauncherBridge
{
    private const string LauncherFolder = "Launcher";
    private const string LauncherFileName = "MiShare.Launcher.exe";

    public static bool StartSender(string queueKey)
    {
        try
        {
            var launcher = ResolveLauncherPath();
            if (launcher is null)
            {
                return false;
            }

            var startInfo = new ProcessStartInfo(launcher)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            startInfo.ArgumentList.Add("--queue");
            startInfo.ArgumentList.Add(queueKey);

            using var process = Process.Start(startInfo);
            return process is not null;
        }
        catch
        {
            return false;
        }
    }

    private static string? ResolveLauncherPath()
    {
        var candidates = new List<string>();

        var packageRoot = GetPackageRoot();
        if (!string.IsNullOrEmpty(packageRoot))
        {
            candidates.Add(Path.Combine(packageRoot, LauncherFolder, LauncherFileName));
        }

        var moduleDirectory = GetModuleDirectory();
        if (!string.IsNullOrEmpty(moduleDirectory))
        {
            // ShellExt\MiShare.ShellExt.dll -> ..\Launcher\MiShare.Launcher.exe
            candidates.Add(Path.GetFullPath(Path.Combine(moduleDirectory, "..", LauncherFolder, LauncherFileName)));
        }

        var overrideRoot = Environment.GetEnvironmentVariable("MISHARE_ROOT");
        if (!string.IsNullOrEmpty(overrideRoot))
        {
            candidates.Add(Path.Combine(overrideRoot, LauncherFolder, LauncherFileName));
        }

        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }

    /// <summary>取当前包（MSIX）的安装根目录；未以打包身份运行时返回 null。</summary>
    private static string? GetPackageRoot()
    {
        try
        {
            uint length = 0;
            Native.GetCurrentPackagePath(&length, null);

            if (length == 0 || length > 32768)
            {
                return null;
            }

            var buffer = stackalloc char[(int)length];
            if (Native.GetCurrentPackagePath(&length, buffer) != 0)
            {
                return null;
            }

            var root = new string(buffer, 0, (int)(length - 1)).TrimEnd('\\');
            return Directory.Exists(root) ? root : null;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>取承载本 DLL 的模块所在目录。</summary>
    private static string? GetModuleDirectory()
    {
        try
        {
            const uint FromAddress = 0x00000004;
            const uint UnchangedRefCount = 0x00000002;

            nint address = (nint)(delegate* unmanaged<int>)&SelfAddressProbe;

            if (Native.GetModuleHandleExW(FromAddress | UnchangedRefCount, address, out var module) == 0 || module == 0)
            {
                return null;
            }

            var buffer = stackalloc char[1024];
            var written = Native.GetModuleFileNameW(module, buffer, 1024);
            if (written == 0 || written >= 1024)
            {
                return null;
            }

            return Path.GetDirectoryName(new string(buffer, 0, (int)written));
        }
        catch
        {
            return null;
        }
    }

    [UnmanagedCallersOnly]
    private static int SelfAddressProbe() => 0;
}
