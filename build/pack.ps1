# 编译 + 汇集 + 打包 + 签名，一条龙产出可直接安装的 .msix
#
# 用法（在仓库根目录）：
#   powershell -ExecutionPolicy Bypass -File build\pack.ps1
#
# 依赖：MinGW-w64 g++（编译发送进程与扩展 DLL）、Windows SDK（makeappx / signtool）
# 上述工具若不在默认位置，可用 -MinGW / -MakeAppx / -SignTool / -Toolchain 指定。
param(
    [string]$MakeAppx = "",
    [string]$SignTool = "",
    [string]$Toolchain = "",
    [string]$MinGW = "",
    [string]$CertSubject = "CN=ZHAN丶HONG",
    [string]$CertPassword = "MiShareMenu",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoRoot = Split-Path -Parent $scriptDir
$layout = Join-Path $scriptDir "layout"
$outDir = Join-Path $scriptDir "out"

if (-not $Toolchain) { $Toolchain = $env:MISHARE_TOOLCHAIN }
if ($Toolchain -and -not (Test-Path $Toolchain)) { throw "Toolchain 目录不存在: $Toolchain" }

# ---- makeappx / signtool ----
if (-not $MakeAppx -or -not $SignTool) {
    $found = $null

    # 1) 随 Toolchain 附带的精简 Windows SDK BuildTools
    if ($Toolchain) {
        $btRoot = Join-Path $Toolchain "sdkbt\bin"
        if (Test-Path $btRoot) {
            $bt = Get-ChildItem $btRoot -Recurse -Filter "makeappx.exe" -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -like "*\x64\*" } | Select-Object -First 1
            if ($bt) { $found = $bt }
        }
    }

    # 2) 正式安装的 Windows 10/11 SDK，取版本号最大的一个
    if (-not $found) {
        $sdkBin = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
        if (Test-Path $sdkBin) {
            $found = Get-ChildItem $sdkBin -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName "x64\makeappx.exe" } |
                Where-Object { Test-Path $_ } |
                Select-Object -First 1
            if ($found) { $found = Get-Item $found }
        }
    }

    if ($found) {
        if (-not $MakeAppx) { $MakeAppx = $found.FullName }
        if (-not $SignTool) { $SignTool = Join-Path $found.DirectoryName "signtool.exe" }
    }
}
if (-not (Test-Path $MakeAppx)) { throw "找不到 makeappx.exe，请安装 Windows SDK 或用 -MakeAppx 指定路径" }
if (-not (Test-Path $SignTool)) { throw "找不到 signtool.exe，请安装 Windows SDK 或用 -SignTool 指定路径" }

# ---- MinGW 工具链 ----
if (-not $MinGW) {
    if ($Toolchain) {
        $candidate = Join-Path $Toolchain "mingw\mingw64\bin\g++.exe"
        if (Test-Path $candidate) { $MinGW = $candidate }
    }
    if (-not $MinGW) {
        $cmd = Get-Command g++ -ErrorAction SilentlyContinue
        if ($cmd) { $MinGW = $cmd.Source }
    }
}
if (-not $MinGW -or -not (Test-Path $MinGW)) {
    throw "找不到 g++。请安装 MinGW-w64，或用 -MinGW 指定 g++.exe 的完整路径"
}

# 静态链接 + 按函数分段后丢弃未引用段：产物只依赖系统 DLL
$commonFlags = @(
    "-std=c++17", "-Os", "-s",
    "-DWIN32_LEAN_AND_MEAN", "-DUNICODE", "-D_UNICODE",
    "-ffunction-sections", "-fdata-sections",
    "-fno-exceptions", "-fno-rtti", "-fno-threadsafe-statics",
    "-static", "-static-libgcc",
    "-Wl,--gc-sections", "-Wl,--no-insert-timestamp"
)

Write-Host "== 1/4 编译 Launcher（C++ 原生 EXE）==" -ForegroundColor Cyan
$launcherSrc = Join-Path $scriptDir "launcher\Launcher.cpp"
$launcherOut = Join-Path $layout "Launcher\MiShare.Launcher.exe"

if (-not $SkipBuild) {
    $launcherDir = Split-Path -Parent $launcherOut
    New-Item -ItemType Directory -Force -Path $launcherDir | Out-Null
    Get-ChildItem $launcherDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    & $MinGW @commonFlags -municode -mwindows -o $launcherOut $launcherSrc `
        -lole32 -lshell32 -lshlwapi -luuid -lversion
    if ($LASTEXITCODE -ne 0) { throw "Launcher 编译失败" }
}
if (-not (Test-Path $launcherOut)) { throw "找不到 Launcher 产物：$launcherOut" }

Write-Host "== 2/4 编译 ShellExt（C++ 原生 DLL，由 dllhost 加载）==" -ForegroundColor Cyan
$shellExtSrc = Join-Path $scriptDir "shellext\ShellExt.cpp"
$shellExtOut = Join-Path $layout "ShellExt\MiShare.ShellExt.dll"

if (-not $SkipBuild) {
    $shellExtDir = Split-Path -Parent $shellExtOut
    New-Item -ItemType Directory -Force -Path $shellExtDir | Out-Null
    Get-ChildItem $shellExtDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    & $MinGW @commonFlags -shared -o $shellExtOut $shellExtSrc `
        -lole32 -lshell32 -lshlwapi -ladvapi32 -luuid
    if ($LASTEXITCODE -ne 0) { throw "ShellExt 编译失败" }
}
if (-not (Test-Path $shellExtOut)) { throw "找不到 ShellExt 产物：$shellExtOut" }

Write-Host "== 3/4 汇集包内容并导出签名证书 ==" -ForegroundColor Cyan
Copy-Item (Join-Path $scriptDir "AppxManifest.xml") (Join-Path $layout "AppxManifest.xml") -Force
New-Item -ItemType Directory -Force -Path (Join-Path $layout "Assets") | Out-Null
Copy-Item (Join-Path $scriptDir "assets\*") (Join-Path $layout "Assets") -Force

# .pfx / .cer 含私钥或可用来验签，已被 .gitignore 排除，不要提交
$cert = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq $CertSubject -and $_.HasPrivateKey } | Select-Object -First 1

if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type Custom `
        -Subject $CertSubject `
        -KeyUsage DigitalSignature `
        -FriendlyName "MiShareMenu package signing" `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}') `
        -NotAfter (Get-Date).AddYears(10)
    Write-Host "  已创建自签名证书 $($cert.Thumbprint)"
}

$pfx = Join-Path $scriptDir "MiShareMenu.pfx"
$cer = Join-Path $scriptDir "MiShareMenu.cer"
$securePwd = ConvertTo-SecureString -String $CertPassword -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $securePwd | Out-Null
Export-Certificate -Cert $cert -FilePath $cer | Out-Null

Write-Host "== 4/4 打包并签名 ==" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
# 输出文件名带上清单里的版本号，避免不同版本的包混在同一目录里分不清
$manifestVersion = ([xml](Get-Content (Join-Path $layout "AppxManifest.xml") -Raw -Encoding UTF8)).Package.Identity.Version
$msix = Join-Path $outDir "MiShareMenu-$manifestVersion.msix"
if (Test-Path $msix) { Remove-Item $msix -Force }

& $MakeAppx pack /d $layout /p $msix /o
if ($LASTEXITCODE -ne 0) { throw "makeappx 失败" }

& $SignTool sign /fd SHA256 /f $pfx /p $CertPassword $msix
if ($LASTEXITCODE -ne 0) { throw "signtool 失败" }

$size = [math]::Round((Get-Item $msix).Length / 1MB, 2)
$sha = (Get-FileHash $msix -Algorithm SHA256).Hash.ToLower()
Write-Host ""
Write-Host "打包完成: $msix ($size MB)" -ForegroundColor Green
Write-Host "SHA256: $sha" -ForegroundColor Green
Write-Host "安装: powershell -ExecutionPolicy Bypass -File `"$(Join-Path $scriptDir 'install.ps1')`"" -ForegroundColor Gray
