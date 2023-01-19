{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Database.Redis.Cluster
  ( Connection(..)
  , NodeRole(..)
  , NodeConnection(..)
  , Node(..)
  , ShardMap(..)
  , HashSlot
  , Shard(..)
  , connect
  , disconnect
  , requestPipelined
  , requestMasterNodes
  , nodes
) where

import qualified Data.ByteString as B
import Data.Char(toLower)
import qualified Data.ByteString.Char8 as Char8
import qualified Data.IORef as IOR
import Data.Maybe(mapMaybe, fromMaybe)
import Data.List(nub, sortBy, find)
import Data.Map(fromListWith, assocs)
import Data.Function(on)
import Control.Exception(Exception, SomeException, throwIO, BlockedIndefinitelyOnMVar(..), catches, Handler(..), try)
import Control.Concurrent.Async(race)
import Control.Concurrent(threadDelay)
import Control.Concurrent.MVar(MVar, newMVar, readMVar, modifyMVar, modifyMVar_)
import Control.DeepSeq(deepseq)
import Control.Monad(zipWithM, when, replicateM)
import Database.Redis.Cluster.HashSlot(HashSlot, keyToSlot)
import qualified Database.Redis.ConnectionContext as CC
import qualified Data.HashMap.Strict as HM
import qualified Data.IntMap.Strict as IntMap
import           Data.Typeable
import qualified Scanner
import System.IO.Unsafe(unsafeInterleaveIO)
import Say(sayString)

import Database.Redis.Protocol(Reply(Error), renderRequest, reply)
import qualified Database.Redis.Cluster.Command as CMD

-- This module implements a clustered connection whilst maintaining
-- compatibility with the original Hedis codebase. In particular it still
-- performs implicit pipelining using `unsafeInterleaveIO` as the single node
-- codebase does. To achieve this each connection carries around with it a
-- pipeline of commands. Every time `sendRequest` is called the command is
-- added to the pipeline and an IO action is returned which will, upon being
-- evaluated, execute the entire pipeline. If the pipeline is already executed
-- then it just looks up it's response in the executed pipeline.

-- | A connection to a redis cluster, it is composed of a map from Node IDs to
-- | 'NodeConnection's, a 'Pipeline', and a 'ShardMap'
type IsReadOnly = Bool

data Connection = Connection (HM.HashMap NodeID NodeConnection) (MVar Pipeline) (MVar ShardMap) CMD.InfoMap IsReadOnly

-- | A connection to a single node in the cluster, similar to 'ProtocolPipelining.Connection'
data NodeConnection = NodeConnection CC.ConnectionContext (IOR.IORef (Maybe B.ByteString)) NodeID

instance Eq NodeConnection where
    (NodeConnection _ _ id1) == (NodeConnection _ _ id2) = id1 == id2

instance Ord NodeConnection where
    compare (NodeConnection _ _ id1) (NodeConnection _ _ id2) = compare id1 id2

data PipelineState =
      -- Nothing in the pipeline has been evaluated yet so nothing has been 
      -- sent
      Pending [[B.ByteString]]
      -- This pipeline has been executed, the replies are contained within it
    | Executed [Reply]
-- A pipeline has an MVar for the current state, this state is actually always
-- `Pending` because the first thing the implementation does when executing a
-- pipeline is to take the current pipeline state out of the MVar and replace
-- it with a new `Pending` state. The executed state is held on to by the
-- replies within it.
newtype Pipeline = Pipeline (MVar PipelineState)

data NodeRole = Master | Slave deriving (Show, Eq, Ord)

type Host = String
type Port = Int
type NodeID = B.ByteString
-- Represents a single node, note that this type does not include the 
-- connection to the node because the shard map can be shared amongst multiple
-- connections
data Node = Node NodeID NodeRole Host Port deriving (Show, Eq, Ord)

type MasterNode = Node
type SlaveNode = Node

-- A 'shard' is a master node and 0 or more slaves, (the 'master', 'slave'
-- terminology is unfortunate but I felt it better to follow the documentation
-- until it changes).
data Shard = Shard MasterNode [SlaveNode] deriving (Show, Eq, Ord)

-- A map from hashslot to shards
newtype ShardMap = ShardMap (IntMap.IntMap Shard) deriving (Show)

newtype MissingNodeException = MissingNodeException [B.ByteString] deriving (Show, Typeable)
instance Exception MissingNodeException

newtype UnsupportedClusterCommandException = UnsupportedClusterCommandException [B.ByteString] deriving (Show, Typeable)
instance Exception UnsupportedClusterCommandException

newtype CrossSlotException = CrossSlotException [B.ByteString] deriving (Show, Typeable)
instance Exception CrossSlotException

data NoNodeException = NoNodeException  deriving (Show, Typeable)
instance Exception NoNodeException

connect :: (Host -> CC.PortID -> Maybe Int -> IO CC.ConnectionContext) -> [CMD.CommandInfo] -> MVar ShardMap -> Maybe Int -> Bool -> (NodeConnection -> IO ShardMap) -> IO Connection
connect withAuth commandInfos shardMapVar timeoutOpt isReadOnly refreshShardMap = do
        shardMap <- readMVar shardMapVar
        stateVar <- newMVar $ Pending []
        pipelineVar <- newMVar $ Pipeline stateVar
        (eNodeConns, shouldRetry) <- nodeConnections shardMap
        -- whenever one of the node connection is not established,
        -- will refresh the slots and retry node connections.
        -- This would handle fail over, IP change use cases.
        nodeConns <-
          if shouldRetry
            then if not (HM.null eNodeConns)
                    then do
                      newShardMap <- refreshShardMap (head $ HM.elems eNodeConns)
                      refreshShardMapVar "locked refreshing due to connection issues" newShardMap
                      simpleNodeConnections newShardMap
                    else
                      throwIO NoNodeException
            else
              return eNodeConns
        return $ Connection nodeConns pipelineVar shardMapVar (CMD.newInfoMap commandInfos) isReadOnly where
    simpleNodeConnections :: ShardMap -> IO (HM.HashMap NodeID NodeConnection)
    simpleNodeConnections shardMap = HM.fromList <$> mapM connectNode (nub $ nodes shardMap)
    nodeConnections :: ShardMap -> IO (HM.HashMap NodeID NodeConnection, Bool)
    nodeConnections shardMap = do
      info <- mapM (try . connectNode) (nub $ nodes shardMap)
      return $
        foldl (\(acc, accB) x -> case x of
                    Right (v, nc) -> (HM.insert v nc acc, accB)
                    Left (_ :: SomeException) -> (acc, True)
           ) (mempty, False) info
    connectNode :: Node -> IO (NodeID, NodeConnection)
    connectNode (Node n _ host port) = do
        ctx <- withAuth host (CC.PortNumber $ toEnum port) timeoutOpt
        ref <- IOR.newIORef Nothing
        return (n, NodeConnection ctx ref n)
    refreshShardMapVar :: String -> ShardMap -> IO ()
    refreshShardMapVar msg shardMap = hasLocked msg $ modifyMVar_ shardMapVar (const (pure shardMap))

disconnect :: Connection -> IO ()
disconnect (Connection nodeConnMap _ _ _ _ ) = mapM_ disconnectNode (HM.elems nodeConnMap) where
    disconnectNode (NodeConnection nodeCtx _ _) = CC.disconnect nodeCtx

-- Add a request to the current pipeline for this connection. The pipeline will
-- be executed implicitly as soon as any result returned from this function is
-- evaluated.
requestPipelined :: IO ShardMap -> Connection -> [B.ByteString] -> IO Reply
requestPipelined refreshAction conn@(Connection _ pipelineVar shardMapVar _ _) nextRequest = modifyMVar pipelineVar $ \(Pipeline stateVar) -> do
    (newStateVar, repliesIndex) <- hasLocked "locked adding to pipeline" $ modifyMVar stateVar $ \case
        Pending requests | length requests > 1000 -> do
            replies <- evaluatePipeline shardMapVar refreshAction conn (nextRequest:requests)
            return (Executed replies, (stateVar, length requests))
        Pending requests ->
            return (Pending (nextRequest:requests), (stateVar, length requests))
        e@(Executed _) -> do
            s' <- newMVar $ Pending [nextRequest]
            return (e, (s', 0))
    evaluateAction <- unsafeInterleaveIO $ do
        replies <- hasLocked "locked evaluating replies" $ modifyMVar newStateVar $ \case
            Executed replies ->
                return (Executed replies, replies)
            Pending requests-> do
                replies <- evaluatePipeline shardMapVar refreshAction conn requests
                replies `deepseq` return (Executed replies, replies)
        return $ replies !! repliesIndex
    return (Pipeline newStateVar, evaluateAction)



data PendingRequest = PendingRequest Int [B.ByteString]
data CompletedRequest = CompletedRequest Int [B.ByteString] Reply

rawRequest :: PendingRequest -> [B.ByteString]
rawRequest (PendingRequest _ r) =  r

responseIndex :: CompletedRequest -> Int
responseIndex (CompletedRequest i _ _) = i

rawResponse :: CompletedRequest -> Reply
rawResponse (CompletedRequest _ _ r) = r

requestForResponse :: CompletedRequest -> [B.ByteString]
requestForResponse (CompletedRequest _ r _) = r

-- The approach we take here is similar to that taken by the redis-py-cluster
-- library, which is described at https://redis-py-cluster.readthedocs.io/en/master/pipelines.html
--
-- Essentially we group all the commands by node (based on the current shardmap)
-- and then execute a pipeline for each node (maintaining the order of commands
-- on a per node basis but not between nodes). Once we've done this, if any of
-- the commands have resulted in a MOVED error we refresh the shard map, then
-- we run through all the responses and retry any MOVED or ASK errors. This retry
-- step is not pipelined, there is a request per error. This is probably
-- acceptable in most cases as these errors should only occur in the case of
-- cluster reconfiguration events, which should be rare.
evaluatePipeline :: MVar ShardMap -> IO ShardMap -> Connection -> [[B.ByteString]] -> IO [Reply]
evaluatePipeline shardMapVar refreshShardmapAction conn requests = do
        shardMap <- hasLocked "reading shardmap in evaluatePipeline" $ readMVar shardMapVar
        requestsByNode <- getRequestsByNode shardMap
        -- catch the exception thrown at each node level
        -- send the command to random node.
        -- merge the current responses with new responses.
        eresps <- mapM (try . uncurry executeRequests) requestsByNode
        -- take a random connection where there are no exceptions.
        -- PERF_CONCERN: Since usually we send only one request at time, this won't be
        -- heavy perf issue. but still should be evaluated and figured out with complete rewrite.
        resps <- concat <$> mapM (\(resp, (cc, r)) -> case resp of
                                        Right v -> return v
                                        Left (_ :: SomeException) -> executeRequests (getRandomConnection cc) r
                      ) (zip eresps requestsByNode)
        -- check for any moved in both responses and continue the flow.
        when (any (moved . rawResponse) resps) (refreshShardMapVar "locked refreshing due to moved responses")
        retriedResps <- mapM (retry 0) resps
        return $ map rawResponse $ sortBy (on compare responseIndex) retriedResps
  where
    getRandomConnection :: NodeConnection -> NodeConnection
    getRandomConnection nc =
      let (Connection hmn _ _ _ _) = conn
          conns = HM.elems hmn
          in fromMaybe (head conns) $ find (nc /= ) conns
    getRequestsByNode :: ShardMap -> IO [(NodeConnection, [PendingRequest])]
    getRequestsByNode shardMap = do
        commandsWithNodes <- zipWithM (requestWithNode shardMap) (reverse [0..(length requests - 1)]) requests
        return $ assocs $ fromListWith (++) commandsWithNodes
    requestWithNode :: ShardMap -> Int -> [B.ByteString] -> IO (NodeConnection, [PendingRequest])
    requestWithNode shardMap index request = do
        nodeConn <- nodeConnectionForCommand conn shardMap request
        return (nodeConn, [PendingRequest index request])
    executeRequests :: NodeConnection -> [PendingRequest] -> IO [CompletedRequest]
    executeRequests nodeConn nodeRequests = do
        replies <- requestNode nodeConn $ map rawRequest nodeRequests
        return $ zipWith (curry (\(PendingRequest i r, rep) -> CompletedRequest i r rep)) nodeRequests replies
    retry :: Int -> CompletedRequest -> IO CompletedRequest
    retry retryCount resp@(CompletedRequest index request thisReply) = do
        print $ "inside retried: " <> show request <> " with respo: " <> show thisReply
        retryReply <- case thisReply of
            (Error errString) | B.isPrefixOf "MOVED" errString -> do
                shardMap <- hasLocked "reading shard map in retry MOVED" $ readMVar shardMapVar
                nodeConn <- nodeConnectionForCommand conn shardMap (requestForResponse resp)
                head <$> requestNode nodeConn [request]
            (askingRedirection -> Just (host, port)) -> do
                shardMap <- hasLocked "reading shardmap in retry ASK" $ readMVar shardMapVar
                let maybeAskNode = nodeConnWithHostAndPort shardMap conn host port
                case maybeAskNode of
                    Just askNode -> last <$> requestNode askNode [["ASKING"], requestForResponse resp]
                    Nothing -> case retryCount of
                        0 -> do
                            _ <- refreshShardMapVar "missing node in first retry of ASK"
                            rawResponse <$> retry (retryCount + 1) resp
                        _ -> throwIO $ MissingNodeException (requestForResponse resp)
            _ -> return thisReply
        return (CompletedRequest index request retryReply)
    refreshShardMapVar :: String -> IO ()
    refreshShardMapVar msg = hasLocked msg $ modifyMVar_ shardMapVar (const refreshShardmapAction)


askingRedirection :: Reply -> Maybe (Host, Port)
askingRedirection (Error errString) = case Char8.words errString of
    ["ASK", _, hostport] -> case Char8.split ':' hostport of
       [host, portString] -> case Char8.readInt portString of
         Just (port,"") -> Just (Char8.unpack host, port)
         _ -> Nothing
       _ -> Nothing
    _ -> Nothing
askingRedirection _ = Nothing

moved :: Reply -> Bool
moved (Error errString) = case Char8.words errString of
    "MOVED":_ -> True
    _ -> False
moved _ = False


nodeConnWithHostAndPort :: ShardMap -> Connection -> Host -> Port -> Maybe NodeConnection
nodeConnWithHostAndPort shardMap (Connection nodeConns _ _ _ _) host port = do
    node <- nodeWithHostAndPort shardMap host port
    HM.lookup (nodeId node) nodeConns

nodeConnectionForCommand :: Connection -> ShardMap -> [B.ByteString] -> IO NodeConnection
nodeConnectionForCommand (Connection nodeConns _ _ infoMap connReadOnly) (ShardMap shardMap) request = do
    let mek = case request of
          ("MULTI" : key : _) -> Just [key]
          ("EXEC" : key : _) -> Just [key]
          _ -> Nothing
        isCmdReadOnly = isCommandReadonly infoMap request
    keys <- case CMD.keysForRequest infoMap request of
        Nothing -> throwIO $ UnsupportedClusterCommandException request
        Just k -> return k
    print $ "keys computed: " <> show keys <> " for request: " <> show request 
    let shards = nub $ mapMaybe ((flip IntMap.lookup shardMap) . fromEnum . keyToSlot) (fromMaybe keys mek)
    node <- case (shards, connReadOnly) of
        ([],_) -> throwIO $ MissingNodeException request
        ([Shard master _], False) ->
            return master
        ([Shard master []], True) ->
            return master
        ([Shard master (slave: _)], True) ->
            if isCmdReadOnly
                then return slave
                else return master
        _ -> throwIO $ CrossSlotException request
    maybe (throwIO $ MissingNodeException request) return (HM.lookup (nodeId node) nodeConns)
    where
        isCommandReadonly :: CMD.InfoMap -> [B.ByteString] -> Bool
        isCommandReadonly (CMD.InfoMap iMap) (command: _) =
            let
                info = HM.lookup (map toLower $ Char8.unpack command) iMap
            in maybe False (CMD.ReadOnly `elem`) (CMD.flags <$> info)
        isCommandReadonly _ _ = False

cleanRequest :: [B.ByteString] -> [B.ByteString]
cleanRequest ("MULTI" : _) = ["MULTI"]
cleanRequest ("EXEC" : _) = ["EXEC"]
cleanRequest req = req

requestNode :: NodeConnection -> [[B.ByteString]] -> IO [Reply]
requestNode (NodeConnection ctx lastRecvRef _) requests = do
  eresp <- race requestNodeImpl (threadDelay 1000000) -- 100 ms
  case eresp of
    Left e -> return e
    Right _ -> putStrLn "timeout happened" *> throwIO NoNodeException
    where

    requestNodeImpl :: IO [Reply]
    requestNodeImpl = do
        let reqs = map cleanRequest requests
        _ <- mapM_ (sendNode . renderRequest) reqs
        _ <- CC.flush ctx
        replicateM (length requests) recvNode

    sendNode :: B.ByteString -> IO ()
    sendNode = CC.send ctx
    recvNode :: IO Reply
    recvNode = do
        maybeLastRecv <- IOR.readIORef lastRecvRef
        scanResult <- case maybeLastRecv of
            Just lastRecv -> Scanner.scanWith (CC.recv ctx) reply lastRecv
            Nothing -> Scanner.scanWith (CC.recv ctx) reply B.empty

        case scanResult of
          Scanner.Fail{}       -> CC.errConnClosed
          Scanner.More{}    -> error "Hedis: parseWith returned Partial"
          Scanner.Done rest' r -> do
            IOR.writeIORef lastRecvRef (Just rest')
            return r

{-# INLINE nodes #-}
nodes :: ShardMap -> [Node]
nodes (ShardMap shardMap) = concatMap snd $ IntMap.toList $ fmap shardNodes shardMap where
    shardNodes :: Shard -> [Node]
    shardNodes (Shard master slaves) = master:slaves


nodeWithHostAndPort :: ShardMap -> Host -> Port -> Maybe Node
nodeWithHostAndPort shardMap host port = find (\(Node _ _ nodeHost nodePort) -> port == nodePort && host == nodeHost) (nodes shardMap)

nodeId :: Node -> NodeID
nodeId (Node theId _ _ _) = theId

hasLocked :: String -> IO a -> IO a
hasLocked msg action =
  action `catches`
  [ Handler $ \exc@BlockedIndefinitelyOnMVar -> sayString ("[MVar]: " ++ msg) >> throwIO exc
  ]


requestMasterNodes :: Connection -> [B.ByteString] -> IO [Reply]
requestMasterNodes conn req = do
    masterNodeConns <- masterNodes conn
    concat <$> mapM (`requestNode` [req]) masterNodeConns

masterNodes :: Connection -> IO [NodeConnection]
masterNodes (Connection nodeConns _ shardMapVar _ _) = do
    (ShardMap shardMap) <- readMVar shardMapVar
    let masters = map ((\(Shard m _) -> m) . snd) $ IntMap.toList shardMap
    let masterNodeIds = map nodeId masters
    return $ mapMaybe (`HM.lookup` nodeConns) masterNodeIds

