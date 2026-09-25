module System.Win32.File where
import System.Win32.Types

type AccessMode = UINT
type ShareMode = UINT
type CreateMode = UINT
type FileAttributeOrFlag = UINT

data BY_HANDLE_FILE_INFORMATION = BY_HANDLE_FILE_INFORMATION
  { bhfiFileAttributes :: DWORD
  , bhfiVolumeSerialNumber :: DWORD
  , bhfiSize :: DDWORD
  , bhfiNumberOfLinks :: DWORD
  , bhfiFileIndex :: DDWORD
  } deriving (Show)

gENERIC_READ, gENERIC_WRITE :: AccessMode
gENERIC_READ = 0x80000000
gENERIC_WRITE = 0x40000000
fILE_SHARE_NONE :: ShareMode
fILE_SHARE_NONE = 0
cREATE_NEW, oPEN_EXISTING :: CreateMode
cREATE_NEW = 1
oPEN_EXISTING = 3
fILE_ATTRIBUTE_NORMAL, fILE_ATTRIBUTE_REPARSE_POINT :: FileAttributeOrFlag
fILE_ATTRIBUTE_NORMAL = 0x80
fILE_ATTRIBUTE_REPARSE_POINT = 0x400

createFile :: String -> AccessMode -> ShareMode -> Maybe LPSECURITY_ATTRIBUTES -> CreateMode -> FileAttributeOrFlag -> Maybe HANDLE -> IO HANDLE
createFile = error "Win32 stub (Linux harness): createFile"
closeHandle :: HANDLE -> IO ()
closeHandle = error "Win32 stub (Linux harness): closeHandle"
flushFileBuffers :: HANDLE -> IO ()
flushFileBuffers = error "Win32 stub (Linux harness): flushFileBuffers"
getFileInformationByHandle :: HANDLE -> IO BY_HANDLE_FILE_INFORMATION
getFileInformationByHandle = error "Win32 stub (Linux harness): getFileInformationByHandle"
getLogicalDrives :: IO DWORD
getLogicalDrives = error "Win32 stub (Linux harness): getLogicalDrives"
