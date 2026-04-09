pub const c = @cImport({
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");

    // COM macros (IUnknown_Release etc.)
    @cDefine("CINTERFACE", "1");
    @cDefine("COBJMACROS", "1");

    @cInclude("windows.h");
    @cInclude("shellapi.h"); // Shell API for tray icon / balloon notification
    @cInclude("dwmapi.h"); // DWM for transparency
    @cInclude("imm.h"); // IME support
    @cInclude("wincred.h"); // CredUI for password dialogs
    @cInclude("d2d1.h");
    @cInclude("d2d1_1.h"); // ID2D1Factory1, ID2D1Device, ID2D1DeviceContext
    @cInclude("dwrite.h");

    // D3D11 + DXGI
    @cInclude("d3d11.h");
    @cInclude("dxgi.h");
    @cInclude("dxgi1_2.h");
    @cInclude("dxgi1_4.h");
});
