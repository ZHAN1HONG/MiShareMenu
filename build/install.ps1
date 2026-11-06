# 安装：优先走签名安装；证书根确认被跳过/拒绝时，回退到开发者模式的松散注册
param(
    [string]$Package = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

if (-not $Package) {
    # 包名按清单版本命名（MiShareMenu-<版本>.msix），取 out 目录里最新的一个
    $latest = Get-ChildItem (Join-Path $scriptDir "out") -Filter "MiShareMenu-*.msix" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { $Package = $latest.FullName }
    else { $Package = Join-Path $scriptDir "out\MiShareMenu.msix" }
}
if (-not (Test-Path $Package)) { throw "找不到安装包: $Package" }

$cer = Join-Path $scriptDir "MiShareMenu.cer"
$hasCert = Test-Path $cer

function Register-Package([string]$path) {
    Add-AppxPackage -Path $path
    Write-Host "  已安装: $path" -ForegroundColor Green
}

function Register-Loose([string]$manifest) {
    # 需要系统开启开发者模式（设置 -> 系统 -> 开发者选项）
    Add-AppxPackage -Register $manifest
    Write-Host "  已注册（松散模式）: $manifest" -ForegroundColor Green
}

Write-Host "== 安装小米互传菜单 ==" -ForegroundColor Cyan

if ($hasCert) {
    Write-Host "1/3 导入信任证书" -ForegroundColor Cyan
    $thumbprint = (Get-PfxCertificate -FilePath $cer).Thumbprint

    # 自签名证书既是叶子也是根；写入 Root 时 Windows 可能弹一次信任确认
    foreach ($store in @("TrustedPeople", "Root")) {
        $location = "Cert:\CurrentUser\$store"
        $exists = Get-ChildItem $location -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $thumbprint }

        if ($exists) {
            Write-Host "  已在 $store"
        } else {
            try {
                Import-Certificate -FilePath $cer -CertStoreLocation $location | Out-Null
                Write-Host "  已导入 $store"
            } catch {
                Write-Host "  导入 $store 失败（$($_.Exception.Message)），稍后回退松散注册" -ForegroundColor Yellow
            }
        }
    }

    Write-Host "2/3 注册应用包（签名模式）" -ForegroundColor Cyan
    try {
        Register-Package $Package
    } catch {
        Write-Host "  签名安装失败（$($_.Exception.Message)）" -ForegroundColor Yellow
        Write-Host "3/3 回退松散注册" -ForegroundColor Cyan
        Register-Loose (Join-Path $scriptDir "layout\AppxManifest.xml")
    }
} else {
    Write-Host "1/2 未找到证书，使用松散注册" -ForegroundColor Yellow
    Register-Loose (Join-Path $scriptDir "layout\AppxManifest.xml")
}

Write-Host ""
Write-Host "安装完成。在资源管理器里选中文件/文件夹，右键即可看到「使用小米互传发送」。" -ForegroundColor Green
Write-Host "若菜单未出现，重启一下 explorer.exe 即可。" -ForegroundColor Gray
