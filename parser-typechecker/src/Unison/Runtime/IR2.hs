{-# language GADTs #-}
{-# language EmptyDataDecls #-}

module Unison.Runtime.IR2 where

import Data.Primitive.PrimArray

-- This outlines some of the ideas/features in this core
-- language, and how they may be used to implement features of
-- the surface language.

-----------------------
-- Delimited control --
-----------------------

-- There is native support for delimited control operations in
-- the core language. This means we can:
--   1. delimit a block of code with an integer tagged prompt,
--      which corresponds to pushing a frame onto the
--      continuation with said tag
--   2. capture a portion of the continuation up to a particular
--      tag frame and turn it into a value, which _removes_ the
--      tag frame from the continuation in the process
--   3. push such a captured value back onto the continuation

-- TBD: Since the captured continuations in _delimited_ control
-- are (in this case impure) functions, it may make sense to make
-- the representation of functions support these captured
-- continuations directly.

-- The obvious use case of this feature is effects and handlers.
-- Delimiting a block with a prompt is part of installing a
-- handler for said block at least naively. The other part is
-- establishing the code that should be executed for each
-- operation to be handled.

-- It's important (I believe) in #2 that the prompt be removed
-- from the continuation by a control effect. The captured
-- continuation not being automatically delimited corresponds to
-- a shallow handler's obligation to re-establish the handling of
-- a re-invoked computation if it wishes to do so. The delimiter
-- being removed from the capturing code's continuation
-- corresponds to a handler being allowed to yield effects from
-- the same siganture that it is handling.

-- In special cases, it should be possible to omit use of control
-- effects in handlers. At the least, if a handler case resumes
-- the computation in tail position, it should be unnecessary to
-- capture the continuation at all. If all cases act this way, we
-- don't need a delimiter, because we will never capture.

-- TBD: it may make more sense to have prompt pushing be part of
-- some other construct, due to A-normal forms of the code.

-----------------------------
-- Unboxed sum-of-products --
-----------------------------

-- It is not usually stated this way, but one of the core
-- features of the STG machine is that functions/closures can
-- return unboxed sum-of-products types. This is actually the way
-- _all_ data types work in STG. The discriminee of a case
-- statement must eventually return by pushing several values
-- onto the stack (the product part) and specifying which branch
-- to return to (the sum part).

-- The way heap allocated data is produced is that an
-- intermediate frame may be in the continuation that grabs this
-- information from the local storage and puts it into the heap.
-- If this frame were omitted, only the unboxed component would
-- be left. Also, in STG, the heap allocated data is just a means
-- of reconstructing its unboxed analogue. Evaluating a heap
-- allocated data type value just results in pushing its stored
-- fields back on the stack, and immediately returning the tag.

-- The portion of this with the heap allocation frame omitted
-- seems to be a natural match for the case analysis portion of
-- handlers. A naive implementation of an effect algebra is as
-- the data type of the polynomial functor generated by the
-- signature, and handling corresponds to case analysis. However,
-- in a real implementation, we don't want a heap allocated
-- representation of this algebra, because its purpose is control
-- flow. Each operation will be handled once as it occurs, and we
-- won't save work by remembering some reified representation of
-- which operations were used.

-- Since handlers in unison are written as functions, it seems to
-- make sense to define a calling convention for unboxed
-- sum-of-products as arguments. Variable numbers of stack
-- positions could be pushed for such arguments, with tags
-- specifying which case is being provided.

-- TBD: sum arguments to a function correspond to a product of
-- functions, so it's possible that the calling convention for
-- these functions should be similar to returning to a case,
-- where we push arguments and then select which of several
-- pieces of code to jump to. This view also seems relevant to
-- the optimized implementation of certain forms of handler,
-- where we want effects to just directly select some code to
-- execute based on state that has been threaded to that point.

-- One thing to note: it probably does not make sense to
-- completely divide returns into unboxed returns and allocation
-- frames. The reason this works in STG is laziness. Naming a
-- computation with `let` does not do any evaluation, but it does
-- allocate space for its (boxed) result. The only thing that
-- _does_ demand evaluation is case analysis. So, if a value with
-- sum type is being evaluated, we know it must be about to be
-- unpacked, and it makes little sense to pack it on the stack,
-- though we can build a closure version of it in the writeback
-- location established by `let`.

-- By contrast, in unison a `let` of a sum type evaluates it
-- immediately, even if no one is analyzing it. So we might waste
-- work rearranging the stack with the unpacked contents when we
-- only needed the closure version to begin with. Instead, we
-- gain the ability to make the unpacking operation use no stack,
-- because we know what we are unpacking must be a value. Turning
-- boxed function calls into unboxed versions thus seems like a
-- situational optimization, rather than a universal calling
-- convention.

data Args'
  = Arg1 !Int
  | Arg2 !Int !Int
  -- frame index of each argument to the function
  | ArgN {-# unpack #-} !(PrimArray Int)
  | ArgR !Int !Int

data Args
  = ZArgs
  | UArg1 !Int
  | UArg2 !Int !Int
  | BArg1 !Int
  | BArg2 !Int !Int
  | DArg2 !Int !Int
  | UArgR !Int !Int
  | BArgR !Int !Int
  | DArgR !Int !Int !Int !Int

ucount, bcount :: Args -> Int

ucount (UArg1 _) = 1
ucount (UArg2 _ _) = 2
ucount (DArg2 _ _) = 1
ucount (UArgR _ l) = l
ucount (DArgR _ l _ _) = l
ucount _ = 0
{-# inline ucount #-}

bcount (BArg1 _) = 1
bcount (BArg2 _ _) = 2
bcount (DArg2 _ _) = 1
bcount (BArgR _ l) = l
bcount (DArgR _ _ _ l) = l
bcount _ = 0
{-# inline bcount #-}

data Prim1 = Dec | Inc
data Prim2 = Add | Sub

-- Instruction tree representation for the machine.
data IR
  = App !Ref      -- function to apply
        !Args     -- additional arguments
  | Reset !Int    -- prompt tag
          !IR     -- delimited computation
  | Capture !Int  -- prompt tag
            !IR   -- following computation
  | Let !IR !IR
  | Prim1 !Prim1 !Int !IR
  | Prim2 !Prim2 !Int !Int !IR
  | Pack !Int !Args !IR
  | Unpack !Int !IR
  | Match !Int !Branch
  | Yield !Args
  | Print !Int !IR
  | Lit !Int !IR

data Comb
  = Lam !Int -- Number of unboxed arguments
        !Int -- Number of boxed arguments
        !Int -- Maximum needed unboxed frame size
        !Int -- Maximum needed boxed frame size
        !IR  -- Code

data Ref = Stk !Int | Env !Int

data Branch
  = Prod !IR -- only one branch
  | Test1 !Int !IR !IR -- if tag == n then t else f
  | Test2 !Int !IR !Int !IR !IR
