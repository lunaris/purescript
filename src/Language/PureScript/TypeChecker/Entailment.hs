{-# LANGUAGE NamedFieldPuns #-}

-- |
-- Type class entailment
--
module Language.PureScript.TypeChecker.Entailment
  ( InstanceContext
  , SolverOptions(..)
  , replaceTypeClassDictionaries
  , newDictionaries
  , entails
  ) where

import Prelude.Compat
import Protolude (ordNub)

import Control.Applicative ((<|>))
import Control.Arrow (second, (&&&))
import Control.Monad.Error.Class (MonadError(..))
import Control.Monad.State
import Control.Monad.Supply.Class (MonadSupply(..))
import Control.Monad.Writer

import Data.Foldable (for_, fold, toList)
import Data.Function (on)
import Data.Functor (($>))
import Data.List (minimumBy, groupBy, nubBy, sortBy)
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Traversable (for)
import Data.Text (Text, stripPrefix, stripSuffix)
import qualified Data.Text as T

import Language.PureScript.AST
import Language.PureScript.Crash
import Language.PureScript.Environment
import Language.PureScript.Errors
import Language.PureScript.Names
import Language.PureScript.Roles
import Language.PureScript.TypeChecker.Monad
import Language.PureScript.TypeChecker.Synonyms
import Language.PureScript.TypeChecker.Unify
import Language.PureScript.TypeClassDictionaries
import Language.PureScript.Types
import Language.PureScript.Label (Label(..))
import Language.PureScript.PSString (PSString, mkString, decodeString)
import qualified Language.PureScript.Constants as C

-- | Describes what sort of dictionary to generate for type class instances
data Evidence
  -- | An existing named instance
  = NamedInstance (Qualified Ident)

  -- | Computed instances
  | WarnInstance Type         -- ^ Warn type class with a user-defined warning message
  | IsSymbolInstance PSString -- ^ The IsSymbol type class for a given Symbol literal
  | EmptyClassInstance        -- ^ For any solved type class with no members
  deriving (Show, Eq)

-- | Extract the identifier of a named instance
namedInstanceIdentifier :: Evidence -> Maybe (Qualified Ident)
namedInstanceIdentifier (NamedInstance i) = Just i
namedInstanceIdentifier _ = Nothing

-- | Description of a type class dictionary with instance evidence
type TypeClassDict = TypeClassDictionaryInScope Evidence

-- | The 'InstanceContext' tracks those constraints which can be satisfied.
type InstanceContext = M.Map (Maybe ModuleName)
                         (M.Map (Qualified (ProperName 'ClassName))
                           (M.Map (Qualified Ident) NamedDict))

-- | A type substitution which makes an instance head match a list of types.
--
-- Note: we store many types per type variable name. For any name, all types
-- should unify if we are going to commit to an instance.
type Matching a = M.Map Text a

combineContexts :: InstanceContext -> InstanceContext -> InstanceContext
combineContexts = M.unionWith (M.unionWith M.union)

-- | Replace type class dictionary placeholders with inferred type class dictionaries
replaceTypeClassDictionaries
  :: forall m
   . (MonadState CheckState m, MonadError MultipleErrors m, MonadWriter MultipleErrors m, MonadSupply m)
  => Bool
  -> Expr
  -> m (Expr, [(Ident, InstanceContext, Constraint)])
replaceTypeClassDictionaries shouldGeneralize expr = flip evalStateT M.empty $ do
    -- Loop, deferring any unsolved constraints, until there are no more
    -- constraints which can be solved, then make a generalization pass.
    let loop e = do
          (e', solved) <- deferPass e
          if getAny solved
            then loop e'
            else return e'
    loop expr >>= generalizePass
  where
    -- This pass solves constraints where possible, deferring constraints if not.
    deferPass :: Expr -> StateT InstanceContext m (Expr, Any)
    deferPass = fmap (second fst) . runWriterT . f where
      f :: Expr -> WriterT (Any, [(Ident, InstanceContext, Constraint)]) (StateT InstanceContext m) Expr
      (_, f, _) = everywhereOnValuesTopDownM return (go True) return

    -- This pass generalizes any remaining constraints
    generalizePass :: Expr -> StateT InstanceContext m (Expr, [(Ident, InstanceContext, Constraint)])
    generalizePass = fmap (second snd) . runWriterT . f where
      f :: Expr -> WriterT (Any, [(Ident, InstanceContext, Constraint)]) (StateT InstanceContext m) Expr
      (_, f, _) = everywhereOnValuesTopDownM return (go False) return

    go :: Bool -> Expr -> WriterT (Any, [(Ident, InstanceContext, Constraint)]) (StateT InstanceContext m) Expr
    go deferErrors (TypeClassDictionary constraint context hints) =
      rethrow (addHints hints) $ entails (SolverOptions shouldGeneralize deferErrors) constraint context hints
    go _ other = return other

-- | Three options for how we can handle a constraint, depending on the mode we're in.
data EntailsResult a
  = Solved a TypeClassDict
  -- ^ We solved this constraint
  | Unsolved Constraint
  -- ^ We couldn't solve this constraint right now, it will be generalized
  | Deferred
  -- ^ We couldn't solve this constraint right now, so it has been deferred
  deriving Show

-- | Options for the constraint solver
data SolverOptions = SolverOptions
  { solverShouldGeneralize :: Bool
  -- ^ Should the solver be allowed to generalize over unsolved constraints?
  , solverDeferErrors      :: Bool
  -- ^ Should the solver be allowed to defer errors by skipping constraints?
  }

data Matched t
  = Match t
  | Apart
  | Unknown
  deriving (Eq, Show, Functor)

instance Monoid t => Monoid (Matched t) where
  mempty = Match mempty

  mappend (Match l) (Match r) = Match (l <> r)
  mappend Apart     _         = Apart
  mappend _         Apart     = Apart
  mappend _         _         = Unknown

-- | Check that the current set of type class dictionaries entail the specified type class goal, and, if so,
-- return a type class dictionary reference.
entails
  :: forall m
   . (MonadState CheckState m, MonadError MultipleErrors m, MonadWriter MultipleErrors m, MonadSupply m)
  => SolverOptions
  -- ^ Solver options
  -> Constraint
  -- ^ The constraint to solve
  -> InstanceContext
  -- ^ The contexts in which to solve the constraint
  -> [ErrorMessageHint]
  -- ^ Error message hints to apply to any instance errors
  -> WriterT (Any, [(Ident, InstanceContext, Constraint)]) (StateT InstanceContext m) Expr
entails SolverOptions{..} constraint context hints =
    solve constraint
  where
    forClassName :: Environment -> InstanceContext -> Qualified (ProperName 'ClassName) -> [Type] -> [TypeClassDict]
    forClassName _ ctx cn@C.Warn [msg] =
      -- Prefer a warning dictionary in scope if there is one available.
      -- This allows us to defer a warning by propagating the constraint.
      findDicts ctx cn Nothing ++ [TypeClassDictionaryInScope [] 0 (WarnInstance msg) [] C.Warn [msg] Nothing]
    forClassName env _ C.Coercible args | Just dicts <- solveCoercible env args = dicts
    forClassName _ _ C.IsSymbol args | Just dicts <- solveIsSymbol args = dicts
    forClassName _ _ C.SymbolCompare args | Just dicts <- solveSymbolCompare args = dicts
    forClassName _ _ C.SymbolAppend args | Just dicts <- solveSymbolAppend args = dicts
    forClassName _ _ C.SymbolCons args | Just dicts <- solveSymbolCons args = dicts
    forClassName _ _ C.RowUnion args | Just dicts <- solveUnion args = dicts
    forClassName _ _ C.RowNub args | Just dicts <- solveNub args = dicts
    forClassName _ _ C.RowLacks args | Just dicts <- solveLacks args = dicts
    forClassName _ _ C.RowCons args | Just dicts <- solveRowCons args = dicts
    forClassName _ _ C.RowToList args | Just dicts <- solveRowToList args = dicts
    forClassName _ ctx cn@(Qualified (Just mn) _) tys = concatMap (findDicts ctx cn) (ordNub (Nothing : Just mn : map Just (mapMaybe ctorModules tys)))
    forClassName _ _ _ _ = internalError "forClassName: expected qualified class name"

    ctorModules :: Type -> Maybe ModuleName
    ctorModules (TypeConstructor (Qualified (Just mn) _)) = Just mn
    ctorModules (TypeConstructor (Qualified Nothing _)) = internalError "ctorModules: unqualified type name"
    ctorModules (TypeApp ty _) = ctorModules ty
    ctorModules (KindedType ty _) = ctorModules ty
    ctorModules _ = Nothing

    findDicts :: InstanceContext -> Qualified (ProperName 'ClassName) -> Maybe ModuleName -> [TypeClassDict]
    findDicts ctx cn = fmap (fmap NamedInstance) . maybe [] M.elems . (>>= M.lookup cn) . flip M.lookup ctx

    valUndefined :: Expr
    valUndefined = Var nullSourceSpan (Qualified (Just (ModuleName [ProperName C.prim])) (Ident C.undefined))

    solve :: Constraint -> WriterT (Any, [(Ident, InstanceContext, Constraint)]) (StateT InstanceContext m) Expr
    solve con = go 0 con
      where
        go :: Int -> Constraint -> WriterT (Any, [(Ident, InstanceContext, Constraint)]) (StateT InstanceContext m) Expr
        go work (Constraint className' tys' _) | work > 1000 = throwError . errorMessage $ PossiblyInfiniteInstance className' tys'
        go work con'@(Constraint className' tys' conInfo) = WriterT . StateT . (withErrorMessageHint (ErrorSolvingConstraint con') .) . runStateT . runWriterT $ do
            -- We might have unified types by solving other constraints, so we need to
            -- apply the latest substitution.
            latestSubst <- lift . lift $ gets checkSubstitution
            let tys'' = map (substituteType latestSubst) tys'
            -- Get the inferred constraint context so far, and merge it with the global context
            inferred <- lift get
            -- We need information about functional dependencies, so we have to look up the class
            -- name in the environment:
            env <- lift . lift $ gets checkEnv
            let classesInScope = typeClasses env
            TypeClassData{ typeClassDependencies } <- case M.lookup className' classesInScope of
              Nothing -> throwError . errorMessage $ UnknownClass className'
              Just tcd -> pure tcd
            let instances = do
                  chain <- groupBy ((==) `on` tcdChain) $
                           sortBy (compare `on` (tcdChain &&& tcdIndex)) $
                           forClassName env (combineContexts context inferred) className' tys''
                  -- process instances in a chain in index order
                  let found = for chain $ \tcd ->
                                -- Make sure the type unifies with the type in the type instance definition
                                case matches typeClassDependencies tcd tys'' of
                                  Apart        -> Right ()                  -- keep searching
                                  Match substs -> Left (Just (substs, tcd)) -- found a match
                                  Unknown      -> Left Nothing              -- can't continue with this chain yet, need proof of apartness
                  case found of
                    Right _               -> []          -- all apart
                    Left Nothing          -> []          -- last unknown
                    Left (Just substsTcd) -> [substsTcd] -- found a match
            solution <- lift . lift $ unique tys'' instances
            case solution of
              Solved substs tcd -> do
                -- Note that we solved something.
                tell (Any True, mempty)
                -- Make sure the substitution is valid:
                lift . lift . for_ substs $ pairwiseM unifyTypes
                -- Now enforce any functional dependencies, using unification
                -- Note: we need to generate fresh types for any unconstrained
                -- type variables before unifying.
                let subst = fmap head substs
                currentSubst <- lift . lift $ gets checkSubstitution
                subst' <- lift . lift $ withFreshTypes tcd (fmap (substituteType currentSubst) subst)
                lift . lift $ zipWithM_ (\t1 t2 -> do
                  let inferredType = replaceAllTypeVars (M.toList subst') t1
                  unifyTypes inferredType t2) (tcdInstanceTypes tcd) tys''
                currentSubst' <- lift . lift $ gets checkSubstitution
                let subst'' = fmap (substituteType currentSubst') subst'
                -- Solve any necessary subgoals
                args <- solveSubgoals subst'' (tcdDependencies tcd)
                initDict <- lift . lift $ mkDictionary (tcdValue tcd) args
                let match = foldr (\(className, index) dict -> subclassDictionaryValue dict className index)
                                  initDict
                                  (tcdPath tcd)
                return match
              Unsolved unsolved -> do
                -- Generate a fresh name for the unsolved constraint's new dictionary
                ident <- freshIdent ("dict" <> runProperName (disqualify (constraintClass unsolved)))
                let qident = Qualified Nothing ident
                -- Store the new dictionary in the InstanceContext so that we can solve this goal in
                -- future.
                newDicts <- lift . lift $ newDictionaries [] qident unsolved
                let newContext = mkContext newDicts
                modify (combineContexts newContext)
                -- Mark this constraint for generalization
                tell (mempty, [(ident, context, unsolved)])
                return (Var nullSourceSpan qident)
              Deferred ->
                -- Constraint was deferred, just return the dictionary unchanged,
                -- with no unsolved constraints. Hopefully, we can solve this later.
                return (TypeClassDictionary (Constraint className' tys'' conInfo) context hints)
          where
            -- | When checking functional dependencies, we need to use unification to make
            -- sure it is safe to use the selected instance. We will unify the solved type with
            -- the type in the instance head under the substition inferred from its instantiation.
            -- As an example, when solving MonadState t0 (State Int), we choose the
            -- MonadState s (State s) instance, and we unify t0 with Int, since the functional
            -- dependency from MonadState dictates that t0 should unify with s\[s -> Int], which is
            -- Int. This is fine, but in some cases, the substitution does not remove all TypeVars
            -- from the type, so we end up with a unification error. So, any type arguments which
            -- appear in the instance head, but not in the substitution need to be replaced with
            -- fresh type variables. This function extends a substitution with fresh type variables
            -- as necessary, based on the types in the instance head.
            withFreshTypes
              :: TypeClassDict
              -> Matching Type
              -> m (Matching Type)
            withFreshTypes TypeClassDictionaryInScope{..} subst = do
                let onType = everythingOnTypes S.union fromTypeVar
                    typeVarsInHead = foldMap onType tcdInstanceTypes
                                  <> foldMap (foldMap (foldMap onType . constraintArgs)) tcdDependencies
                    typeVarsInSubst = S.fromList (M.keys subst)
                    uninstantiatedTypeVars = typeVarsInHead S.\\ typeVarsInSubst
                newSubst <- traverse withFreshType (S.toList uninstantiatedTypeVars)
                return (subst <> M.fromList newSubst)
              where
                fromTypeVar (TypeVar v) = S.singleton v
                fromTypeVar _ = S.empty

                withFreshType s = do
                  t <- freshType
                  return (s, t)

            unique :: [Type] -> [(a, TypeClassDict)] -> m (EntailsResult a)
            unique tyArgs []
              | solverDeferErrors = return Deferred
              -- We need a special case for nullary type classes, since we want
              -- to generalize over Partial constraints.
              | solverShouldGeneralize && (null tyArgs || any canBeGeneralized tyArgs) = return (Unsolved (Constraint className' tyArgs conInfo))
              | otherwise = throwError . errorMessage $ NoInstanceFound (Constraint className' tyArgs conInfo)
            unique _      [(a, dict)] = return $ Solved a dict
            unique tyArgs tcds
              | pairwiseAny overlapping (map snd tcds) =
                  throwError . errorMessage $ OverlappingInstances className' tyArgs (tcds >>= (toList . namedInstanceIdentifier . tcdValue . snd))
              | otherwise = return $ uncurry Solved (minimumBy (compare `on` length . tcdPath . snd) tcds)

            canBeGeneralized :: Type -> Bool
            canBeGeneralized TUnknown{} = True
            canBeGeneralized (KindedType t _) = canBeGeneralized t
            canBeGeneralized _ = False

            -- |
            -- Check if two dictionaries are overlapping
            --
            -- Dictionaries which are subclass dictionaries cannot overlap, since otherwise the overlap would have
            -- been caught when constructing superclass dictionaries.
            overlapping :: TypeClassDict -> TypeClassDict -> Bool
            overlapping TypeClassDictionaryInScope{ tcdPath = _ : _ } _ = False
            overlapping _ TypeClassDictionaryInScope{ tcdPath = _ : _ } = False
            overlapping TypeClassDictionaryInScope{ tcdDependencies = Nothing } _ = False
            overlapping _ TypeClassDictionaryInScope{ tcdDependencies = Nothing } = False
            overlapping tcd1 tcd2 = tcdValue tcd1 /= tcdValue tcd2

            -- Create dictionaries for subgoals which still need to be solved by calling go recursively
            -- E.g. the goal (Show a, Show b) => Show (Either a b) can be satisfied if the current type
            -- unifies with Either a b, and we can satisfy the subgoals Show a and Show b recursively.
            solveSubgoals :: Matching Type -> Maybe [Constraint] -> WriterT (Any, [(Ident, InstanceContext, Constraint)]) (StateT InstanceContext m) (Maybe [Expr])
            solveSubgoals _ Nothing = return Nothing
            solveSubgoals subst (Just subgoals) =
              Just <$> traverse (go (work + 1) . mapConstraintArgs (map (replaceAllTypeVars (M.toList subst)))) subgoals

            -- We need subgoal dictionaries to appear in the term somewhere
            -- If there aren't any then the dictionary is just undefined
            useEmptyDict :: Maybe [Expr] -> Expr
            useEmptyDict args = foldl (App . Abs (VarBinder nullSourceSpan UnusedIdent)) valUndefined (fold args)

            -- Make a dictionary from subgoal dictionaries by applying the correct function
            mkDictionary :: Evidence -> Maybe [Expr] -> m Expr
            mkDictionary (NamedInstance n) args = return $ foldl App (Var nullSourceSpan n) (fold args)
            mkDictionary EmptyClassInstance args = return (useEmptyDict args)
            mkDictionary (WarnInstance msg) args = do
              tell . errorMessage $ UserDefinedWarning msg
              -- We cannot call the type class constructor here because Warn is declared in Prim.
              -- This means that it doesn't have a definition that we can import.
              -- So pass an empty placeholder (undefined) instead.
              return (useEmptyDict args)
            mkDictionary (IsSymbolInstance sym) _ =
              let fields = [ ("reflectSymbol", Abs (VarBinder nullSourceSpan UnusedIdent) (Literal nullSourceSpan (StringLiteral sym))) ] in
              return $ TypeClassDictionaryConstructorApp C.IsSymbol (Literal nullSourceSpan (ObjectLiteral fields))

        -- Turn a DictionaryValue into a Expr
        subclassDictionaryValue :: Expr -> Qualified (ProperName 'ClassName) -> Integer -> Expr
        subclassDictionaryValue dict className index =
          App (Accessor (mkString (superclassName className index)) dict) valUndefined

    solveCoercible :: Environment -> [Type] -> Maybe [TypeClassDict]
    solveCoercible env [a, b] = do
      let tySynMap = typeSynonyms env
          replaceTySyns = either (const Nothing) Just . replaceAllTypeSynonymsM tySynMap
      a' <- replaceTySyns a
      b' <- replaceTySyns b
      -- Solving terminates when the two arguments are the same. Since we
      -- currently don't support higher-rank arguments in instance heads, term
      -- equality is a sufficient notion of "the same".
      if a' == b'
        then pure [TypeClassDictionaryInScope [] 0 EmptyClassInstance [] C.Coercible [a, b] Nothing]
        else do
          -- When solving must reduce and recurse, it doesn't matter whether we
          -- reduce the first or second argument -- if the constraint is
          -- solvable, either path will yield the same outcome. Consequently we
          -- just try the first argument first and the second argument second.
          ws <- coercibleWanteds env a b <|> coercibleWanteds env b a
          pure [TypeClassDictionaryInScope [] 0 EmptyClassInstance [] C.Coercible [a, b] (Just ws)]
    solveCoercible _ _ = Nothing

    -- | Take two types, `a` and `b` representing a desired constraint
    -- `Coercible a b` and reduce them to a set of simpler wanted constraints
    -- whose satisfaction will yield the goal.
    coercibleWanteds :: Environment -> Type -> Type -> Maybe [Constraint]
    coercibleWanteds env a b = case a of
      TypeConstructor tyName -> do
        -- If the first argument is a plain newtype (e.g. `newtype T = T U` and
        -- the constraint `Coercible T b`), look up the type of its wrapped
        -- field and yield a new wanted constraint in terms of that type
        -- (`Coercible U b` in the example).
        (_, wrappedTy, _) <- lookupNewtypeConstructor env tyName
        pure [Constraint C.Coercible [wrappedTy, b] Nothing]
      t
        | Just (TypeConstructor aTyName, axs) <- splitTypeApp a
        , Just (TypeConstructor bTyName, bxs) <- splitTypeApp b
        , aTyName == bTyName
        , tyRoles <- inferRoles env aTyName -> do
            -- If both arguments are applications of the same type constructor
            -- (e.g. `data D a b = D a` in the constraint
            -- `Coercible (D a b) (D a' b')`), infer the roles of the type
            -- constructor's arguments and generate wanted constraints
            -- appropriately (e.g. here `a` is representational and `b` is
            -- phantom, yielding `Coercible a a'`).
            let k (_v, role) ax bx = case role of
                  Representational ->
                    [Constraint C.Coercible [ax, bx] Nothing]
                  Phantom ->
                    []
            pure $ concat $ zipWith3 k tyRoles axs bxs
        | Just (TypeConstructor tyName, xs) <- splitTypeApp t
        , Just (tvs, wrappedTy, _) <- lookupNewtypeConstructor env tyName -> do
            -- If the first argument is a newtype applied to some other types
            -- (e.g. `newtype T a = T a` in `Coercible (T X) b`), look up the
            -- type of its wrapped field and yield a new wanted constraint in
            -- terms of that type with the type arguments substituted in (e.g.
            -- `Coercible (T[X/a]) b = Coercible X b` in the example).
            let wrappedTySub = replaceAllTypeVars (zip tvs xs) wrappedTy
            pure [Constraint C.Coercible [wrappedTySub, b] Nothing]
      _ ->
        -- In all other cases we can't solve the constraint.
        Nothing

    solveIsSymbol :: [Type] -> Maybe [TypeClassDict]
    solveIsSymbol [TypeLevelString sym] = Just [TypeClassDictionaryInScope [] 0 (IsSymbolInstance sym) [] C.IsSymbol [TypeLevelString sym] Nothing]
    solveIsSymbol _ = Nothing

    solveSymbolCompare :: [Type] -> Maybe [TypeClassDict]
    solveSymbolCompare [arg0@(TypeLevelString lhs), arg1@(TypeLevelString rhs), _] =
      let ordering = case compare lhs rhs of
                  LT -> C.orderingLT
                  EQ -> C.orderingEQ
                  GT -> C.orderingGT
          args' = [arg0, arg1, TypeConstructor ordering]
      in Just [TypeClassDictionaryInScope [] 0 EmptyClassInstance [] C.SymbolCompare args' Nothing]
    solveSymbolCompare _ = Nothing

    solveSymbolAppend :: [Type] -> Maybe [TypeClassDict]
    solveSymbolAppend [arg0, arg1, arg2] = do
      (arg0', arg1', arg2') <- appendSymbols arg0 arg1 arg2
      let args' = [arg0', arg1', arg2']
      pure [TypeClassDictionaryInScope [] 0 EmptyClassInstance [] C.SymbolAppend args' Nothing]
    solveSymbolAppend _ = Nothing

    -- | Append type level symbols, or, run backwards, strip a prefix or suffix
    appendSymbols :: Type -> Type -> Type -> Maybe (Type, Type, Type)
    appendSymbols arg0@(TypeLevelString lhs) arg1@(TypeLevelString rhs) _ = Just (arg0, arg1, TypeLevelString (lhs <> rhs))
    appendSymbols arg0@(TypeLevelString lhs) _ arg2@(TypeLevelString out) = do
      lhs' <- decodeString lhs
      out' <- decodeString out
      rhs <- stripPrefix lhs' out'
      pure (arg0, TypeLevelString (mkString rhs), arg2)
    appendSymbols _ arg1@(TypeLevelString rhs) arg2@(TypeLevelString out) = do
      rhs' <- decodeString rhs
      out' <- decodeString out
      lhs <- stripSuffix rhs' out'
      pure (TypeLevelString (mkString lhs), arg1, arg2)
    appendSymbols _ _ _ = Nothing

    solveSymbolCons :: [Type] -> Maybe [TypeClassDict]
    solveSymbolCons [arg0, arg1, arg2] = do
      (arg0', arg1', arg2') <- consSymbol arg0 arg1 arg2
      let args' = [arg0', arg1', arg2']
      pure [TypeClassDictionaryInScope [] 0 EmptyClassInstance [] C.SymbolCons args' Nothing]
    solveSymbolCons _ = Nothing

    consSymbol :: Type -> Type -> Type -> Maybe (Type, Type, Type)
    consSymbol _ _ arg@(TypeLevelString s) = do
      (h, t) <- T.uncons =<< decodeString s
      pure (mkTLString (T.singleton h), mkTLString t, arg)
      where mkTLString = TypeLevelString . mkString
    consSymbol arg1@(TypeLevelString h) arg2@(TypeLevelString t) _ = do
      h' <- decodeString h
      t' <- decodeString t
      guard (T.length h' == 1)
      pure (arg1, arg2, TypeLevelString (mkString $ h' <> t'))
    consSymbol _ _ _ = Nothing

    solveUnion :: [Type] -> Maybe [TypeClassDict]
    solveUnion [l, r, u] = do
      (lOut, rOut, uOut, cst) <- unionRows l r u
      pure [ TypeClassDictionaryInScope [] 0 EmptyClassInstance [] C.RowUnion [lOut, rOut, uOut] cst ]
    solveUnion _ = Nothing

    -- | Left biased union of two row types
    unionRows :: Type -> Type -> Type -> Maybe (Type, Type, Type, Maybe [Constraint])
    unionRows l r _ =
        guard canMakeProgress $> (l, r, rowFromList out, cons)
      where
        (fixed, rest) = rowToList l

        rowVar = TypeVar "r"

        (canMakeProgress, out, cons) =
          case rest of
            -- If the left hand side is a closed row, then we can merge
            -- its labels into the right hand side.
            REmpty -> (True, (fixed, r), Nothing)
            -- If the left hand side is not definitely closed, then the only way we
            -- can safely make progress is to move any known labels from the left
            -- input into the output, and add a constraint for any remaining labels.
            -- Otherwise, the left hand tail might contain the same labels as on
            -- the right hand side, and we can't be certain we won't reorder the
            -- types for such labels.
            _ -> (not (null fixed), (fixed, rowVar), Just [ Constraint C.RowUnion [rest, r, rowVar] Nothing ])

    solveRowCons :: [Type] -> Maybe [TypeClassDict]
    solveRowCons [TypeLevelString sym, ty, r, _] =
      Just [ TypeClassDictionaryInScope [] 0 EmptyClassInstance [] C.RowCons [TypeLevelString sym, ty, r, RCons (Label sym) ty r] Nothing ]
    solveRowCons _ = Nothing

    solveRowToList :: [Type] -> Maybe [TypeClassDict]
    solveRowToList [r, _] = do
      entries <- rowToRowList r
      pure [ TypeClassDictionaryInScope [] 0 EmptyClassInstance [] C.RowToList [r, entries] Nothing ]
    solveRowToList _ = Nothing

    -- | Convert a closed row to a sorted list of entries
    rowToRowList :: Type -> Maybe Type
    rowToRowList r =
        guard (REmpty == rest) $>
        foldr rowListCons (TypeConstructor C.RowListNil) fixed
      where
        (fixed, rest) = rowToSortedList r
        rowListCons (lbl, ty) tl = foldl TypeApp (TypeConstructor C.RowListCons)
                                     [ TypeLevelString (runLabel lbl)
                                     , ty
                                     , tl ]

    solveNub :: [Type] -> Maybe [TypeClassDict]
    solveNub [r, _] = do
      r' <- nubRows r
      pure [ TypeClassDictionaryInScope [] 0 EmptyClassInstance [] C.RowNub [r, r'] Nothing ]
    solveNub _ = Nothing

    nubRows :: Type -> Maybe Type
    nubRows r =
        guard (REmpty == rest) $>
        rowFromList (nubBy ((==) `on` fst) fixed, rest)
      where
        (fixed, rest) = rowToSortedList r

    solveLacks :: [Type] -> Maybe [TypeClassDict]
    solveLacks [TypeLevelString sym, r] = do
      (r', cst) <- rowLacks sym r
      pure [ TypeClassDictionaryInScope [] 0 EmptyClassInstance [] C.RowLacks [TypeLevelString sym, r'] cst ]
    solveLacks _ = Nothing

    rowLacks :: PSString -> Type -> Maybe (Type, Maybe [Constraint])
    rowLacks sym r =
        guard (lacksSym && canMakeProgress) $> (r, cst)
      where
        (fixed, rest) = rowToList r

        lacksSym =
          not $ sym `elem` (runLabel . fst <$> fixed)

        (canMakeProgress, cst) = case rest of
            REmpty -> (True, Nothing)
            _ -> (not (null fixed), Just [ Constraint C.RowLacks [TypeLevelString sym, rest] Nothing ])

-- Check if an instance matches our list of types, allowing for types
-- to be solved via functional dependencies. If the types match, we return a
-- substitution which makes them match. If not, we return 'Nothing'.
matches :: [FunctionalDependency] -> TypeClassDict -> [Type] -> Matched (Matching [Type])
matches deps TypeClassDictionaryInScope{..} tys =
    -- First, find those types which match exactly
    let matched = zipWith typeHeadsAreEqual tys tcdInstanceTypes in
    -- Now, use any functional dependencies to infer any remaining types
    if not (covers matched)
       then if any ((==) Apart . fst) matched then Apart else Unknown
       else -- Verify that any repeated type variables are unifiable
            let determinedSet = foldMap (S.fromList . fdDetermined) deps
                solved = map snd . filter ((`S.notMember` determinedSet) . fst) $ zipWith (\(_, ts) i -> (i, ts)) matched [0..]
            in verifySubstitution (M.unionsWith (++) solved)
  where
    -- | Find the closure of a set of functional dependencies.
    covers :: [(Matched (), subst)] -> Bool
    covers ms = finalSet == S.fromList [0..length ms - 1]
      where
        initialSet :: S.Set Int
        initialSet = S.fromList . map snd . filter ((==) (Match ()) . fst . fst) $ zip ms [0..]

        finalSet :: S.Set Int
        finalSet = untilFixedPoint applyAll initialSet

        untilFixedPoint :: Eq a => (a -> a) -> a -> a
        untilFixedPoint f = go
          where
          go a | a' == a = a'
               | otherwise = go a'
            where a' = f a

        applyAll :: S.Set Int -> S.Set Int
        applyAll s = foldr applyDependency s deps

        applyDependency :: FunctionalDependency -> S.Set Int -> S.Set Int
        applyDependency FunctionalDependency{..} xs
          | S.fromList fdDeterminers `S.isSubsetOf` xs = xs <> S.fromList fdDetermined
          | otherwise = xs

    --
    -- Check whether the type heads of two types are equal (for the purposes of type class dictionary lookup),
    -- and return a substitution from type variables to types which makes the type heads unify.
    --
    typeHeadsAreEqual :: Type -> Type -> (Matched (), Matching [Type])
    typeHeadsAreEqual (KindedType t1 _)    t2                              = typeHeadsAreEqual t1 t2
    typeHeadsAreEqual t1                   (KindedType t2 _)               = typeHeadsAreEqual t1 t2
    typeHeadsAreEqual (TUnknown u1)        (TUnknown u2)        | u1 == u2 = (Match (), M.empty)
    typeHeadsAreEqual (Skolem _ s1 _ _)    (Skolem _ s2 _ _)    | s1 == s2 = (Match (), M.empty)
    typeHeadsAreEqual t                    (TypeVar v)                     = (Match (), M.singleton v [t])
    typeHeadsAreEqual (TypeConstructor c1) (TypeConstructor c2) | c1 == c2 = (Match (), M.empty)
    typeHeadsAreEqual (TypeLevelString s1) (TypeLevelString s2) | s1 == s2 = (Match (), M.empty)
    typeHeadsAreEqual (TypeApp h1 t1)      (TypeApp h2 t2)                 =
      both (typeHeadsAreEqual h1 h2) (typeHeadsAreEqual t1 t2)
    typeHeadsAreEqual REmpty REmpty = (Match (), M.empty)
    typeHeadsAreEqual r1@RCons{} r2@RCons{} =
        foldr both (uncurry go rest) common
      where
        (common, rest) = alignRowsWith typeHeadsAreEqual r1 r2

        go :: ([(Label, Type)], Type) -> ([(Label, Type)], Type) -> (Matched (), Matching [Type])
        go (l,  KindedType t1 _)  (r,  t2)                            = go (l, t1) (r, t2)
        go (l,  t1)               (r,  KindedType t2 _)               = go (l, t1) (r, t2)
        go ([], REmpty)           ([], REmpty)                        = (Match (), M.empty)
        go ([], TUnknown u1)      ([], TUnknown u2)      | u1 == u2   = (Match (), M.empty)
        go ([], TypeVar v1)       ([], TypeVar v2)       | v1 == v2   = (Match (), M.empty)
        go ([], Skolem _ sk1 _ _) ([], Skolem _ sk2 _ _) | sk1 == sk2 = (Match (), M.empty)
        go ([], TUnknown _)       _                                   = (Unknown, M.empty)
        go (sd, r)                ([], TypeVar v)                     = (Match (), M.singleton v [rowFromList (sd, r)])
        go _ _                                                        = (Apart, M.empty)
    typeHeadsAreEqual (TUnknown _) _ = (Unknown, M.empty)
    typeHeadsAreEqual _ _ = (Apart, M.empty)


    both :: (Matched (), Matching [Type]) -> (Matched (), Matching [Type]) -> (Matched (), Matching [Type])
    both (b1, m1) (b2, m2) = (b1 <> b2, M.unionWith (++) m1 m2)

    -- Ensure that a substitution is valid
    verifySubstitution :: Matching [Type] -> Matched (Matching [Type])
    verifySubstitution mts = foldMap meet mts $> mts where
      meet = pairwiseAll typesAreEqual

      -- Note that unknowns are only allowed to unify if they came from a type
      -- which was _not_ solved, i.e. one which was inferred by a functional
      -- dependency.
      typesAreEqual :: Type -> Type -> Matched ()
      typesAreEqual (KindedType t1 _)    t2                   = typesAreEqual t1 t2
      typesAreEqual t1                   (KindedType t2 _)    = typesAreEqual t1 t2
      typesAreEqual (TUnknown u1)        (TUnknown u2)        | u1 == u2 = Match ()
      typesAreEqual (Skolem _ s1 _ _)    (Skolem _ s2 _ _)    | s1 == s2 = Match ()
      typesAreEqual (Skolem _ _ _ _)     _                    = Unknown
      typesAreEqual _                    (Skolem _ _ _ _)     = Unknown
      typesAreEqual (TypeVar v1)         (TypeVar v2)         | v1 == v2 = Match ()
      typesAreEqual (TypeLevelString s1) (TypeLevelString s2) | s1 == s2 = Match ()
      typesAreEqual (TypeConstructor c1) (TypeConstructor c2) | c1 == c2 = Match ()
      typesAreEqual (TypeApp h1 t1)      (TypeApp h2 t2)      = typesAreEqual h1 h2 <> typesAreEqual t1 t2
      typesAreEqual REmpty               REmpty               = Match ()
      typesAreEqual r1                   r2                   | isRCons r1 || isRCons r2 =
          let (common, rest) = alignRowsWith typesAreEqual r1 r2
          in fold common <> uncurry go rest
        where
          go :: ([(Label, Type)], Type) -> ([(Label, Type)], Type) -> Matched ()
          go (l, KindedType t1 _)  (r, t2)                          = go (l, t1) (r, t2)
          go (l, t1)               (r, KindedType t2 _)             = go (l, t1) (r, t2)
          go ([], TUnknown u1)     ([], TUnknown u2)     | u1 == u2 = Match ()
          go ([], Skolem _ s1 _ _) ([], Skolem _ s2 _ _) | s1 == s2 = Match ()
          go ([], Skolem _ _ _ _)  _                                = Unknown
          go _                     ([], Skolem _ _ _ _)             = Unknown
          go ([], REmpty)          ([], REmpty)                     = Match ()
          go ([], TypeVar v1)      ([], TypeVar v2)      | v1 == v2 = Match ()
          go _  _                                                   = Apart
      typesAreEqual _                    _                    = Apart

      isRCons :: Type -> Bool
      isRCons RCons{}    = True
      isRCons _          = False

-- | Add a dictionary for the constraint to the scope, and dictionaries
-- for all implied superclass instances.
newDictionaries
  :: MonadState CheckState m
  => [(Qualified (ProperName 'ClassName), Integer)]
  -> Qualified Ident
  -> Constraint
  -> m [NamedDict]
newDictionaries path name (Constraint className instanceTy _) = do
    tcs <- gets (typeClasses . checkEnv)
    let TypeClassData{..} = fromMaybe (internalError "newDictionaries: type class lookup failed") $ M.lookup className tcs
    supDicts <- join <$> zipWithM (\(Constraint supName supArgs _) index ->
                                      newDictionaries ((supName, index) : path)
                                                      name
                                                      (Constraint supName (instantiateSuperclass (map fst typeClassArguments) supArgs instanceTy) Nothing)
                                  ) typeClassSuperclasses [0..]
    return (TypeClassDictionaryInScope [] 0 name path className instanceTy Nothing : supDicts)
  where
    instantiateSuperclass :: [Text] -> [Type] -> [Type] -> [Type]
    instantiateSuperclass args supArgs tys = map (replaceAllTypeVars (zip args tys)) supArgs

mkContext :: [NamedDict] -> InstanceContext
mkContext = foldr combineContexts M.empty . map fromDict where
  fromDict d = M.singleton Nothing (M.singleton (tcdClassName d) (M.singleton (tcdValue d) d))

-- | Check all pairs of values in a list match a predicate
pairwiseAll :: Monoid m => (a -> a -> m) -> [a] -> m
pairwiseAll _ [] = mempty
pairwiseAll _ [_] = mempty
pairwiseAll p (x : xs) = foldMap (p x) xs <> pairwiseAll p xs

-- | Check any pair of values in a list match a predicate
pairwiseAny :: (a -> a -> Bool) -> [a] -> Bool
pairwiseAny _ [] = False
pairwiseAny _ [_] = False
pairwiseAny p (x : xs) = any (p x) xs || pairwiseAny p xs

pairwiseM :: Applicative m => (a -> a -> m ()) -> [a] -> m ()
pairwiseM _ [] = pure ()
pairwiseM _ [_] = pure ()
pairwiseM p (x : xs) = traverse (p x) xs *> pairwiseM p xs
