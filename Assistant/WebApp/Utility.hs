{- git-annex assistant webapp utilities
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

module Assistant.WebApp.Utility where

import Assistant.Common
import Assistant.WebApp
import Assistant.WebApp.Types
import Assistant.DaemonStatus
import Assistant.ThreadedMonad
import Assistant.TransferQueue
import Assistant.TransferSlots
import Assistant.Sync
import qualified Remote
import qualified Types.Remote as Remote
import qualified Remote.List as Remote
import qualified Assistant.Threads.Transferrer as Transferrer
import Logs.Transfer
import Locations.UserConfig
import qualified Config

import qualified Data.Map as M
import Control.Concurrent
import System.Posix.Signals (signalProcessGroup, sigTERM, sigKILL)
import System.Posix.Process (getProcessGroupIDOf)

{- Use Nothing to change global sync setting. -}
changeSyncable :: (Maybe Remote) -> Bool -> Handler ()
changeSyncable Nothing _ = noop -- TODO
changeSyncable (Just r) True = do
	changeSyncFlag r True
	syncRemote r
changeSyncable (Just r) False = do
	changeSyncFlag r False
	d <- getAssistantY id
	let dstatus = daemonStatus d
	let st = threadState d
	liftIO $ runThreadState st $ updateSyncRemotes dstatus
	{- Stop all transfers to or from this remote.
	 - XXX Can't stop any ongoing scan, or git syncs. -}
	void $ liftIO $ dequeueTransfers (transferQueue d) dstatus tofrom
	mapM_ (cancelTransfer False) =<<
		filter tofrom . M.keys <$>
			liftIO (currentTransfers <$> getDaemonStatus dstatus)
	where
		tofrom t = transferUUID t == Remote.uuid r

changeSyncFlag :: Remote -> Bool -> Handler ()
changeSyncFlag r enabled = runAnnex undefined $ do
	Config.setConfig key value
	void $ Remote.remoteListRefresh
	where
		key = Config.remoteConfig (Remote.repo r) "sync"
		value
			| enabled = "true"
			| otherwise = "false"

{- Start syncing remote, using a background thread. -}
syncRemote :: Remote -> Handler ()
syncRemote remote = do
	d <- getAssistantY id
	liftIO $ syncNewRemote
		(threadState d)
		(daemonStatus d)
		(scanRemoteMap d)
		remote

pauseTransfer :: Transfer -> Handler ()
pauseTransfer = cancelTransfer True

cancelTransfer :: Bool -> Transfer -> Handler ()
cancelTransfer pause t = do
	dstatus <- getAssistantY daemonStatus
	tq <- getAssistantY transferQueue
	m <- getCurrentTransfers
	liftIO $ do
		unless pause $
			{- remove queued transfer -}
			void $ dequeueTransfers tq dstatus $
				equivilantTransfer t
		{- stop running transfer -}
		maybe noop (stop dstatus) (M.lookup t m)
	where
		stop dstatus info = do
			{- When there's a thread associated with the
			 - transfer, it's signaled first, to avoid it
			 - displaying any alert about the transfer having
			 - failed when the transfer process is killed. -}
			maybe noop signalthread $ transferTid info
			maybe noop killproc $ transferPid info
			if pause
				then void $
					alterTransferInfo dstatus t $ \i -> i
						{ transferPaused = True }
				else void $
					removeTransfer dstatus t
		signalthread tid
			| pause = throwTo tid PauseTransfer
			| otherwise = killThread tid
		{- In order to stop helper processes like rsync,
		 - kill the whole process group of the process running the 
		 - transfer. -}
		killproc pid = do
			g <- getProcessGroupIDOf pid
			void $ tryIO $ signalProcessGroup sigTERM g
			threadDelay 50000 -- 0.05 second grace period
			void $ tryIO $ signalProcessGroup sigKILL g

startTransfer :: Transfer -> Handler ()
startTransfer t = do
	m <- getCurrentTransfers
	maybe startqueued go (M.lookup t m)
	where
		go info = maybe (start info) resume $ transferTid info
		startqueued = do
			dstatus <- getAssistantY daemonStatus
			q <- getAssistantY transferQueue
			is <- liftIO $ map snd <$> getMatchingTransfers q dstatus (== t)
			maybe noop start $ headMaybe is
		resume tid = do
			dstatus <- getAssistantY daemonStatus
			liftIO $ do
				alterTransferInfo dstatus t $ \i -> i
					{ transferPaused = False }
				throwTo tid ResumeTransfer
		start info = do
			st <- getAssistantY threadState
			dstatus <- getAssistantY daemonStatus
			slots <- getAssistantY transferSlots
			commitchan <- getAssistantY commitChan
			liftIO $ inImmediateTransferSlot dstatus slots $ do
				program <- readProgramFile
				Transferrer.startTransfer st dstatus commitchan program t info

getCurrentTransfers :: Handler TransferMap
getCurrentTransfers = currentTransfers <$> getDaemonStatusY
