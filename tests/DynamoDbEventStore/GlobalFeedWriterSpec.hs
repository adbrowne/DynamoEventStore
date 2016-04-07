{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE FlexibleContexts #-}

module DynamoDbEventStore.GlobalFeedWriterSpec where

import           Data.List
import           Data.Int
import           Test.Tasty
import           Test.Tasty.QuickCheck((===),testProperty)
import qualified Test.Tasty.QuickCheck as QC
import           Test.Tasty.HUnit
import           Control.Monad.State
import           Control.Monad.Loops
import qualified Data.HashMap.Lazy as HM
import qualified Data.Text             as T
import qualified Data.Text.Encoding             as T
import qualified Data.Text.Lazy        as TL
import qualified Data.ByteString.Lazy        as BL
import qualified Data.Text.Lazy.Encoding    as TL
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Data.Aeson as Aeson

import           DynamoDbEventStore.EventStoreCommands
import           DynamoDbEventStore.EventStoreActions
import qualified DynamoDbEventStore.GlobalFeedWriter as GlobalFeedWriter
import           DynamoDbEventStore.GlobalFeedWriter (FeedEntry())
import           DynamoDbEventStore.DynamoCmdInterpreter

type UploadItem = (T.Text,Int64,T.Text)
newtype UploadList = UploadList [UploadItem] deriving (Show)

-- Generateds a list of length between 1 and maxLength
cappedList :: QC.Arbitrary a => Int -> QC.Gen [a]
cappedList maxLength = QC.listOf1 QC.arbitrary `QC.suchThat` ((< maxLength) . length)

newtype EventData = EventData T.Text deriving Show
instance QC.Arbitrary EventData where
  arbitrary = EventData . T.pack <$> QC.arbitrary
  shrink (EventData xs) = EventData . T.pack <$> QC.shrink (T.unpack xs)

instance QC.Arbitrary UploadList where
  arbitrary = do
    streams <- cappedList 5
    events <- cappedList 100
    eventsWithStream <- mapM (assignStream streams) events
    return $ UploadList $ numberEvents eventsWithStream
    where
      assignStream streams event = do
        stream <- QC.elements streams
        return (stream, event)
      groupTuple xs = HM.toList $ HM.fromListWith (++) ((\(a,b) -> (a,[b])) <$> xs)
      numberEvents :: [(StreamId, EventData)] -> [UploadItem]
      numberEvents xs = do
        (StreamId stream, events) <- groupTuple xs
        (EventData event, number) <- zip events [-1..]
        return (stream, number, event)

writeEvent :: (T.Text, Int64, T.Text) -> DynamoCmdM EventWriteResult
writeEvent (stream, eventNumber, body) = postEventRequestProgram (PostEventRequest stream (Just eventNumber) (TL.encodeUtf8 . TL.fromStrict $ body) "")

publisher :: [(T.Text,Int64,T.Text)] -> DynamoCmdM ()
publisher xs = forM_ xs writeEvent

globalFeedFromUploadList :: [UploadItem] -> Map.Map T.Text (Seq.Seq Int64)
globalFeedFromUploadList =
  foldl' acc Map.empty
  where
    acc :: Map.Map T.Text (Seq.Seq Int64) -> UploadItem -> Map.Map T.Text (Seq.Seq Int64)
    acc s (stream, expectedVersion, _) =
      let 
        eventVersion = expectedVersion + 1
        newValue = maybe (Seq.singleton eventVersion) (Seq.|> eventVersion) $ Map.lookup stream s
      in Map.insert stream newValue s

globalRecordedEventListToMap :: [EventKey] -> Map.Map T.Text (Seq.Seq Int64)
globalRecordedEventListToMap = 
  foldl' acc Map.empty
  where
    acc :: Map.Map T.Text (Seq.Seq Int64) -> EventKey -> Map.Map T.Text (Seq.Seq Int64)
    acc s (EventKey (StreamId stream, number)) =
      let newValue = maybe (Seq.singleton number) (Seq.|> number) $ Map.lookup stream s
      in Map.insert stream newValue s

prop_EventShouldAppearInGlobalFeedInStreamOrder :: UploadList -> QC.Property
prop_EventShouldAppearInGlobalFeedInStreamOrder (UploadList uploadList) =
  let
    programs = Map.fromList [
      ("Publisher", (publisher uploadList,100))
      , ("GlobalFeedWriter1", (GlobalFeedWriter.main, 100))
      --, ("GlobalFeedWriter2", (GlobalFeedWriter.main, 100)) 
      ]
  in QC.forAll (runPrograms programs) check
     where
       check (_, testState) = QC.forAll (runReadAllProgram testState) (\feedItems -> (globalRecordedEventListToMap <$> feedItems) === (Right $ globalFeedFromUploadList uploadList))
       runReadAllProgram = runProgramGenerator "readAllRequestProgram" (getReadAllRequestProgram ReadAllRequest)

getStreamRecordedEvents :: T.Text -> DynamoCmdM [RecordedEvent]
getStreamRecordedEvents streamId = do
   recordedEvents <- concat <$> unfoldrM getEventSet Nothing 
   return $ reverse recordedEvents
   where
    getEventSet :: Maybe Int64 -> DynamoCmdM (Maybe ([RecordedEvent], Maybe Int64)) 
    getEventSet startEvent = 
      if startEvent == Just (-1) then
        return Nothing
      else do
        recordedEvents <- getReadStreamRequestProgram (ReadStreamRequest streamId startEvent)
        if null recordedEvents then
          return Nothing
        else 
          return $ Just (recordedEvents, (Just . (\x -> x - 1) . recordedEventNumber . last) recordedEvents)

readEachStream :: [UploadItem] -> DynamoCmdM (Map.Map T.Text (Seq.Seq Int64))
readEachStream uploadItems = 
  foldM readStream Map.empty streams
  where 
    readStream :: Map.Map T.Text (Seq.Seq Int64) -> T.Text -> DynamoCmdM (Map.Map T.Text (Seq.Seq Int64))
    readStream m streamId = do
      eventIds <- getEventIds streamId
      return $ Map.insert streamId eventIds m
    getEventIds :: T.Text -> DynamoCmdM (Seq.Seq Int64)
    getEventIds streamId = do
       recordedEvents <- getStreamRecordedEvents streamId
       return $ Seq.fromList $ recordedEventNumber <$> recordedEvents
    streams :: [T.Text]
    streams = (\(stream, _, _) -> stream) <$> uploadItems

prop_EventsShouldAppearInTheirSteamsInOrder :: UploadList -> QC.Property
prop_EventsShouldAppearInTheirSteamsInOrder (UploadList uploadList) =
  let
    programs = Map.fromList [
      ("Publisher", (publisher uploadList,100)),
      ("GlobalFeedWriter1", (GlobalFeedWriter.main, 100)) ]
  in QC.forAll (runPrograms programs) check
     where
       check (_, testState) = QC.forAll (runReadEachStream testState) (\streamItems -> streamItems === (Right $ globalFeedFromUploadList uploadList))
       runReadEachStream = runProgramGenerator "readEachStream" (readEachStream uploadList)

eventDataToByteString :: EventData -> BL.ByteString
eventDataToByteString (EventData ed) = (TL.encodeUtf8 . TL.fromStrict) ed

type EventWriter = StreamId -> [(T.Text, BL.ByteString)] -> DynamoCmdM ()

writeEventsWithExplicitExpectedVersions :: EventWriter
writeEventsWithExplicitExpectedVersions (StreamId streamId) events =
  evalStateT (forM_ events writeSingleEvent) (-1)
  where 
    writeSingleEvent (et, ed) = do
      eventNumber <- get
      result <- lift $ postEventRequestProgram (PostEventRequest streamId (Just eventNumber) ed et)
      when (result /= WriteSuccess) $ error "Bad write result"
      put (eventNumber + 1)

writeEventsWithNoExpectedVersions :: EventWriter
writeEventsWithNoExpectedVersions (StreamId streamId) events =
  forM_ events writeSingleEvent
  where 
    writeSingleEvent (et, ed) = do
      result <- postEventRequestProgram (PostEventRequest streamId Nothing ed et)
      when (result /= WriteSuccess) $ error "Bad write result"

writeThenRead :: StreamId -> [(T.Text, BL.ByteString)] -> EventWriter -> DynamoCmdM [RecordedEvent]
writeThenRead (StreamId streamId) events writer = do
  writer (StreamId streamId) events
  getStreamRecordedEvents streamId
  
writtenEventsAppearInReadStream :: EventWriter -> Assertion
writtenEventsAppearInReadStream writer = 
  let 
    streamId = StreamId "MyStream"
    eventDatas = [("MyEvent", TL.encodeUtf8 "My Content"), ("MyEvent2", TL.encodeUtf8 "My Content2")]
    expectedResult = [
      RecordedEvent { 
        recordedEventStreamId = "MyStream", 
        recordedEventNumber = 0, 
        recordedEventData = T.encodeUtf8 "My Content", 
        recordedEventType = "MyEvent"
      }, 
      RecordedEvent { 
        recordedEventStreamId = "MyStream", 
        recordedEventNumber = 1, 
        recordedEventData = T.encodeUtf8 "My Content2", 
        recordedEventType = "MyEvent2"} ] 
    result = runProgram "writeThenRead" (writeThenRead streamId eventDatas writer) emptyTestState
  in assertEqual "Returned events should match input events" (Right expectedResult) result

prop_NoWriteRequestCanCausesAFatalErrorInGlobalFeedWriter :: [PostEventRequest] -> QC.Property
prop_NoWriteRequestCanCausesAFatalErrorInGlobalFeedWriter events =
  let
    programs = Map.fromList [
      ("Publisher", (forM_ events postEventRequestProgram, 100))
      , ("GlobalFeedWriter1", (GlobalFeedWriter.main, 100))
      ]
  in QC.forAll (runPrograms programs) check
     where
       -- global feed writer runs forever unless there is an error so we don't
       -- expect a result
       check (results, _) = Map.lookup "GlobalFeedWriter1" results === Nothing 

cannotWriteEventsOutOfOrder :: Assertion
cannotWriteEventsOutOfOrder =
  let 
    postEventRequest = PostEventRequest { perStreamId = "MyStream", perExpectedVersion = Just 1, perEventData = TL.encodeUtf8 "My Content", perEventType = "MyEvent" }
    result = runProgram "writeEvent" (postEventRequestProgram postEventRequest) emptyTestState
  in assertEqual "Should return an error" (Right WrongExpectedVersion) result

canWriteFirstEvent :: Assertion
canWriteFirstEvent =
  let 
    postEventRequest = PostEventRequest { perStreamId = "MyStream", perExpectedVersion = Just (-1), perEventData = TL.encodeUtf8 "My Content", perEventType = "MyEvent" }
    result = runProgram "writeEvent" (postEventRequestProgram postEventRequest) emptyTestState
  in assertEqual "Should return success" (Right WriteSuccess) result

tests :: [TestTree]
tests = [
      testProperty "Global Feed preserves stream order" prop_EventShouldAppearInGlobalFeedInStreamOrder,
      testProperty "Each event appears in it's correct stream" prop_EventsShouldAppearInTheirSteamsInOrder,
      testProperty "No Write Request can cause a fatal error in global feed writer" prop_NoWriteRequestCanCausesAFatalErrorInGlobalFeedWriter,
      testCase "Written Events Appear In Read Stream - explicit expected version" $ writtenEventsAppearInReadStream writeEventsWithExplicitExpectedVersions,
      testCase "Written Events Appear In Read Stream - explicit expected version" $ writtenEventsAppearInReadStream writeEventsWithNoExpectedVersions,
      testCase "Cannot write event if previous one does not exist" cannotWriteEventsOutOfOrder,
      testCase "Can write first event" canWriteFirstEvent,
      testProperty "Can round trip FeedEntry via JSON" (\(a :: FeedEntry) -> (Aeson.decode . Aeson.encode) a === Just a)
  ]
