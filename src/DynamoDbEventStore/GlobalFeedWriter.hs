{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module DynamoDbEventStore.GlobalFeedWriter (main, FeedEntry(FeedEntry), feedEntryStream, feedEntryNumber, dynamoWriteWithRetry) where

import           Control.Monad
import           Data.Int
import qualified Data.Sequence         as Seq
import qualified Data.Text             as T
import qualified Data.ByteString.Lazy  as BL
import qualified Data.HashMap.Lazy as HM
import qualified DynamoDbEventStore.Constants as Constants
import           DynamoDbEventStore.EventStoreCommands
import           Data.Maybe
import           Data.Monoid
import           Control.Lens
import           Network.AWS.DynamoDB
import qualified Data.Aeson as Aeson
import           Control.Applicative
import           Text.Printf (printf)
import qualified Test.QuickCheck as QC

toText :: Show s => s -> T.Text
toText = T.pack . show

data FeedEntry = FeedEntry {
  feedEntryStream :: StreamId,
  feedEntryNumber :: Int64
} deriving (Eq, Show)

instance QC.Arbitrary FeedEntry where
  arbitrary = do
    stream <- QC.arbitrary
    number <- QC.arbitrary
    return $ FeedEntry stream number

instance Aeson.FromJSON FeedEntry where
    parseJSON (Aeson.Object v) = FeedEntry <$>
                           v Aeson..: "s" <*>
                           v Aeson..: "n"
    parseJSON _                = empty

instance Aeson.ToJSON FeedEntry where
    toJSON (FeedEntry stream number) =
        Aeson.object ["s" Aeson..= stream, "n" Aeson..= number]

data FeedPage = FeedPage {
  feedPageNumber     :: Int,
  feedPageEntries    :: Seq.Seq FeedEntry,
  feedPageIsVerified :: Bool
}

dynamoWriteWithRetry :: DynamoKey -> DynamoValues -> Int -> DynamoCmdM DynamoWriteResult
dynamoWriteWithRetry key value version = loop 0 DynamoWriteFailure
  where
    loop :: Int -> DynamoWriteResult -> DynamoCmdM DynamoWriteResult
    loop 100 previousResult = return previousResult
    loop count DynamoWriteFailure = writeToDynamo' key value version >>= loop (count  + 1)
    loop _ previousResult = return previousResult

getPageDynamoKey :: Int -> DynamoKey
getPageDynamoKey pageNumber =
  let paddedPageNumber = T.pack (printf "%08d" pageNumber)
  in DynamoKey (Constants.pageDynamoKeyPrefix <> paddedPageNumber) 0

getMostRecentPage :: Int -> DynamoCmdM (Maybe FeedPage)
getMostRecentPage startPageNumber = 
  readFeedPage startPageNumber >>= findPage
  where
    readFeedPage :: Int -> DynamoCmdM (Maybe FeedPage)
    readFeedPage pageNumber = do
      dynamoEntry <- readFromDynamo' $ getPageDynamoKey pageNumber
      return $ toFeedPage startPageNumber <$> dynamoEntry
    toFeedPage :: Int -> DynamoReadResult -> FeedPage
    toFeedPage pageNumber readResult =
      let 
        pageValues = dynamoReadResultValue readResult
        isVerified = HM.member Constants.pageIsVerifiedKey pageValues
        entries = readPageBody pageValues
      in FeedPage { feedPageNumber = pageNumber, feedPageEntries = entries, feedPageIsVerified = isVerified }
    findPage :: Maybe FeedPage -> DynamoCmdM (Maybe FeedPage)
    findPage Nothing = return Nothing
    findPage (Just lastPage) = do
      let nextPage = feedPageNumber lastPage + 1
      dynamoEntry <- readFromDynamo' $ getPageDynamoKey nextPage
      let feedPage = toFeedPage nextPage <$> dynamoEntry
      case feedPage of Just _  -> findPage feedPage
                       Nothing -> return (Just lastPage)

entryIsPaged :: DynamoKey -> DynamoCmdM Bool
entryIsPaged item = do
  dynamoItem <- readFromDynamoMustExist item
  return ((not . containsNeedsPagingKey) dynamoItem)
  where
    containsNeedsPagingKey :: DynamoReadResult -> Bool
    containsNeedsPagingKey = HM.member Constants.needsPagingKey . dynamoReadResultValue

previousEntryIsPaged :: DynamoKey -> DynamoCmdM Bool
previousEntryIsPaged item =
  let itemEventNumber = dynamoKeyEventNumber item
  in
    if itemEventNumber == 0 then
      return True
    else
      entryIsPaged (item { dynamoKeyEventNumber = itemEventNumber - 1})

readPageBody :: DynamoValues -> Seq.Seq FeedEntry
readPageBody values = -- todo don't ignore errors
  fromMaybe Seq.empty $ view (ix Constants.pageBodyKey . avB) values >>= Aeson.decodeStrict

nextVersion :: DynamoReadResult -> Int
nextVersion readResult = dynamoReadResultVersion readResult + 1

toDynamoKey :: StreamId -> Int64 -> DynamoKey
toDynamoKey (StreamId streamId) = DynamoKey (Constants.streamDynamoKeyPrefix <> streamId)

setPageEntryPageNumber :: Int -> FeedEntry -> DynamoCmdM ()
setPageEntryPageNumber pageNumber feedEntry = do
  let streamId = feedEntryStream feedEntry
  let dynamoKey = toDynamoKey streamId  (feedEntryNumber feedEntry)
  eventEntry <- readFromDynamoMustExist dynamoKey
  let newValue = (HM.delete Constants.needsPagingKey . HM.insert Constants.eventPageNumberKey (stringAttributeValue (toText pageNumber)) . dynamoReadResultValue) eventEntry
  void $ dynamoWriteWithRetry dynamoKey newValue (nextVersion eventEntry)

checkItemPaged :: DynamoKey -> DynamoCmdM Bool
checkItemPaged item = do
  eventEntry <- readFromDynamoMustExist item
  log' Debug ("checkItemPaged " <> toText eventEntry)
  return $ (HM.member Constants.eventPageNumberKey . dynamoReadResultValue ) eventEntry

stringAttributeValue :: T.Text -> AttributeValue
stringAttributeValue t = set avS (Just t) attributeValue

verifyPage :: Int -> DynamoCmdM ()
verifyPage (-1)       = return ()
verifyPage pageNumber = do
  let pageDynamoKey = getPageDynamoKey pageNumber
  page <- readFromDynamoMustExist pageDynamoKey
  let pageValues = dynamoReadResultValue page
  let pageVersion = dynamoReadResultVersion page
  log' Debug ("verifyPage " <> toText pageNumber <> " go value " <> toText pageValues)
  unless (HM.member Constants.pageIsVerifiedKey pageValues) $ do
    let entries = readPageBody pageValues
    log' Debug ("setPageEntry for " <> toText entries)
    void $ traverse (setPageEntryPageNumber pageNumber) entries
    let newValues = HM.insert Constants.pageIsVerifiedKey (stringAttributeValue "Verified") pageValues
    void $ dynamoWriteWithRetry pageDynamoKey newValues (pageVersion + 1)

logIf :: Bool -> LogLevel -> T.Text -> DynamoCmdM ()
logIf True logLevel t = log' logLevel t
logIf False _ _ = return ()

readFromDynamoMustExist :: DynamoKey -> DynamoCmdM DynamoReadResult
readFromDynamoMustExist key = do
  r <- readFromDynamo' key
  case r of Just x -> return x
            Nothing -> fatalError' ("Could not find item: " <> toText key)

getCurrentPage :: DynamoCmdM FeedPage
getCurrentPage = do
  mostRecentPage <- getMostRecentPage 0
  let mostRecentPageNumber = maybe (-1) feedPageNumber mostRecentPage
  verifyPage mostRecentPageNumber
  let currentPage = FeedPage { feedPageNumber = mostRecentPageNumber + 1, feedPageEntries = Seq.empty, feedPageIsVerified = False }
  return currentPage

updateGlobalFeed :: DynamoKey -> DynamoCmdM ()
updateGlobalFeed item@DynamoKey { dynamoKeyKey = itemKey, dynamoKeyEventNumber = itemEventNumber } = do
  log' Debug ("updateGlobalFeed" <> toText item)
  let streamId = StreamId $ T.drop (T.length Constants.streamDynamoKeyPrefix) itemKey
  currentPage <- getCurrentPage
  itemIsPaged <- checkItemPaged item
  logIf itemIsPaged Debug ("itemIsPaged" <> toText item)
  unless itemIsPaged $ do
    let feedEntry = (BL.toStrict . Aeson.encode . Aeson.toJSON) (feedPageEntries currentPage |> FeedEntry streamId itemEventNumber)
    when (dynamoKeyEventNumber item > 0) (updateGlobalFeed item { dynamoKeyEventNumber = itemEventNumber - 1 })
    pageResult <- dynamoWriteWithRetry (getPageDynamoKey (feedPageNumber currentPage)) (HM.singleton Constants.pageBodyKey (set avB (Just feedEntry) attributeValue)) 0
    onPageResult (feedPageNumber currentPage) pageResult
    return ()
  return ()
  where
    onPageResult :: Int -> DynamoWriteResult -> DynamoCmdM ()
    onPageResult _ DynamoWriteWrongVersion = do
      log' Debug "Got wrong version writing page"
      updateGlobalFeed item
    onPageResult nextPage DynamoWriteSuccess = do
      eventEntry <- readFromDynamoMustExist item
      let values = dynamoReadResultValue eventEntry
      let version = dynamoReadResultVersion eventEntry
      let values' = (HM.delete Constants.needsPagingKey . HM.insert Constants.eventPageNumberKey (set avS (Just (toText nextPage)) attributeValue)) values
      itemUpdateResult <- dynamoWriteWithRetry item values' (version + 1)
      when (itemUpdateResult == DynamoWriteSuccess) (verifyPage nextPage)
    onPageResult _ DynamoWriteFailure = undefined

writeItemToGlobalFeed :: DynamoKey -> DynamoCmdM ()
writeItemToGlobalFeed item = do
  previousEntryOk <- previousEntryIsPaged item
  entryPaged <- entryIsPaged item
  log' Debug ("entryPaged: " <> toText entryPaged <> " previousEntryOk " <> toText previousEntryOk)
  when (previousEntryOk && not entryPaged) (updateGlobalFeed item)

main :: DynamoCmdM ()
main = forever $ do
  scanResult <- scanNeedsPaging'
  forM_ scanResult writeItemToGlobalFeed
  log' Debug $ (toText . length) scanResult
  when (null scanResult) (wait' 1000)
  setPulseStatus' $ case scanResult of [] -> False
                                       _  -> True
