using Microsoft.Win32;

namespace MiShare.Core;

/// <summary>小米电脑管家的安装信息。</summary>
public sealed class PcManagerInstall
{
    public required string Root { get; init; }
    public required string Executable { get; init; }
    public string? IconPath { get; init; }

    public override string ToString() => Executable;
}

/// <summary>
/// 负责定位本机的小米电脑管家（含「小米互联服务」内测版）。
/// 双通道探测：先读 COM 组件注册路径反推安装目录，失败则扫描常见安装位置。
/// </summary>
public static class PcManagerLocator
{
    /// <summary>小米互传右键菜单组件在不同大版本下使用过的 CLSID。</summary>
    private static readonly Guid[] KnownShellClsids =
    [
        new("504D69C0-CB52-48DF-B5B5-7161829FABC8"), // 5.x
        new("1BCA9901-05C3-4D01-8AD4-78DA2EAC9B3F"), // 4.x
    ];

    /// <summary>主程序候选（按优先级），第一个存在者胜出。</summary>
    private static readonly string[] ExecutableCandidates =
    [
        "hyperConnect.exe",
        "MiPcContinuity.exe",
        "XiaomiPcManager.exe",
    ];

    /// <summary>承载 WM_COPYDATA 的顶层窗口类名。</summary>
    private static readonly string[] MessageWindowClasses =
    [
        "XiaomiPCManager",
        "MiPcContinuity",
    ];

    private static readonly object SyncRoot = new();
    private static PcManagerInstall? _cached;
    private static DateTime _cachedAt = DateTime.MinValue;
    private static readonly TimeSpan CacheLifetime = TimeSpan.FromSeconds(30);

    /// <summary>返回安装信息；未安装时返回 null。</summary>
    public static PcManagerInstall? Locate()
    {
        lock (SyncRoot)
        {
            if (_cached is not null && DateTime.UtcNow - _cachedAt < CacheLifetime)
            {
                return _cached;
            }

            _cached = Probe();
            _cachedAt = DateTime.UtcNow;
            return _cached;
        }
    }

    public static bool IsInstalled() => Locate() is not null;

    /// <summary>
    /// 管家自己是否注册了「小米互传」菜单（HKCR 下带 ExplorerCommandHandler 的 MiDropExtMenu）。
    /// 5.x 和 6.0 都会写这个键。只读 HKCR，不做任何修改。
    /// </summary>
    public static bool HasOfficialContextMenu()
    {
        foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
        {
            try
            {
                using var classesRoot = RegistryKey.OpenBaseKey(RegistryHive.ClassesRoot, view);
                foreach (var verb in new[] { @"*\shell\MiDropExtMenu", @"Directory\shell\MiDropExtMenu" })
                {
                    using var key = classesRoot.OpenSubKey(verb);
                    if (key?.GetValue("ExplorerCommandHandler") is string handler
                        && !string.IsNullOrWhiteSpace(handler))
                    {
                        return true;
                    }
                }
            }
            catch
            {
                // 读不到按「没有官方菜单」处理：宁可二级多一条，不能丢菜单
            }
        }

        return false;
    }

    /// <summary>依次尝试所有已知窗口类名，返回第一个存在的窗口句柄。</summary>
    public static nint FindMessageWindow()
    {
        foreach (var className in MessageWindowClasses)
        {
            var hwnd = Native.FindWindowW(className, null);
            if (hwnd != 0)
            {
                return hwnd;
            }
        }

        return 0;
    }

    private static PcManagerInstall? Probe()
    {
        foreach (var clsid in KnownShellClsids)
        {
            var install = FromComRegistration(clsid);
            if (install is not null)
            {
                return install;
            }
        }

        return FromWellKnownFolders();
    }

    private static PcManagerInstall? FromComRegistration(Guid clsid)
    {
        foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
        {
            try
            {
                using var classesRoot = RegistryKey.OpenBaseKey(RegistryHive.ClassesRoot, view);
                using var key = classesRoot.OpenSubKey($@"CLSID\{clsid:B}\InprocServer32");

                if (key?.GetValue(null) is not string raw || string.IsNullOrWhiteSpace(raw))
                {
                    continue;
                }

                var modulePath = Environment.ExpandEnvironmentVariables(raw.Trim().Trim('"'));
                if (!File.Exists(modulePath))
                {
                    continue;
                }

                var install = WalkUpToExecutable(Path.GetDirectoryName(modulePath));
                if (install is not null)
                {
                    return install;
                }
            }
            catch
            {
                // 注册表不可读时静默降级到目录扫描
            }
        }

        return null;
    }

    /// <summary>从给定目录开始向上回溯，找到包含主程序的那一层。</summary>
    private static PcManagerInstall? WalkUpToExecutable(string? startDirectory)
    {
        var dir = startDirectory;
        for (var depth = 0; depth < 8 && !string.IsNullOrEmpty(dir); depth++)
        {
            var install = BuildInstall(dir);
            if (install is not null)
            {
                return install;
            }

            dir = Path.GetDirectoryName(dir);
        }

        return null;
    }

    private static PcManagerInstall? BuildInstall(string directory)
    {
        if (string.IsNullOrEmpty(directory) || !Directory.Exists(directory))
        {
            return null;
        }

        foreach (var candidate in ExecutableCandidates)
        {
            var exePath = Path.Combine(directory, candidate);
            if (File.Exists(exePath))
            {
                return new PcManagerInstall
                {
                    Root = directory,
                    Executable = exePath,
                    IconPath = ResolveIcon(directory, exePath),
                };
            }
        }

        return null;
    }

    private static string ResolveIcon(string directory, string executable)
    {
        // 5.x 及更早：图标在安装目录的 Assets 下；6.0 起挪到了 MiSmartShare 子目录
        string[] candidates =
        [
            Path.Combine(directory, "Assets", "midrop_logo.ico"),
            Path.Combine(directory, "MiSmartShare", "Assets", "midrop_logo.ico"),
        ];
        foreach (var ico in candidates)
        {
            if (File.Exists(ico))
            {
                return ico;
            }
        }

        // 兜底：在安装根目录下再扫一层 <子组件>\Assets\midrop_logo.ico，
        // 覆盖未来可能新增的组件目录；再找不到才退回主程序图标
        try
        {
            foreach (var sub in Directory.EnumerateDirectories(directory))
            {
                var ico = Path.Combine(sub, "Assets", "midrop_logo.ico");
                if (File.Exists(ico))
                {
                    return ico;
                }
            }
        }
        catch
        {
            // 目录不可读时忽略，走回落
        }

        return $"{executable},0";
    }

    /// <summary>兜底：扫描常见安装根目录下的所有版本子目录，取版本号最大者。</summary>
    private static PcManagerInstall? FromWellKnownFolders()
    {
        var roots = new List<string>();

        foreach (var variable in new[] { "ProgramFiles", "ProgramFiles(x86)", "LocalAppData" })
        {
            var basePath = Environment.GetEnvironmentVariable(variable);
            if (string.IsNullOrEmpty(basePath))
            {
                continue;
            }

            roots.Add(Path.Combine(basePath, "MI", "XiaomiPCManager"));
            roots.Add(Path.Combine(basePath, "Programs", "MI", "XiaomiPCManager"));
        }

        foreach (var root in roots)
        {
            if (!Directory.Exists(root))
            {
                continue;
            }

            var direct = BuildInstall(root);
            if (direct is not null)
            {
                return direct;
            }

            IEnumerable<string> versions;
            try
            {
                versions = Directory.EnumerateDirectories(root);
            }
            catch
            {
                continue;
            }

            foreach (var versionDir in versions.OrderByDescending(ParseVersionKey))
            {
                var install = BuildInstall(versionDir);
                if (install is not null)
                {
                    return install;
                }
            }
        }

        return null;
    }

    private static Version ParseVersionKey(string path)
    {
        var name = Path.GetFileName(path);
        return Version.TryParse(name, out var version) ? version : new Version(0, 0);
    }
}
