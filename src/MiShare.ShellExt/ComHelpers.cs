namespace MiShare.ShellExt;

/// <summary>直接操作裸 COM 指针的小工具（只用 IUnknown 的三个方法）。</summary>
internal static unsafe class ComHelpers
{
    public static int QueryInterface(nint punk, Guid* riid, nint* ppv)
    {
        if (punk == 0)
        {
            return ComConstants.E_POINTER;
        }

        var vtbl = *(nint**)punk;
        var fn = (delegate* unmanaged<nint, Guid*, nint*, int>)vtbl[0];
        return fn(punk, riid, ppv);
    }

    public static void AddRef(nint punk)
    {
        if (punk == 0)
        {
            return;
        }

        var vtbl = *(nint**)punk;
        var fn = (delegate* unmanaged<nint, uint>)vtbl[1];
        fn(punk);
    }

    public static void Release(nint punk)
    {
        if (punk == 0)
        {
            return;
        }

        var vtbl = *(nint**)punk;
        var fn = (delegate* unmanaged<nint, uint>)vtbl[2];
        fn(punk);
    }
}
