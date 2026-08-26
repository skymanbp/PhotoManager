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

/* P5-D (round-28 #1): the path an OPEN HANDLE is actually bound to.
 *
 * This is the primitive that closes the TOCTOU window between "resolve the
 * path" and "open it by name".  The answer is derived from the handle we are
 * about to read from, so nothing an attacker does AFTER the open can change
 * it, and anything done BEFORE the open shows up as a different path.
 *
 * FILE_NAME_NORMALIZED | VOLUME_NAME_DOS (both 0) => "\\?\D:\dir\file".
 * Same one-call discipline as above: the return value and GetLastError must
 * be read on the same OS thread. */
DWORD pm_final_path_by_handle(HANDLE h, LPWSTR buf, DWORD cch, DWORD *err)
{
    DWORD n = GetFinalPathNameByHandleW(h, buf, cch, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    *err = (n == 0) ? GetLastError() : 0;
    return n;
}

/* P6-C (roadmap #3): commit-time operations by HANDLE.
 *
 * MoveFileExW / DeleteFileW take only a NAME: between "resolveUnder said this
 * path is fine" and the actual syscall there is a window in which a directory
 * on the way can be swapped for a junction.  These three primitives let the
 * Haskell side (Pm.Win.moveBoundNoReplace / deleteBoundAt) commit through a
 * handle instead: open once, verify what the handle is bound to, then rename/
 * dispose ON THE HANDLE.  MSDN: for SetFileInformationByHandle the
 * FILE_RENAME_INFO.RootDirectory member must be NULL, so the destination side
 * cannot be pre-bound -- the Haskell side re-asks the SAME handle where the
 * object ended up after the rename (post-verification + rename-back).
 *
 * calloc zeroes the struct, which is exactly ReplaceIfExists = FALSE and
 * RootDirectory = NULL -- and sidesteps the ReplaceIfExists/Flags anonymous
 * union spelling differences between SDK header versions. */
#include <stdlib.h>
#include <string.h>

DWORD pm_open_for_dispose(LPCWSTR path, HANDLE *out, DWORD *err)
{
    HANDLE h = CreateFileW(path, DELETE | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING,
                           FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                           NULL);
    if (h == INVALID_HANDLE_VALUE) { *out = NULL; *err = GetLastError(); return 0; }
    *out = h;
    *err = 0;
    return 1;
}

DWORD pm_rename_by_handle(HANDLE h, LPCWSTR new_full, DWORD *err)
{
    size_t len = wcslen(new_full);
    size_t bytes = len * sizeof(WCHAR);
    size_t sz = sizeof(FILE_RENAME_INFO) + bytes;
    FILE_RENAME_INFO *ri = (FILE_RENAME_INFO *)calloc(1, sz);
    if (!ri) { *err = ERROR_OUTOFMEMORY; return 0; }
    ri->FileNameLength = (DWORD)bytes;
    memcpy(ri->FileName, new_full, bytes);
    BOOL ok = SetFileInformationByHandle(h, FileRenameInfo, ri, (DWORD)sz);
    *err = ok ? 0 : GetLastError();
    free(ri);
    return ok ? 1 : 0;
}

DWORD pm_delete_by_handle(HANDLE h, DWORD *err)
{
    FILE_DISPOSITION_INFO di;
    di.DeleteFile = TRUE;
    BOOL ok = SetFileInformationByHandle(h, FileDispositionInfo, &di, sizeof di);
    *err = ok ? 0 : GetLastError();
    return ok ? 1 : 0;
}
