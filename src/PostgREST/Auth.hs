{-|
Module      : PostgREST.Auth
Description : PostgREST authorization functions.

This module provides functions to deal with the JWT authorization (http://jwt.io).
It also can be used to define other authorization functions,
in the future Oauth, LDAP and similar integrations can be coded here.

Authentication should always be implemented in an external service.
In the test suite there is an example of simple login function that can be used for a
very simple authentication system inside the PostgreSQL database.
-}
{-# LANGUAGE RecordWildCards #-}
module PostgREST.Auth
  ( AuthResult (..)
  , getResult
  , getJwtDur
  , getRole
  , middleware
  ) where

import qualified Crypto.JWT                      as JWT
import qualified Data.Aeson                      as JSON
import qualified Data.Aeson.Key                  as K
import qualified Data.Aeson.KeyMap               as KM
import qualified Data.Aeson.Types                as JSON
import qualified Data.ByteString                 as BS
import qualified Data.ByteString.Lazy.Char8      as LBS
import qualified Data.Vault.Lazy                 as Vault
import qualified Data.Vector                     as V
import qualified Network.HTTP.Types.Header       as HTTP
import qualified Network.Wai                     as Wai
import qualified Network.Wai.Middleware.HttpAuth as Wai

import Control.Lens            (set)
import Control.Monad.Except    (liftEither)
import Data.Either.Combinators (mapLeft)
import Data.List               (lookup)
import Data.Time.Clock         (UTCTime)
import System.IO.Unsafe        (unsafePerformIO)
import System.TimeIt           (timeItT)

import PostgREST.AppState (AppState, getConfig, getTime)
import PostgREST.Config   (AppConfig (..), JSPath, JSPathExp (..))
import PostgREST.Error    (Error (..))

import Protolude


data AuthResult = AuthResult
  { authClaims :: KM.KeyMap JSON.Value
  , authRole   :: BS.ByteString
  }

-- | Receives the JWT secret and audience (from config) and a JWT and returns a
-- JSON object of JWT claims.
parseToken :: Monad m =>
  AppConfig -> LByteString -> UTCTime -> ExceptT Error m JSON.Value
parseToken _ "" _ = return JSON.emptyObject
parseToken AppConfig{..} token time = do
  secret <- liftEither . maybeToRight JwtTokenMissing $ configJWKS
  eitherClaims <-
    lift . runExceptT $
      JWT.verifyClaimsAt validation secret time =<< JWT.decodeCompact token
  liftEither . mapLeft jwtClaimsError $ JSON.toJSON <$> eitherClaims
  where
    validation =
      JWT.defaultJWTValidationSettings audienceCheck & set JWT.allowedSkew 30

    audienceCheck :: JWT.StringOrURI -> Bool
    audienceCheck = maybe (const True) (==) configJwtAudience

    jwtClaimsError :: JWT.JWTError -> Error
    jwtClaimsError JWT.JWTExpired = JwtTokenInvalid "JWT expired"
    jwtClaimsError e              = JwtTokenInvalid $ show e

parseClaims :: Monad m =>
  AppConfig -> JSON.Value -> ExceptT Error m AuthResult
parseClaims AppConfig{..} jclaims@(JSON.Object mclaims) = do
  -- role defaults to anon if not specified in jwt
  role <- liftEither . maybeToRight JwtTokenRequired $
    unquoted <$> walkJSPath (Just jclaims) configJwtRoleClaimKey <|> configDbAnonRole
  return AuthResult
           { authClaims = mclaims & KM.insert "role" (JSON.toJSON $ decodeUtf8 role)
           , authRole = role
           }
  where
    walkJSPath :: Maybe JSON.Value -> JSPath -> Maybe JSON.Value
    walkJSPath x                      []                = x
    walkJSPath (Just (JSON.Object o)) (JSPKey key:rest) = walkJSPath (KM.lookup (K.fromText key) o) rest
    walkJSPath (Just (JSON.Array ar)) (JSPIdx idx:rest) = walkJSPath (ar V.!? idx) rest
    walkJSPath _                      _                 = Nothing

    unquoted :: JSON.Value -> BS.ByteString
    unquoted (JSON.String t) = encodeUtf8 t
    unquoted v               = LBS.toStrict $ JSON.encode v
-- impossible case - just added to please -Wincomplete-patterns
parseClaims _ _ = return AuthResult { authClaims = KM.empty, authRole = mempty }

-- | Validate authorization header.
--   Parse and store JWT claims for future use in the request.
middleware :: AppState -> Wai.Middleware
middleware appState app req respond = do
  conf <- getConfig appState
  time <- getTime appState

  let token  = fromMaybe "" $ Wai.extractBearerAuth =<< lookup HTTP.hAuthorization (Wai.requestHeaders req)
      parseJwt = runExceptT $ parseToken conf (LBS.fromStrict token) time >>= parseClaims conf

  if configDbPlanEnabled conf
    then do
      (dur,authResult) <- timeItT parseJwt
      let req' = req { Wai.vault = Wai.vault req & Vault.insert authResultKey authResult & Vault.insert jwtDurKey dur }
      app req' respond
    else do
      authResult <- parseJwt
      let req' = req { Wai.vault = Wai.vault req & Vault.insert authResultKey authResult }
      app req' respond


authResultKey :: Vault.Key (Either Error AuthResult)
authResultKey = unsafePerformIO Vault.newKey
{-# NOINLINE authResultKey #-}

getResult :: Wai.Request -> Maybe (Either Error AuthResult)
getResult = Vault.lookup authResultKey . Wai.vault

jwtDurKey :: Vault.Key Double
jwtDurKey = unsafePerformIO Vault.newKey
{-# NOINLINE jwtDurKey #-}

getJwtDur :: Wai.Request -> Maybe Double
getJwtDur =  Vault.lookup jwtDurKey . Wai.vault

getRole :: Wai.Request -> Maybe BS.ByteString
getRole req = authRole <$> (rightToMaybe =<< getResult req)
