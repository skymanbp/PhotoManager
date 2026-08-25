{-# LANGUAGE OverloadedStrings #-}

-- | 只读一个 EXIF 标签：**拍摄时间**（DESIGN-COMMANDS §7 `pm sort`）。
--
-- 为什么自己写而不是引 EXIF 库：这条路径决定「一张照片被归到哪个事件」，
-- 是会落到计划里、最终移动文件的判断依据。本项目所有碰字节的代码都是第一方
-- 且配突变用例；而这里只需要**一个标签**，解析失败的后果又恰好是安全的
-- ——返回 'Nothing'，调用方按「无法判定」单列、不归位（I1：不猜）。
--
-- 覆盖两种容器，都是 TIFF 结构：
--
--  * JPEG：@FFD8@ 开头，逐段找 @APP1(FFE1)@ 且载荷以 @Exif\\0\\0@ 起，其后是 TIFF；
--  * TIFF 系（@.ARW@ @.DNG@ @.NEF@ …）：文件开头就是 TIFF 头。
--
-- 标签优先级：@DateTimeOriginal(0x9003)@ → @DateTimeDigitized(0x9004)@，
-- 两个都在 Exif 子 IFD（IFD0 的 @0x8769@）里。**只认这两个**——IFD0 的
-- @DateTime(0x0132)@ 是**文件修改时间**，不是拍摄时间，曾作为回退存在过，
-- 已删除（理由见 'parseCaptureTime' 内的注释）。
--
-- **一切偏移都经 'sliceAt' 做边界检查**，越界一律 'Nothing'；只读文件头
-- 'headBytes' 字节，EXIF 不在其中就当读不到——不为一个时间戳把整个 RAW
-- （几十 MB）读进内存。
module Pm.Exif
  ( readCaptureTime
  , parseCaptureTime
  , parseExifDateTime
  , headBytes
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Char (isDigit)
import Data.Time (LocalTime (..), fromGregorianValid, makeTimeOfDayValid)
import Data.Word (Word16, Word32)
import System.IO (IOMode (ReadMode), hClose, openBinaryFile)

import Control.Applicative ((<|>))
import Control.Exception (IOException, bracket, evaluate, try)

-- | 只读文件头这么多字节。EXIF 在 JPEG/ARW 里都紧挨文件开头；Exif 子 IFD 的
-- 偏移理论上可以指到更后面，那种情况这里读不到 → 「无法判定」，交用户。
headBytes :: Int
headBytes = 256 * 1024

-- | 读一个文件的拍摄时间。IO 异常（文件被占、权限、消失）一律当读不到。
--
-- 两处都是必需的，缺一不可（对抗审查实测）：
--
--  * @'evaluate'@ —— @pure@ 在 IO 里是**非严格**的，不强制求值就会返回一个
--    抓着整个 256 KiB 缓冲区不放的 thunk。调用方 'Pm.Sort.readTimes' 用
--    @forM@ 先建完整个列表才 force，于是**每张照片同时占 256 KiB**：实测
--    N=800 常驻 193 MB、N=2400 常驻 518 MB，线性增长；一万张的卡就会把堆吃干。
--    强制之后常驻降到 1.3 MB 且与 N 无关。
--  * @'try'@ —— 本函数的 docstring 一直写着"IO 异常一律当读不到"，但此前
--    并没有实现它，契约靠调用方恰好也包了一层 try 才成立。现在自己兑现。
readCaptureTime :: FilePath -> IO (Maybe LocalTime)
readCaptureTime fp = do
  r <-
    try
      ( bracket (openBinaryFile fp ReadMode) hClose (BS.hGet `flip` headBytes)
          >>= evaluate . parseCaptureTime
      )
  pure (either (\(_ :: IOException) -> Nothing) id r)

-- | 纯解析（可测）：给文件头字节，返回拍摄时间。
parseCaptureTime :: BS.ByteString -> Maybe LocalTime
parseCaptureTime bs = do
  (tiff, off) <- locateTiff bs
  end <- endianAt tiff off
  ifd0 <- u32 end tiff (off + 4)
  let entries0 = ifdEntries end tiff off ifd0
      -- Exif 子 IFD：拍摄时间的正主住在这里。
      -- 类型放宽到 4(LONG) 与 13(IFD)——DNG/TIFF Technical Note 1 允许后者，
      -- 只认 4 会把合法文件挡在外面；同时**钉住 eCount == 1**：count > 1 时
      -- 值字段指向的是一个 LONG **数组**，拿它当子 IFD 偏移会解析到垃圾。
      subEntries = case lookupTag 0x8769 entries0 of
        Just e
          | eType e == 4 || eType e == 13
          , eCount e == 1 ->
              -- 子 IFD 偏移与 IFD0 过同一道下界（在 'ifdEntries' 里）：
              -- 伪造的指针指回 TIFF 头内部同样不成立。
              ifdEntries end tiff off (eVal e)
        _ -> []
      -- 只认真正的**拍摄**时间：DateTimeOriginal → DateTimeDigitized。
      --
      -- 曾经还回退到 IFD0 的 @DateTime(0x0132)@，对抗审查指出那是错的：
      -- 0x0132 是**文件修改时间**，而且那条回退是**无条件**的——子 IFD 因为
      -- 任何原因走不通（指针在 256 KiB 头之外、类型不认、偏移越界）都会掉进
      -- 去，于是返回一个"自信的错时间"。对一个据此**搬动文件**的工具来说，
      -- 错时间远比 Nothing 危险：它会把照片默默归进错事件，而 Nothing 只是
      -- 让人自己判断。读不到就读不到。
      raw =
        asciiTag end tiff off 0x9003 subEntries
          <|> asciiTag end tiff off 0x9004 subEntries
  raw >>= parseExifDateTime

-- ─── 容器定位 ───────────────────────────────────────────────────────────────

-- | 返回 (整段字节, TIFF 头在其中的绝对偏移)。所有 IFD 内偏移都相对这个点。
locateTiff :: BS.ByteString -> Maybe (BS.ByteString, Int)
locateTiff bs
  | BS.length bs >= 4, BS.take 2 bs == "ÿØ" = (,) bs <$> jpegApp1 bs 2
  -- 魔数不在这里比：两种容器统一交给 endianAt 一处校验（见其注释）。
  | otherwise = Just (bs, 0)

-- | 在 JPEG 段链里找 APP1/Exif。段头恒为 @FF xx len16(be)@，len 含自身两字节。
-- 逐段前进，遇到 SOS（@FFDA@，其后是压缩数据不再有段头）或越界就放弃。
-- JPEG B.1.1.2 允许标记前有任意多个 @FF@ 填充字节；TEM(@FF01@) 与
-- RST0-7(@FFD0..FFD7@) 是**独立标记**，其后没有长度字段。此前两者都没处理：
-- 填充字节会让 @m1@ 也是 @FF@、从而把 @FFxx@ 当长度读；独立标记则会把其后的
-- 图像数据当长度——两种都让段链走偏，再往下读到的"段头"已是垃圾。
jpegApp1 :: BS.ByteString -> Int -> Maybe Int
jpegApp1 bs i = do
  m0 <- byteAt bs i
  if m0 /= 0xFF
    then Nothing
    else do
      m1 <- byteAt bs (i + 1)
      if m1 == 0xFF
        then jpegApp1 bs (i + 1) -- 填充字节：右移一格重来
        else
          if m1 == 0xDA
            then Nothing -- SOS：其后是压缩数据，不再有段头
            else
              if m1 == 0x01 || (m1 >= 0xD0 && m1 <= 0xD7)
                then jpegApp1 bs (i + 2) -- 独立标记：无长度字段
                else do
                  len <- fromIntegral <$> be16At bs (i + 2)
                  if len < 2
                    then Nothing
                    else
                      if m1 == 0xE1 && sliceAt bs (i + 4) 6 == Just "Exif\x00\x00"
                        then Just (i + 10)
                        else jpegApp1 bs (i + 2 + len)

-- ─── TIFF / IFD ─────────────────────────────────────────────────────────────

-- | True = little-endian，**连 0x002A 魔数一起验**。
--
-- 此前 JPEG 那条路径在 Exif 签名之后直接取偏移，从不校验那里真有 TIFF 头，
-- 而这里又只比两个字节——于是一个载荷以 II / MM 开头的伪 APP1 就能让解析继续
-- 走下去。现在两种容器共用这一处校验，「TIFF 头一定验过」才是无例外的陈述。
endianAt :: BS.ByteString -> Int -> Maybe Bool
endianAt bs off = case sliceAt bs off 4 of
  Just "II\x2A\x00" -> Just True
  Just "MM\x00\x2A" -> Just False
  _ -> Nothing

data IfdEntry = IfdEntry {eTag :: Word16, eType :: Word16, eCount :: Word32, eVal :: Word32}

-- | 读一个 IFD 的全部条目。@base@ 是 TIFF 头在缓冲里的位置，@rel@ 是 IFD
-- **相对 TIFF 头**的偏移——分开传是为了让下界检查有地方落。
--
-- **下界 8**：TIFF 头本身占 0..7（魔数 4 字节 + IFD0 偏移 4 字节），任何 IFD
-- 都不可能从它内部开始；而 @0@ 在 TIFF 里的含义恰恰是「没有 IFD」。此前没有
-- 这道下界，一个声明 @ifd0 = 0@ 的文件会从偏移 0 读条目数——那两个字节正是
-- 魔数的 @"II"@（= 18761 条），于是条目 1 落在偏移 14，构造者在那里放一个
-- 伪造的 @0x8769@ 指针就能让「没有 IFD」的文件返回一个**自信的拍摄时间**
-- （codex 二十五轮 #1；本地探针复现：直 TIFF 与 JPEG APP1 两条路都返回
-- @Just 2026-08-25 13:45:07@）。
--
-- 条目数上限 4096——正常 IFD 只有几十条，这道闸挡住损坏文件里的天文数字
-- 导致的长循环。
ifdEntries :: Bool -> BS.ByteString -> Int -> Word32 -> [IfdEntry]
ifdEntries end bs base rel
  | rel < 8 = []
  | otherwise = case u16 end bs at of
      Nothing -> []
      Just n ->
        [ e
        | i <- [0 .. min 4095 (fromIntegral n - 1)]
        , Just e <- [entryAt (at + 2 + i * 12)]
        ]
 where
  at = base + fromIntegral rel
  entryAt p =
    IfdEntry
      <$> u16 end bs p
      <*> u16 end bs (p + 2)
      <*> u32 end bs (p + 4)
      <*> u32 end bs (p + 8)

lookupTag :: Word16 -> [IfdEntry] -> Maybe IfdEntry
lookupTag t es = case [e | e <- es, eTag e == t] of (e : _) -> Just e; [] -> Nothing

-- | 取一个 ASCII 标签的值。EXIF 时间是 20 字节（含结尾 NUL），一定走外部偏移
-- （> 4 字节放不进条目内联字段），所以只认外部形式。
asciiTag :: Bool -> BS.ByteString -> Int -> Word16 -> [IfdEntry] -> Maybe String
asciiTag _ bs base t es = do
  e <- lookupTag t es
  if eType e /= 2 || eCount e < 19 || eCount e > 64
    then Nothing
    else -- BS.copy：切片与父缓冲共享 ForeignPtr，不复制的话这 20 字节会把整个
    -- 256 KiB 头一起钉在堆上——与 readCaptureTime 的 evaluate 是同一泄漏的两半。
      BC.unpack . BS.copy . BS.takeWhile (/= 0)
        <$> sliceAt bs (base + fromIntegral (eVal e)) (fromIntegral (eCount e))

-- ─── 时间字面量 ─────────────────────────────────────────────────────────────

-- | EXIF 的格式是 @\"YYYY:MM:DD HH:MM:SS\"@。相机在「没设过时间」时会写
-- 全 0（@0000:00:00 00:00:00@），'fromGregorianValid' 会挡掉——那种时间戳
-- 拿去分段只会造出假事件。
parseExifDateTime :: String -> Maybe LocalTime
parseExifDateTime s = case s of
  [y1, y2, y3, y4, ':', m1, m2, ':', d1, d2, ' ', h1, h2, ':', n1, n2, ':', s1, s2] -> do
    y <- num [y1, y2, y3, y4]
    mo <- num [m1, m2]
    d <- num [d1, d2]
    hh <- num [h1, h2]
    mm <- num [n1, n2]
    ss <- num [s1, s2]
    day <- fromGregorianValid (fromIntegral y) mo d
    tod <- makeTimeOfDayValid hh mm (fromIntegral ss)
    pure (LocalTime day tod)
  _ -> Nothing
 where
  num cs
    | all isDigit cs = Just (read cs :: Int)
    | otherwise = Nothing

-- ─── 边界安全的原语 ─────────────────────────────────────────────────────────

-- | **唯一**的取字节口：偏移为负、长度为负、或越过尾端都返回 'Nothing'。
-- 解析器里没有别的路径直接索引，所以「越界即放弃」是无例外的陈述。
sliceAt :: BS.ByteString -> Int -> Int -> Maybe BS.ByteString
sliceAt bs off n
  | off < 0 || n < 0 || off + n > BS.length bs = Nothing
  | otherwise = Just (BS.take n (BS.drop off bs))

byteAt :: BS.ByteString -> Int -> Maybe Int
byteAt bs i = fromIntegral . BS.head <$> sliceAt bs i 1

be16At :: BS.ByteString -> Int -> Maybe Word16
be16At bs i = do
  s <- sliceAt bs i 2
  pure (fromIntegral (BS.index s 0) * 256 + fromIntegral (BS.index s 1))

u16 :: Bool -> BS.ByteString -> Int -> Maybe Word16
u16 end bs i = do
  s <- sliceAt bs i 2
  let b k = fromIntegral (BS.index s k) :: Word16
  pure (if end then b 1 * 256 + b 0 else b 0 * 256 + b 1)

u32 :: Bool -> BS.ByteString -> Int -> Maybe Word32
u32 end bs i = do
  s <- sliceAt bs i 4
  let b k = fromIntegral (BS.index s k) :: Word32
  pure $
    if end
      then b 3 * 16777216 + b 2 * 65536 + b 1 * 256 + b 0
      else b 0 * 16777216 + b 1 * 65536 + b 2 * 256 + b 3
