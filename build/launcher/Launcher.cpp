// MiShare.Launcher
//
// 右键菜单点下之后真正干活的进程：找到小米电脑管家，把文件列表递过去。
// 单独成进程是为了不把等待和投递放进资源管理器，避免菜单卡顿。
//
// 入口契约（与 ShellExt 约定，不可改）：
//   MiShare.Launcher.exe                    冷启动，只把管家叫起来
//   MiShare.Launcher.exe --queue <key>      从信箱取文件列表后发送
//   MiShare.Launcher.exe --send <a|b|c>     直接发送以 | 分隔的路径
//
// 退出码：0 成功 / 2 参数错 / 3 文件不存在 / 4 连接管家失败 / 5 未安装管家

#include <windows.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <shellapi.h>
#include <cstdlib>
#include <cstdio>
#include <cstring>

// MSVC 下用 pragma 指定依赖库；其它工具链由构建脚本传 -l
#ifdef _MSC_VER
#pragma comment(lib, "kernel32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "version.lib")
#endif

namespace {

const wchar_t* const kCaption = L"小米互传";
const wchar_t* const kMappingName = L"Local\\MiDropFileMappingObject";
const wchar_t* const kMappingArgument = L"--contextmenu_dropfile=1";
const wchar_t* const kShareWindowTitle = L"小米互传 · 发送";

// 承载 WM_COPYDATA 的顶层窗口类名（5.x）
const wchar_t* const kMessageWindowClasses[] = { L"XiaomiPCManager", L"MiPcContinuity" };

// 主程序候选，按优先级
const wchar_t* const kExecutableCandidates[] = { L"hyperConnect.exe", L"MiPcContinuity.exe", L"XiaomiPcManager.exe" };

// 小米互传右键菜单组件在历史版本里用过的 CLSID
const wchar_t* const kKnownShellClsids[] = {
    L"{504D69C0-CB52-48DF-B5B5-7161829FABC8}", // 5.x
    L"{1BCA9901-05C3-4D01-8AD4-78DA2EAC9B3F}", // 4.x
};

const DWORD kWindowWaitMs = 12000;
const DWORD kCopyDataTimeoutMs = 10000;
const int kPathBufferChars = 1024;

// ---------------------------------------------------------------- 小工具

bool FileExists(const wchar_t* path)
{
    const DWORD attr = GetFileAttributesW(path);
    return attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY);
}

bool DirExists(const wchar_t* path)
{
    const DWORD attr = GetFileAttributesW(path);
    return attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY);
}

bool Exists(const wchar_t* path)
{
    return GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
}

// 简单的宽字符缓冲，避免引入 STL 把体积撑起来
struct WStr {
    wchar_t* p;
    size_t len;
    size_t cap;

    WStr() : p(nullptr), len(0), cap(0) { Reserve(64); }
    ~WStr() { free(p); }

    WStr(const WStr&) = delete;
    WStr& operator=(const WStr&) = delete;

    bool Reserve(size_t need)
    {
        if (need + 1 <= cap) return true;
        size_t n = cap ? cap : 64;
        while (n < need + 1) n *= 2;
        wchar_t* q = (wchar_t*)realloc(p, n * sizeof(wchar_t));
        if (!q) return false;
        p = q;
        cap = n;
        return true;
    }

    void Clear() { len = 0; if (p) p[0] = L'\0'; }

    void Append(const wchar_t* s, size_t n)
    {
        if (!Reserve(len + n)) return;
        memcpy(p + len, s, n * sizeof(wchar_t));
        len += n;
        p[len] = L'\0';
    }

    void Append(const wchar_t* s) { if (s) Append(s, wcslen(s)); }
    void Append(wchar_t c) { Append(&c, 1); }
    const wchar_t* c_str() const { return p ? p : L""; }
};

struct PathList {
    wchar_t** items;
    int count;
    int cap;

    PathList() : items(nullptr), count(0), cap(0) {}
    ~PathList() { Clear(); }
    PathList(const PathList&) = delete;
    PathList& operator=(const PathList&) = delete;

    void Clear()
    {
        for (int i = 0; i < count; i++) free(items[i]);
        free(items);
        items = nullptr;
        count = 0;
        cap = 0;
    }

    bool Add(const wchar_t* s)
    {
        if (count == cap) {
            int n = cap ? cap * 2 : 8;
            wchar_t** q = (wchar_t**)realloc(items, n * sizeof(wchar_t*));
            if (!q) return false;
            items = q;
            cap = n;
        }
        size_t n = wcslen(s);
        wchar_t* copy = (wchar_t*)malloc((n + 1) * sizeof(wchar_t));
        if (!copy) return false;
        memcpy(copy, s, (n + 1) * sizeof(wchar_t));
        items[count++] = copy;
        return true;
    }
};

// 去掉首尾空白，写入 out（out 需足够大）
void TrimTo(const wchar_t* src, size_t n, wchar_t* out, size_t outCap)
{
    size_t b = 0, e = n;
    while (b < e && (src[b] == L' ' || src[b] == L'\t' || src[b] == L'\r' || src[b] == L'\n')) b++;
    while (e > b && (src[e - 1] == L' ' || src[e - 1] == L'\t' || src[e - 1] == L'\r' || src[e - 1] == L'\n')) e--;
    size_t len = e - b;
    if (len >= outCap) len = outCap - 1;
    memcpy(out, src + b, len * sizeof(wchar_t));
    out[len] = L'\0';
}

// ---------------------------------------------------------------- 定位管家

// 在目录里按优先级找主程序
bool BuildInstallAt(const wchar_t* dir, WStr* exeOut)
{
    if (!dir || !*dir || !DirExists(dir)) return false;
    wchar_t buf[MAX_PATH * 2];
    for (const wchar_t* candidate : kExecutableCandidates) {
        if (PathCombineW(buf, dir, candidate) == nullptr) continue;
        if (FileExists(buf)) {
            exeOut->Clear();
            exeOut->Append(buf);
            return true;
        }
    }
    return false;
}

// 从起始目录向上最多 8 层，找到含主程序的那一层
bool WalkUpToExecutable(const wchar_t* startDir, WStr* exeOut)
{
    if (!startDir) return false;
    wchar_t dir[MAX_PATH * 2];
    if (wcscpy_s(dir, ARRAYSIZE(dir), startDir) != 0) return false;

    for (int depth = 0; depth < 8 && dir[0]; depth++) {
        if (BuildInstallAt(dir, exeOut)) return true;
        if (!PathRemoveFileSpecW(dir)) break;   // 已到根
    }
    return false;
}

// 读 CLSID\InprocServer32 默认值，反推安装目录
bool FromComRegistration(const wchar_t* clsid, WStr* exeOut)
{
    const REGSAM views[] = { KEY_WOW64_64KEY, KEY_WOW64_32KEY };

    for (REGSAM view : views) {
        wchar_t subKey[256];
        swprintf_s(subKey, L"CLSID\\%s\\InprocServer32", clsid);

        HKEY key = nullptr;
        if (RegOpenKeyExW(HKEY_CLASSES_ROOT, subKey, 0, KEY_READ | view, &key) != ERROR_SUCCESS) continue;

        wchar_t raw[1024] = {};
        DWORD cb = sizeof(raw) - sizeof(wchar_t);
        DWORD type = 0;
        const LONG rc = RegQueryValueExW(key, nullptr, nullptr, &type, (BYTE*)raw, &cb);
        RegCloseKey(key);

        if (rc != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ)) continue;

        wchar_t modulePath[1024] = {};
        if (type == REG_EXPAND_SZ) {
            if (!ExpandEnvironmentStringsW(raw, modulePath, ARRAYSIZE(modulePath))) continue;
        } else {
            wcscpy_s(modulePath, raw);
        }

        // 去掉可能带的引号
        wchar_t* trimmed = modulePath;
        while (*trimmed == L' ' || *trimmed == L'"') trimmed++;
        size_t tl = wcslen(trimmed);
        while (tl > 0 && (trimmed[tl - 1] == L' ' || trimmed[tl - 1] == L'"')) trimmed[--tl] = L'\0';

        if (!FileExists(trimmed)) continue;

        wchar_t dir[MAX_PATH * 2];
        if (wcscpy_s(dir, ARRAYSIZE(dir), trimmed) != 0) continue;
        PathRemoveFileSpecW(dir);

        if (WalkUpToExecutable(dir, exeOut)) return true;
    }
    return false;
}

// 目录名按版本号降序（"6.2.1.0" > "6.2.0.9" > "其他"）
int CompareVersionDir(const wchar_t* a, const wchar_t* b)
{
    const wchar_t* names[2] = { a, b };
    int v[2][4] = {};

    for (int i = 0; i < 2; i++) {
        const wchar_t* s = names[i];
        for (int seg = 0; seg < 4 && *s; seg++) {
            long acc = 0;
            bool digit = false;
            while (*s >= L'0' && *s <= L'9') {
                acc = acc * 10 + (*s - L'0');
                if (acc > 1000000) acc = 1000000;
                s++;
                digit = true;
            }
            if (!digit) { v[i][seg] = 0; while (*s && *s != L'.') s++; }
            else v[i][seg] = (int)acc;
            if (*s == L'.') s++;
            else if (*s) { // 版本号后跟了非数字后缀，视为无效版本
                for (int k = 0; k < 4; k++) v[i][k] = 0;
                break;
            }
        }
    }

    for (int k = 0; k < 4; k++) {
        if (v[0][k] != v[1][k]) return v[1][k] - v[0][k];
    }
    return 0;
}

int CompareVersionDirProc(const void* a, const void* b)
{
    return CompareVersionDir(*(const wchar_t* const*)a, *(const wchar_t* const*)b);
}

// 兜底：扫常见安装根目录
bool FromWellKnownFolders(WStr* exeOut)
{
    const wchar_t* const variables[] = { L"ProgramFiles", L"ProgramFiles(x86)", L"LocalAppData" };
    WStr roots[8];
    int rootCount = 0;

    for (const wchar_t* var : variables) {
        wchar_t base[MAX_PATH * 2] = {};
        if (!GetEnvironmentVariableW(var, base, ARRAYSIZE(base)) || !base[0]) continue;

        wchar_t p[MAX_PATH * 2];
        if (rootCount < 8 && PathCombineW(p, base, L"MI\\XiaomiPCManager") != nullptr) {
            roots[rootCount++].Append(p);
        }
        if (rootCount < 8 && PathCombineW(p, base, L"Programs\\MI\\XiaomiPCManager") != nullptr) {
            roots[rootCount++].Append(p);
        }
    }

    for (int i = 0; i < rootCount; i++) {
        const wchar_t* root = roots[i].c_str();
        if (!DirExists(root)) continue;

        if (BuildInstallAt(root, exeOut)) return true;

        // 枚举版本子目录，按版本号降序试
        WIN32_FIND_DATAW fd = {};
        wchar_t combined[MAX_PATH * 2];
        PathCombineW(combined, root, L"*");
        HANDLE h = FindFirstFileW(combined, &fd);
        if (h == INVALID_HANDLE_VALUE) continue;

        PathList dirs;
        do {
            if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
            if (wcscmp(fd.cFileName, L".") == 0 || wcscmp(fd.cFileName, L"..") == 0) continue;
            wchar_t full[MAX_PATH * 2];
            if (PathCombineW(full, root, fd.cFileName)) dirs.Add(full);
        } while (FindNextFileW(h, &fd));
        FindClose(h);

        if (dirs.count > 0) {
            qsort(dirs.items, (size_t)dirs.count, sizeof(wchar_t*), CompareVersionDirProc);
            for (int d = 0; d < dirs.count; d++) {
                if (BuildInstallAt(dirs.items[d], exeOut)) return true;
            }
        }
    }

    return false;
}

bool LocateManager(WStr* exeOut)
{
    for (const wchar_t* clsid : kKnownShellClsids) {
        if (FromComRegistration(clsid, exeOut)) return true;
    }
    return FromWellKnownFolders(exeOut);
}

HWND FindMessageWindow()
{
    for (const wchar_t* cls : kMessageWindowClasses) {
        HWND h = FindWindowW(cls, nullptr);
        if (h) return h;
    }
    return nullptr;
}

// ---------------------------------------------------------------- 快捷方式

bool IsShortcut(const wchar_t* path)
{
    if (!path || !*path) return false;
    const size_t n = wcslen(path);
    return n >= 4 && _wcsicmp(path + n - 4, L".lnk") == 0;
}

bool IsValidTarget(const wchar_t* target)
{
    if (!target || !*target) return false;
    if (PathIsRelativeW(target) != FALSE) return false;
    return Exists(target);
}

// 解析单个 .lnk；失败返回 false
bool ResolveOne(const wchar_t* lnkPath, WStr* out)
{
    if (!FileExists(lnkPath)) return false;

    HRESULT hrInit = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    bool ownedApartment = false;
    if (hrInit == RPC_E_CHANGED_MODE) {
        // 已在另一种套间模型上初始化过，直接沿用
    } else if (hrInit == S_OK || hrInit == S_FALSE) {
        ownedApartment = true;
    } else {
        return false;
    }

    bool ok = false;
    IShellLinkW* link = nullptr;
    IPersistFile* persist = nullptr;

    do {
        if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                    IID_IShellLinkW, (void**)&link)) || !link) break;

        if (FAILED(link->QueryInterface(IID_IPersistFile, (void**)&persist)) || !persist) break;
        if (FAILED(persist->Load(lnkPath, STGM_READ))) break;

        wchar_t target[kPathBufferChars] = {};
        WIN32_FIND_DATAW fd = {};
        // 优先取文本路径（环境变量会被展开，网络位置优先 UNC）
        if (SUCCEEDED(link->GetPath(target, ARRAYSIZE(target), &fd, SLGP_UNCPRIORITY)) && IsValidTarget(target)) {
            out->Clear();
            out->Append(target);
            ok = true;
            break;
        }

        // 文本路径不可用时退回 PIDL
        PIDLIST_ABSOLUTE pidl = nullptr;
        if (SUCCEEDED(link->GetIDList(&pidl)) && pidl) {
            wchar_t fromPidl[kPathBufferChars] = {};
            if (SHGetPathFromIDListW(pidl, fromPidl) && IsValidTarget(fromPidl)) {
                out->Clear();
                out->Append(fromPidl);
                ok = true;
            }
            CoTaskMemFree(pidl);
        }
    } while (false);

    if (persist) persist->Release();
    if (link) link->Release();
    if (ownedApartment) CoUninitialize();
    return ok;
}

// 支持嵌套快捷方式，最多 5 层
bool ResolveShortcut(const wchar_t* path, WStr* out)
{
    if (!IsShortcut(path)) return false;

    wchar_t current[MAX_PATH * 2];
    if (wcscpy_s(current, ARRAYSIZE(current), path) != 0) return false;

    for (int depth = 0; depth < 5 && IsShortcut(current); depth++) {
        WStr next;
        if (!ResolveOne(current, &next)) return false;
        if (wcscpy_s(current, ARRAYSIZE(current), next.c_str()) != 0) return false;
    }

    if (IsShortcut(current)) return false;
    if (!IsValidTarget(current)) return false;

    out->Clear();
    out->Append(current);
    return true;
}

// ---------------------------------------------------------------- 发送

// 过滤真实存在的绝对路径，快捷方式解析为指向的目标，拼成管家认识的格式
void BuildPayload(const wchar_t* const* paths, int count, WStr* out)
{
    out->Clear();
    if (count == 0) return;

    for (int i = 0; i < count; i++) {
        const wchar_t* path = paths[i];
        if (!path) continue;
        if (PathIsRelativeW(path) != FALSE) continue;
        if (!Exists(path)) continue;

        WStr resolved;
        const wchar_t* effective = ResolveShortcut(path, &resolved) ? resolved.c_str() : path;

        if (out->len > 0) out->Append(L'|');
        out->Append(effective);
    }
}

bool TryStartManager(const wchar_t* exe, const wchar_t* arguments)
{
    if (!exe || !*exe) return false;
    HINSTANCE rc = ShellExecuteW(nullptr, L"open", exe, arguments, nullptr, SW_SHOWNORMAL);
    return (INT_PTR)rc > 32;
}

// 管家主程序大版本 >= 6 才支持共享内存通道
bool SupportsMappingChannel(const wchar_t* exe)
{
    DWORD handle = 0;
    DWORD size = GetFileVersionInfoSizeW(exe, &handle);
    if (!size) return false;

    void* data = malloc(size);
    if (!data) return false;

    bool supported = false;
    if (GetFileVersionInfoW(exe, 0, size, data)) {
        VS_FIXEDFILEINFO* info = nullptr;
        UINT infoLen = 0;
        if (VerQueryValueW(data, L"\\", (void**)&info, &infoLen) && info && infoLen >= sizeof(VS_FIXEDFILEINFO)) {
            supported = HIWORD(info->dwFileVersionMS) >= 6;
        }
    }

    free(data);
    return supported;
}

struct FindWindowContext {
    const wchar_t* title;
    HWND found;
};

// 只认「可见」的窗口：管家会预创建一个同标题的隐藏窗口，
// 如果只看标题存在，会让「发送成功」的判定变成假阳性
BOOL CALLBACK FindVisibleWindowProc(HWND hwnd, LPARAM param)
{
    FindWindowContext* context = (FindWindowContext*)param;
    if (!IsWindowVisible(hwnd)) return TRUE;

    wchar_t text[128] = {};
    if (GetWindowTextW(hwnd, text, ARRAYSIZE(text)) > 0 && wcscmp(text, context->title) == 0) {
        context->found = hwnd;
        return FALSE;
    }

    return TRUE;
}

bool FindVisibleWindowByTitle(const wchar_t* title)
{
    FindWindowContext context = { title, nullptr };
    EnumWindows(FindVisibleWindowProc, (LPARAM)&context);
    return context.found != nullptr;
}

bool WaitForShareWindow(DWORD timeoutMs)
{
    const DWORD deadline = GetTickCount() + timeoutMs;
    while ((int)(GetTickCount() - deadline) < 0) {
        if (FindVisibleWindowByTitle(kShareWindowTitle)) return true;
        Sleep(200);
    }
    return false;
}

HWND WaitForMessageWindow(DWORD timeoutMs)
{
    const DWORD deadline = GetTickCount() + timeoutMs;
    while ((int)(GetTickCount() - deadline) < 0) {
        HWND h = FindMessageWindow();
        if (h) return h;
        Sleep(250);
    }
    return nullptr;
}

bool SendPayload(HWND window, const wchar_t* payload, DWORD timeoutMs)
{
    COPYDATASTRUCT data = {};
    data.dwData = 0;
    data.cbData = (DWORD)(wcslen(payload) * sizeof(wchar_t));
    data.lpData = (void*)payload;

    DWORD_PTR result = 0;
    // fuFlags 传 0：管家一时没响应也继续等，不要立刻放弃
    const LRESULT rc = SendMessageTimeoutW(window, WM_COPYDATA, (WPARAM)1, (LPARAM)&data,
                                           0, timeoutMs, &result);
    return rc != 0;
}

// 6.0+ 通道：共享内存传路径 + 命令行参数启动管家
bool TrySendViaMapping(const wchar_t* exe, const wchar_t* payload)
{
    if (!SupportsMappingChannel(exe)) return false;

    const size_t bytes = (wcslen(payload) + 1) * sizeof(wchar_t);
    const DWORD size = (DWORD)(bytes > 0x10000 ? bytes : 0x10000);

    HANDLE mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, size, kMappingName);
    if (!mapping) return false;

    void* view = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, 0);
    if (!view) {
        CloseHandle(mapping);
        return false;
    }

    memcpy(view, payload, bytes);

    const bool started = TryStartManager(exe, kMappingArgument);
    bool ok = false;
    if (started && WaitForShareWindow(kWindowWaitMs)) {
        // 留一点时间让管家把映射内容读走
        Sleep(1000);
        ok = true;
    }

    UnmapViewOfFile(view);
    CloseHandle(mapping);
    return ok;
}

bool SendFiles(const wchar_t* const* paths, int count)
{
    WStr payload;
    BuildPayload(paths, count, &payload);
    if (payload.len == 0) return false;

    WStr exe;
    if (!LocateManager(&exe)) return false;

    // 6.0+ 优先走共享内存通道；失败时回落到 5.x 的 WM_COPYDATA
    if (TrySendViaMapping(exe.c_str(), payload.c_str())) return true;

    HWND window = FindMessageWindow();
    if (!window) {
        if (!TryStartManager(exe.c_str(), nullptr)) return false;
        window = WaitForMessageWindow(kWindowWaitMs);
        if (!window) return false;
    }

    return SendPayload(window, payload.c_str(), kCopyDataTimeoutMs);
}

// ---------------------------------------------------------------- 信箱

// 信箱目录：%LOCALAPPDATA%\MiShareMenu\queue（out 需能放下 MAX_PATH * 2）
void GetQueueDirectory(wchar_t* out)
{
    wchar_t base[MAX_PATH * 2] = {};
    if (!GetEnvironmentVariableW(L"LocalAppData", base, ARRAYSIZE(base))) {
        SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr, 0, base);
    }
    PathCombineW(out, base, L"MiShareMenu\\queue");
}

bool IsHexKey(const wchar_t* key)
{
    if (!key || wcslen(key) != 32) return false;
    for (const wchar_t* p = key; *p; p++) {
        if (!((*p >= L'0' && *p <= L'9') || (*p >= L'a' && *p <= L'f') || (*p >= L'A' && *p <= L'F'))) return false;
    }
    return true;
}

// 读 UTF-8 文本（写端是 .NET File.WriteAllText，带 BOM），按行拆成路径列表
bool Dequeue(const wchar_t* key, PathList* out)
{
    if (!IsHexKey(key)) return false;

    wchar_t dir[MAX_PATH * 2];
    GetQueueDirectory(dir);

    wchar_t file[MAX_PATH * 2];
    if (!PathCombineW(file, dir, key)) return false;
    if (!FileExists(file)) return false;

    HANDLE h = CreateFileW(file, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;

    LARGE_INTEGER size = {};
    GetFileSizeEx(h, &size);
    if (size.QuadPart <= 0 || size.QuadPart > (4LL << 20)) {
        CloseHandle(h);
        return false;
    }

    const DWORD bytes = (DWORD)size.QuadPart;
    char* raw = (char*)malloc(bytes + 1);
    if (!raw) {
        CloseHandle(h);
        return false;
    }

    DWORD got = 0;
    const BOOL read = ReadFile(h, raw, bytes, &got, nullptr);
    CloseHandle(h);
    if (!read) {
        free(raw);
        return false;
    }
    raw[got] = '\0';

    // 跳过 UTF-8 BOM
    const char* text = raw;
    DWORD textLen = got;
    if (textLen >= 3 && (unsigned char)text[0] == 0xEF && (unsigned char)text[1] == 0xBB && (unsigned char)text[2] == 0xBF) {
        text += 3;
        textLen -= 3;
    }

    const int wideLen = MultiByteToWideChar(CP_UTF8, 0, text, (int)textLen, nullptr, 0);
    if (wideLen <= 0) {
        free(raw);
        return false;
    }

    wchar_t* wide = (wchar_t*)malloc((wideLen + 1) * sizeof(wchar_t));
    if (!wide) {
        free(raw);
        return false;
    }
    MultiByteToWideChar(CP_UTF8, 0, text, (int)textLen, wide, wideLen);
    wide[wideLen] = L'\0';
    free(raw);

    // 拆行 + 去空白 + 空行丢弃
    wchar_t* cursor = wide;
    while (*cursor) {
        wchar_t* start = cursor;
        while (*cursor && *cursor != L'\n') cursor++;
        const size_t chunk = (size_t)(cursor - start);

        // 比缓冲还长的行直接跳过：宁可漏发，也不要把截断后的错路径当成文件发出去
        wchar_t trimmed[MAX_PATH * 2];
        if (chunk < ARRAYSIZE(trimmed)) {
            TrimTo(start, chunk, trimmed, ARRAYSIZE(trimmed));
            if (trimmed[0]) out->Add(trimmed);
        }

        if (*cursor == L'\n') cursor++;
    }
    free(wide);

    DeleteFileW(file);
    return true;
}

// ---------------------------------------------------------------- 参数与入口

void ShowError(const wchar_t* message)
{
    MessageBoxW(nullptr, message, kCaption, MB_ICONWARNING | MB_TOPMOST);
}

int FailNotInstalled()
{
    MessageBoxW(nullptr,
                L"没有检测到「小米电脑管家」。\n请先安装小米电脑管家（或小米互联服务），再使用此功能。",
                kCaption, MB_ICONWARNING | MB_TOPMOST);
    return 5;
}

// --send 的值按 | 拆成多个路径
void SplitSendArgs(const wchar_t* value, PathList* out)
{
    const wchar_t* p = value;
    while (*p) {
        const wchar_t* sep = wcschr(p, L'|');
        const size_t chunk = sep ? (size_t)(sep - p) : wcslen(p);

        // 同 Dequeue：超长项跳过，不做截断
        wchar_t trimmed[MAX_PATH * 2];
        if (chunk < ARRAYSIZE(trimmed)) {
            TrimTo(p, chunk, trimmed, ARRAYSIZE(trimmed));
            if (trimmed[0]) out->Add(trimmed);
        }

        if (!sep) break;
        p = sep + 1;
    }
}

int Run(int argc, wchar_t** argv)
{
    WStr queueKey;
    PathList directPaths;
    bool hasQueue = false;
    bool hasSend = false;

    for (int i = 1; i < argc; i++) {
        if (wcscmp(argv[i], L"--queue") == 0 && i + 1 < argc) {
            hasQueue = true;
            queueKey.Append(argv[++i]);
            break;
        }
        if (wcscmp(argv[i], L"--send") == 0 && i + 1 < argc) {
            hasSend = true;
            SplitSendArgs(argv[++i], &directPaths);
            break;
        }
    }

    // 两个开关都没命中却带了参数 → 参数错误
    if (!hasQueue && !hasSend) {
        if (argc > 1) {
            MessageBoxW(nullptr, L"参数不正确。", kCaption, MB_ICONWARNING | MB_TOPMOST);
            return 2;
        }

        // 从开始菜单 / 应用列表冷启动：只负责把管家叫起来
        WStr exe;
        if (!LocateManager(&exe)) return FailNotInstalled();
        return TryStartManager(exe.c_str(), nullptr) ? 0 : FailNotInstalled();
    }

    if (hasQueue) {
        Dequeue(queueKey.c_str(), &directPaths);
    }

    if (directPaths.count == 0) {
        ShowError(L"要发送的文件已经不存在了，请重新从右键菜单发送。");
        return 3;
    }

    WStr exe;
    if (!LocateManager(&exe)) return FailNotInstalled();

    if (SendFiles((const wchar_t* const*)directPaths.items, directPaths.count)) return 0;

    ShowError(L"连接小米电脑管家失败。\n请先在任务栏打开「小米电脑管家」，再重试一次。");
    return 4;
}

} // namespace

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, PWSTR, int)
{
    int argc = 0;
    wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) return 1;

    const int code = Run(argc, argv);
    LocalFree(argv);
    return code;
}

