{- git-annex special remote configuration
 -
 - Copyright 2011-2019 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

module Annex.SpecialRemote (
	module Annex.SpecialRemote,
	module Annex.SpecialRemote.Config
) where

import Annex.Common
import Annex.SpecialRemote.Config
import Remote (remoteTypes)
import Types.Remote (RemoteConfig, SetupStage(..), typename, setup)
import Types.GitConfig
import Config
import Remote.List
import Logs.Remote
import Logs.Trust
import qualified Git.Config
import qualified Types.Remote as Remote
import Git.Types (RemoteName)

import qualified Data.Map as M
import Data.Ord

{- See if there's an existing special remote with this name.
 -
 - Prefer remotes that are not dead when a name appears multiple times. -}
findExisting :: RemoteName -> Annex (Maybe (UUID, RemoteConfig, Maybe (ConfigFrom UUID)))
findExisting name = do
	t <- trustMap
	headMaybe
		. sortBy (comparing $ \(u, _, _) -> Down $ M.lookup u t)
		. findByName name
		<$> Logs.Remote.readRemoteLog

findByName :: RemoteName ->  M.Map UUID RemoteConfig -> [(UUID, RemoteConfig, Maybe (ConfigFrom UUID))]
findByName n = map sameasuuid . filter (matching . snd) . M.toList
  where
	matching c = case lookupName c of
		Nothing -> False
		Just n'
			| n' == n -> True
			| otherwise -> False
	sameasuuid (u, c) = case M.lookup sameasUUIDField c of
		Nothing -> (u, c, Nothing)
		Just u' -> (toUUID u', c, Just (ConfigFrom u))

newConfig
	:: RemoteName
	-> Maybe (Sameas UUID)
	-> RemoteConfig
	-- ^ configuration provided by the user
	-> M.Map UUID RemoteConfig
	-- ^ configuration of other special remotes, to inherit from
	-- when sameas is used
	-> RemoteConfig
newConfig name sameas fromuser m = case sameas of
	Nothing -> M.insert nameField name fromuser
	Just (Sameas u) -> addSameasInherited m $ M.fromList
		[ (sameasNameField, name)
		, (sameasUUIDField, fromUUID u)
		] `M.union` fromuser

specialRemoteMap :: Annex (M.Map UUID RemoteName)
specialRemoteMap = do
	m <- Logs.Remote.readRemoteLog
	return $ M.fromList $ mapMaybe go (M.toList m)
  where
	go (u, c) = case lookupName c of
		Nothing -> Nothing
		Just n -> Just (u, n)

{- find the remote type -}
findType :: RemoteConfig -> Either String RemoteType
findType config = maybe unspecified specified $ M.lookup typeField config
  where
	unspecified = Left "Specify the type of remote with type="
	specified s = case filter (findtype s) remoteTypes of
		[] -> Left $ "Unknown remote type " ++ s
		(t:_) -> Right t
	findtype s i = typename i == s

autoEnable :: Annex ()
autoEnable = do
	remotemap <- M.filter configured <$> readRemoteLog
	enabled <- getenabledremotes
	forM_ (M.toList remotemap) $ \(cu, c) -> unless (cu `M.member` enabled) $ do
		let u = case findSameasUUID c of
			Just (Sameas u') -> u'
			Nothing -> cu
		case (lookupName c, findType c) of
			(Just name, Right t) -> whenM (canenable u) $ do
				showSideAction $ "Auto enabling special remote " ++ name
				dummycfg <- liftIO dummyRemoteGitConfig
				tryNonAsync (setup t (Enable c) (Just u) Nothing c dummycfg) >>= \case
					Left e -> warning (show e)
					Right (_c, _u) ->
						when (cu /= u) $
							setConfig (remoteConfig c "config-uuid") (fromUUID cu)
			_ -> return ()
  where
	configured rc = fromMaybe False $
		Git.Config.isTrue =<< M.lookup autoEnableField rc
	canenable u = (/= DeadTrusted) <$> lookupTrust u
	getenabledremotes = M.fromList
		. map (\r -> (getcu r, r))
		<$> remoteList
	getcu r = fromMaybe
		(Remote.uuid r)
		(remoteAnnexConfigUUID (Remote.gitconfig r))
