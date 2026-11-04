# MiShareMenu · Windows 11 右键「使用小米互传发送」

在 Windows 11 文件资源管理器的**一级右键菜单**里加一项 **「使用小米互传发送」**。
选中文件或文件夹 → 右键 → 点一下，路径直接交给本机已装好的**小米电脑管家**，由它弹出设备选择窗口完成传输。

> 非小米官方项目，仅做菜单入口转发；传输本身完全由小米电脑管家的「小米互传」负责。

## 下载

| 地址 | 说明 |
|---|---|
| [**Release v9.9.9.9**](https://github.com/ZHAN1HONG/MiShareMenu/releases/download/v9.9.9.9/MiShareMenu.msix) | GitHub 直链，`curl -L` 可用 |
| `https://cdn.jsdelivr.net/gh/ZHAN1HONG/MiShareMenu/MiShareMenu.msix` | jsDelivr CDN，国内更快 |

脚本里直接下载（含校验）：

```bat
curl.exe -L --fail --retry 3 -o MiShareMenu.msix ^
  https://cdn.jsdelivr.net/gh/ZHAN1HONG/MiShareMenu/MiShareMenu.msix
```

## 特性

- **一级菜单**：出现在右键第一层，不用点「显示更多选项」
- **体积小**：应用包约 1.7 MB，NativeAOT 编译，不依赖 .NET 运行时
- **支持多选**：选中多个文件/文件夹一起发送
- **不自带传输逻辑**：只把选中路径投递给管家窗口（`WM_COPYDATA`），协议、加密、速度全由官方客户端决定
- **装完即用**：MSIX 打包，带文件资源管理器右键菜单扩展（`windows.fileExplorerContextMenus`）

## 系统要求

| 项目 | 要求 |
|---|---|
| 系统 | Windows 11（Build 22000 及以上） |
| 架构 | x64 |
| 依赖 | 已安装 **小米电脑管家**（需含「小米互传」） |

没装管家时菜单仍会出现，但点击无反应；装上管家后即可正常使用。

## 安装

把下面三个文件放到**同一个文件夹**：

```
MiShareMenu.msix   应用包（1.7 MB）
MiShareMenu.cmd    启动器 / 菜单
MiShareMenu.ps1    安装、卸载逻辑
```

然后双击 `MiShareMenu.cmd` → 输入 `1` → UAC 点「是」。

也可以直接静默安装（管理员 PowerShell）：

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

安装完成后，选中文件 → 右键，一级菜单里就有「使用小米互传发送」。
如果没立刻出现，运行 `MiShareMenu.cmd` 选 `3` 重启资源管理器。

## 卸载

双击 `MiShareMenu.cmd` → 输入 `2`，脚本会：

1. 移除应用包注册
2. 移除系统预置包
3. 移除本机信任的签名证书
4. 清理 `%LOCALAPPDATA%\MiShareMenu` 缓存

命令行等价：

```powershell
Get-AppxPackage -Name MiShareMenu.Extension | Remove-AppxPackage
```

## 应用信息

| 字段 | 值 |
|---|---|
| 包名 | `MiShareMenu.Extension` |
| 版本 | `9.9.9.9` |
| 发布者 | `CN=ZHAN丶HONG` |
| 架构 | x64 |
| 签名 | 自签名证书 `CN=ZHAN丶HONG`，有效期 2020-01-01 ~ 2045-01-01（不受时钟偏差影响） |

## 文件校验

```
MD5     3e6d296841c3860b7f07f2bfcbf1f00c  MiShareMenu.msix
SHA256  aff542ab664c477667a47442ed303239e83fb77c15471dc83e58c80b7bb7fd98  MiShareMenu.msix
```

## 常见问题

**Q：菜单出现了，但点击没反应？**
A：先确认小米电脑管家能正常打开「小米互传」并传一次文件。菜单只是把路径转发给管家窗口，管家没运行/版本不支持时会无响应。

**Q：安装报 0x800B0109 / 证书不受信任？**
A：以管理员身份重新运行 `MiShareMenu.cmd`，让它把证书装进 `LocalMachine\Root`。

**Q：安装报 0x800B0101 / 证书不在有效期内？**
A：签名的自签证书有效期为 2020-01-01 ~ 2045-01-01，正常时钟不会触发。若仍报此错，说明目标机器时间被改到了 2020 年之前，先同步系统时间：管理员运行 `w32tm /resync /force`。

**Q：能在 Windows 10 上用吗？**
A：不行。一级右键菜单扩展和 MSIX 的 `fileExplorerContextMenus` 只有 Windows 11 支持。

## 免责声明

本项目为第三方实现，与小米公司无关，不使用小米的任何代码或素材用于商业用途。使用风险自负。
