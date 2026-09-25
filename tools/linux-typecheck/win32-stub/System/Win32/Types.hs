module System.Win32.Types where
import Foreign.Ptr (Ptr)
import Foreign.C.Types (CWchar)
import Data.Word (Word32, Word64)
import System.IO (Handle)

type HANDLE = Ptr ()
type DWORD = Word32
type DDWORD = Word64
type UINT = Word32
type TCHAR = CWchar
type LPTSTR = Ptr TCHAR
type LPCTSTR = LPTSTR
type LPSECURITY_ATTRIBUTES = Ptr ()

hANDLEToHandle :: HANDLE -> IO Handle
hANDLEToHandle = error "Win32 stub (Linux harness): hANDLEToHandle"
withHandleToHANDLE :: Handle -> (HANDLE -> IO a) -> IO a
withHandleToHANDLE = error "Win32 stub (Linux harness): withHandleToHANDLE"
peekTString :: LPCTSTR -> IO String
peekTString = error "Win32 stub (Linux harness): peekTString"
withTString :: String -> (LPTSTR -> IO a) -> IO a
withTString = error "Win32 stub (Linux harness): withTString"
failIfFalse_ :: String -> IO Bool -> IO ()
failIfFalse_ = error "Win32 stub (Linux harness): failIfFalse_"
