{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module WebserverSpec (postEventSpec, getStreamSpec, getEventSpec) where

import           BasicPrelude
import           Test.Tasty.Hspec
import           Network.Wai.Test
import           Network.Wai
import           Control.Monad.Reader
import           Data.Time.Clock
import           Data.Time.Format
import qualified DynamoDbEventStore.Webserver as W
import qualified Web.Scotty.Trans as S
import qualified Network.HTTP.Types as H

addEventPost :: [H.Header] -> Session SResponse
addEventPost headers =
  request $ defaultRequest {
               pathInfo = ["streams","streamId"],
               requestMethod = H.methodPost,
               requestHeaders = headers,
               requestBody = pure "" }

evHeader :: H.HeaderName
evHeader = "ES-ExpectedVersion"
etHeader :: H.HeaderName
etHeader = "ES-EventType"
eventIdHeader :: H.HeaderName
eventIdHeader = "ES-EventId"


app :: IO Application
app = do
  sampleTime <- parseTimeM True defaultTimeLocale rfc822DateFormat "Sun, 08 May 2016 12:49:41 +0000"
  S.scottyAppT (flip runReaderT sampleTime) (W.app W.showEventResponse :: S.ScottyT LText (ReaderT UTCTime IO) ()) 
postEventSpec :: Spec
postEventSpec = do
  let baseHeaders = [(etHeader, "MyEventType"),(eventIdHeader, "12f44004-f5dd-41f1-8225-72dd65a0332e")]
  let requestWithExpectedVersion = addEventPost $ (evHeader, "1"):baseHeaders
  let requestWithoutExpectedVersion = addEventPost baseHeaders
  let requestWithoutBadExpectedVersion = addEventPost $ (evHeader, "NotAnInt"):baseHeaders
  let requestWithoutEventType = addEventPost [(evHeader, "1")]

  describe "Parse Int64 header" $ do
    it "responds with 200" $
      waiCase requestWithExpectedVersion $ assertStatus 200

    it "responds with body" $
      waiCase requestWithExpectedVersion $ assertBody "PostEvent (PostEventRequest {perStreamId = \"streamId\", perExpectedVersion = Just 1, perEvents = EventEntry {eventEntryData = \"\", eventEntryType = EventType \"MyEventType\", eventEntryEventId = EventId 12f44004-f5dd-41f1-8225-72dd65a0332e, eventEntryCreated = EventTime 2016-05-08 12:49:41 UTC, eventEntryIsJson = True} :| []})"

  describe "POST /streams/streamId without ExepectedVersion" $ do
    it "responds with 200" $
      waiCase requestWithoutExpectedVersion $ assertStatus 200

    it "responds with body" $
      waiCase requestWithoutExpectedVersion $ assertBody "PostEvent (PostEventRequest {perStreamId = \"streamId\", perExpectedVersion = Nothing, perEvents = EventEntry {eventEntryData = \"\", eventEntryType = EventType \"MyEventType\", eventEntryEventId = EventId 12f44004-f5dd-41f1-8225-72dd65a0332e, eventEntryCreated = EventTime 2016-05-08 12:49:41 UTC, eventEntryIsJson = True} :| []})"

  describe "POST /streams/streamId without EventType" $
    it "responds with 400" $
      waiCase requestWithoutEventType $ assertStatus 400

  describe "POST /streams/streamId without ExepectedVersion greater than Int64.max" $
    it "responds with 400" $
       addEventPost [("ES-ExpectedVersion", "9223372036854775808")] `waiCase` assertStatus 400

  describe "POST /streams/streamId with non-integer ExpectedVersion" $
    it "responds with 400" $
      requestWithoutBadExpectedVersion `waiCase` assertStatus 400
  where
    waiCase r assertion = do
      app' <- app
      flip runSession app' $ assertion =<< r

getStream :: Text -> Session SResponse
getStream streamId =
  request $ defaultRequest {
               pathInfo = ["streams",streamId],
               requestMethod = H.methodGet
            }

getStreamSpec :: Spec
getStreamSpec = do
  describe "Get stream" $ do
    let getExample = getStream "myStreamId"
    it "responds with 200" $
      waiCase getExample $ assertStatus 200

    it "responds with body" $
      waiCase getExample $ assertBody "ReadStream (ReadStreamRequest {rsrStreamId = \"myStreamId\", rsrStartEventNumber = Nothing, rsrMaxItems = 10})"

  describe "Get stream with missing stream name" $ do
    let getExample = getStream ""
    it "responds with 400" $
      waiCase getExample $ assertStatus 400

  where
    waiCase r assertion = do
      app' <- app
      flip runSession app' $ assertion =<< r

getEvent :: Text -> Int64 -> Session SResponse
getEvent streamId eventNumber =
  request $ defaultRequest {
               pathInfo = ["streams",streamId,show eventNumber],
               requestMethod = H.methodGet
            }

getEventSpec :: Spec 
getEventSpec = do
  describe "Get stream" $ do
    let getExample = getEvent "myStreamId" 0
    it "responds with 200" $
      waiCase getExample $ assertStatus 200

    it "responds with body" $
      waiCase getExample $ assertBody "ReadEvent (ReadEventRequest {rerStreamId = \"myStreamId\", rerEventNumber = 0})"

  where
    waiCase r assertion = do
      app' <- app
      flip runSession app' $ assertion =<< r
