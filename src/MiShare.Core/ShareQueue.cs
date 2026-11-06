using System.Text;

namespace MiShare.Core;

/// <summary>
/// 右键菜单（运行在 COM 代理进程）与真正的发送进程之间传递文件列表的信箱。
/// 用临时文件而不是命令行，避免超长路径 / 大量文件撑爆命令行长度限制。
/// </summary>
public static class ShareQueue
{
    private static readonly string QueueDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "MiShareMenu",
        "queue");

    private static readonly TimeSpan MaxAge = TimeSpan.FromMinutes(10);

    /// <summary>把文件列表写入信箱，返回取件码；无有效文件时返回 null。</summary>
    public static string? Enqueue(IEnumerable<string> paths)
    {
        try
        {
            var normalized = paths
                .Where(static p => !string.IsNullOrWhiteSpace(p))
                .Select(static p => p.Trim())
                .Where(static p => Path.IsPathFullyQualified(p))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();

            if (normalized.Length == 0)
            {
                return null;
            }

            Directory.CreateDirectory(QueueDirectory);
            Cleanup();

            var key = Guid.NewGuid().ToString("N");
            File.WriteAllText(Path.Combine(QueueDirectory, key), string.Join('\n', normalized), Encoding.UTF8);
            return key;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>取出并销毁信箱内容；失败返回空数组。</summary>
    public static string[] Dequeue(string? key)
    {
        if (string.IsNullOrWhiteSpace(key) || key.Length != 32 || !key.All(static c => char.IsAsciiHexDigit(c)))
        {
            return [];
        }

        var file = Path.Combine(QueueDirectory, key);

        try
        {
            if (!File.Exists(file))
            {
                return [];
            }

            var content = File.ReadAllText(file, Encoding.UTF8);
            File.Delete(file);

            return content
                .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .ToArray();
        }
        catch
        {
            return [];
        }
    }

    private static void Cleanup()
    {
        try
        {
            var now = DateTime.UtcNow;
            foreach (var file in Directory.EnumerateFiles(QueueDirectory))
            {
                try
                {
                    if (now - File.GetLastWriteTimeUtc(file) > MaxAge)
                    {
                        File.Delete(file);
                    }
                }
                catch
                {
                    // 单个文件清理失败不影响主流程
                }
            }
        }
        catch
        {
            // 目录不可用时忽略
        }
    }
}
