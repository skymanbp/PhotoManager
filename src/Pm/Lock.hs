{-# LANGUAGE ScopedTypeVariables #-}

-- | Single-instance guard (invariant I10)。实现自三十一轮起下沉到
-- 'Pm.Config.withRootLock'——'Pm.Config.writeSideCache'（backup-cache 与
-- vault-cache 共用的成对写）需要在自己内部取锁，而 Lock 依赖 Config，原语
-- 只能住在 Config 层。本模块保留为再导出，既有调用点零改动。
module Pm.Lock
  ( withRootLock
  ) where

import Pm.Config (withRootLock)
