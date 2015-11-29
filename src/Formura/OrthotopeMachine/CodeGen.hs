{-# LANGUAGE DataKinds, DeriveFunctor, DeriveFoldable,
DeriveTraversable, FlexibleContexts, FlexibleInstances, PatternSynonyms,
TemplateHaskell, TypeOperators, ViewPatterns #-}
module Formura.OrthotopeMachine.CodeGen where

import           Control.Applicative
import           Control.Lens hiding (op, at)
import           Control.Monad
import           Control.Monad.Reader
import qualified Data.IntMap as G
import qualified Data.Map as M
import qualified Data.Set as S
import           Data.Ratio
import           Text.Trifecta (failed, raiseErr)

import           Formura.Language.Combinator
import qualified Formura.Annotation as A
import           Formura.Compiler
import           Formura.Syntax
import           Formura.Vec
import           Formura.OrthotopeMachine.Instruction

type NodeTypeF = Sum '[ GridTypeF, ElemTypeF ]
type NodeType  = Fix NodeTypeF


type NodeID  = G.Key
data Node = Node {_nodeInst :: OMInstF NodeID, _nodeType :: NodeType, _nodeAnnot :: A.Annotation}
makeLenses ''Node
instance A.Annotated Node where
  annotation = nodeAnnot

type Graph = G.IntMap Node

data NodeValueF x = NodeValueF NodeID NodeType
                 deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

pattern NodeValue n t <- ((^? match) -> Just (NodeValueF n t)) where NodeValue n t = match # NodeValueF n t
pattern n :. t <- ((^? match) -> Just (NodeValueF n t)) where n :. t = match # NodeValueF n t


data FunValueF x = FunValueF LExpr RXExpr
                 deriving (Eq, Ord, Show, Functor, Foldable, Traversable)
pattern FunValue l r <- ((^? match) -> Just (FunValueF l r)) where FunValue l r = match # FunValueF l r


-- | RExpr extended with
type RXExprF = Sum '[ LetF, LambdaF, ApplyF, GridF, TupleF, OperatorF, IdentF, FunValueF, NodeValueF, ImmF ]
type RXExpr  = Fix RXExprF
type ValueExprF = Sum '[TupleF, FunValueF, NodeValueF, ImmF]
type ValueExpr = Fix ValueExprF
type ValueLexExprF = Sum '[TupleF, FunValueF, NodeValueF, IdentF, ImmF]
type ValueLexExpr = Fix ValueLexExprF


type Binding = M.Map IdentName ValueExpr
type LexBinding = M.Map IdentName ValueLexExpr

class HasBinding s where
  binding :: Lens' s Binding

instance HasBinding Binding where
  binding = simple

data CodeGenState = CodeGenState
  { _codegenSyntacticState :: CompilerSyntacticState
  , _theGraph :: Graph
  }
makeClassy ''CodeGenState

instance HasCompilerSyntacticState CodeGenState where
  compilerSyntacticState = codegenSyntacticState


-- | the code generator monad.
type GenM = CompilerMonad Binding () CodeGenState
type LexGenM = CompilerMonad LexBinding () CodeGenState


class Generatable f where
  gen :: f (GenM ValueExpr) -> GenM ValueExpr

freeNodeID :: GenM NodeID
freeNodeID = do
  g <- use theGraph
  return $ G.size g

insert :: OMInstF NodeID -> NodeType -> GenM ValueExpr
insert inst typ = do
  n0 <- freeNodeID
  foc <- use compilerFocus
  let a = case foc of
        Just meta -> A.singleton meta
        Nothing   -> A.empty
  theGraph %= G.insert n0 (Node inst typ a)
  return $ NodeValue n0 typ


instance Generatable ImmF where
  gen (Imm r) = do
    insert (Imm r) (ElemType "Rational")

instance Generatable OperatorF where
  gen (Uniop op gA)       = do a <- gA                  ; goUniop op a
  gen (Binop op gA gB)    = do a <- gA; b <- gB         ; goBinop op a b
  gen (Triop op gA gB gC) = do a <- gA; b <- gB; c <- gC; goTriop op a b c

goUniop :: IdentName -> ValueExpr -> GenM ValueExpr
goUniop op (av :. at) = insert (Uniop op av) at
goUniop _ _  = raiseErr $ failed $ "unimplemented path in unary operator"

goBinop :: IdentName -> ValueExpr -> ValueExpr -> GenM ValueExpr
goBinop op (av :. at) (bv :. bt)
  | at == bt = insert (Binop op av bv) at
  | otherwise = raiseErr $ failed "type of the both hand sides does not match"
goBinop _ _ _  = raiseErr $ failed $ "unimplemented path in binary operator"

goTriop :: IdentName -> ValueExpr -> ValueExpr -> ValueExpr -> GenM ValueExpr
goTriop op (av :. at) (bv :. bt) (cv :. ct)
  | op == "ite" && at == ElemType "bool" && bt == ct = insert (Triop op av bv cv) bt
goTriop _ _ _ _ = raiseErr $ failed $ "unimplemented path in trinary operator"

instance Generatable IdentF where
  gen (Ident n) = insert (Load n) (ElemType "Real")

instance Generatable TupleF where
  gen (Tuple xsGen) = do
    xs <- sequence xsGen
    return $ Tuple xs

instance Generatable GridF where
  gen (Grid npks gen0) = do
    vt0@(val0 :. typ0) <- gen0
    case typ0 of
      ElemType _   -> return vt0
      GridType offs0 etyp0 -> do
        let
            patK   = fmap (^. _2) (npks :: Vec NPlusK)
            newPos = offs0 - patK
            intOff = fmap floor newPos
            newOff = liftA2 (\r n -> r - fromIntegral n) newPos intOff
            typ1 = GridType newOff etyp0
        if intOff == 0
                then return (val0 :. typ1)
                else insert (Shift intOff val0) typ1

  gen _ = raiseErr $ failed "unexpected happened in gen of grid"

instance Generatable ApplyF where
  gen (Apply fgen agen) = do
    f0 <- fgen
    a0 <- agen
    goApply f0 a0

goApply :: ValueExpr -> ValueExpr -> GenM ValueExpr
goApply (Tuple xs) (Imm r) = do
  when (denominator r /= 1) $ raiseErr $ failed "non-integer indexing in tuple access"
  let n = fromInteger $  numerator r
      l = length xs
  when (n < 0 || n >= l) $ raiseErr $ failed "tuple access out of bounds"
  return $ xs!!n
goApply (Tuple xs) _ = raiseErr $ failed "tuple applied to non-constant integer"
goApply  _ _ = raiseErr $ failed "unexpected combination of application"

instance Generatable LambdaF where
  -- Expand all but bound variables, in order to implement lexical scope
  gen (Lambda l r) = do
    let conv :: Binding -> CodeGenState -> (LexBinding, CodeGenState)
        conv b s = (M.insert (nameOfLhs l) (Ident $ nameOfLhs l) $ M.map subFix b, s)
    r' <- withCompiler conv $ resolveLex $ subFix r
    return $ FunValue l r'

resolveLex :: RXExpr -> LexGenM RXExpr
resolveLex r = compilerMFold resolveLexAlg r

resolveLexAlg :: RXExprF RXExpr -> LexGenM RXExpr
resolveLexAlg (Ident n) = do
  b <- ask
  case M.lookup n b of
    Nothing -> raiseErr $ failed $ "undefined variable: " ++ n
    Just x  -> return $ subFix x
resolveLexAlg (Lambda l r) = do
  r' <- local (M.insert (nameOfLhs l) (Ident $ nameOfLhs l)) $ resolveLex $ subFix r
  return $ FunValue l r'
resolveLexAlg (FunValue l r) = do
  r' <- local (M.insert (nameOfLhs l) (Ident $ nameOfLhs l)) $ resolveLex r
  return $ FunValue l r'
resolveLexAlg fx = mTransAlg fx

instance Generatable LetF where
  gen (Let b genX) = withBindings b genX

nameOfLhs :: LExpr -> IdentName
nameOfLhs (Ident n) = n
nameOfLhs (Grid _ x) = nameOfLhs x
nameOfLhs (Vector _ x) = nameOfLhs x
nameOfLhs _ = error "unsupported form in type decl"


withBindings :: BindingF (GenM ValueExpr) -> GenM ValueExpr -> GenM ValueExpr
withBindings b1 genX = do
  b0 <- view binding
  let
      BindingF stmts0 = b1
      typeDecls0 :: [(LExpr, TypeExpr)]
      typeDecls0 = concat $ flip map stmts0 $ \x -> case x of
        TypeDeclF t l -> [(l, t)]
        _             -> []

      substs0 :: [(LExpr, GenM ValueExpr)]
      substs0 = concat $ flip map stmts0 $ \x -> case x of
        SubstF l r -> [(l, r)]
        _             -> []

      typeDict :: M.Map IdentName TypeExpr
      typeDict = M.fromList [(nameOfLhs l, t) | (l,t)<- typeDecls0]

  let
    -- Let bindings enter scope one by one, not simultaneously
    graduallyBind :: [(LExpr, GenM ValueExpr)] -> GenM [(IdentName, ValueExpr)]
    graduallyBind [] = return []
    graduallyBind ((l,genV):lgvs) = do
      v <- genV
      -- TODO: LHS grid pattern must be taken care of.
      -- TODO: Typecheck must take place.
      local (binding %~ M.insert (nameOfLhs l) v) $ graduallyBind lgvs
  substs1 <- graduallyBind substs0


  --  M.union prefers left-hand-side when duplicate keys are encountered
  local (binding %~ M.union (M.fromList substs1)) genX

instance Generatable (Sum '[]) where
  gen _ =  raiseErr $ failed "impossible happened: gen of Void"

instance (Generatable f, Generatable (Sum fs)) => Generatable (Sum (f ': fs)) where
  gen =  gen +:: gen

genRhs :: RExpr -> GenM ValueExpr
genRhs r = foldout gen r
