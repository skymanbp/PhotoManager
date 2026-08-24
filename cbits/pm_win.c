/* P3b-15 (round-12 #3): GetFileAttributesW + GetLastError must be captured in
 * ONE foreign call.  As two separate Haskell FFI calls, the threaded RTS may
 * run them on different OS threads (GetLastError is per-OS-thread), so the
 * error code read back could belong to some other call.  One C function, one
 * OS thread, no assumption. */
#include <windows.h>

DWORD pm_get_file_attributes_err(LPCWSTR path, DWORD *err)
{
    DWORD a = GetFileAttributesW(path);
    *err = (a == INVALID_FILE_ATTRIBUTES) ? GetLastError() : 0;
    return a;
}
