# 构建说明

## 环境要求

| 工具 | 用途 | 说明 |
|---|---|---|
| [MinGW-w64](https://github.com/brechtsanders/winlibs_mingw/releases) g++ | 编译两个 C++ 源文件 | 任选一套 x86_64 + UCRT 的发行包，或 MSYS2 的 `mingw-w64-x86_64-gcc` |
| Windows 10/11 SDK | `makeappx.exe` / `signtool.exe` | 只用来打包与签名；装 VS 时勾选 Windows SDK 即可 |
| Windows 11（Build 22000+） | 运行 / 调试 | 一级右键菜单扩展仅 Win11 支持 |

> 全部代码都是 C++，编译只需要 g++ 一个工具；不依赖 .NET SDK、MSVC 或 vcvars 环境。

## 代码结构

完整目录树与各文件职责见 README 的 [目录说明](README.md#-目录说明)，这里只列构建相关的部分：

| 位置 | 作用 |
|---|---|
| `build\AppxManifest.xml` | MSIX 清单：Verb、CLSID、版本号都在这里改 |
| `build\pack.ps1` | 编译 → 汇集 → 打包 → 签名，产出一个可安装的 msix |
| `build\install.ps1` | 安装本地产物，签名装不上时回退松散注册 |
| `build\launcher\Launcher.cpp` | 发送进程：定位管家、解析快捷方式、投递路径，编成约 30KB 原生 EXE |
| `build\shellext\ShellExt.cpp` | 右键菜单扩展：COM 入口、`IExplorerCommand`、信箱写入，编成约 27KB 原生 DLL |
| `build\assets\` | MSIX 图标与磁贴资源 |

运行链路：

```text
资源管理器右键 → dllhost 加载 ShellExt.dll → 写信箱 → 拉起 Launcher.exe（C++ 原生）
                                                            ↓
                                            按管家版本选通道投递路径
```

> 根目录的 `MiShareMenu.cmd` 是给最终用户的本地安装器（与 `MiShareMenu.msix` 同目录使用），`MiShareMenu-Switch.cmd` 是同类的联网版（自己下包、校验、安装）；
> `build\` 下的 `pack.ps1` / `install.ps1` 是开发用脚本，负责编译、打包与安装本地产物；两套脚本用途不同，不要混用。

## 构建

在**仓库根目录**执行：

```powershell
powershell -ExecutionPolicy Bypass -File build\pack.ps1
```

产物：`build\out\MiShareMenu-<版本>.msix`，版本号取自 `build\AppxManifest.xml` 的 `<Identity Version>`。

工具不在默认位置时可显式指定：

```powershell
# 分别指定工具
powershell -File build\pack.ps1 `
    -MakeAppx "C:\SDK\makeappx.exe" -SignTool "C:\SDK\signtool.exe" `
    -MinGW "C:\mingw64\bin\g++.exe"

# 或指向一个自带 mingw / SDK 的目录（便携工具链）
powershell -File build\pack.ps1 -Toolchain "D:\toolchain"
```

`g++` 的查找顺序：`-MinGW` 指定值 → `-Toolchain\mingw\mingw64\bin\g++.exe` → 系统 `PATH`。
两个产物都静态链接、只依赖系统 DLL（UCRT 属于 Win10+ 自带组件），不需要附带任何运行时。

只改清单、不重新编译时加 `-SkipBuild`（复用上次 `build\layout` 里的二进制）。

## 安装 / 卸载

```powershell
# 安装（需要一个带签名的包）
powershell -ExecutionPolicy Bypass -File build\install.ps1

# 卸载
Get-AppxPackage -Name MiShareMenu.Extension | Remove-AppxPackage
```

## 关于签名证书

`pack.ps1` 会用当前用户证书库里 `CN=ZHAN丶HONG` 的自签证书签名；没有就自动新建一张（默认 10 年，年数写死在 `pack.ps1` 的 `-NotAfter` 里），并导出到 `build\MiShareMenu.pfx` / `.cer`。仓库现用的那张是 2020 年签发的 25 年期证书，到 2045-01-01 到期。

- 这两个文件**已被 `.gitignore` 排除，不要提交**（`.pfx` 含私钥）
- 自签证书装到别的机器上必须先把 `.cer` 导入「受信任的根证书颁发机构」，否则报 `0x800B0109`
- 换发布者时改 `-CertSubject`，同时同步 `AppxManifest.xml` 的 `Publisher`，两者必须完全一致

## 调试

扩展运行时不写日志，只往 `%LOCALAPPDATA%\MiShareMenu\queue` 写一个只含路径的队列文件（`Launcher` 读完即删），不会在你的文件上留下任何痕迹。需要观察菜单行为时，可用调试器附加到加载本扩展的 `dllhost.exe`，或临时加日志后重新编译——发版前记得把这些临时代码撤掉。

菜单显隐的判定逻辑在 `build\shellext\ShellExt.cpp` 的 `Command::GetState`：管家未安装、或处于「显示更多选项」且检测到官方同名入口时返回 `ECS_HIDDEN`。

## 已知限制

- 只支持 x64；ARM64 未适配
- 一级菜单图标取 `midrop_logo.ico`，管家目录结构变化时会回退为主程序图标
- 未装管家时菜单不出现（`GetState` 直接返回 `ECS_HIDDEN`）
