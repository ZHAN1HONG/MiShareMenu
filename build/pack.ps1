# 编译 + 汇集 + 打包 + 签名，一条龙产出可直接安装的 .msix
#
# 用法（在仓库根目录）：
#   powershell -ExecutionPolicy Bypass -File build\pack.ps1
#
# 依赖：.NET 9 SDK、MSVC C++ 工具链（NativeAOT 链接用）、Windows SDK（makeappx / signtool）
# 上述工具若不在默认位置，可用 -DotNet / -MakeAppx / -SignTool / -Toolchain 指定。
param(
    [string]$DotNet = "",
    [string]$MakeAppx = "",
    [string]$SignTool = "",
    [string]$Toolchain = "",
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

# ---- dotnet ----
if (-not $DotNet) {
    if ($Toolchain) {
        $candidate = Join-Path $Toolchain "dotnet\dotnet.exe"
        if (Test-Path $candidate) { $DotNet = $candidate }
    }
    if (-not $DotNet) {
        $cmd = Get-Command dotnet -ErrorAction SilentlyContinue
        if ($cmd) { $DotNet = $cmd.Source }
    }
}
if (-not $DotNet -or -not (Test-Path $DotNet)) {
    throw "找不到 dotnet.exe。请安装 .NET 9 SDK，或用 -DotNet 指定路径"
}

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

# ---- NativeAOT 链接工具链 ----
# 手动指定 link.exe + LIB，避免依赖 vcvars 环境；没配置也能编，只是可能找不到 libcmt.lib
$aotArgs = @()
$msvcRoots = @()
if ($Toolchain) {
    # 精简工具链：编译器和 CRT 导入库分开放
    foreach ($rel in @("vcpkg\tools\Contents\VC\Tools\MSVC", "vcpkg\crt\Contents\VC\Tools\MSVC")) {
        $p = Join-Path $Toolchain $rel
        if (Test-Path $p) { $msvcRoots += $p }
    }
} else {
    # 已安装的 Visual Studio / Build Tools
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath
        if ($vsPath) { $msvcRoots += (Join-Path $vsPath "VC\Tools\MSVC") }
    }
}

foreach ($root in $msvcRoots) {
    $ver = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $ver) { continue }

    $binDir = Join-Path $ver.FullName "bin\Hostx64\x64"
    if (-not (Test-Path (Join-Path $binDir "link.exe"))) { continue }

    $env:PATH = "$binDir;$env:PATH"
    $libDirs = @()

    # 所有 MSVC 根下的 lib\x64 都要加：精简包里编译器和 CRT 的 .lib 是分开放的
    foreach ($r in $msvcRoots) {
        $v = Get-ChildItem $r -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if (-not $v) { continue }
        $lib = Join-Path $v.FullName "lib\x64"
        if ((Test-Path $lib) -and ($libDirs -notcontains $lib)) { $libDirs += $lib }
    }

    if ($Toolchain) {
        # 精简包的 SDK 导入库单独放在 sdklibs 下
        foreach ($lib in @("sdklibs\c\um\x64", "sdklibs\c\ucrt\x64")) {
            $p = Join-Path $Toolchain $lib
            if ((Test-Path $p) -and ($libDirs -notcontains $p)) { $libDirs += $p }
        }
    } else {
        # 正式 SDK 的 um / ucrt 导入库
        $kitsLib = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Lib"
        if (Test-Path $kitsLib) {
            $sdkVer = Get-ChildItem $kitsLib -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
            if ($sdkVer) {
                foreach ($sub in @("um\x64", "ucrt\x64")) {
                    $p = Join-Path $sdkVer.FullName $sub
                    if ((Test-Path $p) -and ($libDirs -notcontains $p)) { $libDirs += $p }
                }
            }
        }
    }

    $env:LIB = $libDirs -join ";"
    $aotArgs += "-p:IlcUseEnvironmentalTools=true"
    Write-Host "  使用 MSVC 工具链: $($ver.Name)" -ForegroundColor DarkGray
    break
}

Write-Host "== 1/5 发布 Launcher（NativeAOT 原生 EXE）==" -ForegroundColor Cyan
if (-not $SkipBuild) {
    & $DotNet publish (Join-Path $repoRoot "src\MiShare.Launcher\MiShare.Launcher.csproj") `
        -c Release -r win-x64 -o (Join-Path $layout "Launcher") --nologo -v m @aotArgs
    if ($LASTEXITCODE -ne 0) { throw "Launcher 发布失败" }
}

Write-Host "== 2/5 发布 ShellExt（NativeAOT 原生 DLL）==" -ForegroundColor Cyan
if (-not $SkipBuild) {
    & $DotNet publish (Join-Path $repoRoot "src\MiShare.ShellExt\MiShare.ShellExt.csproj") `
        -c Release -r win-x64 -o (Join-Path $layout "ShellExt") --nologo -v m @aotArgs
    if ($LASTEXITCODE -ne 0) { throw "ShellExt 发布失败" }
}

Write-Host "== 3/5 汇集包内容 ==" -ForegroundColor Cyan
Copy-Item (Join-Path $scriptDir "AppxManifest.xml") (Join-Path $layout "AppxManifest.xml") -Force
New-Item -ItemType Directory -Force -Path (Join-Path $layout "Assets") | Out-Null
Copy-Item (Join-Path $scriptDir "assets\*") (Join-Path $layout "Assets") -Force
# 清掉调试符号等无关文件，减小包体（必须用 -LiteralPath 逐个删，管道输入在部分环境会被拦截）
Get-ChildItem $layout -Recurse -Filter *.pdb -File | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
}
$leftPdb = @(Get-ChildItem $layout -Recurse -Filter *.pdb -File)
if ($leftPdb.Count -gt 0) { Write-Host "  [警告] 仍有 $($leftPdb.Count) 个 pdb 未清理" -ForegroundColor Yellow }

Write-Host "== 4/5 生成签名证书 ==" -ForegroundColor Cyan
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

# .pfx / .cer 含私钥或可用来验签，已被 .gitignore 排除，不要提交
$pfx = Join-Path $scriptDir "MiShareMenu.pfx"
$cer = Join-Path $scriptDir "MiShareMenu.cer"
$securePwd = ConvertTo-SecureString -String $CertPassword -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $securePwd | Out-Null
Export-Certificate -Cert $cert -FilePath $cer | Out-Null

Write-Host "== 5/5 打包并签名 ==" -ForegroundColor Cyan
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
$installCmd = 'powershell -ExecutionPolicy Bypass -File "{0}\install.ps1"' -f $scriptDir
Write-Host ""
Write-Host "打包完成: $msix ($size MB)" -ForegroundColor Green
Write-Host "SHA256: $sha" -ForegroundColor Green
Write-Host "安装: $installCmd" -ForegroundColor Gray
