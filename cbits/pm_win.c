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

/* Test-harness precondition (CI probe branch, 2026-08-28): the ACL-injection
 * cases (TestUtil.withDenyAll / withDenyList) assert what pm does when the OS
 * says ACCESS_DENIED.  A process whose token holds SeBackupPrivilege /
 * SeRestorePrivilege ENABLED never sees that: every backup-intent open
 * (GetFileAttributesEx, FindFirstFile, DeleteFile, CreateFile with
 * FILE_FLAG_BACKUP_SEMANTICS -- i.e. exactly pm's probes) bypasses the DACL,
 * while a plain GENERIC_READ open is still denied.  That is what happened on
 * the GitHub windows runner: the token is an elevated administrator's, and
 * MSYS2 bash enables both privileges in its own token at startup, so `stack
 * test` started from bash inherited them enabled -> 9 ACL cases red, every
 * other case green.  The suite disables the two in its OWN token at startup,
 * so the precondition holds regardless of which shell launched it.  A token
 * that does not hold them at all (a normal desktop session) is the normal
 * case: AdjustTokenPrivileges reports ERROR_NOT_ALL_ASSIGNED, nothing to do.
 * Returns 1 on success; on failure 0 with the Win32 error in *err. */
DWORD pm_disable_backup_privileges(DWORD *err)
{
    static const wchar_t *names[2] = { L"SeBackupPrivilege", L"SeRestorePrivilege" };
    HANDLE tok;
    DWORD ok = 1;
    *err = 0;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &tok)) {
        *err = GetLastError();
        return 0;
    }
    for (int i = 0; i < 2; i++) {
        TOKEN_PRIVILEGES tp;
        tp.PrivilegeCount = 1;
        tp.Privileges[0].Attributes = 0; /* 0 = disabled */
        if (!LookupPrivilegeValueW(NULL, names[i], &tp.Privileges[0].Luid)) { *err = GetLastError(); ok = 0; continue; }
        if (!AdjustTokenPrivileges(tok, FALSE, &tp, 0, NULL, NULL)) { *err = GetLastError(); ok = 0; }
        /* returns TRUE with ERROR_NOT_ALL_ASSIGNED when the token lacks it: fine */
    }
    CloseHandle(tok);
    return ok;
}
