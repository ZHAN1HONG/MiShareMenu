@echo off&Title Win11 小米互传一级菜单开关
mode con cols=100 lines=30 & color 3F
setlocal enabledelayedexpansion

:: ============================================================
:: 全局变量定义
:: ============================================================
set "PKGID=MiShareMenu.Extension"
set "DLDIR=%LOCALAPPDATA%\MiShareMenu"
set "URL1=https://cdn.jsdelivr.net/gh/ZHAN1HONG/MiShareMenu@main/MiShareMenu.msix"
set "URL2=https://github.com/ZHAN1HONG/MiShareMenu/releases/latest/download/MiShareMenu.msix"
set "SHAURL1=https://cdn.jsdelivr.net/gh/ZHAN1HONG/MiShareMenu@main/MiShareMenu.sha256"
set "SHAURL2=https://github.com/ZHAN1HONG/MiShareMenu/releases/latest/download/MiShareMenu.sha256"
set "MSIX=%DLDIR%\MiShareMenu.msix"

:: ============================================================
:: 检查并请求管理员权限
:: ============================================================
net session >nul 2>&1
if errorlevel 1 (
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
echo                  [状态] 本地缓存：%status_cache%
echo ============================================================
echo.&echo.  →→ 1、★★★ 安装 / 开启 ★★★←←
echo.&echo.  →→ 2、★★★ 卸载 / 关闭 ★★★←←
echo.&echo.  →→ 0、★★★    退出     ★★★←←
echo.
echo ============================================================
echo.
set "Choice="
set /p Choice=√ 请输入选项数字并回车：
for /f "delims=0123456789" %%a in ("!Choice!") do set "Choice="

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

:: 本地缓存状态
set "status_cache=未缓存"
if exist "%MSIX%" (
    for %%F in ("%MSIX%") do (
        if %%~zF GEQ 50000 set "status_cache=已缓存"
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
    echo [提示] 无需重复安装，如需重装或更换版本请先执行卸载！
    echo.
    pause
    goto Menu
)

:: 创建下载目录
if not exist "%DLDIR%" md "%DLDIR%" >nul 2>&1

:: 获取官方校验值
call :FetchSha

:: 检查本地缓存
set "useMSIX=0"
if exist "%MSIX%" for %%F in ("%MSIX%") do if %%~zF GEQ 50000 set "useMSIX=1"

if "!useMSIX!"=="1" (
    for %%F in ("%MSIX%") do echo [提示] 检测到本地缓存（%%~zF 字节），正在校验...
    call :Verify
    if "!verifyOK!"=="1" goto Register
    echo [提示] 本地缓存已过期或损坏，将重新下载...
    del "%MSIX%" >nul 2>&1
)

:: 下载扩展包
echo [提示] 正在下载安装包（约 70 KB）...
echo [提示] 当前下载源为 jsDelivr ...
curl.exe -L --progress-bar --retry 3 --connect-timeout 15 --max-time 300 -o "%MSIX%" "%URL1%"
if not errorlevel 1 (
    call :Verify
    if "!verifyOK!"=="1" goto Register
    echo [警告] 安装包与官方校验值不符，用 GitHub 重下...
)

echo [提示] 当前下载源为 GitHub ...
curl.exe -L --progress-bar --retry 3 --connect-timeout 15 --max-time 300 -o "%MSIX%" "%URL2%"
if errorlevel 1 (
    echo.
    echo [失败] 安装包下载失败，请检查网络后重试！
    echo.
    pause
    goto Menu
)

call :Verify
if "!verifyOK!"=="1" goto Register

:: 换源再取一次重新校验
call :FetchSha retry
if defined MSIXSHA (
    call :Verify
    if "!verifyOK!"=="1" goto Register
)

echo.
echo [失败] 安装包校验失败，可能已损坏或不是官方安装包！
del "%MSIX%" >nul 2>&1
echo [提示] 已删除缓存文件，请重新执行安装！
echo.
pause
goto Menu

:Register
:: 导入证书并注册 MSIX
echo [提示] 正在导入证书并注册扩展...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try{ $c=(Get-AuthenticodeSignature -FilePath '%MSIX%').SignerCertificate; if(-not $c){ throw 'NO_CERT' }; $f=Join-Path $env:TEMP 'MiShareMenu.cer'; [IO.File]::WriteAllBytes($f,$c.RawData); Import-Certificate -FilePath $f -CertStoreLocation Cert:\LocalMachine\Root -ErrorAction SilentlyContinue | Out-Null; Import-Certificate -FilePath $f -CertStoreLocation Cert:\LocalMachine\TrustedPeople -ErrorAction SilentlyContinue | Out-Null; Add-AppxPackage -Path '%MSIX%' -ErrorAction Stop; Remove-Item $f -Force -ErrorAction SilentlyContinue }catch{ Remove-Item (Join-Path $env:TEMP 'MiShareMenu.cer') -Force -ErrorAction SilentlyContinue; Write-Output ('INSTALL_FAIL: ' + $_.Exception.Message) }"

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
echo [提示] 若菜单未出现，请重新打开资源管理器窗口或重启电脑。
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
echo 4. 清理下载缓存目录
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
echo [1/4] 正在移除扩展包注册...
powershell -NoProfile -Command "try{ $p = @(Get-AppxPackage -AllUsers -Name %PKGID%); if ($p.Count -eq 0) { Write-Output '[信息] EXT_NOT_FOUND' } else { foreach ($i in $p) { Remove-AppxPackage -Package $i.PackageFullName -AllUsers -ErrorAction Stop; Write-Output ('[信息] REMOVED: ' + $i.PackageFullName) } } }catch{ Write-Output ('[信息] REMOVE_FAIL: ' + $_.Exception.Message) }"

:: 移除系统暂存包
echo [2/4] 正在移除系统暂存包...
powershell -NoProfile -Command "Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -like 'MiShareMenu.Extension*' } | ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName | Out-Null }" >nul 2>&1

:: 移除导入的证书
echo [3/4] 正在移除导入的证书...
powershell -NoProfile -Command "foreach ($s in 'Root','TrustedPeople') { Get-ChildItem ('Cert:\LocalMachine\' + $s) | Where-Object { $_.Subject -like 'CN=ZHAN丶HONG*' } | ForEach-Object { Remove-Item $_.PSPath -Force -ErrorAction SilentlyContinue } }" >nul 2>&1

:: 清理下载缓存目录
echo [4/4] 正在清理下载缓存目录...
if exist "%DLDIR%" (
    rd /s /q "%DLDIR%" >nul 2>&1
    if exist "%DLDIR%" (
        echo [提示] 缓存目录残留：%DLDIR%
    ) else (
        echo [成功] 下载缓存目录已清理！
    )
) else (
    echo [提示] 下载缓存目录不存在！
)

:: 验证卸载结果
echo.
echo [提示] 正在验证卸载结果...
call :GetStatus
if /i "!status_install!"=="未安装" (
    echo [成功] 小米互传扩展卸载成功！
) else (
    echo [失败] 小米互传扩展卸载失败！
    echo [提示] 当前仍安装版本：V!installed!
    echo.
    pause
    goto Menu
)

:: 重启资源管理器
echo [提示] 正在重启资源管理器以生效...
taskkill /f /IM explorer.exe >nul 2>&1
timeout /t 1 >nul
start explorer.exe

echo.
echo [完成] 小米互传扩展已卸载完成！
echo.
pause
goto Menu

:: ============================================================
:: 从仓库获取官方校验值
:: ============================================================
:FetchSha
set "MSIXSHA="
set "SHAFILE=%DLDIR%\MiShareMenu.sha256"
if not exist "%DLDIR%" md "%DLDIR%" >nul 2>&1
del "%SHAFILE%" >nul 2>&1
if "%~1"=="retry" (
    echo [提示] 正在从 GitHub 重新获取...
    curl.exe -fL -s --retry 2 --connect-timeout 10 --max-time 30 -o "%SHAFILE%" "%SHAURL2%" >nul 2>&1
) else (
    echo [提示] 正在获取官方校验值...
    curl.exe -fL -s --retry 2 --connect-timeout 10 --max-time 30 -o "%SHAFILE%" "%SHAURL1%" >nul 2>&1
    if not exist "%SHAFILE%" (
        echo [提示] jsDelivr 获取校验值失败，改用 GitHub ...
        curl.exe -fL -s --retry 2 --connect-timeout 10 --max-time 30 -o "%SHAFILE%" "%SHAURL2%" >nul 2>&1
    )
)
if exist "%SHAFILE%" for /f "usebackq tokens=1" %%A in ("%SHAFILE%") do if not defined MSIXSHA set "MSIXSHA=%%A"
set "SHAOK="
if defined MSIXSHA for /f "delims=" %%A in ('powershell -NoProfile -Command "if('!MSIXSHA!' -match '^[0-9a-fA-F]{64}$'){ '!MSIXSHA!'.ToUpper() }"') do set "SHAOK=%%A"
set "MSIXSHA=!SHAOK!"
if defined MSIXSHA (
    echo [信息] 官方校验值：!MSIXSHA!
) else (
    echo [警告] 未获取到官方校验值，将跳过完整性校验！
)
exit /b 0

:: ============================================================
:: 校验安装包
:: ============================================================
:Verify
set "verifyOK=0"
set "fsize="
for %%F in ("%MSIX%") do set "fsize=%%~zF"
if not defined fsize exit /b 0
if !fsize! LSS 50000 (
    echo [警告] 下载不完整（仅 !fsize! 字节）
    exit /b 0
)
if not defined MSIXSHA (
    echo [提示] 未获取到官方校验值，将跳过完整性校验！
    set "verifyOK=1"
    exit /b 0
)
echo [提示] 正在校验安装包完整性（!fsize! 字节）...
powershell -NoProfile -Command "$h=''; try{ $h=(Get-FileHash -LiteralPath '%MSIX%' -Algorithm SHA256).Hash.ToUpper() }catch{ }; if($h -eq '!MSIXSHA!'){ Write-Host '[信息] HASH_OK'; exit 0 } else { Write-Host '[信息] HASH_FAIL'; exit 1 }"
if errorlevel 1 exit /b 0
echo [成功] 安装包已校验通过！
set "verifyOK=1"
exit /b 0
