{-# LANGUAGE TypeSynonymInstances #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use zipWithM" #-}
{-# HLINT ignore "Eta reduce" #-}
module Futz.Infer where

import Control.Applicative -- Otherwise you can't do the Applicative instance.
import Control.Monad (ap, liftM)
import Control.Monad.Except
import Control.Monad.State
import Data.List
import Debug.Trace
import Futz.Syntax
import Futz.Types



data Expl = Expl Var Scheme [Binding]
  deriving (Eq, Show)
data Impl = Impl Var [Binding]
  deriving (Eq, Show)

implName (Impl v _) = v
implBindings (Impl _ as) = as
--
--   A Type Inference Monad
type TI a = ExceptT TypeError (State InferState) a

-- type TI a = ExceptT InferState (State TypeError) a

data InferState = InferState
  { substs :: Subst,
    nextId :: Int
  }
  deriving (Eq, Show)

defaultInferState = InferState {substs = nullSubst, nextId = 0}


runTI :: TI a -> Either TypeError a
runTI ti = evalState (runExceptT ti) defaultInferState

-- evalState (runExceptT ti) defaultInferState

-- The getSubst operation returns the current substitution, while unify extends it with a most
-- general unifier of its arguments:

getSubst :: TI Subst
getSubst = do
  (lift . gets) substs

unify :: Type -> Type -> TI ()
unify t1 t2 = do
  s <- getSubst
  u <- liftEither $ mgu (apply s t1) (apply s t2)
  extSubst u

-- For clarity, we define the operation that extends the substitution as a separate function,
-- even though it is used only here in the definition of unify:
extSubst :: Subst -> TI ()
extSubst s' = do
  (lift . Control.Monad.State.modify) (\st -> st {substs = s' @@ substs st})

-- TI (\s n -> (s' @@ s, n, ()))

-- Overall, the decision to hide the current substitution in the TI monad makes the presentation
-- of type inference much clearer. In particular, it avoids heavy use of apply every time an
-- extension is (or might have been) computed.
--
-- There is only one primitive that deals with the integer portion of the state, using it in
-- combination with enumId to generate a new type variable of a specified kind:
--
newIdNum :: TI Int
newIdNum = do
  ps <- get
  let id = nextId ps
  put $ ps {nextId = id + 1}
  return id

-- TI (\s n -> (s, n + 1, n))

newTVar :: Kind -> TI Type
newTVar k = do
  n <- newIdNum
  return $ TVar (Tyvar (enumId n) k)

-- One place where newTVar is useful is in instantiating a type scheme
-- with new type variables of appropriate kinds:
freshInst :: Scheme -> TI (Qual Type)
freshInst (Forall ks qt) = do
  ts <- mapM newTVar ks
  return (inst ts qt)

-- The structure of this definition guarantees that ts has exactly the right number of type
-- variables, and each with the right kind, to match ks. Hence, if the type scheme is well-formed,
-- then the qualified type returned by freshInst will not contain any unbound generics of the form
-- TGen n. The definition relies on an auxiliary function inst, which is a variation of apply that
-- works on generic variables. In other words, inst ts t replaces each occurrence of a generic variable
-- TGen n in t with ts!!n. It is convenient to build up the definition of inst using overloading:

class Instantiate t where
  inst :: [Type] -> t -> t

instance Instantiate Type where
  inst ts (TAp l r) = TAp (inst ts l) (inst ts r)
  inst ts (TGen n) = ts !! n
  inst ts t = t

instance Instantiate a => Instantiate [a] where
  inst ts = map (inst ts)

instance Instantiate t => Instantiate (Qual t) where
  inst ts (ps :=> t) = inst ts ps :=> inst ts t

instance Instantiate Pred where
  inst ts (IsIn c t) = IsIn c (inst ts t)

-------------------------------------------------------------------------------
--
--
--
--
--   Type Inference
--
-- With this section we have reached the heart of the paper, detailing our algorithm for type
-- inference. It is here that we finally see how the machinery that has been built up in earlier
-- sections is actually put to use. We develop the complete algorithm in stages, working through
-- the abstract syntax of the input language from the simplest part (literals) to the most complex
-- (binding groups). Most of the typing rules are expressed by functions whose types are simple
-- variants of the following synonym:
type Infer e t = ClassEnv -> [Assump] -> e -> TI ([Pred], t)

class Inferrable e where
  infer :: Infer e Type

-- Expressions
-- Next we describe type inference for expressions, represented by the Expr datatype:
tiExpr :: Infer (Exp SourceRange) Type
tiExpr ce as e = case e of
  -- let, supporting rec
  Let _ n v e -> do
    (ps, as') <- tiDefinitions ce as [Definition n Nothing [Binding [] v]]
    (qs, t) <- tiExpr ce (as' ++ as) e
    return (ps ++ qs, t)
  Lit _ (LitInt _) -> do
    v <- newTVar Star
    return ([IsIn "Num" v], v)
  -- return ([], tInt)

  -- variable inference is just a lookup
  Var _ i -> case Futz.Types.find i as of
    Just sc -> do
      (ps :=> t) <- freshInst sc
      return (ps, t)
    Nothing -> throwError $ TEGeneric ("Failed: variable " <> i <> " not bound")

  IfElse _ tst thn els -> do
    (psTst, tTst) <- tiExpr ce as tst
    (psThn, tThn) <- tiExpr ce as thn
    (psEls, tEls) <- tiExpr ce as els
    -- The "test" value of the if-else must be a Bool
    unify tBool tTst

    -- Both arms of the if statement must be the same type.
    t <- newTVar Star
    unify tThn t
    unify tEls t
    return (psTst ++ psThn ++ psEls, tEls)

  -- For lambdas, turn `\x->e` into `let f x = e in f`
  -- and typecheck that instead
  Lambda ann a x -> do
    n <- newIdNum
    let tmpVar = "$INVALIDVAR" <> show n
    (ps, as') <- tiDefinitions ce as [Definition tmpVar Nothing [Binding [PVar a] x]]
    (qs, t) <- tiExpr ce (as' ++ as) (Var ann tmpVar)
    return (ps ++ qs, t)
  -- Simple appication
  App _ e f -> do
    (ps, te) <- tiExpr ce as e
    (qs, tf) <- tiExpr ce as f
    t <- newTVar Star
    unify (tf `fn` t) te
    return (ps ++ qs, t)

  -- Infix syntax is just a magic version of apply
  Inf a op l r -> tiExpr ce as (App a (App a (Var a op) l) r)

-- -- Everything else is a double, for now. TODO: fix this!
-- _ -> do
--   return ([], tDouble)

tiBinding :: Infer Binding Type
tiBinding ce as (Binding pats e) = do
  (ps, as', ts) <- tiPats pats
  (qs, t) <- tiExpr ce (as' ++ as) e
  return (ps ++ qs, foldr fn t ts)

tiBindings :: ClassEnv -> [Assump] -> [Binding] -> Type -> TI [Pred]
tiBindings ce as bindings t = do
  psts <- mapM (tiBinding ce as) bindings
  mapM_ (unify t . snd) psts
  return (concatMap fst psts)

tiPat :: Pat -> TI ([Pred], [Assump], Type)
tiPat (PVar i) = do
  v <- newTVar Star
  return ([], [i :>: toScheme v], v)

tiPats :: [Pat] -> TI ([Pred], [Assump], [Type])
tiPats pats = do
  psasts <- mapM tiPat pats
  let ps = concat [ps' | (ps', _, _) <- psasts]
      as = concat [as' | (_, as', _) <- psasts]
      ts = [t | (_, _, t) <- psasts]
  return (ps, as, ts)

tiDefinitions :: Infer [Definition] [Assump]
tiDefinitions ce as defs = do
  -- Split the definitions into "Explicit" and "Implicit" groups based on
  -- if they are provided with a type or now.
  let es = [Expl v sc alts | o@(Definition v (Just sc) alts) <- defs]
  let iss = [Impl v alts | o@(Definition v Nothing alts) <- defs]
  -- TODO:
  -- return ([], as)
  let as' = [v :>: sc | (Expl v sc alts) <- es]
  (ps, as'') <- tiImpls ce (as' ++ as) iss
  qss <- mapM (tiExpl ce (as'' ++ as' ++ as)) es
  return (ps ++ concat qss, as'' ++ as')

tiExpl :: ClassEnv -> [Assump] -> Expl -> TI [Pred]
tiExpl ce as ex@(Expl i sc alts) =
  do
    (qs :=> t) <- freshInst sc
    ps <- tiBindings ce as alts t
    s <- getSubst
    let qs' = apply s qs
        t' = apply s t
        fs = tv (apply s as)
        gs = tv t' \\ fs
        sc' = quantify gs (qs' :=> t')
        ps' = filter (not . entail ce qs') (apply s ps)
    (ds, rs) <- split ce fs gs ps'
    if sc /= sc'
      then liftEither $ genericTypeError ("signature too general" <> show ex <> " sc:" <> show sc <> " sc':" <> show sc')
      else
        if not (null rs)
          then liftEither $ genericTypeError "context too weak"
          else return ds

restricted :: [Impl] -> Bool
restricted = any simple
  where
    simple (Impl i alts) = any (null . bindingPatterns) alts

tiImpls :: Infer [Impl] [Assump]
tiImpls ce as bs = do
  ts <- mapM (\_ -> newTVar Star) bs
  let is = map implName bs
      scs = map toScheme ts
      as' = zipWith (:>:) is scs ++ as
      altss = map implBindings bs
  pss <- sequence (zipWith (tiBindings ce as') altss ts)
  s <- getSubst
  let ps' = apply s (concat pss)
      ts' = apply s ts
      fs = tv (apply s as)
      vss = map tv ts'
      gs = foldr1 union vss \\ fs
  (ds, rs) <- split ce fs (foldr1 intersect vss) ps'
  if restricted bs
    then
      let gs' = gs \\ tv rs
          scs' = map (quantify gs' . ([] :=>)) ts'
       in return (ds ++ rs, zipWith (:>:) is scs')
    else
      let scs' = map (quantify gs . (rs :=>)) ts'
       in return (ds, zipWith (:>:) is scs')

tiSeq :: Infer bg [Assump] -> Infer [bg] [Assump]
tiSeq ti ce as [] = return ([], [])
tiSeq ti ce as (bs : bss) = do
  (ps, as') <- ti ce as bs
  (qs, as'') <- tiSeq ti ce (as' ++ as) bss
  return (ps ++ qs, as'' ++ as')

--------------------------------------------------------------------------------
split ::
  ClassEnv ->
  [Tyvar] ->
  [Tyvar] ->
  [Pred] ->
  TI ([Pred], [Pred])
split ce fs gs ps = do
  ps' <- liftEither $ reduce ce ps
  let (ds, rs) = partition (all (`elem` fs) . tv) ps'
  rs' <- defaultedPreds ce (fs ++ gs) rs
  return (ds, rs \\ rs')

candidates :: ClassEnv -> Ambiguity -> [Type]
candidates ce (v, qs) =
  [ t'
    | let is = [i | IsIn i t <- qs]
          ts = [t | IsIn i t <- qs],
      all (TVar v ==) ts,
      any (`elem` numClasses) is,
      all (`elem` stdClasses) is,
      t' <- defaults ce,
      all (entail ce []) [IsIn i t' | i <- is]
  ]

stdClasses :: [Id]
stdClasses =
  [ "Eq",
    "Ord",
    "Show",
    "Read",
    "Bounded",
    "Enum",
    "Ix",
    "Functor",
    "Monad",
    "MonadPlus"
  ]
    ++ numClasses

type Ambiguity = (Tyvar, [Pred])

ambiguities :: ClassEnv -> [Tyvar] -> [Pred] -> [Ambiguity]
ambiguities ce vs ps = [(v, filter (elem v . tv) ps) | v <- tv ps \\ vs]

numClasses :: [Id]
numClasses = ["Num", "Integral", "Floating", "Fractional", "Real", "RealFloat", "RealFrac"]

withDefaults ::
  ([Ambiguity] -> [Type] -> a) ->
  ClassEnv ->
  [Tyvar] ->
  [Pred] ->
  TI a
withDefaults f ce vs ps
  | any null tss = trace (show ce) $ throwError (TEGeneric "cannot resolve ambiguity")
  | otherwise = return (f vps (map head tss))
  where
    vps = ambiguities ce vs ps
    tss = map (candidates ce) vps

defaultedPreds :: ClassEnv -> [Tyvar] -> [Pred] -> TI [Pred]
defaultedPreds = withDefaults (\vps ts -> concatMap snd vps)

defaultSubst :: ClassEnv -> [Tyvar] -> [Pred] -> TI Subst
defaultSubst ce ts ps = withDefaults (zip . map fst) ce ts ps

tiProgram :: ClassEnv -> [Assump] -> [Program] -> Either TypeError [Assump]
tiProgram ce as progs = runTI $
  do
    (ps, as') <- tiSeq tiDefinitions ce as (map defs progs)
    s <- getSubst
    rs <- liftEither $ reduce ce (apply s ps)
    -- let rs = apply s ps
    s' <- defaultSubst ce [] rs
    return (reverse (apply (s' @@ s) as'))
