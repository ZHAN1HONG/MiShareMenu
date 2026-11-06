@echo off&Title Win11 小米互传一级菜单开关
mode con cols=100 lines=30 & color 3F
setlocal enabledelayedexpansion

:: ============================================================
:: 全局变量定义
:: ============================================================
set "PKGID=MiShareMenu.Extension"
:: 本地安装包目录
set "MSIX=%~dp0MiShareMenu.msix"

:: ============================================================
:: 检查并请求管理员权限
:: ============================================================
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 正在请求管理员权限...
    powershell -NoProfile -Command "try{ Start-Process -FilePath '%~f0' -Verb RunAs -ErrorAction Stop }catch{ exit 1 }" 2>nul
    if errorlevel 1 (
        echo.
        echo [失败] 获取管理员权限被取消或失败，无法安装 / 卸载扩展！
        echo [提示] 请右键本脚本，选择「以管理员身份运行」后重试！
        echo [提示] 若本机没有管理员账户，请联系管理员操作！
        echo.
        pause
    )
    exit /b
)

:: ============================================================
:: 检测小米电脑管家互传组件
:: ============================================================
set "miFound=0"
reg query "HKCR\CLSID\{504d69c0-cb52-48df-b5b5-7161829fabc8}\InprocServer32" >nul 2>&1 && set "miFound=1"
reg query "HKCR\CLSID\{1bca9901-05c3-4d01-8ad4-78da2eac9b3f}\InprocServer32" >nul 2>&1 && set "miFound=1"

:Menu
Cls
:: 获取当前状态
call :GetStatus

echo ============================================================
echo                Win11 小米互传 一级菜单开关
echo                 [脚本作者] BY：ZHAN丶HONG
echo ============================================================
echo                [状态] 小米电脑管家：%status_mi%
echo                  [状态] 扩展安装：%status_install%
echo                  [状态] 本地安装包：%status_pkg%
echo ============================================================
echo.&echo.  →→ 1、★★★ 安装 / 开启 ★★★←←
echo.&echo.  →→ 2、★★★ 卸载 / 关闭 ★★★←←
echo.&echo.  →→ 0、★★★    退出     ★★★←←
echo.
echo ============================================================
echo.
set "Choice="
set /p Choice=√ 请输入选项数字并回车：

if "%Choice%"=="0" exit /b
if "%Choice%"=="1" Goto Install
if "%Choice%"=="2" Goto Uninstall

echo.&echo → [提示] 该输入无效，请重新输入！
echo.
pause
goto Menu

:: ============================================================
:: 获取当前状态
:: ============================================================
:GetStatus
:: 小米电脑管家组件状态
set "status_mi=未安装"
if "!miFound!"=="1" set "status_mi=已安装"

:: 扩展安装状态
set "installed="
for /f "delims=" %%i in ('powershell -NoProfile -Command "(Get-AppxPackage -AllUsers -Name %PKGID%).Version" 2^>nul') do set "installed=%%i"
if defined installed (
    set "status_install=已安装"
) else (
    set "status_install=未安装"
)

:: 本地安装包状态
set "status_pkg=未找到"
if exist "%MSIX%" (
    for %%F in ("%MSIX%") do (
        if %%~zF GEQ 1000000 set "status_pkg=已就绪"
    )
)
goto :eof

:: ============================================================
:: 安装 / 开启小米互传
:: ============================================================
:Install
Cls
echo ============================================================
echo                    正在安装小米互传扩展
echo ============================================================
echo [提示] 正在检查当前小米互传扩展安装状态...
call :GetStatus
if /i "!status_install!"=="已安装" (
    echo [提示] 已安装小米互传扩展：V!installed!
    echo [提示] 无需重复安装，如需重装请先执行卸载！
    echo.
    pause
    goto Menu
)

:: 检查本地安装包
if not exist "%MSIX%" (
    echo [失败] 未找到 MiShareMenu.msix！
    echo [提示] 请将安装包与本脚本放在同一目录后再运行。
    echo.
    pause
    goto Menu
)
set "pkgsize="
for %%F in ("%MSIX%") do set "pkgsize=%%~zF"
if !pkgsize! LSS 1000000 (
    echo [失败] 安装包不完整（仅 !pkgsize! 字节），请更换完整的 MiShareMenu.msix！
    echo.
    pause
    goto Menu
)
for %%F in ("%MSIX%") do echo [提示] 使用本地安装包（%%~zF 字节）...
goto Register

:Register
:: 导入证书并注册 MSIX
echo [提示] 正在导入证书并注册扩展...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try{ $c=(Get-AuthenticodeSignature -FilePath '%MSIX%').SignerCertificate; if(-not $c){ throw 'NO_CERT' }; $f=Join-Path $env:TEMP 'MiShareMenu.cer'; [IO.File]::WriteAllBytes($f,$c.RawData); Import-Certificate -FilePath $f -CertStoreLocation Cert:\LocalMachine\Root -ErrorAction SilentlyContinue | Out-Null; Import-Certificate -FilePath $f -CertStoreLocation Cert:\LocalMachine\TrustedPeople -ErrorAction SilentlyContinue | Out-Null; Add-AppxPackage -Path '%MSIX%' -ErrorAction Stop }catch{ Write-Output ('INSTALL_FAIL: ' + $_.Exception.Message) }"

:: 验证安装结果
echo.
echo [提示] 正在验证安装结果...
call :GetStatus
if /i "!status_install!"=="已安装" (
    echo [成功] 小米互传扩展安装成功！
    echo [信息] 当前版本：V!installed!
) else (
    echo [失败] 小米互传扩展安装失败！
    echo [提示] 常见原因：证书未导入成功 / 未开启开发者模式！
    echo.
    pause
    goto Menu
)

echo.
echo [完成] 小米互传扩展已安装完成！
echo [提示] 右键任意文件，一级菜单即显示小米互传！
echo.
pause
goto Menu

:: ============================================================
:: 卸载 / 关闭小米互传
:: ============================================================
:Uninstall
Cls
echo ============================================================
echo                    正在卸载小米互传扩展
echo ============================================================
echo [提示] 正在检查当前小米互传扩展安装状态...
call :GetStatus
if /i "!status_install!"=="未安装" (
    echo [提示] 当前未安装小米互传扩展！
    echo [提示] 无需卸载，如需安装请先执行安装！
    echo.
    pause
    goto Menu
)

echo.
echo 即将执行【卸载小米互传扩展】涉及如下！
echo 1. 移除扩展包注册
echo 2. 移除系统暂存包
echo 3. 移除导入的证书
echo.
choice /C YN /M "确认卸载小米互传扩展吗"
if errorlevel 2 (
    echo [提示] 已取消！
    echo.
    pause
    goto Menu
)

echo.
:: 移除扩展包注册
echo [1/3] 正在移除扩展包注册...
powershell -NoProfile -Command "try{ $p = (Get-AppxPackage -AllUsers -Name %PKGID%).PackageFullName; if (-not $p) { Write-Output '[信息] EXT_NOT_FOUND' } else { Remove-AppxPackage -Package $p -AllUsers -ErrorAction Stop; Write-Output ('[信息] REMOVED: ' + $p) } }catch{ Write-Output ('[信息] REMOVE_FAIL: ' + $_.Exception.Message) }"

:: 移除系统暂存包
echo [2/3] 正在移除系统暂存包...
powershell -NoProfile -Command "Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -like '*8t4hnfycfsk2p*' } | ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName | Out-Null }" >nul 2>&1

:: 移除导入的证书
echo [3/3] 正在移除导入的证书...
powershell -NoProfile -Command "Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object { $_.Subject -eq 'CN=ZHAN丶HONG' } | ForEach-Object { Remove-Item $_.PSPath -Force }" >nul 2>&1

:: 验证卸载结果
echo.
echo [提示] 正在验证卸载结果...
call :GetStatus
if /i "!status_install!"=="未安装" (
    echo [成功] 小米互传扩展卸载成功！
) else (
    echo [失败] 小米互传扩展卸载失败！
    echo [提示] 当前仍安装版本：!status_install!
    echo.
    pause
    goto Menu
)

:: 重启资源管理器
echo [提示] 正在重启资源管理器以生效...
taskkill /f /IM explorer.exe >nul 2>&1
start explorer.exe

echo.
echo [完成] 小米互传扩展已卸载完成！
echo.
pause
goto Menu
