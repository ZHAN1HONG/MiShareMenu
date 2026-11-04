@echo off
chcp 936 >nul 2>&1
setlocal EnableExtensions
cd /d "%~dp0"
title 小米互传右键菜单 v1.2.0.2

set "SELF=%~f0"
set "HERE=%~dp0"
set "MSIX=%HERE%MiShareMenu.msix"
set "PS1=%HERE%MiShareMenu.ps1"

if /i "%~1"=="/i" goto DO_INSTALL
if /i "%~1"=="/u" goto DO_UNINSTALL
if /i "%~1"=="/r" goto DO_RESTART
if /i "%~1"=="/h" goto HELP

:MENU
cls
echo ================================================================
echo    小米互传右键菜单  v1.2.0.2  (Windows 11 x64)
echo ================================================================
echo.
echo     [1]  安装   —— 右键出现「使用小米互传发送」
echo     [2]  卸载   —— 移除菜单和发送程序
echo     [3]  重启资源管理器   —— 装好后菜单没出现时用
echo     [4]  帮助
echo     [0]  退出
echo.
set "CH="
set /p "CH=请输入数字并回车: "
if "%CH%"=="1" goto NEED_ADMIN_INSTALL
if "%CH%"=="2" goto NEED_ADMIN_UNINSTALL
if "%CH%"=="3" goto DO_RESTART
if "%CH%"=="4" goto HELP
if "%CH%"=="0" exit /b 0
goto MENU

:HELP
cls
echo ================================================================
echo    使用帮助
echo ================================================================
echo.
echo  安装前：Windows 11 64 位 + 已安装「小米电脑管家」并登录。
echo         没装管家时菜单项会自动隐藏，不会留死菜单。
echo.
echo  安装  ：输入 1 回车；弹「用户账户控制」点【是】最稳。
echo          不想授权就点【否】，程序会自动改用开发者模式安装。
echo  使用  ：选中文件或文件夹 - 右键 - 「使用小米互传发送」。
echo  卸载  ：输入 2 回车。
echo  菜单不出现：先选 [3] 重启资源管理器，仍无则注销重新登录；
echo          老系统上可能在「显示更多选项」里。
echo.
echo  本目录必须同时存在这三个文件，缺一不可：
echo    MiShareMenu.cmd    本脚本
echo    MiShareMenu.ps1    安装/卸载逻辑
echo    MiShareMenu.msix   应用包
echo.
echo  命令行参数： /i 安装    /u 卸载    /r 重启资源管理器
echo.
pause
goto MENU

:NEED_ADMIN_INSTALL
call :CHECK_ADMIN
if "%ADMIN%"=="1" goto DO_INSTALL
echo.
echo 正在请求管理员权限，请在弹出的窗口点「是」...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -ArgumentList '/i' -Verb RunAs"
if errorlevel 1 goto INSTALL_NOELEV
exit /b 0

:INSTALL_NOELEV
echo.
echo 已取消授权，改为以当前用户身份安装（必要时自动用开发者模式）。
echo.
goto DO_INSTALL

:NEED_ADMIN_UNINSTALL
call :CHECK_ADMIN
if "%ADMIN%"=="1" goto DO_UNINSTALL
echo.
echo 正在请求管理员权限，请在弹出的窗口点「是」...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -ArgumentList '/u' -Verb RunAs"
if errorlevel 1 goto UNINSTALL_NOELEV
exit /b 0

:UNINSTALL_NOELEV
echo.
echo 已取消授权，继续以当前用户身份卸载（管理员证书残留不影响使用）。
echo.
goto DO_UNINSTALL

:CHECK_ADMIN
set "ADMIN=0"
net session >nul 2>&1
if not errorlevel 1 set "ADMIN=1"
if "%ADMIN%"=="1" exit /b 0
fltmc >nul 2>&1
if not errorlevel 1 set "ADMIN=1"
exit /b 0

:DO_INSTALL
cls
call :CHECK_FILES
if errorlevel 1 exit /b 1
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Action install
set "RC=%errorlevel%"
if not "%RC%"=="0" goto INSTALL_FAIL
echo.
set "CH="
set /p "CH=是否现在重启资源管理器让菜单立即生效? (Y/N): "
if /i "%CH%"=="Y" call :RESTART_EXPLORER
echo.
echo 用法：选中文件或文件夹 - 右键 - 「使用小米互传发送」
echo.
pause
exit /b 0

:INSTALL_FAIL
echo.
echo 安装未成功，请把上面的提示截图反馈。
echo.
pause
exit /b 1

:DO_UNINSTALL
cls
call :CHECK_FILES
if errorlevel 1 exit /b 1
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Action uninstall
set "RC=%errorlevel%"
echo.
set "CH="
set /p "CH=是否现在重启资源管理器? (Y/N): "
if /i "%CH%"=="Y" call :RESTART_EXPLORER
echo.
pause
exit /b %RC%

:DO_RESTART
call :RESTART_EXPLORER
echo 资源管理器已重启。
echo.
pause
exit /b 0

:RESTART_EXPLORER
echo.
echo 正在重启资源管理器...
"%SystemRoot%\System32\taskkill.exe" /f /im explorer.exe >nul 2>&1
"%SystemRoot%\System32\timeout.exe" /t 2 /nobreak >nul
start "" explorer.exe
"%SystemRoot%\System32\timeout.exe" /t 3 /nobreak >nul
exit /b 0

:CHECK_FILES
if exist "%MSIX%" goto CHECK_PS1
echo.
echo [错误] 缺少文件：MiShareMenu.msix
echo        请把 MiShareMenu.msix 与本脚本放在同一个文件夹内。
echo.
pause
exit /b 1
:CHECK_PS1
if exist "%PS1%" exit /b 0
echo.
echo [错误] 缺少文件：MiShareMenu.ps1
echo        请把 MiShareMenu.ps1 与本脚本放在同一个文件夹内。
echo.
pause
exit /b 1
