@echo off
rem Builds Aseprite from .\aseprite against the prebuilt Skia in .\deps\skia.
rem Output: .\aseprite\build\bin\aseprite.exe
setlocal
set ROOT=%~dp0..
set VS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
set PATH=%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%

set SKIA=%ROOT%\deps\skia
if not exist "%ROOT%\aseprite\build" mkdir "%ROOT%\aseprite\build"
cd /d "%ROOT%\aseprite\build" || exit /b 1

if not exist build.ninja (
  cmake -G Ninja ^
    -DCMAKE_BUILD_TYPE=RelWithDebInfo ^
    -DLAF_BACKEND=skia ^
    -DSKIA_DIR="%SKIA%" ^
    -DSKIA_LIBRARY_DIR="%SKIA%\out\Release-x64" ^
    -DSKIA_LIBRARY="%SKIA%\out\Release-x64\skia.lib" ^
    -DENABLE_UPDATER=OFF ^
    -DENABLE_CCACHE=OFF ^
    .. || exit /b 1
)
ninja aseprite || exit /b 1
echo Built: %CD%\bin\aseprite.exe
