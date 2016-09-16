{-#LANGUAGE DeriveGeneric #-}
{-#LANGUAGE NoImplicitPrelude #-}
{-#LANGUAGE OverloadedStrings #-}
{-#LANGUAGE OverloadedLists #-}
{-#LANGUAGE LambdaCase #-}
{-#LANGUAGE ScopedTypeVariables #-}
{-#LANGUAGE FlexibleInstances #-}
{-#LANGUAGE FlexibleContexts #-}
{-#LANGUAGE MultiParamTypeClasses #-}
module Web.Templar.Handlers.Respond
( respondTemplateHtml
, respondTemplateText
)
where

import ClassyPrelude
import Web.Templar.Backends
import qualified Network.Wai as Wai
import Web.Templar.Logger as Logger
import Web.Templar.Project
import Web.Templar.ProjectConfig

import Text.Ginger
       (parseGinger, Template, runGingerT, GingerContext, GVal(..), ToGVal(..),
        (~>))
import qualified Text.Ginger as Ginger
import Text.Ginger.Html (Html, htmlSource)

import qualified Data.ByteString.UTF8 as UTF8
import qualified Data.ByteString.Lazy.UTF8 as LUTF8
import Data.ByteString.Builder (stringUtf8)
import qualified Data.Yaml as YAML
import qualified Data.Aeson as JSON
import qualified Data.Aeson.Encode.Pretty as JSON
import Data.Default (Default, def)
import Data.Text (Text)
import qualified Data.Text as Text
import System.Locale.Read (getLocale)
import qualified Text.Pandoc as Pandoc
import qualified Text.Pandoc.Readers.Creole as Pandoc
import qualified Data.CaseInsensitive as CI

import Network.HTTP.Types
       (Status, status200, status302, status400, status404, status500)
import Network.HTTP.Types.URI (queryToQueryText)

import Web.Templar.Backends.Loader.Type
       (PostBodySource (..), pbsFromRequest, pbsInvalid)

instance ToGVal m ByteString where
    toGVal = toGVal . UTF8.toString

instance ToGVal m (CI.CI ByteString) where
    toGVal = toGVal . CI.original

instance ToGVal m Wai.Request where
    toGVal rq =
        Ginger.orderedDict
            [ "httpVersion" ~> tshow (Wai.httpVersion rq)
            , "method" ~> decodeUtf8 (Wai.requestMethod rq)
            , "path" ~> decodeUtf8 (Wai.rawPathInfo rq)
            , "query" ~> decodeUtf8 (Wai.rawQueryString rq)
            , "pathInfo" ~> Wai.pathInfo rq
            , ( "queryInfo"
              , Ginger.orderedDict
                    [ (key, toGVal val)
                    | (key, val)
                    <- queryToQueryText (Wai.queryString rq)
                    ]
              )
            , ( "headers"
              , Ginger.orderedDict
                    [ (decodeCI n, toGVal $ decodeUtf8 v)
                    | (n, v)
                    <- Wai.requestHeaders rq
                    ]
              )
            ]

decodeCI :: CI.CI ByteString -> Text
decodeCI = decodeUtf8 . CI.original

data GingerFunctionCallException =
    GingerInvalidFunctionArgs
        { invalidFunctionName :: Text
        , invalidFunctionExpectedArgs :: Text
        }
    deriving (Show, Eq, Generic)

instance Exception GingerFunctionCallException


respondTemplateHtml :: ToGVal (Ginger.Run IO Html) a => Project -> Status -> Text -> HashMap Text a -> Wai.Application
respondTemplateHtml project status templateName contextMap request respond = do
    let contextLookup = mkContextLookup request project contextMap
        headers = [("Content-type", "text/html;charset=utf8")]
    template <- getTemplate project templateName
    respond . Wai.responseStream status headers $ \write flush -> do
        let writeHtml = write . stringUtf8 . unpack . htmlSource
            context :: GingerContext IO Html
            context = Ginger.makeContextHtmlM contextLookup writeHtml
        runGingerT context template
        flush

respondTemplateText :: ToGVal (Ginger.Run IO Text) a => Project -> Status -> Text -> HashMap Text a -> Wai.Application
respondTemplateText project status templateName contextMap request respond = do
    let contextLookup = mkContextLookup request project contextMap
        headers = [("Content-type", "text/plain;charset=utf8")]
    template <- getTemplate project templateName
    respond . Wai.responseStream status headers $ \write flush -> do
        let writeText = write . stringUtf8 . unpack
            context :: GingerContext IO Text
            context = Ginger.makeContextTextM contextLookup writeText
        runGingerT context template
        flush

mkContextLookup :: (ToGVal (Ginger.Run IO h) a)
                => Wai.Request
                -> Project
                -> HashMap Text a
                -> Text
                -> Ginger.Run IO h (GVal (Ginger.Run IO h))
mkContextLookup request project contextMap key = do
    let cache = projectBackendCache project
        logger = projectLogger project
        contextMap' =
            fmap toGVal contextMap <>
            mapFromList
                [ "request" ~> request
                , ("load", Ginger.fromFunction (gfnLoadBackendData (writeLog logger) cache))
                , ("ellipse", Ginger.fromFunction gfnEllipse)
                , ("json", Ginger.fromFunction gfnJSON)
                , ("yaml", Ginger.fromFunction gfnYAML)
                , ("getlocale", Ginger.fromFunction (gfnGetLocale (writeLog logger)))
                , ("pandoc", Ginger.fromFunction (gfnPandoc (writeLog logger)))
                , ("markdown", Ginger.fromFunction (gfnPandocAlias "markdown" (writeLog logger)))
                , ("textile", Ginger.fromFunction (gfnPandocAlias "textile" (writeLog logger)))
                , ("rst", Ginger.fromFunction (gfnPandocAlias "rst" (writeLog logger)))
                , ("creole", Ginger.fromFunction (gfnPandocAlias "creole" (writeLog logger)))
                ]
    return . fromMaybe def $ lookup key contextMap'

gfnLoadBackendData :: forall h. (LogLevel -> Text -> IO ()) -> RawBackendCache -> Ginger.Function (Ginger.Run IO h)
gfnLoadBackendData writeLog cache args =
    Ginger.dict <$> forM (zip [0..] args) loadPair
    where
        loadPair :: (Int, (Maybe Text, GVal (Ginger.Run IO h)))
                 -> Ginger.Run IO h (Text, GVal (Ginger.Run IO h))
        loadPair (index, (keyMay, gBackendURL)) = do
            let backendURL = Ginger.asText gBackendURL
            backendData :: Items (BackendData IO h) <- liftIO $
                loadBackendData writeLog pbsInvalid cache =<< parseBackendURI backendURL
            return
                ( fromMaybe (tshow index) keyMay
                , toGVal backendData
                )

catchToGinger :: forall h m. (LogLevel -> Text -> IO ())
              -> IO (GVal m)
              -> IO (GVal m)
catchToGinger writeLog action =
    action
        `catch` (\(e :: SomeException) -> do
            writeLog Logger.Error . tshow $ e
            return . toGVal $ False
        )

gfnPandoc :: forall h. (LogLevel -> Text -> IO ()) -> Ginger.Function (Ginger.Run IO h)
gfnPandoc writeLog args = liftIO . catchToGinger writeLog $
    case Ginger.extractArgsDefL [("src", ""), ("reader", "markdown")] args of
        Right [src, readerName] -> toGVal <$> pandoc (Ginger.asText readerName) (Ginger.asText src)
        _ -> throwM $ GingerInvalidFunctionArgs "pandoc" "string src, string reader"

gfnPandocAlias :: forall h. Text -> (LogLevel -> Text -> IO ()) -> Ginger.Function (Ginger.Run IO h)
gfnPandocAlias readerName writeLog args = liftIO . catchToGinger writeLog $
    case Ginger.extractArgsDefL [("src", "")] args of
        Right [src] -> toGVal <$> pandoc readerName (Ginger.asText src)
        _ -> throwM $ GingerInvalidFunctionArgs "pandoc" "string src, string reader"

pandoc :: Text -> Text -> IO Pandoc.Pandoc
pandoc readerName src = do
    reader <- either
        (\err -> fail $ "Invalid reader: " ++ show err)
        return
        (getReader $ unpack readerName)
    let read = case reader of
            Pandoc.StringReader r -> r Pandoc.def . unpack
            Pandoc.ByteStringReader r -> fmap (fmap fst) . r Pandoc.def . encodeUtf8
    read (fromStrict src) >>= either
        (\err -> fail $ "Reading " ++ show readerName ++ " failed: " ++ show err)
        return
    where
        getReader "creole" = Right $ Pandoc.mkStringReader Pandoc.readCreole
        getReader readerName = Pandoc.getReader readerName

gfnGetLocale :: forall h. (LogLevel -> Text -> IO ()) -> Ginger.Function (Ginger.Run IO h)
gfnGetLocale writeLog args = liftIO . catchToGinger writeLog $
    case Ginger.extractArgsDefL [("category", "LC_TIME"), ("locale", "")] args of
        Right [gCat, gName] ->
            case (Ginger.asText gCat, Text.unpack . Ginger.asText $ gName) of
                ("LC_TIME", "") -> toGVal <$> getLocale Nothing
                ("LC_TIME", localeName) -> toGVal <$> getLocale (Just localeName)
                (cat, localeName) -> return def -- valid call, but category not implemented
        _ -> throwM $ GingerInvalidFunctionArgs "getlocale" "string category, string name"

gfnEllipse :: Ginger.Function (Ginger.Run IO h)
gfnEllipse [] = return def
gfnEllipse [(Nothing, str)] =
    gfnEllipse [(Nothing, str), (Nothing, toGVal (100 :: Int))]
gfnEllipse [(Nothing, str), (Nothing, len)] = do
    let txt = Ginger.asText str
        actualLen = ClassyPrelude.length txt
        targetLen = fromMaybe 100 $ ceiling <$> Ginger.asNumber len
        txt' = if actualLen + 3 > targetLen
                    then take (targetLen - 3) txt <> "..."
                    else txt
    return . toGVal $ txt'
gfnEllipse ((Nothing, str):xs) = do
    let len = fromMaybe (toGVal (100 :: Int)) $ lookup (Just "len") xs
    gfnEllipse [(Nothing, str), (Nothing, len)]
gfnEllipse xs = do
    let str = fromMaybe def $ lookup (Just "str") xs
    gfnEllipse $ (Nothing, str):xs

gfnJSON :: Ginger.Function (Ginger.Run IO h)
gfnJSON [] = return def
gfnJSON ((_, x):xs) =
    return . toGVal . LUTF8.toString . JSON.encodePretty $ x

gfnYAML :: Ginger.Function (Ginger.Run IO h)
gfnYAML [] = return def
gfnYAML ((_, x):xs) =
    return . toGVal . UTF8.toString . YAML.encode $ x
