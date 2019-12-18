{-# LANGUAGE Trustworthy, TemplateHaskell, LambdaCase, ViewPatterns #-}
------------------------------------------------------------------------
-- |
-- Module      :  Data.Extensible.Effect.TH
-- Copyright   :  (c) Fumiaki Kinoshita 2019
-- License     :  BSD3
--
-- Maintainer  :  Fumiaki Kinoshita <fumiexcel@gmail.com>
--
------------------------------------------------------------------------
module Data.Extensible.Effect.TH (decEffects
  , decEffectSet
  , decEffectSuite
  , customDecEffects) where

import Data.Extensible.Effect
import Data.List (nub)
import Language.Haskell.TH
import Data.Char
import Control.Monad
import Type.Membership

-- | Generate named effects from a GADT declaration.
--
-- @
-- decEffects [d|
--  data Blah a b x where
--    Blah :: Int -> a -> Blah a b b
--  |]
-- @
--
-- generates
--
-- @
-- type Blah a b = \"Blah\" >: Action '[Int, a] b
-- blah :: forall xs a b
--   . Associate \"Blah\" (Action '[Int, a] b) xs
--   => Int -> a -> Eff xs b
-- blah a0 a1
--   = liftEff
--     (Data.Proxy.Proxy :: Data.Proxy.Proxy \"Blah\")
--     (AArgument a0 (AArgument a1 AResult))
-- @
decEffects :: DecsQ -> DecsQ
decEffects = customDecEffects False True

-- | Instead of making a type synonym for individual actions, it defines a list
-- of actions.
decEffectSet :: DecsQ -> DecsQ
decEffectSet = customDecEffects True False

-- | Generates type synonyms for the set of actions and also individual actions.
decEffectSuite :: DecsQ -> DecsQ
decEffectSuite = customDecEffects True True

-- | Generate effect suite with custom settings.
customDecEffects :: Bool -- ^ generate a synonym of the set of actions
    -> Bool -- ^ generate synonyms for individual actions
    -> DecsQ -> DecsQ
customDecEffects synSet synActions decs = decs >>= \ds -> fmap concat $ forM ds $ \case
  DataD _ dataName tparams _ cs _
    -> do
      (cxts, dcs) <- fmap unzip $ traverse (con2Eff tparams) cs

      let vars = map PlainTV $ nub $ concatMap (varsT . snd) cxts
      return $ [TySynD dataName vars (typeListT $ map snd cxts) | synSet]
          ++ [ TySynD k (map PlainTV $ nub $ varsT t) t | synActions, (k, t) <- cxts]
          ++ concat dcs
  _ -> fail "mkEffects accepts GADT declaration"

con2Eff :: [TyVarBndr] -> Con -> Q ((Name, Type), [Dec])
con2Eff _ (GadtC [name] st (AppT _ resultT))
  = return $ effectFunD name (map snd st) resultT
con2Eff tparams (ForallC _ eqs (NormalC name st))
  = return $ fromMangledGADT tparams eqs name st
con2Eff tparams (ForallC _ _ c) = con2Eff tparams c
con2Eff _ p = do
  runIO (print p)
  fail "Unsupported constructor"

fromMangledGADT :: [TyVarBndr] -> [Type] -> Name -> [(Strict, Type)] -> ((Name, Type), [Dec])
fromMangledGADT tyvars_ eqs con fieldTypes
  = effectFunD con argumentsT result
  where
    getTV (PlainTV n) = n
    getTV (KindedTV n _) = n

    tyvars = map getTV tyvars_

    dic_ = [(v, t) | AppT (AppT EqualityT (VarT v)) t <- eqs]
    dic = dic_ ++ [(t, VarT v) | (v, VarT t) <- dic_]

    params' = do
      (t, v) <- zip tyvars uniqueNames
      case lookup t dic of
        Just (VarT p) -> return (t, p)
        _ -> return (t, v)

    argumentsT = map (\case
      (_, VarT n) -> maybe (VarT n) VarT $ lookup n params'
      (_, x) -> x) fieldTypes

    result = case lookup (last tyvars) dic of
      Just (VarT v) -> case lookup v params' of
        Just p -> VarT p
        Nothing -> VarT v
      Just t -> t
      Nothing -> VarT $ mkName "x"

varsT :: Type -> [Name]
varsT (VarT v) = [v]
varsT (AppT s t) = varsT s ++ varsT t
varsT _ = []

effectFunD :: Name
  -> [Type]
  -> Type
  -> ((Name, Type), [Dec])
effectFunD key argumentsT resultT = ((key, PromotedT '(:>) `AppT` nameT `AppT` actionT)
  , [SigD fName typ, FunD fName [effClause nameT (length argumentsT)]]) where

    varList = mkName "xs"

    fName = let (ch : rest) = nameBase key in mkName $ toLower ch : rest

    typ = ForallT (map PlainTV $ varList : varsT resultT ++ concatMap varsT argumentsT)
        [associateT nameT actionT varList]
        $ effectFunT varList argumentsT resultT

    -- Action [a, B, C] R
    actionT = ConT ''Action `AppT` typeListT argumentsT `AppT` resultT

    nameT = LitT $ StrTyLit $ nameBase key

effectFunT :: Name
  -> [Type]
  -> Type
  -> Type
effectFunT varList argumentsT resultT
  = foldr (\x y -> ArrowT `AppT` x `AppT` y) rt argumentsT where
    rt = ConT ''Eff `AppT` VarT varList `AppT` resultT

uniqueNames :: [Name]
uniqueNames = map mkName $ concatMap (flip replicateM ['a'..'z']) [1..]

typeListT :: [Type] -> Type
typeListT = foldr (\x y -> PromotedConsT `AppT` x `AppT` y) PromotedNilT

associateT :: Type -- key
  -> Type -- type
  -> Name -- variable
  -> Type
associateT nameT t xs = ConT ''Lookup `AppT` VarT xs `AppT` nameT `AppT` t

effClause :: Type -- effect key
  -> Int -- number of arguments
  -> Clause
effClause nameT n = Clause (map VarP argNames) (NormalB rhs) [] where
  -- liftEff (Proxy :: Proxy "Foo")
  lifter = VarE 'liftEff `AppE` (ConE 'Proxy `SigE` AppT (ConT ''Proxy) nameT)

  argNames = map (mkName . ("a" ++) . show) [0..n-1]

  rhs = lifter `AppE` foldr (\x y -> ConE 'AArgument `AppE` x `AppE` y)
    (ConE 'AResult)
    (map VarE argNames)
