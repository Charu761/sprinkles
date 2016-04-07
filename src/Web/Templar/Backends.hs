{-#LANGUAGE NoImplicitPrelude #-}
{-#LANGUAGE OverloadedStrings #-}
module Web.Templar.Backends
where

import ClassyPrelude
import Data.Aeson as JSON
import Data.Aeson.TH as JSON
import Data.Yaml as YAML
import qualified Network.HTTP as HTTP
import Network.Mime
            ( MimeType
            , MimeMap
            , defaultMimeLookup
            , defaultMimeMap
            , mimeByExt
            , defaultMimeType
            , FileName
            )
import Network.URI (parseURI)
import qualified Text.Pandoc as Pandoc
import Text.Pandoc (Pandoc)
import Text.Pandoc.Error (PandocError)
import Text.Ginger (ToGVal (..), GVal, Run (..), dict, (~>))
import Web.Templar.PandocGVal

mimeMap :: MimeMap
mimeMap =
    defaultMimeMap <>
    mapFromList
        [ ("yml", "application/x-yaml")
        , ("yaml", "application/x-yaml")
        , ("md", "application/x-markdown")
        , ("markdown", "application/x-markdown")
        ]

mimeLookup :: FileName -> MimeType
mimeLookup = mimeByExt mimeMap defaultMimeType

data BackendData m h =
    BackendData
        { bdJSON :: JSON.Value
        , bdGVal :: GVal (Run m h)
        , bdRaw :: LByteString
        , bdMimeType :: MimeType
        }

instance ToJSON (BackendData m h) where
    toJSON = bdJSON

jsonToBackend :: JSON.Value -> BackendData m h
jsonToBackend val = BackendData val (toGVal val) (JSON.encode val) "application/json"

loadBackendData :: String -> IO (Maybe (BackendData m h))
loadBackendData backendURLStr = do
    fetchedMay <- fetchBackendData backendURLStr
    case fetchedMay of
        Nothing ->
            return Nothing
        Just (mimeType, responseBody) -> do
            beData <- parseBackendData mimeType responseBody
            return $ Just beData

fetchBackendData :: String -> IO (Maybe (MimeType, LByteString))
fetchBackendData backendURLStr = do
    let protocol = takeWhile (/= ':') backendURLStr
    case protocol of
        "http" -> fetchBackendDataHTTP backendURLStr
        "https" -> fetchBackendDataHTTP backendURLStr
        "file" -> fetchBackendDataFile (drop 7 backendURLStr)
        x -> fail $ "Unknown protocol: " <> show x

fetchBackendDataFile :: String -> IO (Maybe (MimeType, LByteString))
fetchBackendDataFile filename = fetch `catchIOError` handle
    where
        fetch = do
            let mimeType = mimeLookup . pack $ filename
            contents <- readFile filename
            return $ Just (mimeType, contents)
        handle err
            | isDoesNotExistError err = return Nothing
            | otherwise = ioError err

fetchBackendDataHTTP :: String -> IO (Maybe (MimeType, LByteString))
fetchBackendDataHTTP backendURLStr = do
    backendURL <- maybe
        (fail $ "Invalid backend URL: " ++ backendURLStr)
        return
        (parseURI backendURLStr)
    let backendRequest =
            HTTP.Request
                backendURL
                HTTP.GET
                []
                ""
    backendResponse <- HTTP.simpleHTTP backendRequest
    backendBody <- HTTP.getResponseBody backendResponse
    headers <- case backendResponse of
                    Left err -> fail (show err)
                    Right resp -> return $ HTTP.getHeaders resp
    let backendType = encodeUtf8 . pack . fromMaybe "text/plain" . lookupHeader HTTP.HdrContentType $ headers
    return $ Just (backendType, backendBody)

lookupHeader :: HTTP.HeaderName -> [HTTP.Header] -> Maybe String
lookupHeader name headers =
    headMay [ v | HTTP.Header n v <- headers, n == name ]

parseBackendData :: Monad m => MimeType -> LByteString -> m (BackendData n h)
parseBackendData "application/json" = parseJSONData
parseBackendData "text/json" = parseJSONData
parseBackendData "application/x-yaml" = parseYamlData
parseBackendData "application/yaml" = parseYamlData
parseBackendData "text/yaml" = parseYamlData
parseBackendData "text/x-yaml" = parseYamlData
parseBackendData "application/x-markdown" =
    parsePandocDataString
        (Pandoc.readMarkdown Pandoc.def)
        "application/x-markdown"
parseBackendData t = parseRawData t

parseRawData :: Monad m => MimeType-> LByteString -> m (BackendData n h)
parseRawData mimeType input =
    return $ BackendData
        { bdJSON = JSON.Null
        , bdGVal = toGVal JSON.Null
        , bdRaw = input
        , bdMimeType = mimeType
        }

parseJSONData :: Monad m => LByteString -> m (BackendData n h)
parseJSONData jsonSrc =
    case JSON.eitherDecode jsonSrc of
        Left err -> fail $ err ++ "\n" ++ show jsonSrc
        Right json -> return . jsonToBackend $ (json :: JSON.Value)

parseYamlData :: Monad m => LByteString -> m (BackendData n h)
parseYamlData yamlSrc =
    case YAML.decodeEither (toStrict yamlSrc) of
        Left err -> fail $ err ++ "\n" ++ show yamlSrc
        Right json -> return . jsonToBackend $ (json :: JSON.Value)

parsePandocDataLBS :: Monad m
                   => (LByteString -> Either PandocError Pandoc)
                   -> MimeType
                   -> LByteString
                   -> m (BackendData n h)
parsePandocDataLBS reader mimeType input = do
    case reader input of
        Left err -> fail . show $ err
        Right pandoc ->
            return $ BackendData
                        { bdJSON = toJSON pandoc
                        , bdGVal = toGVal pandoc
                        , bdRaw = input
                        , bdMimeType = mimeType
                        }

parsePandocDataString :: Monad m
                   => (String -> Either PandocError Pandoc)
                   -> MimeType
                   -> LByteString
                   -> m (BackendData n h)
parsePandocDataString reader =
    parsePandocDataLBS (reader . unpack . decodeUtf8)
