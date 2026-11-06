param(
    [ValidateSet('install', 'uninstall')]
    [string]$Action = 'install'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# 脚本所在目录（分发目录，msix 就在旁边）
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$pkgName   = 'MiShareMenu.Extension'

# 数据目录：开发者模式散装注册需要文件长期留存，所以解到 LOCALAPPDATA
$dataRoot  = Join-Path $env:LOCALAPPDATA 'MiShareMenu'
$appDir    = Join-Path $dataRoot 'App'
$keepMsix  = Join-Path $dataRoot 'MiShareMenu.msix'
$cerPath   = Join-Path $env:TEMP 'MiShareMenu.cer'

function W-Step($t) { Write-Host ''; Write-Host $t -ForegroundColor Cyan }
function W-Ok($t)   { Write-Host "  $t" -ForegroundColor Green }
function W-Warn($t) { Write-Host "  $t" -ForegroundColor Yellow }
function W-Err($t)  { Write-Host "  $t" -ForegroundColor Red }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-Msix {
    foreach ($c in @($scriptDir, $dataRoot)) {
        $p = Join-Path $c 'MiShareMenu.msix'
        if (Test-Path $p) { return $p }
    }
    return $null
}

# 把 msix/PowerShell 的错误码翻译成一句人话 + 对应处理建议
function Get-InstallHint($ex) {
    $msg = "$($ex.Message)"
    if ($msg -match '80073CFB') {
        return @(
            '系统不允许同版本号覆盖安装（0x80073CFB）。',
            '请先卸载再装：Get-AppxPackage -Name MiShareMenu.Extension | Remove-AppxPackage'
        )
    }
    if ($msg -match '800B0109') {
        return @(
            '签名证书不受信任（0x800B0109）。',
            '请右键 MiShareMenu.cmd，选择「以管理员身份运行」后重试。'
        )
    }
    if ($msg -match '800B0101') {
        return @(
            '签名证书不在有效期内（0x800B0101）。',
            '自签证书有效期 2020-01-01 ~ 2045-01-01，正常时钟不会触发。',
            '请先同步系统时间：管理员运行 w32tm /resync /force'
        )
    }
    if ($msg -match '80073D02|80073D06') {
        return @(
            '相关应用正在运行（0x80073D02）。',
            '请关闭小米电脑管家和资源管理器窗口后重试，或重启电脑。'
        )
    }
    if ($msg -match '80073CF3|80073CF0') {
        return @(
            '包注册冲突（0x80073CF3 / 0x80073CF0）。',
            '请先卸载旧版再装，或重启系统后重试。'
        )
    }
    return $null
}

# 证书不单独分发，直接从 msix 的数字签名里取
function Get-SignerCert($msixPath) {
    if ($msixPath -and (Test-Path $msixPath)) {
        try {
            $sig = Get-AuthenticodeSignature -FilePath $msixPath
            if ($sig -and $sig.SignerCertificate) { return $sig.SignerCertificate }
        } catch { }
    }
    return $null
}

# MSIX 正式安装要求证书在本机（LocalMachine）信任库；非管理员时单独提权做这一步
function Import-CertToMachine($cerPath) {
    if (-not (Test-Path $cerPath)) { return $false }
    $inner = @(
        "Import-Certificate -FilePath '$cerPath' -CertStoreLocation 'Cert:\LocalMachine\Root' -ErrorAction SilentlyContinue | Out-Null"
        "Import-Certificate -FilePath '$cerPath' -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' -ErrorAction SilentlyContinue | Out-Null"
    ) -join '; '
    try {
        $p = Start-Process -FilePath 'powershell' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $inner) `
            -Verb RunAs -Wait -PassThru -WindowStyle Hidden
        return ($p.ExitCode -eq 0)
    } catch {
        return $false
    }
}

# 检测小米电脑管家，返回主程序 exe 路径或 $null
function Find-PcManager {
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not $base) { continue }
        foreach ($rel in @('MI\XiaomiPCManager', 'Programs\MI\XiaomiPCManager')) {
            $p = Join-Path $base $rel
            if (-not (Test-Path $p)) { continue }
            $exe = Get-ChildItem $p -Recurse -Depth 2 -Include 'XiaomiPcManager.exe', 'hyperConnect.exe' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
    }
    return $null
}

# ---------------------------------------------------------------- 安装
function Do-Install {
    Write-Host ''
    Write-Host '===== 小米互传右键菜单 安装 =====' -ForegroundColor Cyan

    $msix = Resolve-Msix
    if (-not $msix) {
        W-Err '找不到 MiShareMenu.msix，请把它和脚本放在同一文件夹。'
        return 1
    }
    Write-Host "  安装包: $msix"

    W-Step '[1/5] 系统检查'
    $isAdmin = Test-Admin
    $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
    Write-Host "  Windows 版本: $build  (需 22000 以上，即 Windows 11)"
    if ($build -lt 22000) {
        W-Warn '低于 Windows 11，一级右键菜单不可用，只能在「显示更多选项」里看到'
    }

    $found = Find-PcManager
    if ($found) {
        Write-Host "  小米电脑管家: $found"
    } else {
        W-Warn '未检测到小米电脑管家。菜单能装上，但点击后无法发送文件。'
    }

    W-Step '[2/5] 信任签名证书'
    $cert = Get-SignerCert $msix
    if ($cert) {
        [IO.File]::WriteAllBytes($cerPath, $cert.RawData)
        if ($isAdmin) {
            $stores = @('Cert:\LocalMachine\TrustedPeople', 'Cert:\LocalMachine\Root')
        } else {
            $stores = @('Cert:\CurrentUser\TrustedPeople', 'Cert:\CurrentUser\Root')
            W-Warn '非管理员：证书只能装到当前用户，签名安装可能失败（会自动改用开发者模式安装）'
        }
        foreach ($store in $stores) {
            $exists = Get-ChildItem $store -ErrorAction SilentlyContinue |
                Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
            if ($exists) { Write-Host "  已在 $store"; continue }
            try {
                Import-Certificate -FilePath $cerPath -CertStoreLocation $store | Out-Null
                Write-Host "  已导入 $store"
            } catch {
                W-Warn "导入 $store 失败：$($_.Exception.Message)"
            }
        }
    } else {
        W-Warn '未能读取签名证书，直接尝试安装'
    }

    W-Step '[3/5] 安装应用包'
    $installed = Get-AppxPackage -Name $pkgName -ErrorAction SilentlyContinue
    if ($installed) {
        Write-Host "  已存在 $($installed.Version)，先移除旧版"
        Remove-AppxPackage -Package $installed.PackageFullName -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }

    $ok = $false
    $lastEx = $null
    try {
        Add-AppxPackage -Path $msix -ForceApplicationShutdown
        $ok = $true
        W-Ok '签名安装成功'
    } catch {
        $lastEx = $_.Exception
        W-Warn "签名安装失败：$($lastEx.Message)"

        # 常见原因：证书只在当前用户库，MSIX 要求本机信任库。单独提权补这一步再重试一次
        if (-not $isAdmin -and (Test-Path $cerPath)) {
            Write-Host '  正在请求一次管理员授权，把签名证书装到本机信任库后重试...'
            if (Import-CertToMachine $cerPath) {
                Write-Host '  证书已装入本机信任库，重新尝试签名安装...'
                try {
                    Add-AppxPackage -Path $msix -ForceApplicationShutdown
                    $ok = $true
                    W-Ok '签名安装成功'
                } catch {
                    $lastEx = $_.Exception
                    W-Warn "仍然失败：$($lastEx.Message)"
                }
            } else {
                W-Warn '未获得授权，跳过签名安装'
            }
        }

        # 错误码翻译成处理建议
        if (-not $ok) {
            $hint = Get-InstallHint $lastEx
            if ($hint) {
                Write-Host ''
                foreach ($line in $hint) { Write-Host "  $line" -ForegroundColor Yellow }
            }
        }
    }

    if (-not $ok) {
        Write-Host '  改用开发者模式安装（不需要受信任证书）...'
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            if (Test-Path $appDir) { Remove-Item $appDir -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Force -Path $appDir | Out-Null
            [System.IO.Compression.ZipFile]::ExtractToDirectory($msix, $appDir)
            Add-AppxPackage -Register (Join-Path $appDir 'AppxManifest.xml')
            $ok = $true
            W-Ok '开发者模式安装成功'
        } catch {
            $hint = Get-InstallHint $_.Exception
            Write-Host ''
            W-Err "安装失败：$($_.Exception.Message)"
            if ($hint) {
                Write-Host ''
                foreach ($line in $hint) { Write-Host "  $line" -ForegroundColor Yellow }
            }
            Write-Host ''
            Write-Host '请按下面任一方式处理后重试：' -ForegroundColor Yellow
            Write-Host '  1) 右键 MiShareMenu.cmd → 以管理员身份运行（推荐，会自动信任证书）'
            Write-Host '  2) 设置 > 系统 > 开发者选项 > 打开「开发人员模式」，再重新运行'
            return 1
        }
    }

    # 留一份包在数据目录，卸载时用来取证书
    try {
        New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
        if ([IO.Path]::GetFullPath($msix) -ne [IO.Path]::GetFullPath($keepMsix)) {
            Copy-Item $msix $keepMsix -Force -ErrorAction SilentlyContinue
        }
    } catch { }

    W-Step '[4/5] 确认结果'
    $pkg = Get-AppxPackage -Name $pkgName -ErrorAction SilentlyContinue
    if (-not $pkg) {
        W-Err '安装未生效，请查看上面的错误信息。'
        return 1
    }
    W-Ok "已安装：$($pkg.PackageFullName)"
    Write-Host "  版本：$($pkg.Version)   发布者：$($pkg.Publisher)"
    Write-Host "  位置：$($pkg.InstallLocation)"

    W-Step '[5/5] 校验右键菜单扩展'
    $manifest = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
    $hasExt = (Test-Path $manifest) -and (Select-String -Path $manifest -Pattern 'fileExplorerContextMenus' -Quiet -ErrorAction SilentlyContinue)
    if ($hasExt) {
        W-Ok '右键菜单扩展已随包注册（windows.fileExplorerContextMenus）'
    } else {
        W-Warn '未在包清单中找到菜单扩展，右键菜单可能不会出现，请反馈'
    }

    Remove-Item $cerPath -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '安装完成。选中文件或文件夹右键即可看到「使用小米互传发送」。' -ForegroundColor Green
    return 0
}

# ---------------------------------------------------------------- 卸载
function Do-Uninstall {
    Write-Host ''
    Write-Host '===== 小米互传右键菜单 卸载 =====' -ForegroundColor Cyan

    $pkg = Get-AppxPackage -Name $pkgName -ErrorAction SilentlyContinue
    if ($pkg) {
        Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Continue
        Write-Host "  已卸载：$($pkg.PackageFullName)" -ForegroundColor Green
    } else {
        W-Warn '未检测到已安装的应用包'
    }

    $cert = Get-SignerCert (Resolve-Msix)
    if ($cert) {
        $stores = @('Cert:\CurrentUser\TrustedPeople', 'Cert:\CurrentUser\Root')
        if (Test-Admin) {
            $stores += @('Cert:\LocalMachine\TrustedPeople', 'Cert:\LocalMachine\Root')
        }
        foreach ($store in $stores) {
            Get-ChildItem $store -ErrorAction SilentlyContinue |
                Where-Object { $_.Thumbprint -eq $cert.Thumbprint } |
                ForEach-Object {
                    Remove-Item $_.PSPath -Force -ErrorAction SilentlyContinue
                    Write-Host "  已从 $store 移除签名证书"
                }
        }
    }

    # 清空数据目录（App 散装目录 + 留存的 msix 备份）
    if (Test-Path $dataRoot) {
        Remove-Item $dataRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $cerPath -Force -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host '卸载完成。如菜单仍然显示，重启资源管理器或注销后即可消失。' -ForegroundColor Green
    return 0
}

if ($Action -eq 'uninstall') { exit (Do-Uninstall) } else { exit (Do-Install) }
