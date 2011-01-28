{- git-annex command
 -
 - Copyright 2010 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.Unused where

import Control.Monad (filterM, unless)
import Control.Monad.State (liftIO)
import qualified Data.Map as M
import Data.Maybe
import System.FilePath
import System.Directory

import Command
import Types
import Content
import Messages
import Locations
import Utility
import qualified Annex
import qualified GitRepo as Git
import qualified Backend

command :: [Command]
command = [Command "unused" paramNothing seek "look for unused file content"]

seek :: [CommandSeek]
seek = [withNothing start]

{- Finds unused content in the annex. -} 
start :: CommandStartNothing
start = do
	showStart "unused" ""
	return $ Just perform

perform :: CommandPerform
perform = do
	_ <- checkUnused
	return $ Just $ return True

checkUnused :: Annex Bool
checkUnused = do
	showNote "checking for unused data..."
	(unused, staletmp) <- unusedKeys
	let unusedlist = number 0 unused
	let staletmplist = number (length unused) staletmp
	let list = unusedlist ++ staletmplist
	g <- Annex.gitRepo
	liftIO $ safeWriteFile (gitAnnexUnusedLog g) $ unlines $ 
		map (\(n, k) -> show n ++ " " ++ show k) list
	unless (null unused) $
		showLongNote $ unusedmsg unusedlist
	unless (null staletmp) $
		showLongNote $ staletmpmsg staletmplist
	unless (null list) $
		showLongNote $ "\n"
	return $ null list

	where
		unusedmsg u = unlines $
			["Some annexed data is no longer pointed to by any files in the repository:"]
			++ table u ++
			["(To see where data was previously used, try: git log --stat -S'KEY')"] ++
			dropmsg
		staletmpmsg t = unlines $ 
			["Some partially transferred data exists in temporary files:"]
			++ table t ++ dropmsg
		dropmsg = ["(To remove unwanted data: git-annex dropunused NUMBER)"]
			
		table l = ["  NUMBER  KEY"] ++ map cols l
		cols (n,k) = "  " ++ pad 6 (show n) ++ "  " ++ show k
		pad n s = s ++ replicate (n - length s) ' '

number :: Int -> [a] -> [(Int, a)]
number _ [] = []
number n (x:xs) = (n+1, x):(number (n+1) xs)

{- Finds keys whose content is present, but that do not seem to be used
 - by any files in the git repo, or that are only present as tmp files. -}
unusedKeys :: Annex ([Key], [Key])
unusedKeys = do
	g <- Annex.gitRepo
	present <- getKeysPresent
	referenced <- getKeysReferenced
	
	let unused = present `exclude` referenced

	-- Some tmp files may be dups copies of content that is fully present.
	-- Simply delete those, while including the keys for the rest of
	-- the temp files in the returned list for the user to deal with.
	tmps <- tmpKeys
	let staletmp = tmps `exclude` present
	let duptmp = tmps `exclude` staletmp
	_ <- liftIO $ mapM (\t -> removeFile $ gitAnnexTmpLocation g t) duptmp

	return (unused, staletmp)

	where
		-- Constructing a single map, of the set that tends to be
		-- smaller, appears more efficient in both memory and CPU
		-- than constructing and taking the M.difference of two maps.
		exclude [] _ = [] -- optimisation
		exclude smaller larger = M.keys $ remove larger $ existsMap smaller

		existsMap :: Ord k => [k] -> M.Map k Int
		existsMap l = M.fromList $ map (\k -> (k, 1)) l

		remove a b = foldl (flip M.delete) b a

{- List of keys referenced by symlinks in the git repo. -}
getKeysReferenced :: Annex [Key]
getKeysReferenced = do
	g <- Annex.gitRepo
	files <- liftIO $ Git.inRepo g [Git.workTree g]
	keypairs <- mapM Backend.lookupFile files
	return $ map fst $ catMaybes keypairs

{- List of keys that have temp files in the git repo. -}
tmpKeys :: Annex [Key]
tmpKeys = do
	g <- Annex.gitRepo
	let tmp = gitAnnexTmpDir g
	exists <- liftIO $ doesDirectoryExist tmp
	if (not exists)
		then return []
		else do
			contents <- liftIO $ getDirectoryContents tmp
			files <- liftIO $ filterM doesFileExist $
				map (tmp </>) contents
			return $ map (fileKey . takeFileName) files
