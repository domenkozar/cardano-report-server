{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module Pos.ReportServer.Server
       ( reportServerApp
       , limitBodySize
       ) where

import           Universum

import           Control.Exception (displayException, throwIO)
import           Control.Monad.Trans.Control (MonadBaseControl)
import           Data.Aeson (eitherDecodeStrict)
import           Data.List (lookup)
import qualified Data.Text as T
import           Network.HTTP.Types (StdMethod (POST), parseMethod)
import           Network.HTTP.Types.Status (Status, status200, status404, status413, status500)
import           Network.Wai (Application, Middleware, Request, RequestBodyLength (..), Response,
                              requestBodyLength, requestHeaders, requestMethod, responseLBS)
import           Network.Wai.Parse (File, Param, defaultParseRequestBodyOptions, fileContent,
                                    lbsBackEnd, parseRequestBodyEx)
import           Network.Wai.UrlMap (mapUrls, mount, mountRoot)
import           System.IO (hPutStrLn)

import           Pos.ForwardClient.Client (createTicket, getAgentID)
import           Pos.ForwardClient.Types (Agent, AgentId, CustomReport (..))
import           Pos.ReportServer.ClientInfo (clientInfo)
import           Pos.ReportServer.Exception (ReportServerException (BadRequest, ParameterNotFound),
                                             tryAll)
import           Pos.ReportServer.FileOps (LogsHolder, addEntry)
import           Pos.ReportServer.Report (ReportInfo (..), ReportType (..))
import           Pos.ReportServer.Util (prettifyJson)

limitBodySize :: Word64 -> Middleware
limitBodySize limit application request responseHandler =
    if exceeds
        then onExceeds
        else application request responseHandler
  where
    exceeds =
        case requestBodyLength request of
            ChunkedBody   -> False
            KnownLength l -> l > limit
    onExceeds =
        responseHandler $ responseLBS
            status413
            [("Content-Type", "text/plain")]
            "Request body too large to be processed."

liftAndCatchIO
    :: (MonadIO m, MonadCatch m, MonadBaseControl IO m)
    => IO a -> m (Either ReportServerException a)
liftAndCatchIO = tryAll . liftIO

withStatus :: Status -> T.Text -> Request -> Response
withStatus status msg req = responseLBS status (requestHeaders req) (encodeUtf8 msg)

-- | Gets the list of the uploaded files.
bodyParse :: Request -> IO ([Param], [File LByteString])
bodyParse request = do
    let parseBodyOptions = defaultParseRequestBodyOptions
    parseRequestBodyEx parseBodyOptions lbsBackEnd request

-- Tries to retrieve the `ReportInfo` from the raw `Request`, throwing an exception if
-- the parameter cannot be found.
param :: ByteString -> [Param] -> IO ByteString
param key ps = case lookup key ps of
    Just val -> return val
    Nothing  -> throwIO $ ParameterNotFound (decodeUtf8 key)

reportApp :: LogsHolder -> Agent -> AgentId -> Application
reportApp holder zdAgent zdAgentId req respond =
    case parseMethod (requestMethod req) of
        Right POST -> do
          (!params, !files) <- bodyParse req
          !(payload :: ReportInfo) <-
              either failPayload pure . eitherDecodeStrict =<< param "payload" params
          let logFiles = map (bimap decodeUtf8 fileContent) files
          let cInfo = clientInfo req
          let clientInfoFile = ("client.info", encodeUtf8 $ prettifyJson cInfo)
          res <- liftAndCatchIO $ do
              let allLogs = clientInfoFile : logFiles
              -- Send data to zendesk if needed.
              zResp <-
                  case rReportType payload of
                      RCustomReport{..} -> do
                          let cr = CustomReport crEmail crSubject crProblem
                          Just <$> createTicket zdAgent zdAgentId cr allLogs
                      _                 -> pure Nothing
              -- Put record into the local storage.
              addEntry holder payload allLogs
              pure zResp
          case res of
              Right maybeZDResp -> do
                  let respText = fromMaybe mempty $ decodeUtf8 <$> maybeZDResp
                  respond (with200Response respText req)
              Left e -> do
                  let ex = displayException e
                  hPutStrLn stderr ("An exception occurred: " <> ex)
                  respond (with500Response (toText ex) req)
        _  -> respond (with404Response req)
  where
    failPayload e =
        throwM $ BadRequest $ "Couldn't manage to parse json payload: " <> T.pack e

with404Response :: Request -> Response
with404Response = withStatus status404 "Not found"

with200Response :: Text -> Request -> Response
with200Response = withStatus status200

with500Response :: Text -> Request -> Response
with500Response = withStatus status500

notFound :: Application
notFound req respond = respond (with404Response req)

reportServerApp :: LogsHolder -> Agent -> AgentId -> Application
reportServerApp holder agent agentID =
    mapUrls $
        mount "report" (reportApp holder agent agentID) <|>
        mountRoot notFound
