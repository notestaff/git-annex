{- git-annex command
 -
 - Copyright 2011-2019 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

module Command.InitRemote where

import qualified Data.Map as M

import Command
import Annex.SpecialRemote
import qualified Remote
import qualified Logs.Remote
import qualified Types.Remote as R
import Annex.UUID
import Logs.UUID
import Logs.Remote
import Types.GitConfig
import Config

cmd :: Command
cmd = command "initremote" SectionSetup
	"creates a special (non-git) remote"
	(paramPair paramName $ paramOptional $ paramRepeating paramKeyValue)
	(seek <$$> optParser)

data InitRemoteOptions = InitRemoteOptions
	{ cmdparams :: CmdParams
	, sameas :: Maybe (DeferredParse UUID)
	}

optParser :: CmdParamsDesc -> Parser InitRemoteOptions
optParser desc = InitRemoteOptions
	<$> cmdParams desc
	<*> optional parseSameasOption

parseSameasOption :: Parser (DeferredParse UUID)
parseSameasOption = parseUUIDOption <$> strOption
	( long "sameas"
	<> metavar (paramRemote `paramOr` paramDesc `paramOr` paramUUID)
	<> help "new remote that accesses the same data"
	<> completeRemotes
	)

seek :: InitRemoteOptions -> CommandSeek
seek o = withWords (commandAction . (start o)) (cmdparams o)

start :: InitRemoteOptions -> [String] -> CommandStart
start _ [] = giveup "Specify a name for the remote."
start o (name:ws) = ifM (isJust <$> findExisting name)
	( giveup $ "There is already a special remote named \"" ++ name ++
		"\". (Use enableremote to enable an existing special remote.)"
	, do
		ifM (isJust <$> Remote.byNameOnly name)
			( giveup $ "There is already a remote named \"" ++ name ++ "\""
			, do
				sameasuuid <- maybe
					(pure Nothing)
					(Just . Sameas <$$> getParsed)
					(sameas o) 
				c <- newConfig name sameasuuid
					(Logs.Remote.keyValToConfig ws)
					<$> readRemoteLog
				t <- either giveup return (findType c)
				starting "initremote" (ActionItemOther (Just name)) $
					perform t name c o
			)
	)

perform :: RemoteType -> String -> R.RemoteConfig -> InitRemoteOptions -> CommandPerform
perform t name c o = do
	dummycfg <- liftIO dummyRemoteGitConfig
	(c', u) <- R.setup t R.Init (sameasu <|> uuidfromuser) Nothing c dummycfg
	next $ cleanup u name c' o
  where
	uuidfromuser = case M.lookup "uuid" c of
		Just s
			| isUUID s -> Just (toUUID s)
			| otherwise -> giveup "invalid uuid"
		Nothing -> Nothing
	sameasu = toUUID <$> M.lookup sameasUUIDField c

cleanup :: UUID -> String -> R.RemoteConfig -> InitRemoteOptions -> CommandCleanup
cleanup u name c o = do
	case sameas o of
		Nothing -> do
			describeUUID u (toUUIDDesc name)
			Logs.Remote.configSet u c
		Just _ -> do
			cu <- liftIO genUUID
			setConfig (remoteConfig c "config-uuid") (fromUUID cu)
			Logs.Remote.configSet cu c
	return True
