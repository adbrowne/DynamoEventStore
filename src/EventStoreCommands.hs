{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveGeneric #-}

module EventStoreCommands where

import Control.Applicative
import Control.Monad
import Control.Monad.Free
import Control.Monad.Free.TH

import GHC.Generics
import Data.Aeson
import Data.Int
import qualified Data.Text as T
import qualified Data.ByteString as BS

newtype StreamId = StreamId T.Text deriving (Ord, Eq, Show)
newtype EventKey = EventKey (StreamId, Int64) deriving (Ord, Eq, Show)
type EventType = T.Text
type PageKey = (Int, Int) -- (Partition, PageNumber)
data EventWriteResult = WriteSuccess | EventExists | WriteError deriving (Eq, Show)
type EventReadResult = Maybe (EventType, BS.ByteString, Maybe PageKey)
data SetEventPageResult = SetEventPageSuccess | SetEventPageError
data PageStatus = Version Int | Full | Verified deriving (Eq, Show, Generic)

data RecordedEvent = RecordedEvent {
   recordedEventStreamId :: T.Text,
   recordedEventNumber   :: Int64,
   recordedEventData     :: BS.ByteString,
   recordedEventType     :: T.Text
} deriving (Show, Eq, Ord)

instance FromJSON PageStatus
instance ToJSON PageStatus

instance FromJSON StreamId where
  parseJSON (String v) =
    return $ StreamId v
  parseJSON _ = mzero
instance ToJSON StreamId where
  toJSON (StreamId streamId) =
    String streamId
instance FromJSON EventKey where
  parseJSON (Object v) =
    EventKey <$>
    ((,) <$> v .: "streamId"
         <*> v .: "eventNumber")
  parseJSON _ = mzero
instance ToJSON EventKey where
  toJSON (EventKey(streamId, eventNumber)) =
    object [ "streamId"    .= streamId
           , "eventNumber" .= eventNumber
           ]

data PageWriteRequest = PageWriteRequest {
      expectedStatus :: Maybe PageStatus
      , newStatus    :: PageStatus
      , entries   :: [EventKey]
}

-- Low level event store commands
-- should map almost one to one with dynamodb operations
data EventStoreCmd next =
  GetEvent'
    EventKey
    (EventReadResult -> next) |
  GetEventsBackward'
    StreamId
    Int -- max events to retrieve
    (Maybe Int64) -- starting event, Nothing means start at head
    ([RecordedEvent] -> next) |
  WriteEvent'
    EventKey
    EventType
    BS.ByteString
    (EventWriteResult -> next) |
  Wait'
    (() -> next) |
  SetEventPage'
    EventKey
    PageKey
    (SetEventPageResult -> next) |
  WritePageEntry'
    PageKey
    PageWriteRequest
    (Maybe PageStatus -> next) |
  GetPageEntry'
    PageKey
    (Maybe (PageStatus, [EventKey]) -> next) |
  ScanUnpagedEvents'
    ([EventKey] -> next)
  deriving (Functor) -- todo support paging

type EventStoreCmdM = Free EventStoreCmd

makeFree ''EventStoreCmd
