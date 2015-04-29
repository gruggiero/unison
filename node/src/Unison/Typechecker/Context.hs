{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

-- | The Unison language typechecker
module Unison.Typechecker.Context (context, subtype, synthesizeClosed) where

import Control.Applicative
import Data.List
import Data.Set (Set)
import Unison.Note (Note,Noted(..))
import Unison.Term (Term)
import Unison.Type (Type, Monotype(..))
import qualified Unison.ABT as ABT
import qualified Data.Foldable as Foldable
import qualified Unison.Note as Note
import qualified Data.Set as Set
import qualified Unison.Term as Term
import qualified Unison.Type as Type

-- | Elements of an algorithmic context
data Element
  = Universal ABT.V       -- | ^ `v` is universally quantified
  | Existential ABT.V     -- | ^ `v` existential and unsolved
  | Solved ABT.V Monotype -- | ^ `v` is solved to some monotype
  | Ann ABT.V Type        -- | ^ `v` has type `a`, which may be quantified
  | Marker ABT.V          -- | ^ used for scoping
  deriving Eq

instance Show Element where
  show (Universal v) = show v
  show (Existential v) = "'"++show v
  show (Solved v t) = "'"++show v++" = "++show t
  show (Ann v t) = show v++" : "++show t
  show (Marker v) = "|"++show v++"|"

varUsedBy :: Element -> ABT.V
varUsedBy e = case e of
  Existential v -> v
  Universal v -> v
  Marker v -> v
  Ann v _ -> v
  Solved v _ -> v

(===) :: Element -> Element -> Bool
Existential v === Existential v2 | v == v2 = True
Universal v   === Universal v2 | v == v2 = True
Marker v      === Marker v2 | v == v2 = True
_ === _ = False

{- An ordered algorithmic context, stored as a snoc list of
   elements (the first element of the list represents the last element
   of the context).

   The set stored along with each element is the set of variables
   referenced by elements up to and including that element. With
   this representation, any suffix of the `Context` element list
   is also a valid context, and a fresh name can be obtained just
   by inspecting the first set in the list.
-}
newtype Context = Context [(Element,Set ABT.V)]

context0 :: Context
context0 = Context []

instance Show Context where
  show (Context es) = "Γ\n  " ++ (intercalate "\n  " . map (show . fst)) (reverse es)

usedVars :: Context -> Set ABT.V
usedVars (Context []) = Set.empty
usedVars (Context ((_,s) : _)) = s

-- | Add an element onto the end of this `Context`
extend :: Element -> Context -> Context
extend e c@(Context ctx) = Context ((e,s'):ctx) where
  s' = Set.insert (varUsedBy e) (usedVars c)

context :: [Element] -> Context
context xs = foldl' (flip extend) context0 xs

append :: Context -> Context -> Context
append ctxL (Context es) = foldl' f ctxL (reverse es) where
  f ctx (e,_) = extend e ctx

fresh :: ABT.V -> Context -> ABT.V
fresh v ctx = ABT.freshIn' (usedVars ctx) v

fresh3 :: ABT.V -> ABT.V -> ABT.V -> Context -> (ABT.V, ABT.V, ABT.V)
fresh3 va vb vc ctx = (fresh va ctx, fresh vb ctx, fresh vc ctx)

-- | Extend this `Context` with a single universally quantified variable,
-- guaranteed to be fresh
extendUniversal :: ABT.V -> Context -> (ABT.V, Context)
extendUniversal v ctx = case fresh v ctx of
  v -> (v, extend (Universal v) ctx)

-- | Extend this `Context` with a marker variable, guaranteed to be fresh
extendMarker :: ABT.V -> Context -> (ABT.V, Context)
extendMarker v ctx = case fresh v ctx of
  v -> (v, ctx `append` context [Marker v, Existential v])

-- | Delete from the end of this context up to and including
-- the given `Element`. Returns `Left` if the element is not found.
retract :: Element -> Context -> Either Note Context
retract m (Context ctx) =
  let maybeTail [] = Left $ Note.note ("unable to retract: " ++ show m)
      maybeTail (_:t) = Right t
  -- note: no need to recompute used variables; any suffix of the
  -- context snoc list is also a valid context
  in Context <$> maybeTail (dropWhile (\(e,_) -> e /= m) ctx)

retract' :: Element -> Context -> Context
retract' e ctx = case retract e ctx of
  Left _ -> context []
  Right ctx -> ctx

universals :: Context -> [ABT.V]
universals (Context ctx) = [v | (Universal v,_) <- ctx]

existentials :: Context -> [ABT.V]
existentials (Context ctx) = ctx >>= go where
  go (Existential v,_) = [v]
  go (Solved v _,_) = [v]
  go _ = []

solved :: Context -> [(ABT.V, Monotype)]
solved (Context ctx) = [(v, sa) | (Solved v sa,_) <- ctx]

unsolved :: Context -> [ABT.V]
unsolved (Context ctx) = [v | (Existential v,_) <- ctx]

replace :: Element -> Context -> Context -> Context
replace e focus ctx = let (l,r) = breakAt e ctx in l `append` focus `append` r

breakAt :: Element -> Context -> (Context, Context)
breakAt m (Context xs) =
  let (r, l) = break (\(e,_) -> e === m) xs
  -- l is a suffix of xs and is already a valid context;
  -- r needs to be rebuilt
  in (Context (drop 1 l), context . map fst $ reverse r)

-- | ordered Γ α β = True <=> Γ[α^][β^]
ordered :: Context -> ABT.V -> ABT.V -> Bool
ordered ctx v v2 = v `elem` existentials (retract' (Existential v2) ctx)

-- | Check that the context is well formed, namely that
-- there are no circular variable references, and any types
-- mentioned in either `Ann` or `Solved` elements must be
-- wellformed with respect to the prefix of the context
-- leading up to these elements.
wellformed :: Context -> Bool
wellformed ctx = all go (zipTail ctx) where
  go (Universal v, ctx') = v `notElem` universals ctx'
  go (Existential v, ctx') = v `notElem` existentials ctx'
  go (Solved v sa, ctx') = v `notElem` existentials ctx' && wellformedType ctx' (Type.getPolytype sa)
  go (Ann v t, ctx') = v `notElem` vars ctx' && wellformedType ctx' t
  go (Marker v, ctx') = v `notElem` vars ctx' && v `notElem` existentials ctx'

zipTail :: Context -> [(Element, Context)]
zipTail (Context ctx) = zip (map fst ctx) (map Context $ tail (tails ctx))

-- | Check that the type is well formed wrt the given `Context`
wellformedType :: Context -> Type -> Bool
wellformedType c t = wellformed c && case t of
  Type.Existential' v -> v `elem` existentials c
  Type.Universal' v -> v `elem` universals c
  Type.Lit' _ -> True
  Type.Arrow' i o -> wellformedType c i && wellformedType c o
  Type.Ann' t' _ -> wellformedType c t'
  Type.App' x y -> wellformedType c x && wellformedType c y
  Type.Constrain' t' _ -> wellformedType c t'
  Type.Forall' v t ->
    let (v',ctx2) = extendUniversal v c
    in wellformedType ctx2 (ABT.replace (Type.universal v') (Type.matchUniversal v) t)
  _ -> error $ "Context.wellformedType - ill formed type - " ++ show t

bindings :: Context -> [(ABT.V, Type)]
bindings (Context ctx) = [(v,a) | (Ann v a,_) <- ctx]

lookupType :: Context -> ABT.V -> Maybe Type
lookupType ctx v = lookup v (bindings ctx)

vars :: Context -> [ABT.V]
vars = fmap fst . bindings

-- | solve (ΓL,α^,ΓR) α τ = (ΓL,α = τ,ΓR)
-- If the given existential variable exists in the context,
-- we solve it to the given monotype, otherwise return `Nothing`
solve :: Context -> ABT.V -> Monotype -> Maybe Context
solve ctx v t
  | wellformedType ctxL (Type.getPolytype t) = Just ctx'
  | otherwise                                = Nothing
  where (ctxL,ctxR) = breakAt (Existential v) ctx
        ctx' = ctxL `append` context [Solved v t] `append` ctxR

-- | Replace any existentials with their solution in the context
apply :: Context -> Type -> Type
apply ctx t = case t of
  Type.Universal' _ -> t
  Type.Lit' _ -> t
  Type.Existential' v ->
    maybe t (\(Type.Monotype t') -> apply ctx t') (lookup v (solved ctx))
  Type.Arrow' i o -> Type.arrow (apply ctx i) (apply ctx o)
  Type.App' x y -> Type.app (apply ctx x) (apply ctx y)
  Type.Ann' v k -> Type.ann (apply ctx v) k
  Type.Constrain' v c -> Type.constrain (apply ctx v) c
  Type.Forall' v t' -> Type.forall v (apply ctx t')
  _ -> error $ "Context.apply ill formed type - " ++ show t

-- | `subtype ctx t1 t2` returns successfully if `t1` is a subtype of `t2`.
-- This may have the effect of altering the context.
subtype :: Context -> Type -> Type -> Either Note Context
subtype ctx tx ty = Note.scope (show tx++" <: "++show ty) (go tx ty) where -- Rules from figure 9
  go (Type.Lit' l) (Type.Lit' l2) | l == l2 = pure ctx -- `Unit`
  go t1@(Type.Universal' v1) t2@(Type.Universal' v2) -- `Var`
    | v1 == v2 && wellformedType ctx t1 && wellformedType ctx t2
    = pure ctx
  go t1@(Type.Existential' v1) t2@(Type.Existential' v2) -- `Exvar`
    | v1 == v2 && wellformedType ctx t1 && wellformedType ctx t2
    = pure ctx
  go (Type.Arrow' i1 o1) (Type.Arrow' i2 o2) = do -- `-->`
    ctx' <- subtype ctx i1 i2
    subtype ctx' (apply ctx' o1) (apply ctx' o2)
  go (Type.App' x1 y1) (Type.App' x2 y2) = do -- analogue of `-->`
    ctx' <- subtype ctx x1 x2
    subtype ctx' (apply ctx' y1) (apply ctx' y2)
  go (Type.Forall' v t) t2 = Note.scope "forall (L)" $
    let (v', ctx') = extendMarker v ctx
        t' = ABT.replace (Type.existential v') (Type.matchUniversal v) t
    in Note.scope (show t') $
       subtype ctx' (apply ctx' t') t2 >>= retract (Marker v')
  go t (Type.Forall' v t2) = Note.scope "forall (R)" $
    let (v', ctx') = extendUniversal v ctx
        t2' = ABT.replace (Type.universal v') (Type.matchUniversal v) t2
    in subtype ctx' t t2' >>= retract (Universal v')
  go (Type.Existential' v) t -- `InstantiateL`
    | v `elem` existentials ctx && Set.notMember v (Type.freeVars t) =
    instantiateL ctx v t
  go t (Type.Existential' v) -- `InstantiateR`
    | v `elem` existentials ctx && Set.notMember v (Type.freeVars t) =
    instantiateR ctx t v
  go _ _ = Left $ Note.note "not a subtype"

-- | Instantiate the given existential such that it is
-- a subtype of the given type, updating the context
-- in the process.
instantiateL :: Context -> ABT.V -> Type -> Either Note Context
instantiateL ctx v t = case Type.monotype t >>= solve ctx v of
  Just ctx' -> pure ctx' -- InstLSolve
  Nothing -> case t of
    Type.Existential' v2 | ordered ctx v v2 -> -- InstLReach (both are existential, set v2 = v)
      maybe (Left $ Note.note "InstLReach failed") pure $
        solve ctx v2 (Type.Monotype (Type.existential v))
    Type.Arrow' i o -> -- InstLArr
      let i' = fresh (ABT.v' "i") ctx
          o' = fresh (ABT.v' "o") ctx
          s = Solved v (Type.Monotype (Type.arrow (Type.existential i') (Type.existential o')))
      in do
        ctx' <- instantiateR (replace (Existential v) (context [Existential o', Existential i', s]) ctx)
                             i
                             i'
        instantiateL ctx' o' (apply ctx' o)
    Type.App' x y -> -- analogue of InstLArr
      let x' = fresh (ABT.v' "x") ctx
          y' = fresh (ABT.v' "y") ctx
          s = Solved v (Type.Monotype (Type.app (Type.existential x') (Type.existential y')))
          ctx0 = replace (Existential v)
                         (context [Existential y', Existential x', s])
                         ctx
      in do
        ctx' <- instantiateL ctx0 x' (apply ctx0 x)
        instantiateL ctx' y' (apply ctx' y)
    Type.Forall' x body -> -- InstLIIL
      let (v', ctx') = extendUniversal x ctx
      in instantiateL ctx' v (ABT.replace (Type.universal v') (Type.matchUniversal x) body)
         >>= retract (Universal v')
    _ -> Left $ Note.note "could not instantiate left"

-- | Instantiate the given existential such that it is
-- a supertype of the given type, updating the context
-- in the process.
instantiateR :: Context -> Type -> ABT.V -> Either Note Context
instantiateR ctx t v = case Type.monotype t >>= solve ctx v of
  Just ctx' -> pure ctx' -- InstRSolve
  Nothing -> case t of
    Type.Existential' v2 | ordered ctx v v2 -> -- InstRReach (both are existential, set v2 = v)
      maybe (Left $ Note.note "InstRReach failed") pure $
        solve ctx v2 (Type.Monotype (Type.existential v))
    Type.Arrow' i o -> -- InstRArrow
      let i' = fresh (ABT.v' "i") ctx
          o' = fresh (ABT.v' "o") ctx
          s = Solved v (Type.Monotype (Type.arrow (Type.existential i') (Type.existential o')))
      in do
        ctx' <- instantiateL (replace (Existential v) (context [Existential o', Existential i', s]) ctx)
                             i'
                             i
        instantiateR ctx' (apply ctx' o) o'
    Type.App' x y -> -- analogue of InstRArr
      let x' = fresh (ABT.v' "x") ctx
          y' = fresh (ABT.v' "y") ctx
          s = Solved v (Type.Monotype (Type.app (Type.existential x') (Type.existential y')))
          ctx0 = replace (Existential v)
                         (context [Existential y', Existential x', s])
                         ctx
      in do
        ctx' <- instantiateR ctx0 (apply ctx0 x) x'
        instantiateR ctx' (apply ctx' y) y'
    Type.Forall' x body -> -- InstRAIIL
      let x' = fresh (ABT.v' "v") ctx
      in
        instantiateR (ctx `append` context [Marker x', Existential x'])
                     (ABT.replace (Type.existential x') (Type.matchUniversal x) body)
                     v
        >>= retract (Marker x')
    _ -> Left $ Note.note "could not instantiate right"

-- | Check that under the given context, `e` has type `t`,
-- updating the context in the process.
check :: Context -> Term -> Type -> Either Note Context
check ctx e t | wellformedType ctx t = Note.scope (show e ++ " : " ++ show t) $ go e t where
  go (Term.Lit' l) _ = subtype ctx (synthLit l) t -- 1I
  go _ (Type.Forall' x body) = -- ForallI
    let (x', ctx') = extendUniversal x ctx
    in check ctx' e (ABT.replace (Type.universal x') (Type.matchUniversal x) body)
       >>= retract (Universal x')
  go (Term.Lam' x body) (Type.Arrow' i o) = -- =>I
    let x' = fresh x ctx
        ctx' = extend (Ann x' i) ctx
        body' = ABT.subst (ABT.var x') x body
    in check ctx' body' o >>= retract (Ann x' i)
  -- go Term.Blank _ = Right ctx -- possible hack to workaround lack of impredicative instantiation
  go _ _ = do -- Sub
    (a, ctx') <- synthesize ctx e
    subtype ctx' (apply ctx' a) (apply ctx' t)
check ctx _ t = Note.scope ("context: " ++ show ctx) .
                Note.scope ("type: " ++ show t) .
                Note.scope ("context well formed: " ++ show (wellformed ctx)) .
                Note.scope ("type well formed: " ++ show (wellformedType ctx t))
                $ Left (Note.note "check failed")

-- | Infer the type of a literal
synthLit :: Term.Literal -> Type
synthLit lit = Type.lit $ case lit of
  Term.Number _ -> Type.Number
  Term.Text _ -> Type.Text
  Term.Distance _ -> Type.Distance

-- | Synthesize the type of the given term, updating the context in the process.
synthesize :: Context -> Term -> Either Note (Type, Context)
synthesize ctx e = Note.scope ("infer: " ++ show e) $ go e where
  go (Term.Var' v) = case lookupType ctx v of -- Var
    Nothing -> Left $ Note.note "type not in scope"
    Just t -> pure (t, ctx)
  go Term.Blank' = let v = ABT.v' "t" in pure (Type.forall v (Type.universal v), ctx)
  go (Term.Ann' (Term.Ref' _) t) =
    pure (t, ctx) -- innermost Ref annotation assumed to be correctly provided by `synthesizeClosed`
  go (Term.Ref' h) = Left . Note.note $ "unannotated reference: " ++ show h
  go (Term.Ann' e' t) = (,) t <$> check ctx e' t -- Anno
  go (Term.Lit' l) = pure (synthLit l, ctx) -- 1I=>
  go (Term.App' f arg) = do -- ->E
    (ft, ctx') <- synthesize ctx f
    synthesizeApp ctx' (apply ctx' ft) arg
  go (Term.Vector' v) =
    let e = fresh (ABT.v' "e") ctx
        ctxTl = context [Marker e, Existential e]
        step term ctx = check ctx term (Type.existential e)
    in Foldable.foldrM step (ctx `append` ctxTl) v >>=
       \ctx' -> pure $
         let
           (ctx1, ctx2) = breakAt (Marker e) ctx'
           -- unsolved existentials get generalized to universals
           vt = apply ctx2 (Type.lit Type.Vector `Type.app` Type.existential e)
           existentials' = unsolved ctx2
           vt2 = foldr gen vt existentials'
           gen e vt = Type.forall e (ABT.replace (Type.universal e) (Type.matchExistential e) vt)
         in (vt2, ctx1)
  go (Term.Lam' x body) = -- ->I=> (Full Damas Milner rule)
    let (arg, i, o) = fresh3 (ABT.v' "arg") x (ABT.v' "o") ctx
        ctxTl = context [Marker i, Existential i, Existential o,
                         Ann arg (Type.existential i)]
    in do
      ctx' <- check (ctx `append` ctxTl)
                    (ABT.subst (ABT.var arg) x body)
                    (Type.existential o)
      pure $ let
        (ctx1, ctx2) = breakAt (Marker i) ctx'
        -- unsolved existentials get generalized to universals
        ft = apply ctx2 (Type.existential i `Type.arrow` Type.existential o)
        existentials' = unsolved ctx2
        ft2 = foldr gen ft existentials'
        gen e ft = Type.forall e (ABT.replace (Type.universal e) (Type.matchExistential e) ft)
        in (ft2, ctx1)
  go _ = Left . Note.note $ "unknown case in synthesize"

-- | Synthesize the type of the given term, `arg` given that a function of
-- the given type `ft` is being applied to `arg`. Update the context in
-- the process.
synthesizeApp :: Context -> Type -> Term -> Either Note (Type, Context)
synthesizeApp ctx ft arg = go ft where
  go (Type.Forall' x body) = let x' = fresh x ctx -- Forall1App
    in synthesizeApp (ctx `append` context [Existential x'])
                     (ABT.replace (Type.existential x') (Type.matchUniversal x) body)
                     arg
  go (Type.Arrow' i o) = (,) o <$> check ctx arg i -- ->App
  go (Type.Existential' a) = -- a^App
    let i = fresh a ctx
        o = fresh (ABT.v' "o") ctx
        soln = Monotype (Type.existential i `Type.arrow` Type.existential o)
        ctxMid = context [Existential o, Existential i, Solved a soln]
    in (,) (Type.existential o) <$>
      check (replace (Existential a) ctxMid ctx)
                      arg
                      (Type.existential i)
  go _ = Left $ Note.note "unable to synthesize type of application"

annotateRefs :: Applicative f => Type.Env f -> Term -> Noted f Term
annotateRefs synth term = ABT.visit f term where
  f (Term.Ref' h) = Just (Term.ann (Term.ref h) <$> synth h)
  f _ = Nothing

synthesizeClosed :: Applicative f => Type.Env f -> Term -> Noted f Type
synthesizeClosed synthRef term = Noted $ synth <$> Note.unnote (annotateRefs synthRef term)
  where
    synth :: Either Note Term -> Either Note Type
    synth (Left e) = Left e
    synth (Right a) = go <$> synthesize (context []) a
    go (t, ctx) = apply ctx t
