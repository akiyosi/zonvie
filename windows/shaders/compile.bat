@echo off
REM Compile shaders to bytecode
REM Run this on Windows with DirectX SDK or Windows SDK installed

echo Compiling vertex shader...
fxc /T vs_5_0 /E VSMain /O3 /Fo vs_main.cso main.hlsl
if errorlevel 1 (
    echo Failed to compile vertex shader
    exit /b 1
)

echo Compiling pixel shader...
fxc /T ps_5_0 /E PSMain /O3 /Fo ps_main.cso main.hlsl
if errorlevel 1 (
    echo Failed to compile pixel shader
    exit /b 1
)

echo.
echo Shaders compiled successfully!
echo.
echo Now run: python generate_zig.py
echo Or manually convert .cso files to Zig byte arrays
