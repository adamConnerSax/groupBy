{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE AllowAmbiguousTypes   #-}
{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE DeriveFoldable        #-}
{-# LANGUAGE DeriveTraversable     #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE OverloadedLists       #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -fwarn-incomplete-patterns #-}
{-|
Module      : Control.MapReduce.Engines.GroupBy
Description : map-reduce-folds builders
Copyright   : (c) Adam Conner-Sax 2019
License     : BSD-3-Clause
Maintainer  : adam_conner_sax@yahoo.com
Stability   : experimental

use recursion schemes to build group-by functions, that is, functions of the form,
(Ord k, Applicative f, Functor f) => f (k,c) -> f (k,f c)

This is a warm-up for building the entire engine via recursion-schemes
-}
module Control.MapReduce.Engines.GroupBy
  (
    -- * utilities
    unDList
    -- * List grouping
  , groupByTVL
  , groupByHR
  , groupByNaiveInsert
  , groupByNaiveBubble
  , groupByNaiveInsert'
  , groupByNaiveBubble'
  , groupByNaiveInsertY
  , groupByNaiveBubbleY
  , groupByInsert
  , groupByBubble
  , groupByInsert'
  , groupByBubble'
  , groupByTree1
  , groupByTree2
  , groupByNaiveInsert2
  , listViaHylomorphism
  , listViaMetamorphism
  , groupBy
  , groupByOrderedKey
  , groupByHashableKey
  )
where

import           Data.Bool                      ( bool )
import qualified Data.DList                    as DL
import           Data.DList                     ( DList )
import           Data.Function                  ( on )
import qualified Data.Map.Strict               as MS
import qualified Data.Map.Lazy                 as ML
import qualified Data.HashMap.Strict           as HMS
import           Data.Maybe                     ( fromMaybe )
import qualified Data.List                     as L
import           Data.Functor.Foldable         as RS
import           Data.Functor.Foldable          ( Fix(..)
                                                , unfix
                                                , ListF(..)
                                                )
import           Data.Functor.Foldable.TH      as RS
import qualified Data.Foldable                 as F
import           Data.Hashable                  ( Hashable )
import           Control.Arrow                  ( second
                                                , (&&&)
                                                , (|||)
                                                )
import qualified Control.Foldl                 as FL
import           GHC.Exts                       ( IsList
                                                , Item
                                                , build
                                                )
import qualified Yaya.Fold                     as Y
import           Yaya.Pattern                   ( XNor(..) )
{-
We always (?) need to begin with fmap promote so that the elements are combinable.
It might be faster to do this in-line but it seems to complicate things...
-}
promote :: (IsList l, Item l ~ v) => (k, v) -> (k, l)
promote (k, v) = (k, [v])
--{-# INLINABLE promote #-}

-- Fix a fully polymorphic version to our types
specify
  :: (Ord k, Monoid b)
  => (((k, b) -> (k, b) -> Ordering) -> ((k, b) -> (k, b) -> (k, b)) -> t)
  -> t
specify f = g where g = f (compare `on` fst) (\(k, x) (_, y) -> (k, x <> y))
--{-# INLINABLE specify #-}

-- as a last step on any of these functions it will use DLists instead of lists
unDList :: [(k, DList v)] -> [(k, [v])]
unDList = fmap (second DL.toList)
{-# INLINABLE unDList #-}


{-
We set up some basic machinery to use all of this with Yaya as well as recursion schemes.
-}
{-
instance Y.Projectable [a] (ListF a) where
  project [] = Nil
  project (x:xs) = Cons x xs

instance Y.Steppable [a] (ListF a) where
  embed Nil = []
  embed (Cons x xs) = x : xs
-}

instance Y.Recursive [a] (XNor a) where
  cata f = c where c = f . fmap c . Y.project
{-  cata alg [] = alg Neither
  cata alg (x : xs) = alg $ Both x (Y.cata alg xs) -}
  {-# INLINABLE cata #-}

instance Y.Corecursive [a] (XNor a) where
  ana coalg = a where a = Y.embed . fmap a . coalg
{-  ana coalg = (\case
                  Neither -> []
                  Both x xs -> x : Y.ana coalg xs
              ) . coalg -}
  {-# INLINABLE ana #-}

{-
Following <https://www.cs.ox.ac.uk/ralf.hinze/publications/Sorting.pdf>,
we'll start with a Naive sort of a list

we want [x] -> [x] (where the rhs has equal elements grouped via some (x -> x -> x), e.g. (<>)
or (Fix (ListF x) -> List x)
recall:  fold :: (f a -> a) -> (Fix f -> a)
in this case f ~ (ListF x) and a ~ [x] 
we need an algebra, (f a -> a), that is  (ListF x [x] -> [x])
or (ListF x [x] -> Fix (ListF x))
This algebra is also an unfold.
recall: unfold (b -> g b) -> (b -> Fix g)
in this case, b ~ ListF x [x] and g ~ ListF x
so the required co-algebra has the form (ListF x [x] -> ListF x (ListF x [x]))
-}
coalg1
  :: (a -> a -> Ordering)
  -> (a -> a -> a)
  -> ListF a [a]
  -> ListF a (ListF a [a])
coalg1 _   _ Nil               = Nil
coalg1 _   _ (Cons a []      ) = Cons a Nil
coalg1 cmp f (Cons a (a' : l)) = case cmp a a' of
  LT -> Cons a (Cons a' l)
  GT -> Cons a' (Cons a l)
  EQ -> Cons (f a a') (RS.project l)
--{-# INLINABLE coalg1 #-}

groupByNaiveInsert
  :: (IsList l, Item l ~ v, Monoid l, Ord k) => [(k, v)] -> [(k, l)]
groupByNaiveInsert = RS.fold (RS.unfold (specify coalg1)) . fmap promote
{-# INLINABLE groupByNaiveInsert #-}

{-
now we do this in the other order
we want [x] -> [x] (wherer the rhs is grouped according to some (x -> x -> x), e.g., (<>)
or ([x] -> Fix (ListF x)), which is an unfold, with coalgebra ([x] -> ListF x [x])
but this co-algebra is also of the form (Fix (ListF x) -> ListF x [x])
which is a fold with algebra (ListF x (ListF x [x]) -> ListF x [x])
-}
alg1
  :: (a -> a -> Ordering)
  -> (a -> a -> a)
  -> ListF a (ListF a [a])
  -> ListF a [a]
alg1 _   _ Nil                   = Nil
alg1 _   _ (Cons a Nil         ) = Cons a []
alg1 cmp f (Cons a (Cons a' as)) = case cmp a a' of
  LT -> Cons a (a' : as)
  GT -> Cons a' (a : as)
  EQ -> Cons (f a a') as
--{-# INLINABLE alg1 #-}

groupByNaiveBubble
  :: (IsList l, Item l ~ v, Monoid l, Ord k) => [(k, v)] -> [(k, l)]
groupByNaiveBubble = RS.unfold (RS.fold (specify alg1)) . fmap promote
{-# INLINABLE groupByNaiveBubble #-}

{-
Some notes at this point:
1. Naive bubble is much faster than naive insert.  I think because we do the combining sooner?
2. coalg1 and and alg1 are almost the same. Let's explore this for a bit, ignoring the cmp and combine arguments
We look at the type of coalg after unrolling one level of Fix, i.e.,
since [a] = Fix (ListF a), we have `unfix [a] :: ListF a (Fix (ListF a)) ~ ListF a [a]
coalg1 :: ListF a [a] -> ListF a (ListF a [a]), so (coalg1 . fmap Fix) :: ListF a (ListF a [a]) -> ListF a (ListF a [a])
alg1 ::  ListF a (ListF a [a]) -> ListF a [a], so (fmap unfix . alg1) ::  ListF a (ListF a [a]) -> ListF a (ListF a [a])
which suggests that there is some function, following the paper, we'll call it "swap" such that
coalg1 . fmap Fix = swap = fmap unfix . alg1, or coalg1 = swap . fmap unfix and alg1 = fmap Fix . swap
Because the lhs and rhs lists look the same, this looks like an identity.  But the rhs is sorted, while the lhs is not.
-}
swap
  :: (a -> a -> Ordering)
  -> (a -> a -> a)
  -> ListF a (ListF a [a])
  -> ListF a (ListF a [a])
swap _   _ Nil                   = Nil
swap _   _ (Cons a Nil         ) = Cons a Nil
swap cmp f (Cons a (Cons a' as)) = case cmp a a' of
  LT -> Cons a (Cons a' as) -- already in order
  GT -> Cons a' (Cons a as) -- need to swap
  EQ -> Cons (f a a') (RS.project as)
--{-# INLINABLE swap #-}

groupByNaiveInsert'
  :: (IsList l, Item l ~ v, Monoid l, Ord k) => [(k, v)] -> [(k, l)]
groupByNaiveInsert' =
  RS.fold (RS.unfold (specify swap . fmap RS.project)) . fmap promote
{-# INLINABLE groupByNaiveInsert' #-}

groupByNaiveBubble'
  :: (IsList l, Item l ~ v, Monoid l, Ord k) => [(k, v)] -> [(k, l)]
groupByNaiveBubble' =
  RS.unfold (RS.fold (fmap RS.embed . specify swap)) . fmap promote
{-# INLINABLE groupByNaiveBubble' #-}


swapYaya
  :: (a -> a -> Ordering)
  -> (a -> a -> a)
  -> XNor a (XNor a [a])
  -> XNor a (XNor a [a])
swapYaya _   _ Neither               = Neither
swapYaya _   _ (Both a Neither     ) = Both a Neither
swapYaya cmp f (Both a (Both a' as)) = case cmp a a' of
  LT -> Both a (Both a' as) -- already in order
  GT -> Both a' (Both a as) -- need to swap
  EQ -> Both (f a a') (Y.project as)

groupByNaiveInsertY
  :: (IsList l, Item l ~ v, Monoid l, Ord k) => [(k, v)] -> [(k, l)]
groupByNaiveInsertY =
  Y.cata (Y.ana (specify swapYaya . fmap Y.project)) . fmap promote
{-# INLINABLE groupByNaiveInsertY #-}

groupByNaiveBubbleY
  :: (IsList l, Item l ~ v, Monoid l, Ord k) => [(k, v)] -> [(k, l)]
groupByNaiveBubbleY =
  Y.ana (Y.cata (fmap Y.embed . specify swapYaya)) . fmap promote
{-# INLINABLE groupByNaiveBubbleY #-}

{-
As pointed out in Hinze, this is inefficient because the rhs list is already sorted.
So in the non-swap cases, we need not do any more work.
The simplest way to manage that is to use an apomorphism (an unfold) in order to stop the recursion in those cases.
The types:
fold (apo coalg) :: [a] -> [a] ~ Fix (ListF a) -> [a]
apo coalg :: (ListF a [a] -> [a]) ~ ListF a [a] -> Fix (ListF a)
coalg :: (ListF a [a] -> ListF a (Either [a] (ListF a [a]))
NB: The "Left" constructor of Either stops the recursion in that branch where the "Right" constructor continues
-}
apoCoalg
  :: (a -> a -> Ordering)
  -> (a -> a -> a)
  -> ListF a [a]
  -> ListF a (Either [a] (ListF a [a]))
apoCoalg _   _ Nil                = Nil
apoCoalg _   _ (Cons a []       ) = Cons a (Left []) -- could also be 'Cons a (Right Nil)'
apoCoalg cmp f (Cons a (a' : as)) = case cmp a a' of
  LT -> Cons a (Left (a' : as)) -- stop recursing here
  GT -> Cons a' (Right (Cons a as)) -- keep recursing, a may not be in the right place yet!
  EQ -> Cons (f a a') (Left as) -- ??
--{-# INLINABLE apoCoalg #-}

groupByInsert :: (IsList l, Item l ~ v, Monoid l, Ord k) => [(k, v)] -> [(k, l)]
groupByInsert = RS.fold (RS.apo (specify apoCoalg)) . fmap promote
{-# INLINABLE groupByInsert #-}

{-
Now we go the other way and then get both versions as before.
unfold (para alg) :: [a] -> [a] ~ [a] -> Fix (ListF a)
para alg :: [a] -> ListF a [a] ~ Fix (ListF a) -> ListF a [a]
alg :: ListF a ([a],ListF a [a]) -> ListF a [a]
-}
paraAlg
  :: (a -> a -> Ordering)
  -> (a -> a -> a)
  -> ListF a ([a], ListF a [a])
  -> ListF a [a]
paraAlg = go
 where
  go _   _ Nil                       = Nil
  go _   _ (Cons a (_, Nil        )) = Cons a []
  go cmp f (Cons a (_, Cons a' as')) = case cmp a a' of
    LT -> Cons a (a' : as')
    GT -> Cons a' (a : as')
    EQ -> Cons (f a a') as'
--{-# INLINABLE paraAlg #-}

groupByBubble :: (IsList l, Item l ~ v, Monoid l, Ord k) => [(k, v)] -> [(k, l)]
groupByBubble = RS.unfold (RS.para (specify paraAlg)) . fmap promote
--groupByBubble = RS.unfold (RS.para (specify alg1 . fmap snd)) . fmap promote  -- this one is also slow.  So it's para, not paraAlg
{-# INLINABLE groupByBubble #-}

{-
We observe, as before, apoCoalg and paraAlg are very similar, though it's less clear here.
But let's unroll one level of Fix:
apoCoalg :: ListF a (ListF a [a]) -> ListF (Either [a] (ListF a [a]))
paraAlg :: ListF a ([a], ListF a [a]) -> ListF a (ListF a [a])
So, if we had
swop :: ListF a ([a], ListF a [a]) -> ListF (Either [a] (ListF a [a]))
we could write
apoCoalg = swop . fmap (id &&& RS.project)
paraAlg = fmap (id ||| RS.embed) . swop 
-}

swop
  :: (a -> a -> Ordering)
  -> (a -> a -> a)
  -> ListF a ([a], ListF a [a])
  -> ListF a (Either [a] (ListF a [a]))
swop _   _ Nil                        = Nil
swop _   _ (Cons a (as, Nil        )) = Cons a (Left as)
swop cmp f (Cons a (as, Cons a' as')) = case cmp a a' of
  LT -> Cons a (Left as)
  GT -> Cons a' (Right (Cons a as'))
  EQ -> Cons (f a a') (Left as')
--{-# INLINABLE swop #-}

groupByInsert'
  :: (IsList l, Item l ~ v, Monoid l, Ord k) => [(k, v)] -> [(k, l)]
groupByInsert' =
  RS.fold (RS.apo (specify swop . fmap (id &&& RS.project))) . fmap promote
{-# INLINABLE groupByInsert' #-}

groupByBubble'
  :: (IsList l, Item l ~ v, Monoid l, Ord k) => [(k, v)] -> [(k, l)]
groupByBubble' =
  RS.unfold (RS.para (fmap (id ||| RS.embed) . specify swop)) . fmap promote
{-# INLINABLE groupByBubble' #-}




{-
Now we try to do better by unfolding to a Tree and folding to a list
which makes for fewer comparisons.
We'd like to do all the combining as we make the tree but we don't here because the tree forks any time the list elements aren't equal.
So we combine any equal ones that are adjacent on the way down.  Then combine the rest as we recombine that tree into a list.
-}
data Tree a where
  Tip :: Tree a
  Leaf :: a -> Tree a
  Fork :: Tree a -> Tree a -> Tree a deriving (Show, Functor, Foldable, Traversable)

data TreeF a b where
  TipF :: TreeF a b
  LeafF :: a -> TreeF a b
  ForkF :: b -> b -> TreeF a b deriving (Show, Functor)

type instance Base (Tree a) = TreeF a

instance RS.Recursive (Tree a) where
  project Tip = TipF
  project (Leaf a) = LeafF a
  project (Fork t1 t2) = ForkF t1 t2
  {-# INLINABLE project #-}

instance RS.Corecursive (Tree a) where
  embed TipF = Tip
  embed (LeafF a) = Leaf a
  embed (ForkF t1 t2) = Fork t1 t2
  {-# INLINABLE embed #-}

--RS.makeBaseFunctor ''Tree

{-
We begin by unfolding to a Tree.
unfold coalg :: ([a] -> Tree a) ~ ([a] -> Fix (TreeF a))
coalg :: ([a] -> TreeF a [a])
and we note that this coalgebra is a fold
fold alg :: ([a] -> TreeF a [a]) ~ (Fix (ListF a) -> TreeF a [a])
alg :: (ListF a (TreeF a [a]) -> TreeF a [a])
-}
toTreeAlg
  :: (a -> a -> Ordering)
  -> (a -> a -> a)
  -> ListF a (TreeF a [a])
  -> TreeF a [a]
toTreeAlg cmp f = go
 where
  go Nil                 = TipF
  go (Cons a TipF      ) = LeafF a
  go (Cons a (LeafF a')) = case cmp a a' of
    LT -> ForkF [a] [a']
    GT -> ForkF [a'] [a]
    EQ -> LeafF (f a a')
  go (Cons a (ForkF ls rs)) = ForkF (a : rs) ls
--{-# INLINABLE toTreeAlg #-}

toTreeCoalg :: (a -> a -> Ordering) -> (a -> a -> a) -> [a] -> TreeF a [a]
toTreeCoalg cmp f = go where go x = RS.fold (toTreeAlg cmp f) x
--{-# INLINABLE toTreeCoalg #-}

{-
fold alg :: (Tree a -> [a]) ~ (Fix (TreeF a) -> [a])
alg :: (TreeF a [a] -> [a]) ~ (TreeF a [a] -> Fix (ListF a))
and we note that this algebra is an unfold
unfold coalg :: TreeF a [a] -> Fix (ListF a)
coalg :: TreeF a [a] -> ListF a (TreeF a [a])
-}
toListCoalg
  :: (a -> a -> Ordering)
  -> (a -> a -> a)
  -> TreeF a [a]
  -> ListF a (TreeF a [a])
toListCoalg cmp f = go
 where
  go TipF                        = Nil
  go (LeafF a                  ) = Cons a TipF
  go (ForkF []       []        ) = Nil
  go (ForkF (a : as) []        ) = Cons a (ForkF [] as)
  go (ForkF []       (a  : as )) = Cons a (ForkF [] as)
  go (ForkF (a : as) (a' : as')) = case cmp a a' of
    LT -> Cons a (ForkF as (a' : as'))
    GT -> Cons a' (ForkF (a : as) as')
    EQ -> Cons (f a a') (ForkF as as')
{-# INLINE toListCoalg #-}

toListAlg :: (a -> a -> Ordering) -> (a -> a -> a) -> TreeF a [a] -> [a]
toListAlg cmp f = go where go x = RS.unfold (toListCoalg cmp f) x
--{-# INLINABLE toListAlg #-}


groupByTree1 :: (IsList l, Item l ~ v, Monoid l, Ord k) => [(k, v)] -> [(k, l)]
--groupByTree1 = RS.hylo (specify toListAlg) (specify toTreeCoalg) . fmap promote
groupByTree1 =
  RS.hylo (RS.ana (specify toListCoalg)) (RS.cata (specify toTreeAlg))
    . fmap promote
{-# INLINABLE groupByTree1 #-}
--{-# SPECIALIZE groupByTree1 :: [(Char, Int)] -> [(Char, [Int])] #-}


{-
Let's try again with a more direct hylo
-}

listToTreeCoalg :: [a] -> TreeF a [a]
listToTreeCoalg []       = TipF
listToTreeCoalg (x : []) = LeafF x
listToTreeCoalg xs =
  let (as, bs) = L.splitAt (L.length xs `div` 2) xs in ForkF as bs

treeToListAlg :: (a -> a -> Ordering) -> (a -> a -> a) -> TreeF a [a] -> [a]
treeToListAlg cmp f = go
 where
  go TipF          = []
  go (LeafF a    ) = [a]
  go (ForkF as bs) = mergeBy cmp f as bs

groupByTree2 :: (IsList l, Item l ~ v, Monoid l, Ord k) => [(k, v)] -> [(k, l)]
groupByTree2 = RS.hylo (specify treeToListAlg) listToTreeCoalg . fmap promote


mergeBy :: (a -> a -> Ordering) -> (a -> a -> a) -> [a] -> [a] -> [a]
mergeBy cmp f = loop
 where
  loop []       ys       = ys
  loop xs       []       = xs
  loop (x : xs) (y : ys) = case cmp x y of
    GT -> y : loop (x : xs) ys
    EQ -> f x y : loop xs ys
    _  -> x : loop xs (y : ys)


-- from /u/Bliminse on reddit
populateMap :: Ord k => ListF (k, v) (MS.Map k [v]) -> MS.Map k [v]
populateMap RS.Nil              = MS.empty
populateMap (RS.Cons !(k, v) m) = MS.insertWith ((:) . head) k [v] m

mapToList :: Ord k => MS.Map k [v] -> RS.ListF (k, [v]) (MS.Map k [v])
mapToList m = bool (RS.Cons (MS.elemAt 0 m) (MS.drop 1 m)) (RS.Nil) (MS.null m)

meta
  :: (RS.Corecursive c, RS.Recursive r)
  => (a -> RS.Base c a)
  -> (RS.Base r a -> a)
  -> r
  -> c
meta f g = RS.ana f . RS.cata g

listViaMetamorphism :: Ord k => [(k, v)] -> [(k, [v])]
listViaMetamorphism = meta mapToList populateMap

-- Algebra to transform a list of Maybe as into list of as, by dropping Nothings and unwrapping Just values.
stripNothings :: RS.ListF (Maybe a) [a] -> [a]
stripNothings RS.Nil                 = []
stripNothings (RS.Cons Nothing  acc) = acc
stripNothings (RS.Cons (Just a) acc) = a : acc

-- Coalgebra where the seed is a list/map pair and we build a list of Maybe (k,[v]) 
buildList
  :: Ord k
  => ([(k, v)], MS.Map k [v])
  -> RS.ListF (Maybe (k, [v])) ([(k, v)], MS.Map k [v])
buildList !([], m) =
  bool (RS.Cons (Just (MS.elemAt 0 m)) ([], MS.drop 1 m)) (RS.Nil) (MS.null m)
buildList !(!(k, v) : xs, m) =
  RS.Cons Nothing (xs, MS.insertWith ((:) . head) k [v] m)

-- hylo after pairing our input list with an empty map to provide the initial seed to the coalgebra.
listViaHylomorphism :: Ord k => [(k, v)] -> [(k, [v])]
listViaHylomorphism = RS.hylo stripNothings buildList . flip (,) MS.empty


groupBy
  :: forall t k c v l g
   . (Foldable g, Functor g)
  => FL.Fold (k, v) t -- ^ fold to tree
  -> (t -> [(k, l)]) -- ^ tree to List
  -> (forall a . FL.Fold a (g a)) -- ^ fold to g
  -> g (k, v)
  -> g (k, l)
groupBy foldToMap mapToList foldOut x =
  FL.fold foldOut . mapToList . FL.fold foldToMap $ x
{-# INLINABLE groupBy #-}

groupByOrderedKey
  :: forall g k v l
   . (Ord k, Semigroup l, Foldable g, Functor g)
  => (v -> l)
  -> (forall a . FL.Fold a (g a))
  -> g (k, v)
  -> g (k, l)
groupByOrderedKey promote = groupBy foldToStrictMap MS.toList
 where
  foldToStrictMap = FL.premap (second promote) $ FL.Fold
    (\t (k, l) -> MS.insertWithKey (\_ x y -> x <> y) k l t)
    MS.empty
    id
{-# INLINABLE groupByOrderedKey #-}

groupByHashableKey
  :: forall g k v l
   . (Hashable k, Eq k, Semigroup l, Foldable g, Functor g)
  => (v -> l)
  -> (forall a . FL.Fold a (g a))
  -> g (k, v)
  -> g (k, l)
groupByHashableKey promote = groupBy foldToStrictHashMap HMS.toList
 where
  foldToStrictHashMap = FL.premap (second promote)
    $ FL.Fold (\t (k, l) -> HMS.insertWith (<>) k l t) HMS.empty id
{-# INLINABLE groupByHashableKey #-}


{-
treeCoalg
  :: (a -> a -> Ordering)
  -> (a -> a -> a)
  -> ListF a (Tree a)
  -> TreeF a (ListF a (Tree a))
treeCoalg _   _ Nil        = TNil
treeCoalg cmp f (Cons a t) = case RS.project t of
  TNil    -> Leaf a
  Leaf a' -> case compare a a' of
    LT -> Fork (Cons a tNil) (Cons a' tNil)
    GT -> Fork (Cons a' tNil) (Cons a tNil)
    EQ -> Leaf (Cons (f a a') tNil)
  Fork tl tr -> Fork (Cons a tr) (Cons tl) -- reverse the branches for balance ??

listToGroupedTree :: [(k, v)] -> Tree (k, [v])
listToGroupedTree = RS.fold (RS.unfold treeCoalg) . fmap promote
-}


{-
What if we try to do the x -> [x] in-line?
We want [(k,v)] -> [(k,[v])]
or (Fix (ListF (k,v)) -> Fix (ListF (k,[v])))
as a fold :: (f a -> a) -> (Fix f -> a) with f ~ ListF (k,v) and a ~ [(k,[v])]
so the algebra has the form ListF (k,v) [(k,[v])] -> [(k,[v])] or ListF (k,v) [(k,[v])] -> Fix (ListF (k,[v]))
-}
alg2 :: Ord k => ListF (k, v) [(k, [v])] -> [(k, [v])]
alg2 Nil                           = []
alg2 (Cons (k, v) []             ) = [(k, [v])]
alg2 (Cons (k, v) ((k', vs) : xs)) = case compare k k' of
  LT -> (k, [v]) : (k', vs) : xs
  GT -> (k', vs) : alg2 (Cons (k, v) xs)
  EQ -> (k, v : vs) : xs
--{-# INLINABLE alg2 #-}

groupByNaiveInsert2 :: Ord k => [(k, v)] -> [(k, [v])]
groupByNaiveInsert2 = RS.fold alg2
{-# INLINABLE groupByNaiveInsert2 #-}

{-
data TreeF a r where
  Nil :: TreeF a r
  Leaf :: a -> TreeF a r
  Node :: r -> r -> TreeF a r deriving (Show, Functor)

type Tree a = Fix (TreeF a)
-}
-- fold a Foldable f => f (k,v) into Tree (k,[v])
-- we need an algebra (Fix () -> Tree (k,[v]))

-- hand-rolled from list functions
groupByHR :: Ord k => [(k, v)] -> [(k, [v])]
groupByHR
  = let
      fld = FL.Fold step begin done
       where
        sameKey k mk = fromMaybe False (fmap (== k) mk)
        step ([]               , _    ) (k, v) = ([(k, [v])], Just k)
        step (ll@((_, vs) : xs), mCurr) (k, v) = if sameKey k mCurr
          then ((k, v : vs) : xs, mCurr)
          else ((k, [v]) : ll, Just k)
        begin = ([], Nothing)
        done  = fst
    in  FL.fold fld . L.sortBy (compare `on` fst)
{-# INLINABLE groupByHR #-}



-- from <https://twanvl.nl/blog/haskell/generic-merge>

-- list merge, preserving ordering of keys and using semigroup (<>) when keys are equal
groupByTVL :: Ord k => [(k, v)] -> [(k, [v])]
groupByTVL = mergeSortUnion . fmap (second $ pure @[])
--{-# INLINABLE groupByTVL #-}

mergeSemi :: (Ord k, Semigroup w) => [(k, w)] -> [(k, w)] -> [(k, w)]
mergeSemi = unionByWith (\a b -> compare (fst a) (fst b))
                        (\(k, w1) (_, w2) -> (k, w1 <> w2))
--{-# INLINABLE mergeSemi #-}

unionByWith :: (a -> a -> Ordering) -> (a -> a -> a) -> [a] -> [a] -> [a]
unionByWith cmp f = mergeByR cmp (\a b c -> f a b : c) (:) (:) []
--{-# INLINABLE unionByWith #-}

split :: [a] -> ([a], [a])
split (x : y : zs) = let (xs, ys) = split zs in (x : xs, y : ys)
split xs           = (xs, [])
--{-# INLINABLE split #-}

mergeSortUnion :: Ord k => [(k, [v])] -> [(k, [v])]
mergeSortUnion []  = []
mergeSortUnion [x] = [x]
mergeSortUnion xs =
  let (ys, zs) = split xs in mergeSemi (mergeSortUnion ys) (mergeSortUnion zs)
--{-# INLINABLE mergeSortUnion #-}

mergeByR
  :: (a -> b -> Ordering)  -- ^ cmp: Comparison function
  -> (a -> b -> c -> c)    -- ^ fxy: Combine when a and b are equal
  -> (a -> c -> c)         -- ^ fx:  Combine when a is less
  -> (b -> c -> c)         -- ^ fy:  Combine when b is less
  -> c                     -- ^ z:   Base case
  -> [a]
  -> [b]
  -> c       -- ^ Argument lists and result list
mergeByR cmp fxy fx fy z = go
 where
  go []       ys       = foldr fy z ys
  go xs       []       = foldr fx z xs
  go (x : xs) (y : ys) = case cmp x y of
    LT -> fx x (go xs (y : ys))
    EQ -> fxy x y (go xs ys)
    GT -> fy y (go (x : xs) ys)
{-# INLINABLE mergeByR #-}


