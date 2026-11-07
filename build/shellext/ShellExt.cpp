// MiShare.ShellExt
//
// Win11 右键菜单「使用小米互传发送」的进程内 COM 服务器：
//
//   DllGetClassObject / DllCanUnloadNow           —— 模块入口
//   IExplorerCommand                              —— 菜单项标题、图标、可用性与点击
//   IObjectWithSite                               —— 经典菜单宿主会探测
//   IClassFactory                                 —— 类工厂
//
// 这里只做「读路径 → 写信箱 → 拉起发送进程」，等待与投递都交给 MiShare.Launcher.exe，
// 避免拖住资源管理器。

#define _WIN32_WINNT 0x0A00

#include <windows.h>
#include <objbase.h>
#include <ocidl.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <shlwapi.h>

#include <cstdlib>
#include <cstring>
#include <new>

// 自带 operator new / delete：只为这几处分配把静态 libstdc++ 整库链进来不划算
void* operator new(size_t size) { return malloc(size); }
void* operator new(size_t size, const std::nothrow_t&) noexcept { return malloc(size); }
void operator delete(void* p) noexcept { free(p); }
void operator delete(void* p, const std::nothrow_t&) noexcept { free(p); }
void operator delete(void* p, size_t) noexcept { free(p); }

// ---------------------------------------------------------------- 常量

namespace {

const wchar_t* const kMenuTitle = L"使用小米互传发送";
const wchar_t* const kToolTip = L"把选中的文件发送到小米手机、平板或电脑";

// 本扩展自身的 COM 类标识（与 AppxManifest 里登记的一致，不可改）
const GUID kClsid = { 0x8F3A6B21, 0x4C7D, 0x4E9A, { 0x9F, 0x52, 0x1D, 0x6E, 0x7B, 0x0C, 0x3A, 0x84 } };

// 经典菜单（显示更多选项）宿主在 GetState 之前探测的两个私有接口。
// 一级菜单（Win11 现代菜单）从不请求它们 —— 用它区分一级 / 二级调用。
// 探测不到时退化为「二级也显示」，最坏只是多一条菜单，不会丢功能。
const GUID kClassicProbe1 = { 0xD51836B4, 0x8B5A, 0x4E11, { 0x8F, 0x97, 0xD4, 0x89, 0xBD, 0x4B, 0x28, 0xC0 } };
const GUID kClassicProbe2 = { 0x1C9CD5BB, 0x98E9, 0x4491, { 0xA6, 0x0F, 0x31, 0xAA, 0xCC, 0x72, 0xB8, 0x3C } };

// 小米互传右键菜单组件在历史版本里用过的 CLSID（5.x / 4.x）
const wchar_t* const kKnownShellClsids[] = {
    L"{504D69C0-CB52-48DF-B5B5-7161829FABC8}", // 5.x
    L"{1BCA9901-05C3-4D01-8AD4-78DA2EAC9B3F}", // 4.x
};

// 管家主程序候选，按优先级
const wchar_t* const kExecutableCandidates[] = { L"hyperConnect.exe", L"MiPcContinuity.exe", L"XiaomiPcManager.exe" };

const wchar_t* const kLauncherFolder = L"Launcher";
const wchar_t* const kLauncherName = L"MiShare.Launcher.exe";

const int kPathChars = 1024;
const int kMaxItems = 4096;
const DWORD kLocateCacheMs = 30000;
const ULONGLONG kQueueMaxAge100ns = 6000000000ULL;   // 10 分钟

// ---------------------------------------------------------------- 生命周期计数

LONG g_liveObjects = 0;
LONG g_factoryLocks = 0;

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

// 简单的宽字符缓冲，避免引入 STL 把产物撑大
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
        const size_t n = wcslen(s);
        wchar_t* copy = (wchar_t*)malloc((n + 1) * sizeof(wchar_t));
        if (!copy) return false;
        memcpy(copy, s, (n + 1) * sizeof(wchar_t));
        items[count++] = copy;
        return true;
    }
};

// 去掉首尾空白，写入 out（调用方保证容量）
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

// ---------------------------------------------------------------- 注册表（裸 Win32）

// 读 HKEY_CLASSES_ROOT 下的字符串值；两个位宽视图都试。
// 只读、不写 —— 本扩展的 COM 注册由 MSIX 清单声明，部署时由系统落盘。
bool ReadClassesString(const wchar_t* subKey, const wchar_t* valueName, wchar_t* out, DWORD outChars)
{
    const REGSAM views[] = { KEY_WOW64_64KEY, KEY_WOW64_32KEY };

    for (REGSAM view : views) {
        HKEY key = nullptr;
        if (RegOpenKeyExW(HKEY_CLASSES_ROOT, subKey, 0, KEY_READ | view, &key) != ERROR_SUCCESS) continue;

        wchar_t raw[kPathChars * 2] = {};
        DWORD cb = (DWORD)sizeof(raw) - (DWORD)sizeof(wchar_t);
        DWORD type = 0;
        const LONG rc = RegQueryValueExW(key, valueName, nullptr, &type, (BYTE*)raw, &cb);
        RegCloseKey(key);

        if (rc != ERROR_SUCCESS) continue;
        if (type != REG_SZ && type != REG_EXPAND_SZ) continue;
        if (!raw[0]) continue;

        if (type == REG_EXPAND_SZ) {
            if (!ExpandEnvironmentStringsW(raw, out, outChars)) continue;
        } else {
            if (wcslen(raw) >= (size_t)outChars) continue;
            wcscpy_s(out, outChars, raw);
        }
        return true;
    }

    return false;
}

// 管家自己是否注册了「小米互传」菜单（5.x / 6.x 都会写这个键）。
bool HasOfficialContextMenu()
{
    const wchar_t* const verbs[] = { L"*\\shell\\MiDropExtMenu", L"Directory\\shell\\MiDropExtMenu" };

    for (const wchar_t* verb : verbs) {
        wchar_t handler[kPathChars] = {};
        if (ReadClassesString(verb, L"ExplorerCommandHandler", handler, ARRAYSIZE(handler)) && handler[0]) {
            return true;
        }
    }

    return false;
}

// ---------------------------------------------------------------- 定位管家

struct InstallInfo {
    WStr root;
    WStr exe;
    WStr icon;
    bool found;

    InstallInfo() : found(false) {}
};

// 图标：5.x 及更早在安装目录 Assets 下；6.0 起挪到 MiSmartShare 子目录
void ResolveIcon(const wchar_t* dir, const wchar_t* exe, WStr* out)
{
    wchar_t p[MAX_PATH * 2];

    if (PathCombineW(p, dir, L"Assets\\midrop_logo.ico") && FileExists(p)) {
        out->Clear();
        out->Append(p);
        return;
    }
    if (PathCombineW(p, dir, L"MiSmartShare\\Assets\\midrop_logo.ico") && FileExists(p)) {
        out->Clear();
        out->Append(p);
        return;
    }

    // 兜底：扫一层子目录的 Assets\midrop_logo.ico，覆盖未来新增的组件目录
    wchar_t pattern[MAX_PATH * 2];
    if (PathCombineW(pattern, dir, L"*")) {
        WIN32_FIND_DATAW fd = {};
        HANDLE h = FindFirstFileW(pattern, &fd);
        if (h != INVALID_HANDLE_VALUE) {
            do {
                if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
                if (wcscmp(fd.cFileName, L".") == 0 || wcscmp(fd.cFileName, L"..") == 0) continue;

                wchar_t sub[MAX_PATH * 2];
                wchar_t ico[MAX_PATH * 2];
                if (!PathCombineW(sub, dir, fd.cFileName)) continue;
                if (!PathCombineW(ico, sub, L"Assets\\midrop_logo.ico")) continue;
                if (FileExists(ico)) {
                    out->Clear();
                    out->Append(ico);
                    FindClose(h);
                    return;
                }
            } while (FindNextFileW(h, &fd));
            FindClose(h);
        }
    }

    // 再找不到就用主程序图标（"路径,0" 是 shell 认的资源引用写法）
    out->Clear();
    out->Append(exe);
    out->Append(L",0");
}

bool BuildInstallAt(const wchar_t* dir, InstallInfo* out)
{
    if (!dir || !*dir || !DirExists(dir)) return false;

    wchar_t buf[MAX_PATH * 2];
    for (const wchar_t* candidate : kExecutableCandidates) {
        if (!PathCombineW(buf, dir, candidate)) continue;
        if (!FileExists(buf)) continue;

        out->root.Clear();
        out->root.Append(dir);
        out->exe.Clear();
        out->exe.Append(buf);
        ResolveIcon(dir, buf, &out->icon);
        out->found = true;
        return true;
    }

    return false;
}

// 从起始目录向上最多 8 层，找到含主程序的那一层
bool WalkUpToExecutable(const wchar_t* startDir, InstallInfo* out)
{
    if (!startDir) return false;

    wchar_t dir[MAX_PATH * 2];
    wcscpy_s(dir, startDir);

    for (int depth = 0; depth < 8 && dir[0]; depth++) {
        if (BuildInstallAt(dir, out)) return true;
        if (!PathRemoveFileSpecW(dir)) break;
    }

    return false;
}

// 读 CLSID\InprocServer32 默认值，反推安装目录
bool FromComRegistration(const wchar_t* clsid, InstallInfo* out)
{
    wchar_t subKey[256];
    wcscpy_s(subKey, L"CLSID\\");
    wcscat_s(subKey, clsid);
    wcscat_s(subKey, L"\\InprocServer32");

    wchar_t modulePath[kPathChars] = {};
    if (!ReadClassesString(subKey, nullptr, modulePath, ARRAYSIZE(modulePath))) return false;

    // 去引号 / 空白
    wchar_t* trimmed = modulePath;
    while (*trimmed == L' ' || *trimmed == L'"') trimmed++;
    size_t tl = wcslen(trimmed);
    while (tl > 0 && (trimmed[tl - 1] == L' ' || trimmed[tl - 1] == L'"')) trimmed[--tl] = L'\0';
    if (!FileExists(trimmed)) return false;

    wchar_t dir[MAX_PATH * 2];
    wcscpy_s(dir, trimmed);
    PathRemoveFileSpecW(dir);

    return WalkUpToExecutable(dir, out);
}

// 目录名按版本号降序："6.2.1.0" > "6.2.0.9" > "其他"
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
            if (!digit) {
                v[i][seg] = 0;
                while (*s && *s != L'.') s++;
            } else {
                v[i][seg] = (int)acc;
            }
            if (*s == L'.') {
                s++;
            } else if (*s) {
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

// 兜底：扫常见安装根目录下的版本子目录，取版本号最大者
bool FromWellKnownFolders(InstallInfo* out)
{
    const wchar_t* const variables[] = { L"ProgramFiles", L"ProgramFiles(x86)", L"LocalAppData" };
    WStr roots[8];
    int rootCount = 0;

    for (const wchar_t* var : variables) {
        wchar_t base[MAX_PATH * 2] = {};
        if (!GetEnvironmentVariableW(var, base, ARRAYSIZE(base)) || !base[0]) continue;

        wchar_t p[MAX_PATH * 2];
        if (rootCount < 8 && PathCombineW(p, base, L"MI\\XiaomiPCManager")) roots[rootCount++].Append(p);
        if (rootCount < 8 && PathCombineW(p, base, L"Programs\\MI\\XiaomiPCManager")) roots[rootCount++].Append(p);
    }

    for (int i = 0; i < rootCount; i++) {
        const wchar_t* root = roots[i].c_str();
        if (!DirExists(root)) continue;

        if (BuildInstallAt(root, out)) return true;

        WIN32_FIND_DATAW fd = {};
        wchar_t pattern[MAX_PATH * 2];
        if (!PathCombineW(pattern, root, L"*")) continue;

        HANDLE h = FindFirstFileW(pattern, &fd);
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
                if (BuildInstallAt(dirs.items[d], out)) return true;
            }
        }
    }

    return false;
}

// 定位结果缓存：菜单每次展示都会问一遍，别每次都翻注册表和目录
SRWLOCK g_locateLock = SRWLOCK_INIT;
InstallInfo g_locateCache;
DWORD g_locateStamp = 0;
bool g_locateCached = false;

bool LocateManager(InstallInfo* out)
{
    AcquireSRWLockExclusive(&g_locateLock);

    const DWORD now = GetTickCount();
    if (!g_locateCached || (DWORD)(now - g_locateStamp) >= kLocateCacheMs) {
        g_locateCache.found = false;
        for (const wchar_t* clsid : kKnownShellClsids) {
            if (FromComRegistration(clsid, &g_locateCache)) break;
        }
        if (!g_locateCache.found) FromWellKnownFolders(&g_locateCache);

        g_locateStamp = now;
        g_locateCached = true;
    }

    const bool found = g_locateCache.found;
    if (found && out) {
        out->found = true;
        out->root.Clear();
        out->root.Append(g_locateCache.root.c_str());
        out->exe.Clear();
        out->exe.Append(g_locateCache.exe.c_str());
        out->icon.Clear();
        out->icon.Append(g_locateCache.icon.c_str());
    }

    ReleaseSRWLockExclusive(&g_locateLock);
    return found;
}

// ---------------------------------------------------------------- 信箱（与 Launcher 的取件契约）

// 信箱目录：%LOCALAPPDATA%\MiShareMenu\queue（out 需能放下 MAX_PATH * 2）
void GetQueueDirectory(wchar_t* out)
{
    wchar_t base[MAX_PATH * 2] = {};
    if (!GetEnvironmentVariableW(L"LocalAppData", base, ARRAYSIZE(base))) {
        SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr, 0, base);
    }
    PathCombineW(out, base, L"MiShareMenu\\queue");
}

void NewQueueKey(wchar_t* out)
{
    static const wchar_t* const kHex = L"0123456789abcdef";

    BYTE bytes[16] = {};
    GUID guid = {};
    if (SUCCEEDED(CoCreateGuid(&guid))) {
        memcpy(bytes, &guid, sizeof(bytes));
    } else {
        // 极少数情况下 COM 没起来，退回计数器凑 16 字节（两端只校验长度与十六进制）
        LARGE_INTEGER perf = {};
        QueryPerformanceCounter(&perf);
        ULONGLONG mix = (ULONGLONG)perf.QuadPart ^ ((ULONGLONG)GetTickCount64() << 17) ^ (ULONGLONG)GetCurrentProcessId();
        for (int i = 0; i < 8; i++) bytes[i] = (BYTE)(mix >> (i * 8));
        for (int i = 0; i < 8; i++) bytes[8 + i] = (BYTE)((mix * 6364136223846793005ULL) >> (i * 8));
    }

    for (int i = 0; i < 16; i++) {
        out[i * 2] = kHex[bytes[i] >> 4];
        out[i * 2 + 1] = kHex[bytes[i] & 0x0F];
    }
    out[32] = L'\0';
}

void CleanupQueue(const wchar_t* dir)
{
    wchar_t pattern[MAX_PATH * 2];
    if (!PathCombineW(pattern, dir, L"*")) return;

    WIN32_FIND_DATAW fd = {};
    HANDLE h = FindFirstFileW(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE) return;

    FILETIME now = {};
    GetSystemTimeAsFileTime(&now);

    ULARGE_INTEGER b;
    b.LowPart = now.dwLowDateTime;
    b.HighPart = now.dwHighDateTime;

    do {
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;

        ULARGE_INTEGER a;
        a.LowPart = fd.ftLastWriteTime.dwLowDateTime;
        a.HighPart = fd.ftLastWriteTime.dwHighDateTime;

        if (b.QuadPart > a.QuadPart && (b.QuadPart - a.QuadPart) > kQueueMaxAge100ns) {
            wchar_t victim[MAX_PATH * 2];
            if (PathCombineW(victim, dir, fd.cFileName)) DeleteFileW(victim);
        }
    } while (FindNextFileW(h, &fd));

    FindClose(h);
}

// 去空、去重（忽略大小写）、只留完全限定的绝对路径
void NormalizePaths(const PathList* input, PathList* out)
{
    for (int i = 0; i < input->count; i++) {
        if (!input->items[i]) continue;

        const size_t rawLen = wcslen(input->items[i]);
        if (rawLen >= (size_t)kPathChars) continue;   // 超出缓冲的路径直接丢弃，不做截断

        wchar_t trimmed[kPathChars];
        TrimTo(input->items[i], rawLen, trimmed, ARRAYSIZE(trimmed));
        if (!trimmed[0]) continue;
        if (PathIsRelativeW(trimmed) != FALSE) continue;

        bool duplicate = false;
        for (int j = 0; j < out->count; j++) {
            if (_wcsicmp(out->items[j], trimmed) == 0) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) out->Add(trimmed);
    }
}

bool WriteQueueFile(const wchar_t* dir, const wchar_t* key, const PathList* items)
{
    wchar_t file[MAX_PATH * 2];
    if (!PathCombineW(file, dir, key)) return false;

    WStr joined;
    for (int i = 0; i < items->count; i++) {
        if (i > 0) joined.Append(L'\n');
        joined.Append(items->items[i]);
    }

    const int wideLen = (int)joined.len;
    const int byteLen = WideCharToMultiByte(CP_UTF8, 0, joined.c_str(), wideLen, nullptr, 0, nullptr, nullptr);
    if (byteLen <= 0) return false;

    char* utf8 = (char*)malloc((size_t)byteLen);
    if (!utf8) return false;
    WideCharToMultiByte(CP_UTF8, 0, joined.c_str(), wideLen, utf8, byteLen, nullptr, nullptr);

    HANDLE h = CreateFileW(file, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) {
        free(utf8);
        return false;
    }

    DWORD written = 0;
    const BOOL ok = WriteFile(h, utf8, (DWORD)byteLen, &written, nullptr);
    CloseHandle(h);
    free(utf8);

    if (!ok || written != (DWORD)byteLen) {
        DeleteFileW(file);
        return false;
    }

    return true;
}

bool Enqueue(const PathList* rawPaths, wchar_t* keyOut)
{
    PathList normalized;
    NormalizePaths(rawPaths, &normalized);
    if (normalized.count == 0) return false;

    wchar_t dir[MAX_PATH * 2];
    GetQueueDirectory(dir);
    SHCreateDirectoryExW(nullptr, dir, nullptr);
    if (!DirExists(dir)) return false;

    CleanupQueue(dir);

    NewQueueKey(keyOut);
    return WriteQueueFile(dir, keyOut, &normalized);
}

// ---------------------------------------------------------------- 拉起发送进程

typedef LONG(WINAPI* PFN_GetCurrentPackagePath)(UINT32*, PWSTR);

// 取当前包（MSIX）的安装根目录；未以打包身份运行时返回 false
bool GetPackageRoot(wchar_t* out, DWORD capChars)
{
    static PFN_GetCurrentPackagePath getPath = (PFN_GetCurrentPackagePath)(void*)GetProcAddress(
        GetModuleHandleW(L"kernel32.dll"), "GetCurrentPackagePath");
    if (!getPath) return false;

    UINT32 length = 0;
    getPath(&length, nullptr);
    if (length == 0 || length > 32768) return false;

    wchar_t* buffer = (wchar_t*)malloc((size_t)length * sizeof(wchar_t));
    if (!buffer) return false;

    bool ok = false;
    if (getPath(&length, buffer) == ERROR_SUCCESS) {
        // 返回的长度包含结尾 NUL；按实际字符串长度收尾，避免吃掉路径末字符
        size_t len = wcsnlen(buffer, (size_t)length - 1);
        while (len > 0 && buffer[len - 1] == L'\\') len--;
        buffer[len] = L'\0';
        if (len > 0 && len < (size_t)capChars && DirExists(buffer)) {
            wcscpy_s(out, capChars, buffer);
            ok = true;
        }
    }

    free(buffer);
    return ok;
}

// 承载本 DLL 的模块所在目录
bool GetModuleDirectory(wchar_t* out, DWORD capChars)
{
    HMODULE module = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            (LPCWSTR)(void*)&GetModuleDirectory, &module) || !module) {
        return false;
    }

    wchar_t path[MAX_PATH * 2] = {};
    const DWORD written = GetModuleFileNameW(module, path, ARRAYSIZE(path));
    if (written == 0 || written >= ARRAYSIZE(path)) return false;

    if (!PathRemoveFileSpecW(path)) return false;
    if (wcslen(path) >= (size_t)capChars) return false;
    wcscpy_s(out, capChars, path);
    return true;
}

bool ResolveLauncherPath(WStr* out)
{
    wchar_t root[32768];
    wchar_t candidate[MAX_PATH * 2];

    if (GetPackageRoot(root, ARRAYSIZE(root))) {
        if (PathCombineW(candidate, root, L"Launcher\\MiShare.Launcher.exe") && FileExists(candidate)) {
            out->Clear();
            out->Append(candidate);
            return true;
        }
    }

    wchar_t moduleDir[MAX_PATH * 2];
    if (GetModuleDirectory(moduleDir, ARRAYSIZE(moduleDir))) {
        // ShellExt\MiShare.ShellExt.dll -> ..\Launcher\MiShare.Launcher.exe
        if (PathCombineW(candidate, moduleDir, L"..\\Launcher\\MiShare.Launcher.exe")) {
            wchar_t full[MAX_PATH * 2];
            if (PathCanonicalizeW(full, candidate) && FileExists(full)) {
                out->Clear();
                out->Append(full);
                return true;
            }
        }
    }

    wchar_t overrideRoot[MAX_PATH * 2] = {};
    if (GetEnvironmentVariableW(L"MISHARE_ROOT", overrideRoot, ARRAYSIZE(overrideRoot))) {
        if (PathCombineW(candidate, overrideRoot, L"Launcher\\MiShare.Launcher.exe") && FileExists(candidate)) {
            out->Clear();
            out->Append(candidate);
            return true;
        }
    }

    return false;
}

bool StartSender(const wchar_t* key)
{
    WStr launcher;
    if (!ResolveLauncherPath(&launcher)) return false;

    WStr command;
    command.Append(L'"');
    command.Append(launcher.c_str());
    command.Append(L"\" --queue ");
    command.Append(key);

    // CreateProcessW 会就地改写命令行，必须给可写缓冲区
    wchar_t* mutableCmd = (wchar_t*)malloc((command.len + 1) * sizeof(wchar_t));
    if (!mutableCmd) return false;
    memcpy(mutableCmd, command.c_str(), (command.len + 1) * sizeof(wchar_t));

    STARTUPINFOW si = {};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi = {};

    const BOOL ok = CreateProcessW(launcher.c_str(), mutableCmd, nullptr, nullptr, FALSE,
                                   CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
                                   nullptr, nullptr, &si, &pi);
    free(mutableCmd);

    if (!ok) return false;

    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return true;
}

// ---------------------------------------------------------------- 从 IShellItemArray 抠路径

void CollectPaths(IShellItemArray* items, PathList* out)
{
    if (!items) return;

    DWORD count = 0;
    if (FAILED(items->GetCount(&count)) || count == 0) return;
    if (count > (DWORD)kMaxItems) count = (DWORD)kMaxItems;

    for (DWORD i = 0; i < count; i++) {
        IShellItem* item = nullptr;
        if (FAILED(items->GetItemAt(i, &item)) || !item) continue;

        LPWSTR name = nullptr;
        if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &name)) && name) {
            if (*name) out->Add(name);
            CoTaskMemFree(name);
        }

        item->Release();
    }
}

// ---------------------------------------------------------------- COM 对象

class Command final : public IExplorerCommand, public IObjectWithSite
{
public:
    Command() : ref_(1), site_(nullptr), classicHint_(0) { InterlockedIncrement(&g_liveObjects); }
    ~Command()
    {
        if (site_) {
            site_->Release();
            site_ = nullptr;
        }
        InterlockedDecrement(&g_liveObjects);
    }

    // ---- IUnknown ----

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override
    {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;

        if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_IExplorerCommand)) {
            *ppv = static_cast<IExplorerCommand*>(this);
        } else if (IsEqualIID(riid, IID_IObjectWithSite)) {
            *ppv = static_cast<IObjectWithSite*>(this);
        } else {
            // 经典菜单宿主在 GetState 前会探测这两个私有接口：记下来供 GetState 判断层级，
            // 但仍按「不实现」返回（与官方行为一致）
            if (IsEqualIID(riid, kClassicProbe1) || IsEqualIID(riid, kClassicProbe2)) classicHint_ = 1;
            return E_NOINTERFACE;
        }

        AddRefImpl();
        return S_OK;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return AddRefImpl(); }
    ULONG STDMETHODCALLTYPE Release() override { return ReleaseImpl(); }

    // ---- IExplorerCommand ----

    HRESULT STDMETHODCALLTYPE GetTitle(IShellItemArray*, LPWSTR* name) override
    {
        if (!name) return E_POINTER;
        return SHStrDupW(kMenuTitle, name);
    }

    HRESULT STDMETHODCALLTYPE GetIcon(IShellItemArray*, LPWSTR* icon) override
    {
        if (!icon) return E_POINTER;
        *icon = nullptr;

        InstallInfo info;
        // 取不到图标就返回失败码，绝不外流空串指针：上层会拿它做字符串比较
        if (!LocateManager(&info) || !info.icon.c_str()[0]) return E_FAIL;

        return SHStrDupW(info.icon.c_str(), icon);
    }

    HRESULT STDMETHODCALLTYPE GetToolTip(IShellItemArray*, LPWSTR* tip) override
    {
        if (!tip) return E_POINTER;
        return SHStrDupW(kToolTip, tip);
    }

    HRESULT STDMETHODCALLTYPE GetCanonicalName(GUID* name) override
    {
        if (!name) return E_POINTER;
        *name = kClsid;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetState(IShellItemArray*, WINBOOL, EXPCMDSTATE* state) override
    {
        if (!state) return E_POINTER;

        // 没装管家就干脆不出现，避免点了没反应的死菜单。
        // 二级菜单（经典菜单）在官方已注册同名项时让位，避免两条重名。
        const bool installed = LocateManager(nullptr);
        const bool hideInClassic = classicHint_ != 0 && HasOfficialContextMenu();

        *state = (installed && !hideInClassic) ? ECS_ENABLED : ECS_HIDDEN;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE Invoke(IShellItemArray* items, IBindCtx*) override
    {
        // 这里跑在 COM 代理进程（dllhost）里，必须尽快返回，否则资源管理器会判超时。
        // 所以只做「写信箱 + 拉起发送进程」，等待与投递全交给 Launcher。
        PathList paths;
        CollectPaths(items, &paths);
        if (paths.count == 0) return E_FAIL;

        wchar_t key[33] = {};
        if (!Enqueue(&paths, key)) return E_FAIL;

        return StartSender(key) ? S_OK : E_FAIL;
    }

    HRESULT STDMETHODCALLTYPE GetFlags(EXPCMDFLAGS* flags) override
    {
        if (!flags) return E_POINTER;
        *flags = ECF_DEFAULT;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE EnumSubCommands(IEnumExplorerCommand** enumerator) override
    {
        if (enumerator) *enumerator = nullptr;
        return E_NOTIMPL;
    }

    // ---- IObjectWithSite ----

    HRESULT STDMETHODCALLTYPE SetSite(IUnknown* site) override
    {
        if (site) site->AddRef();
        if (site_) site_->Release();
        site_ = site;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetSite(REFIID riid, void** site) override
    {
        if (!site) return E_POINTER;
        *site = nullptr;
        if (!site_) return E_FAIL;
        return site_->QueryInterface(riid, site);
    }

private:
    ULONG AddRefImpl() { return (ULONG)InterlockedIncrement(&ref_); }

    ULONG ReleaseImpl()
    {
        const LONG remaining = InterlockedDecrement(&ref_);
        if (remaining == 0) delete this;
        return (ULONG)(remaining > 0 ? remaining : 0);
    }

    LONG ref_;
    IUnknown* site_;
    LONG classicHint_;
};

class Factory final : public IClassFactory
{
public:
    Factory() : ref_(1) { InterlockedIncrement(&g_liveObjects); }
    ~Factory() { InterlockedDecrement(&g_liveObjects); }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override
    {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;

        if (!IsEqualIID(riid, IID_IUnknown) && !IsEqualIID(riid, IID_IClassFactory)) return E_NOINTERFACE;

        *ppv = static_cast<IClassFactory*>(this);
        AddRef();
        return S_OK;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG)InterlockedIncrement(&ref_); }

    ULONG STDMETHODCALLTYPE Release() override
    {
        const LONG remaining = InterlockedDecrement(&ref_);
        if (remaining == 0) delete this;
        return (ULONG)(remaining > 0 ? remaining : 0);
    }

    HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown* outer, REFIID riid, void** ppv) override
    {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;

        // 创建引用交还给调用方的 QI：这里必须先释放预置的那一份，
        // 否则引用计数永远多 1，对象不析构、DllCanUnloadNow 恒为 S_FALSE
        Command* command = new (std::nothrow) Command();
        if (!command) return E_OUTOFMEMORY;

        const HRESULT hr = command->QueryInterface(riid, ppv);
        command->Release();
        return hr;
    }

    HRESULT STDMETHODCALLTYPE LockServer(WINBOOL lock) override
    {
        if (lock) InterlockedIncrement(&g_factoryLocks);
        else InterlockedDecrement(&g_factoryLocks);
        return S_OK;
    }

private:
    LONG ref_;
};

} // namespace

// ---------------------------------------------------------------- 导出

extern "C" {

__declspec(dllexport) HRESULT __stdcall DllGetClassObject(REFCLSID rclsid, REFIID riid, void** ppv)
{
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    if (!IsEqualCLSID(rclsid, kClsid)) return CLASS_E_CLASSNOTAVAILABLE;

    // 管家不在时整个 COM 类不可用：宿主拿不到对象，菜单项也就不会出现
    if (!LocateManager(nullptr)) return CLASS_E_CLASSNOTAVAILABLE;

    Factory* factory = new (std::nothrow) Factory();
    if (!factory) return E_OUTOFMEMORY;

    const HRESULT hr = factory->QueryInterface(riid, ppv);
    factory->Release();
    return hr;
}

__declspec(dllexport) HRESULT __stdcall DllCanUnloadNow()
{
    return (g_liveObjects == 0 && g_factoryLocks == 0) ? S_OK : S_FALSE;
}

} // extern "C"

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(module);
    return TRUE;
}

