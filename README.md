<div align="center">

<img src="assets/logo.png" width="96" alt="MiShareMenu" />

# MiShareMenu

**在 Windows 11 一级右键菜单里，直接「使用小米互传发送」**

选中文件或文件夹 → 右键 → 点一下，路径交给本机已装好的**小米电脑管家**，
由它弹出设备选择窗口完成传输。

[![版本](https://img.shields.io/badge/版本-6.6.6.6%20%7C%209.9.9.9-blue)](#-下载)
[![平台](https://img.shields.io/badge/平台-Windows%2011%20x64-0078D4)](#-系统要求)
[![体积](https://img.shields.io/badge/应用包-约%2070%20KB-success)](#-特性)
[![License](https://img.shields.io/badge/许可-仅供学习交流-lightgrey)](#-免责声明)

</div>

---

> [!NOTE]
> 非小米官方项目，仅做菜单入口转发；传输本身完全由小米电脑管家的「小米互传」负责。

## ✨ 特性

- **一级菜单** — 出现在右键第一层，不用再点「显示更多选项」
- **体积小巧** — 应用包约 70 KB，右键扩展与发送进程全部 C++ 原生编译，不依赖 .NET 运行时
- **支持多选** — 选中多个文件 / 文件夹一起发送
- **快捷方式直达** — 右键 `.lnk` 时自动解析目标，实际发送的是它指向的文件 / 文件夹，与官方菜单行为一致；一级 / 二级菜单都生效，目标失效时回落发送快捷方式本身
- **嵌套快捷方式** — 快捷方式指向快捷方式也能逐层解析，最多 5 层
- **新旧管家通吃** — 自动识别管家版本选择投递方式，5.x 与 6.0+ 都支持
- **装完即用** — MSIX 打包，内置文件资源管理器右键菜单扩展（`windows.fileExplorerContextMenus`）

## 📥 下载

按你的**小米电脑管家版本**选一个：

| 版本 | 适用管家 | 版本能力 | 下载（两个文件都要） |
|---|---|---|---|
| **v9.9.9.9**（推荐） | 6.0 及以上 | 一级菜单 · 快捷方式解析 · 多选发送 | [MiShareMenu.msix](https://github.com/ZHAN1HONG/MiShareMenu/releases/download/v9.9.9.9/MiShareMenu.msix)<br>[MiShareMenu.cmd](https://github.com/ZHAN1HONG/MiShareMenu/releases/download/v9.9.9.9/MiShareMenu.cmd) |
| **v6.6.6.6** | 5.x / 4.x | 一级菜单 · 快捷方式解析 · 多选发送 | [MiShareMenu.msix](https://github.com/ZHAN1HONG/MiShareMenu/releases/download/v6.6.6.6/MiShareMenu.msix)<br>[MiShareMenu.cmd](https://github.com/ZHAN1HONG/MiShareMenu/releases/download/v6.6.6.6/MiShareMenu.cmd) |

> `MiShareMenu.msix` 是应用包，`MiShareMenu.cmd` 是配套安装器，两个缺一不可；用法见下面 [📦 安装](#-安装)。

> [!NOTE]
> 两个包是同一份代码，只有版本号不同；两者都会自动识别管家版本，6.0+ 与 5.x / 4.x 都能用。
> 拿不准就装 v9.9.9.9。

<details>
<summary><b>命令行下载 / 国内加速</b></summary>

国内网络走 jsDelivr 更快（`@main` 永远指向最新版，也可换成 `@v9.9.9.9`、`@v6.6.6.6` 固定某一版）：

```text
https://cdn.jsdelivr.net/gh/ZHAN1HONG/MiShareMenu@main/MiShareMenu.msix
```

或者用 curl 直接下（失败自动重试 3 次）：

```bat
curl.exe -L --fail --retry 3 -o MiShareMenu.msix ^
  https://github.com/ZHAN1HONG/MiShareMenu/releases/download/v9.9.9.9/MiShareMenu.msix
curl.exe -L --fail --retry 3 -o MiShareMenu.cmd ^
  https://github.com/ZHAN1HONG/MiShareMenu/releases/download/v9.9.9.9/MiShareMenu.cmd
```

</details>

## 💻 系统要求

| 项目 | 要求 |
|---|---|
| 系统 | Windows 11（Build 22000 及以上） |
| 架构 | x64 |
| 依赖 | 已安装**小米电脑管家**（需含「小米互传」） |

> 没装管家时扩展会自动隐藏菜单项，右键里看不到；装好管家后重新右键即可出现。

## 📦 安装

下载 [MiShareMenu.msix](https://github.com/ZHAN1HONG/MiShareMenu/releases/download/v9.9.9.9/MiShareMenu.msix) 和 [MiShareMenu.cmd](https://github.com/ZHAN1HONG/MiShareMenu/releases/download/v9.9.9.9/MiShareMenu.cmd)，放到**同一个文件夹**（两个文件缺一不可）：

```text
MiShareMenu.msix   应用包（约 70 KB）
MiShareMenu.cmd    本地安装器（导入证书、注册应用包）
```

双击 `MiShareMenu.cmd` → 输入 `1` → UAC 点「是」，完成。

<details>
<summary><b>手动安装（管理员 PowerShell）</b></summary>

```powershell
# 1) 信任包内自签名证书（脚本会自动做，这里给出等价命令）
$sig = Get-AuthenticodeSignature .\MiShareMenu.msix
$tmp = Join-Path $env:TEMP 'MiShareMenu.cer'
[IO.File]::WriteAllBytes($tmp, $sig.SignerCertificate.RawData)
Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\Root
Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\TrustedPeople

# 2) 安装
Add-AppxPackage -Path .\MiShareMenu.msix
```

</details>

安装完成后，选中文件 → 右键，一级菜单里就有「使用小米互传发送」。
如果没立刻出现，重启一次资源管理器（任务管理器里右键「Windows 资源管理器」→ 重新启动）。

## 🖱️ 一键开关（联网自动安装）

不想手动下载安装包？一个脚本搞定——**自动下载 → 校验 → 安装**，也可以一键卸载清理。

[点此下载 MiShareMenu-Switch.cmd](https://github.com/ZHAN1HONG/MiShareMenu/releases/download/v9.9.9.9/MiShareMenu-Switch.cmd)

- 按 `1` 安装：自动从 jsDelivr / GitHub 下载 v9.9.9.9 安装包（约 70 KB），实时读取仓库的 [`MiShareMenu.sha256`](MiShareMenu.sha256) 做完整性校验，随后完成证书导入与注册
- 按 `2` 卸载：自动移除扩展包、预置包、签名证书并清理缓存
- 主菜单实时显示当前状态（管家组件 / 扩展安装 / 本地缓存）

> 脚本会请求管理员权限（安装 MSIX 与导入证书必需）；下载源国内走 jsDelivr，失败自动切换 GitHub Release。想完全离线安装，用上面 [📦 安装](#-安装) 的方式即可。

## 🗑️ 卸载

双击 `MiShareMenu.cmd` → 输入 `2`，脚本会：

1. 移除应用包注册
2. 移除系统预置包
3. 移除本机信任的签名证书

卸载完脚本会自动重启资源管理器，右键菜单随即消失。

命令行等价：

```powershell
Get-AppxPackage -Name MiShareMenu.Extension | Remove-AppxPackage
```

## 📁 目录说明

```text
.
├─ .gitattributes                    换行符与二进制标记（脚本按文本，包与图片按二进制）
├─ .gitignore                        忽略构建产物与签名材料（pfx / cer 绝不提交）
│
├─ build/                            打包与安装
│  ├─ AppxManifest.xml               MSIX 清单：Verb、CLSID、版本号
│  ├─ pack.ps1                       编译 → 汇集 → 打包 → 签名
│  ├─ install.ps1                    安装 / 卸载，签名装不上时回退松散注册
│  ├─ launcher/                      发送进程（C++ 单文件，编成约 30KB 原生 EXE）
│  ├─ shellext/                      右键菜单扩展（C++ 单文件，编成约 30KB 原生 DLL）
│  └─ assets/                        应用图标与磁贴资源
│
├─ assets/                           仓库展示素材（README 顶部 logo）
│
├─ MiShareMenu.cmd                   本地安装器：导入证书、注册应用包（与 msix 同目录）
├─ MiShareMenu.msix                  应用包，配合上面的脚本本地直装
├─ MiShareMenu.sha256                应用包校验值，一键开关脚本联网实时读取
├─ MiShareMenu-Switch.cmd            一键开关脚本：联网下载 → 校验 → 安装 / 卸载
│
├─ BUILD.md                          构建说明
└─ README.md                         本文件
```

## 🛠️ 构建

```powershell
powershell -ExecutionPolicy Bypass -File build\pack.ps1
```

构建依赖 MinGW-w64 g++（编译两个 C++ 源文件）和 Windows SDK（`makeappx` / `signtool`），不需要 .NET SDK；产物为 `build\out\MiShareMenu-<版本>.msix`。签好名的包换台机器装还需要先信任自签证书，详细步骤与排错见 [BUILD.md](BUILD.md)。

## ℹ️ 应用信息

| 字段 | 值 |
|---|---|
| 包名 | `MiShareMenu.Extension` |
| 发布者 | `CN=ZHAN丶HONG`，自签名证书，有效期 2020-01-01 ~ 2045-01-01 |
| 架构 | x64 |

## 🔍 文件校验

`MiShareMenu-Switch.cmd` 不内置校验值，每次运行都从仓库的 [`MiShareMenu.sha256`](MiShareMenu.sha256) 实时读取、下载后比对，不一致会自动换源重下。手动下载的话，可以用下面的值核对：

**v9.9.9.9**

```text
MD5     95680df1e76f52fb2ed5ef192525f04c  MiShareMenu.msix
SHA256  de81fc6bbee90bb6e1797c4de24575050c2f0c664410725c329c13fc11160024  MiShareMenu.msix
```

**v6.6.6.6**

```text
MD5     9f1ae9ef0d8a4062cf07607ebfcea38c  MiShareMenu.msix
SHA256  9333776669664a29fd5b59a87399ff35a01f771a828bf996defe200b30a57518  MiShareMenu.msix
```

## ❓ 常见问题

<details>
<summary><b>菜单出现了，但点击没反应？</b></summary>

先确认小米电脑管家能正常打开「小米互传」并传一次文件。仍无反应的话，重启一次资源管理器再试；也可以在管家设置里确认「小米互传」已开启。

</details>

<details>
<summary><b>安装时提示「已安装相同版本」（0x80073CFB）？</b></summary>

系统不允许同版本号覆盖安装，先卸载再装即可：

```powershell
Get-AppxPackage -Name MiShareMenu.Extension | Remove-AppxPackage
Add-AppxPackage -Path .\MiShareMenu.msix
```

</details>

<details>
<summary><b>一级菜单图标显示成「小米电脑管家」的图标？</b></summary>

图标优先取管家目录下的 `midrop_logo.ico`（小米互传自己的图标），取不到才回退成主程序的图标。

</details>

<details>
<summary><b>安装报 0x800B0109 / 证书不受信任？</b></summary>

以管理员身份重新运行 `MiShareMenu.cmd`，让它把证书装进 `LocalMachine\Root`。

</details>

<details>
<summary><b>安装报 0x800B0101 / 证书不在有效期内？</b></summary>

自签证书有效期为 2020-01-01 ~ 2045-01-01，正常时钟不会触发。若仍报此错，说明目标机器时间不在这个区间，先同步系统时间：管理员运行 `w32tm /resync /force`。

</details>

<details>
<summary><b>双击脚本没反应，或提示需要管理员权限？</b></summary>

安装 / 卸载都要写系统证书库和系统包目录，必须有管理员权限：右键 `MiShareMenu.cmd` →「以管理员身份运行」。标准账户没有管理员密码时无法使用，需要找管理员操作。

</details>

<details>
<summary><b>能在 Windows 10 上用吗？</b></summary>

不行。一级右键菜单扩展和 MSIX 的 `fileExplorerContextMenus` 只有 Windows 11 支持。

</details>

## 📄 免责声明

本项目为第三方实现，与小米公司无关，不使用小米的任何代码或素材用于商业用途。使用风险自负。

---

<div align="center">

**如果这个项目帮到了你，欢迎点个 ⭐ Star**

</div>
