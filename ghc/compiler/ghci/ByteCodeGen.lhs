%
% (c) The University of Glasgow 2000
%
\section[ByteCodeGen]{Generate bytecode from Core}

\begin{code}
module ByteCodeGen ( byteCodeGen, assembleBCO ) where

#include "HsVersions.h"

import Outputable
import Name		( Name, getName )
import Id		( Id, idType, isDataConId_maybe )
import OrdList		( OrdList, consOL, snocOL, appOL, unitOL, 
			  nilOL, toOL, concatOL, fromOL )
import FiniteMap	( FiniteMap, addListToFM, listToFM, 
			  addToFM, lookupFM, fmToList, emptyFM, plusFM )
import CoreSyn
import PprCore		( pprCoreExpr, pprCoreAlt )
import Literal		( Literal(..) )
import PrimRep		( PrimRep(..) )
import CoreFVs		( freeVars )
import Type		( typePrimRep )
import DataCon		( DataCon, dataConTag, fIRST_TAG, dataConTyCon, 
			  dataConRepArgTys )
import TyCon		( TyCon, tyConFamilySize, isDataTyCon, tyConDataCons )
import Class		( Class, classTyCon )
import Util		( zipEqual, zipWith4Equal, naturalMergeSortLe, nOfThem )
import Var		( isTyVar )
import VarSet		( VarSet, varSetElems )
import PrimRep		( getPrimRepSize, isFollowableRep )
import Constants	( wORD_SIZE )
import CmdLineOpts	( DynFlags, DynFlag(..) )
import ErrUtils		( showPass, dumpIfSet_dyn )
import UniqSet		( emptyUniqSet )
import ClosureInfo	( mkVirtHeapOffsets )

import List		( intersperse )
import Monad		( foldM )
import ST		( runST )
import MArray		( MArray(..), IOArray, IOUArray, HasBounds(..),
			  castSTUArray, readWord32Array,
			  newFloatArray, writeFloatArray,
			  newDoubleArray,  writeDoubleArray,
			  newIntArray, writeIntArray,
			  newAddrArray, writeAddrArray )
import Foreign		( Storable(..), Word8, Word16, Word32, Ptr, 
			  malloc, castPtr, plusPtr )
import Addr		( Addr, addrToInt, nullAddr )
import Bits		( Bits(..), shiftR )
--import CTypes		( )
\end{code}

Entry point.

\begin{code}
-- visible from outside
byteCodeGen :: DynFlags
            -> [CoreBind] 
            -> [TyCon] -> [Class]
            -> IO ([UnlinkedBCO], ItblEnv)
byteCodeGen dflags binds local_tycons local_classes
   = do showPass dflags "ByteCodeGen"
        let tycs = local_tycons ++ map classTyCon local_classes
        itblenv <- mkITbls tycs

        let flatBinds = concatMap getBind binds
            getBind (NonRec bndr rhs) = [(bndr, freeVars rhs)]
            getBind (Rec binds)       = [(bndr, freeVars rhs) | (bndr,rhs) <- binds]
            final_state = runBc (BcM_State [] 0) 
                                (mapBc schemeR flatBinds `thenBc_` returnBc ())
            (BcM_State proto_bcos final_ctr) = final_state

        dumpIfSet_dyn dflags Opt_D_dump_BCOs
           "Proto-bcos" (vcat (intersperse (char ' ') (map ppr proto_bcos)))

        bcos <- mapM assembleBCO proto_bcos

        return (bcos, itblenv)
        
-- TEMPORARY !
data UnlinkedBCO 
   = UnlinkedBCO (IOUArray Int Word16)	-- insns
                 (IOUArray Int Word32)	-- literals
                 (IOArray Int Name)	-- ptrs
                 (IOArray Int Name)	-- itbl refs

-- needs a proper home
type ItblEnv    = FiniteMap Name (Ptr StgInfoTable)
\end{code}


%************************************************************************
%*									*
\subsection{Bytecodes, and Outputery.}
%*									*
%************************************************************************

\begin{code}

type LocalLabel = Int

data UnboxedLit = UnboxedI Int | UnboxedF Float | UnboxedD Double

data BCInstr
   -- Messing with the stack
   = ARGCHECK  Int
   -- Push locals (existing bits of the stack)
   | PUSH_L    Int{-offset-}
   | PUSH_LL   Int Int{-2 offsets-}
   | PUSH_LLL  Int Int Int{-3 offsets-}
   -- Push a ptr
   | PUSH_G    Name
   -- Push an alt continuation
   | PUSH_AS   Name PrimRep	-- push alts and BCO_ptr_ret_info
				-- PrimRep so we know which itbl
   -- Pushing literals
   | PUSH_UBX  Literal	Int 
                        -- push this int/float/double, NO TAG, on the stack
			-- Int is # of items in literal pool to push
   | PUSH_TAG  Int      -- push this tag on the stack

   | SLIDE     Int{-this many-} Int{-down by this much-}
   -- To do with the heap
   | ALLOC     Int	-- make an AP_UPD with this many payload words, zeroed
   | MKAP      Int{-ptr to AP_UPD is this far down stack-} Int{-# words-}
   | UNPACK    Int	-- unpack N ptr words from t.o.s Constr
   | UPK_TAG   Int Int Int
			-- unpack N non-ptr words from offset M in constructor
			-- K words down the stack
   | PACK      DataCon Int
			-- after assembly, the DataCon is an index into the
			-- itbl array
   -- For doing case trees
   | LABEL     LocalLabel
   | TESTLT_I  Int    LocalLabel
   | TESTEQ_I  Int    LocalLabel
   | TESTLT_F  Float  LocalLabel
   | TESTEQ_F  Float  LocalLabel
   | TESTLT_D  Double LocalLabel
   | TESTEQ_D  Double LocalLabel
   | TESTLT_P  Int    LocalLabel
   | TESTEQ_P  Int    LocalLabel
   | CASEFAIL
   -- To Infinity And Beyond
   | ENTER
   | RETURN	-- unboxed value on TOS.  Use tag to find underlying ret itbl
		-- and return as per that.


instance Outputable BCInstr where
   ppr (ARGCHECK n)          = text "ARGCHECK" <+> int n
   ppr (PUSH_L offset)       = text "PUSH_L  " <+> int offset
   ppr (PUSH_LL o1 o2)       = text "PUSH_LL " <+> int o1 <+> int o2
   ppr (PUSH_LLL o1 o2 o3)   = text "PUSH_LLL" <+> int o1 <+> int o2 <+> int o3
   ppr (PUSH_G nm)           = text "PUSH_G  " <+> ppr nm
   ppr (PUSH_AS nm pk)       = text "PUSH_AS " <+> ppr nm <+> ppr pk
   ppr (SLIDE n d)           = text "SLIDE   " <+> int n <+> int d
   ppr (ALLOC sz)            = text "ALLOC   " <+> int sz
   ppr (MKAP offset sz)      = text "MKAP    " <+> int offset <+> int sz
   ppr (UNPACK sz)           = text "UNPACK  " <+> int sz
   ppr (PACK dcon sz)        = text "PACK    " <+> ppr dcon <+> ppr sz
   ppr (LABEL     lab)       = text "__"       <> int lab <> colon
   ppr (TESTLT_I  i lab)     = text "TESTLT_I" <+> int i <+> text "__" <> int lab
   ppr (TESTEQ_I  i lab)     = text "TESTEQ_I" <+> int i <+> text "__" <> int lab
   ppr (TESTLT_F  f lab)     = text "TESTLT_F" <+> float f <+> text "__" <> int lab
   ppr (TESTEQ_F  f lab)     = text "TESTEQ_F" <+> float f <+> text "__" <> int lab
   ppr (TESTLT_D  d lab)     = text "TESTLT_D" <+> double d <+> text "__" <> int lab
   ppr (TESTEQ_D  d lab)     = text "TESTEQ_D" <+> double d <+> text "__" <> int lab
   ppr (TESTLT_P  i lab)     = text "TESTLT_P" <+> int i <+> text "__" <> int lab
   ppr (TESTEQ_P  i lab)     = text "TESTEQ_P" <+> int i <+> text "__" <> int lab
   ppr CASEFAIL              = text "CASEFAIL"
   ppr ENTER                 = text "ENTER"
   ppr RETURN                = text "RETURN"

pprAltCode discrs_n_codes
   = vcat (map f discrs_n_codes)
     where f (discr, code) = ppr discr <> colon <+> vcat (map ppr (fromOL code))

instance Outputable a => Outputable (ProtoBCO a) where
   ppr (ProtoBCO name instrs origin)
      = (text "ProtoBCO" <+> ppr name <> colon)
        $$ nest 6 (vcat (map ppr instrs))
        $$ case origin of
              Left alts -> vcat (map (pprCoreAlt.deAnnAlt) alts)
              Right rhs -> pprCoreExpr (deAnnotate rhs)
\end{code}

%************************************************************************
%*									*
\subsection{Compilation schema for the bytecode generator.}
%*									*
%************************************************************************

\begin{code}

type BCInstrList = OrdList BCInstr

data ProtoBCO a 
   = ProtoBCO a 			-- name, in some sense
              [BCInstr] 		-- instrs
					-- what the BCO came from
              (Either [AnnAlt Id VarSet]
                      (AnnExpr Id VarSet))


type Sequel = Int	-- back off to this depth before ENTER

-- Maps Ids to the offset from the stack _base_ so we don't have
-- to mess with it after each push/pop.
type BCEnv = FiniteMap Id Int	-- To find vars on the stack


-- Create a BCO and do a spot of peephole optimisation on the insns
-- at the same time.
mkProtoBCO nm instrs_ordlist origin
   = ProtoBCO nm (peep (fromOL instrs_ordlist)) origin
     where
        peep (PUSH_L off1 : PUSH_L off2 : PUSH_L off3 : rest)
           = PUSH_LLL off1 (off2-1) (off3-2) : peep rest
        peep (PUSH_L off1 : PUSH_L off2 : rest)
           = PUSH_LL off1 off2 : peep rest
        peep (i:rest)
           = i : peep rest
        peep []
           = []


-- Compile code for the right hand side of a let binding.
-- Park the resulting BCO in the monad.  Also requires the
-- variable to which this value was bound, so as to give the
-- resulting BCO a name.
schemeR :: (Id, AnnExpr Id VarSet) -> BcM ()
schemeR (nm, rhs) = schemeR_wrk rhs nm (collect [] rhs)

collect xs (_, AnnLam x e) 
   = collect (if isTyVar x then xs else (x:xs)) e
collect xs not_lambda
   = (reverse xs, not_lambda)

schemeR_wrk original_body nm (args, body)
   = let fvs       = filter (not.isTyVar) (varSetElems (fst original_body))
         all_args  = fvs ++ reverse args
         szsw_args = map taggedIdSizeW all_args
         szw_args  = sum szsw_args
         p_init    = listToFM (zip all_args (mkStackOffsets 0 szsw_args))
         argcheck  = if null args then nilOL else unitOL (ARGCHECK szw_args)
     in
     schemeE szw_args 0 p_init body 		`thenBc` \ body_code ->
     emitBc (mkProtoBCO (getName nm) (appOL argcheck body_code) (Right original_body))

-- Let szsw be the sizes in words of some items pushed onto the stack,
-- which has initial depth d'.  Return the values which the stack environment
-- should map these items to.
mkStackOffsets :: Int -> [Int] -> [Int]
mkStackOffsets original_depth szsw
   = map (subtract 1) (tail (scanl (+) original_depth szsw))

-- Compile code to apply the given expression to the remaining args
-- on the stack, returning a HNF.
schemeE :: Int -> Sequel -> BCEnv -> AnnExpr Id VarSet -> BcM BCInstrList

-- Delegate tail-calls to schemeT.
schemeE d s p e@(fvs, AnnApp f a) 
   = returnBc (schemeT (should_args_be_tagged e) d s 0 p (fvs, AnnApp f a))
schemeE d s p e@(fvs, AnnVar v)
   | isFollowableRep (typePrimRep (idType v))
   = returnBc (schemeT (should_args_be_tagged e) d s 0 p (fvs, AnnVar v))
   | otherwise
   = -- returning an unboxed value.  Heave it on the stack, SLIDE, and RETURN.
     let (push, szw) = pushAtom True d p (AnnVar v)
     in  returnBc (push 			-- value onto stack
                   `snocOL` SLIDE szw (d-s) 	-- clear to sequel
                   `snocOL` RETURN)		-- go

schemeE d s p (fvs, AnnLit literal)
   = let (push, szw) = pushAtom True d p (AnnLit literal)
     in  returnBc (push 			-- value onto stack
                   `snocOL` SLIDE szw (d-s) 	-- clear to sequel
                   `snocOL` RETURN)		-- go

schemeE d s p (fvs, AnnLet binds b)
   = let (xs,rhss) = case binds of AnnNonRec x rhs  -> ([x],[rhs])
                                   AnnRec xs_n_rhss -> unzip xs_n_rhss
         n     = length xs
         fvss  = map (filter (not.isTyVar).varSetElems.fst) rhss
         sizes = map (\rhs_fvs -> 1 + sum (map taggedIdSizeW rhs_fvs)) fvss

         -- This p', d' defn is safe because all the items being pushed
         -- are ptrs, so all have size 1.  d' and p' reflect the stack
         -- after the closures have been allocated in the heap (but not
         -- filled in), and pointers to them parked on the stack.
         p'    = addListToFM p (zipE xs (mkStackOffsets d (nOfThem n 1)))
         d'    = d + n

         infos = zipE4 fvss sizes xs [n, n-1 .. 1]
         zipE  = zipEqual "schemeE"
         zipE4 = zipWith4Equal "schemeE" (\a b c d -> (a,b,c,d))

         -- ToDo: don't build thunks for things with no free variables
         buildThunk dd ([], size, id, off)
            = PUSH_G (getName id) 
              `consOL` unitOL (MKAP (off+size-1) size)
         buildThunk dd ((fv:fvs), size, id, off)
            = case pushAtom True dd p' (AnnVar fv) of
                 (push_code, pushed_szw)
                    -> push_code `appOL`
                       buildThunk (dd+pushed_szw) (fvs, size, id, off)

         thunkCode = concatOL (map (buildThunk d') infos)
         allocCode = toOL (map ALLOC sizes)
     in
     schemeE d' s p' b   				`thenBc`  \ bodyCode ->
     mapBc schemeR (zip xs rhss) 			`thenBc_`
     returnBc (allocCode `appOL` thunkCode `appOL` bodyCode)


schemeE d s p (fvs, AnnCase scrut bndr alts)
   = let
        -- Top of stack is the return itbl, as usual.
        -- underneath it is the pointer to the alt_code BCO.
        -- When an alt is entered, it assumes the returned value is
        -- on top of the itbl.
        ret_frame_sizeW = 2

        -- Env and depth in which to compile the alts, not including
        -- any vars bound by the alts themselves
        d' = d + ret_frame_sizeW + taggedIdSizeW bndr
        p' = addToFM p bndr (d' - 1)

        scrut_primrep = typePrimRep (idType bndr)
        isAlgCase
           = case scrut_primrep of
                IntRep -> False ; FloatRep -> False ; DoubleRep -> False
                PtrRep -> True
                other  -> pprPanic "ByteCodeGen.schemeE" (ppr other)

        -- given an alt, return a discr and code for it.
        codeAlt alt@(discr, binds_f, rhs)
           | isAlgCase 
           = let binds_r      = reverse binds_f
                 binds_r_szsw = map untaggedIdSizeW binds_r
                 binds_szw    = sum binds_r_szsw
                 p''          = addListToFM 
                                   p' (zip binds_r (mkStackOffsets d' binds_r_szsw))
                 d''          = d' + binds_szw
                 unpack_code  = mkUnpackCode 0 0 (map (typePrimRep.idType) binds_f)
             in schemeE d'' s p'' rhs	`thenBc` \ rhs_code -> 
                returnBc (my_discr alt, unpack_code `appOL` rhs_code)
           | otherwise 
           = ASSERT(null binds_f) 
             schemeE d' s p' rhs	`thenBc` \ rhs_code ->
             returnBc (my_discr alt, rhs_code)

        my_discr (DEFAULT, binds, rhs)  = NoDiscr
        my_discr (DataAlt dc, binds, rhs) = DiscrP (dataConTag dc)
        my_discr (LitAlt l, binds, rhs)
           = case l of MachInt i     -> DiscrI (fromInteger i)
                       MachFloat r   -> DiscrF (fromRational r)
                       MachDouble r  -> DiscrD (fromRational r)

        maybe_ncons 
           | not isAlgCase = Nothing
           | otherwise 
           = case [dc | (DataAlt dc, _, _) <- alts] of
                []     -> Nothing
                (dc:_) -> Just (tyConFamilySize (dataConTyCon dc))

     in 
     mapBc codeAlt alts 				`thenBc` \ alt_stuff ->
     mkMultiBranch maybe_ncons alt_stuff		`thenBc` \ alt_final ->
     let 
         alt_bco_name = getName bndr
         alt_bco      = mkProtoBCO alt_bco_name alt_final (Left alts)
     in
     schemeE (d + ret_frame_sizeW) 
             (d + ret_frame_sizeW) p scrut		`thenBc` \ scrut_code ->

     emitBc alt_bco 					`thenBc_`
     returnBc (PUSH_AS alt_bco_name scrut_primrep `consOL` scrut_code)


schemeE d s p (fvs, AnnNote note body)
   = schemeE d s p body

schemeE d s p other
   = pprPanic "ByteCodeGen.schemeE: unhandled case" 
               (pprCoreExpr (deAnnotate other))


-- Compile code to do a tail call.  Doesn't need to be monadic.
schemeT :: Bool 	-- do tagging?
        -> Int 		-- Stack depth
        -> Sequel 	-- Sequel depth
        -> Int 		-- # arg words so far
        -> BCEnv 	-- stack env
        -> AnnExpr Id VarSet 
        -> BCInstrList

schemeT enTag d s narg_words p (_, AnnApp f a)
   = case snd a of
        AnnType _ -> schemeT enTag d s narg_words p f
        other
           -> let (push, arg_words) = pushAtom enTag d p (snd a)
              in push 
                 `appOL` schemeT enTag (d+arg_words) s (narg_words+arg_words) p f

schemeT enTag d s narg_words p (_, AnnVar f)
   | Just con <- isDataConId_maybe f
   = ASSERT(enTag == False)
     PACK con narg_words `consOL` (mkSLIDE 1 (d-s-1) `snocOL` ENTER)
   | otherwise
   = ASSERT(enTag == True)
     let (push, arg_words) = pushAtom True d p (AnnVar f)
     in  push 
         `appOL`  mkSLIDE (narg_words+arg_words) (d - s - narg_words)
         `snocOL` ENTER

mkSLIDE n d 
   = if d == 0 then nilOL else unitOL (SLIDE n d)

should_args_be_tagged (_, AnnVar v)
   = case isDataConId_maybe v of
        Just dcon -> False; Nothing -> True
should_args_be_tagged (_, AnnApp f a)
   = should_args_be_tagged f
should_args_be_tagged (_, other)
   = panic "should_args_be_tagged: tail call to non-con, non-var"


-- Make code to unpack a constructor onto the stack, adding
-- tags for the unboxed bits.  Takes the PrimReps of the constructor's
-- arguments, and a travelling offset along both the constructor
-- (off_h) and the stack (off_s).
mkUnpackCode :: Int -> Int -> [PrimRep] -> BCInstrList
mkUnpackCode off_h off_s [] = nilOL
mkUnpackCode off_h off_s (r:rs)
   | isFollowableRep r
   = let (rs_ptr, rs_nptr) = span isFollowableRep (r:rs)
         ptrs_szw = sum (map untaggedSizeW rs_ptr) 
     in  ASSERT(ptrs_szw == length rs_ptr)
         ASSERT(off_h == 0)
         ASSERT(off_s == 0)
         UNPACK ptrs_szw 
         `consOL` mkUnpackCode (off_h + ptrs_szw) (off_s + ptrs_szw) rs_nptr
   | otherwise
   = case r of
        IntRep    -> approved
        FloatRep  -> approved
        DoubleRep -> approved
     where
        approved = UPK_TAG usizeW off_h off_s   `consOL` theRest
        theRest  = mkUnpackCode (off_h + usizeW) (off_s + tsizeW) rs
        usizeW   = untaggedSizeW r
        tsizeW   = taggedSizeW r

-- Push an atom onto the stack, returning suitable code & number of
-- stack words used.  Pushes it either tagged or untagged, since 
-- pushAtom is used to set up the stack prior to copying into the
-- heap for both APs (requiring tags) and constructors (which don't).
--
-- NB this means NO GC between pushing atoms for a constructor and
-- copying them into the heap.  It probably also means that 
-- tail calls MUST be of the form atom{atom ... atom} since if the
-- expression head was allowed to be arbitrary, there could be GC
-- in between pushing the arg atoms and completing the head.
-- (not sure; perhaps the allocate/doYouWantToGC interface means this
-- isn't a problem; but only if arbitrary graph construction for the
-- head doesn't leave this BCO, since GC might happen at the start of
-- each BCO (we consult doYouWantToGC there).
--
-- Blargh.  JRS 001206
--
-- NB (further) that the env p must map each variable to the highest-
-- numbered stack slot for it.  For example, if the stack has depth 4 
-- and we tagged-ly push (v :: Int#) on it, the value will be in stack[4],
-- the tag in stack[5], the stack will have depth 6, and p must map v to
-- 5 and not to 4.  Stack locations are numbered from zero, so a depth
-- 6 stack has valid words 0 .. 5.

pushAtom :: Bool -> Int -> BCEnv -> AnnExpr' Id VarSet -> (BCInstrList, Int)
pushAtom tagged d p (AnnVar v) 
   = let str = "\npushAtom " ++ showSDocDebug (ppr v) ++ ", depth = " ++ show d
               ++ ", env =\n" ++ 
               showSDocDebug (nest 4 (vcat (map ppr (fmToList p))))
               ++ " -->\n" ++
               showSDoc (nest 4 (vcat (map ppr (fromOL (fst result)))))
               ++ "\nendPushAtom " ++ showSDocDebug (ppr v)
         str' = if str == str then str else str

         result
            = case lookupBCEnv_maybe p v of
                 Just d_v -> (toOL (nOfThem nwords (PUSH_L (d-d_v+sz_t-2))), sz_t)
                 Nothing  -> ASSERT(sz_t == 1) (unitOL (PUSH_G nm), sz_t)

         nm     = getName v
         sz_t   = taggedIdSizeW v
         sz_u   = untaggedIdSizeW v
         nwords = if tagged then sz_t else sz_u
     in
         --trace str'
         result

pushAtom True d p (AnnLit lit)
   = let (ubx_code, ubx_size) = pushAtom False d p (AnnLit lit)
     in  (ubx_code `snocOL` PUSH_TAG ubx_size, 1 + ubx_size)

pushAtom False d p (AnnLit lit)
   = case lit of
        MachInt i    -> code IntRep
        MachFloat r  -> code FloatRep
        MachDouble r -> code DoubleRep
     where
        code rep
           = let size_host_words = untaggedSizeW rep
                 size_in_word32s = (size_host_words * wORD_SIZE) `div` 4
             in (unitOL (PUSH_UBX lit size_in_word32s), size_host_words)

pushAtom tagged d p (AnnApp f (_, AnnType _))
   = pushAtom tagged d p (snd f)

pushAtom tagged d p other
   = pprPanic "ByteCodeGen.pushAtom" 
              (pprCoreExpr (deAnnotate (undefined, other)))


-- Given a bunch of alts code and their discrs, do the donkey work
-- of making a multiway branch using a switch tree.
-- What a load of hassle!
mkMultiBranch :: Maybe Int	-- # datacons in tycon, if alg alt
				-- a hint; generates better code
				-- Nothing is always safe
              -> [(Discr, BCInstrList)] 
              -> BcM BCInstrList
mkMultiBranch maybe_ncons raw_ways
   = let d_way     = filter (isNoDiscr.fst) raw_ways
         notd_ways = naturalMergeSortLe 
                        (\w1 w2 -> leAlt (fst w1) (fst w2))
                        (filter (not.isNoDiscr.fst) raw_ways)

         mkTree :: [(Discr, BCInstrList)] -> Discr -> Discr -> BcM BCInstrList
         mkTree [] range_lo range_hi = returnBc the_default

         mkTree [val] range_lo range_hi
            | range_lo `eqAlt` range_hi 
            = returnBc (snd val)
            | otherwise
            = getLabelBc 				`thenBc` \ label_neq ->
              returnBc (mkTestEQ (fst val) label_neq 
			`consOL` (snd val
			`appOL`   unitOL (LABEL label_neq)
			`appOL`   the_default))

         mkTree vals range_lo range_hi
            = let n = length vals `div` 2
                  vals_lo = take n vals
                  vals_hi = drop n vals
                  v_mid = fst (head vals_hi)
              in
              getLabelBc 				`thenBc` \ label_geq ->
              mkTree vals_lo range_lo (dec v_mid) 	`thenBc` \ code_lo ->
              mkTree vals_hi v_mid range_hi 		`thenBc` \ code_hi ->
              returnBc (mkTestLT v_mid label_geq
                        `consOL` (code_lo
			`appOL`   unitOL (LABEL label_geq)
			`appOL`   code_hi))
 
         the_default 
            = case d_way of [] -> unitOL CASEFAIL
                            [(_, def)] -> def

         -- None of these will be needed if there are no non-default alts
         (mkTestLT, mkTestEQ, init_lo, init_hi)
            | null notd_ways
            = panic "mkMultiBranch: awesome foursome"
            | otherwise
            = case fst (head notd_ways) of {
              DiscrI _ -> ( \(DiscrI i) fail_label -> TESTLT_I i fail_label,
                            \(DiscrI i) fail_label -> TESTEQ_I i fail_label,
                            DiscrI minBound,
                            DiscrI maxBound );
              DiscrF _ -> ( \(DiscrF f) fail_label -> TESTLT_F f fail_label,
                            \(DiscrF f) fail_label -> TESTEQ_F f fail_label,
                            DiscrF minF,
                            DiscrF maxF );
              DiscrD _ -> ( \(DiscrD d) fail_label -> TESTLT_D d fail_label,
                            \(DiscrD d) fail_label -> TESTEQ_D d fail_label,
                            DiscrD minD,
                            DiscrD maxD );
              DiscrP _ -> ( \(DiscrP i) fail_label -> TESTLT_P i fail_label,
                            \(DiscrP i) fail_label -> TESTEQ_P i fail_label,
                            DiscrP algMinBound,
                            DiscrP algMaxBound )
              }

         (algMinBound, algMaxBound)
            = case maybe_ncons of
                 Just n  -> (fIRST_TAG, fIRST_TAG + n - 1)
                 Nothing -> (minBound, maxBound)

         (DiscrI i1) `eqAlt` (DiscrI i2) = i1 == i2
         (DiscrF f1) `eqAlt` (DiscrF f2) = f1 == f2
         (DiscrD d1) `eqAlt` (DiscrD d2) = d1 == d2
         (DiscrP i1) `eqAlt` (DiscrP i2) = i1 == i2
         NoDiscr     `eqAlt` NoDiscr     = True
         _           `eqAlt` _           = False

         (DiscrI i1) `leAlt` (DiscrI i2) = i1 <= i2
         (DiscrF f1) `leAlt` (DiscrF f2) = f1 <= f2
         (DiscrD d1) `leAlt` (DiscrD d2) = d1 <= d2
         (DiscrP i1) `leAlt` (DiscrP i2) = i1 <= i2
         NoDiscr     `leAlt` NoDiscr     = True
         _           `leAlt` _           = False

         isNoDiscr NoDiscr = True
         isNoDiscr _       = False

         dec (DiscrI i) = DiscrI (i-1)
         dec (DiscrP i) = DiscrP (i-1)
         dec other      = other		-- not really right, but if you
		-- do cases on floating values, you'll get what you deserve

         -- same snotty comment applies to the following
         minF, maxF :: Float
         minD, maxD :: Double
         minF = -1.0e37
         maxF =  1.0e37
         minD = -1.0e308
         maxD =  1.0e308
     in
         mkTree notd_ways init_lo init_hi

\end{code}

%************************************************************************
%*									*
\subsection{Supporting junk for the compilation schemes}
%*									*
%************************************************************************

\begin{code}

-- Describes case alts
data Discr 
   = DiscrI Int
   | DiscrF Float
   | DiscrD Double
   | DiscrP Int
   | NoDiscr

instance Outputable Discr where
   ppr (DiscrI i) = int i
   ppr (DiscrF f) = text (show f)
   ppr (DiscrD d) = text (show d)
   ppr (DiscrP i) = int i
   ppr NoDiscr    = text "DEF"


-- Find things in the BCEnv (the what's-on-the-stack-env)
-- See comment preceding pushAtom for precise meaning of env contents
lookupBCEnv :: BCEnv -> Id -> Int
lookupBCEnv env nm
   = case lookupFM env nm of
        Nothing -> pprPanic "lookupBCEnv" 
                            (ppr nm $$ char ' ' $$ vcat (map ppr (fmToList env)))
        Just xx -> xx

lookupBCEnv_maybe :: BCEnv -> Id -> Maybe Int
lookupBCEnv_maybe = lookupFM


-- When I push one of these on the stack, how much does Sp move by?
taggedSizeW :: PrimRep -> Int
taggedSizeW pr
   | isFollowableRep pr = 1
   | otherwise          = 1{-the tag-} + getPrimRepSize pr


-- The plain size of something, without tag.
untaggedSizeW :: PrimRep -> Int
untaggedSizeW pr
   | isFollowableRep pr = 1
   | otherwise          = getPrimRepSize pr


taggedIdSizeW, untaggedIdSizeW :: Id -> Int
taggedIdSizeW   = taggedSizeW   . typePrimRep . idType
untaggedIdSizeW = untaggedSizeW . typePrimRep . idType

\end{code}

%************************************************************************
%*									*
\subsection{The bytecode generator's monad}
%*									*
%************************************************************************

\begin{code}
data BcM_State 
   = BcM_State { bcos      :: [ProtoBCO Name],	-- accumulates completed BCOs
                 nextlabel :: Int }		-- for generating local labels

type BcM result = BcM_State -> (result, BcM_State)

mkBcM_State :: [ProtoBCO Name] -> Int -> BcM_State
mkBcM_State = BcM_State

runBc :: BcM_State -> BcM () -> BcM_State
runBc init_st m = case m init_st of { (r,st) -> st }

thenBc :: BcM a -> (a -> BcM b) -> BcM b
thenBc expr cont st
  = case expr st of { (result, st') -> cont result st' }

thenBc_ :: BcM a -> BcM b -> BcM b
thenBc_ expr cont st
  = case expr st of { (result, st') -> cont st' }

returnBc :: a -> BcM a
returnBc result st = (result, st)

mapBc :: (a -> BcM b) -> [a] -> BcM [b]
mapBc f []     = returnBc []
mapBc f (x:xs)
  = f x          `thenBc` \ r  ->
    mapBc f xs   `thenBc` \ rs ->
    returnBc (r:rs)

emitBc :: ProtoBCO Name -> BcM ()
emitBc bco st
   = ((), st{bcos = bco : bcos st})

getLabelBc :: BcM Int
getLabelBc st
   = (nextlabel st, st{nextlabel = 1 + nextlabel st})

\end{code}

%************************************************************************
%*									*
\subsection{The bytecode assembler}
%*									*
%************************************************************************

The object format for bytecodes is: 16 bits for the opcode, and 16 for
each field -- so the code can be considered a sequence of 16-bit ints.
Each field denotes either a stack offset or number of items on the
stack (eg SLIDE), and index into the pointer table (eg PUSH_G), an
index into the literal table (eg PUSH_I/D/L), or a bytecode address in
this BCO.

\begin{code}
-- Top level assembler fn.
assembleBCO :: ProtoBCO Name -> IO UnlinkedBCO

assembleBCO (ProtoBCO nm instrs origin)
   = let
         -- pass 1: collect up the offsets of the local labels
         label_env = mkLabelEnv emptyFM 0 instrs

         mkLabelEnv env i_offset [] = env
         mkLabelEnv env i_offset (i:is)
            = let new_env 
                     = case i of LABEL n -> addToFM env n i_offset ; _ -> env
              in  mkLabelEnv new_env (i_offset + instrSizeB i) is

         findLabel lab
            = case lookupFM label_env lab of
                 Just bco_offset -> bco_offset
                 Nothing -> pprPanic "assembleBCO.findLabel" (int lab)

         init_n_insns = 10
         init_n_lits  = 4
         init_n_ptrs  = 4
         init_n_itbls = 4
     in
     do  insns <- newXIOUArray init_n_insns :: IO (XIOUArray Word16)
         lits  <- newXIOUArray init_n_lits  :: IO (XIOUArray Word32)
         ptrs  <- newXIOArray  init_n_ptrs  -- :: IO (XIOArray Name)
         itbls <- newXIOArray  init_n_itbls -- :: IO (XIOArray Name)

         -- pass 2: generate the instruction, ptr and nonptr bits
         let init_asm_state = (insns,lits,ptrs,itbls)
         final_asm_state <- mkBits findLabel init_asm_state instrs         

         -- unwrap the expandable arrays
         let final_insns = stuffXIOU insns
             final_nptrs = stuffXIOU lits
             final_ptrs  = stuffXIO  ptrs
             final_itbls = stuffXIO  itbls

         return (UnlinkedBCO final_insns final_nptrs final_ptrs final_itbls)


-- instrs nonptrs ptrs itbls
type AsmState = (XIOUArray Word16, XIOUArray Word32, XIOArray Name, XIOArray Name)


-- This is where all the action is (pass 2 of the assembler)
mkBits :: (Int -> Int) 			-- label finder
       -> AsmState
       -> [BCInstr]			-- instructions (in)
       -> IO AsmState

mkBits findLabel st proto_insns
  = foldM doInstr st proto_insns
    where
       doInstr :: AsmState -> BCInstr -> IO AsmState
       doInstr st i
          = case i of
               ARGCHECK  n        -> instr2 st i_ARGCHECK n
               PUSH_L    o1       -> instr2 st i_PUSH_L o1
               PUSH_LL   o1 o2    -> instr3 st i_PUSH_LL o1 o2
               PUSH_LLL  o1 o2 o3 -> instr4 st i_PUSH_LLL o1 o2 o3
               PUSH_G    nm       -> do (p, st2) <- ptr st nm
                                        instr2 st2 i_PUSH_G p
               PUSH_AS   nm pk    -> do (p, st2)  <- ptr st nm
                                        (np, st3) <- ret_itbl st2 pk
                                        instr3 st3 i_PUSH_AS p np
               PUSH_UBX lit nw32s -> do (np, st2) <- literal st lit
                                        instr3 st2 i_PUSH_UBX np nw32s
               PUSH_TAG  tag      -> instr2 st i_PUSH_TAG tag
               SLIDE     n by     -> instr3 st i_SLIDE n by
               ALLOC     n        -> instr2 st i_ALLOC n
               MKAP      off sz   -> instr3 st i_MKAP off sz
               UNPACK    n        -> instr2 st i_UNPACK n
               UPK_TAG   n m k    -> instr4 st i_UPK_TAG n m k
               PACK      dcon sz  -> do (itbl_no,st2) <- itbl st dcon
                                        instr3 st2 i_PACK itbl_no sz
               LABEL     lab      -> return st
               TESTLT_I  i l      -> do (np, st2) <- int st i
                                        instr3 st2 i_TESTLT_I np (findLabel l)
               TESTEQ_I  i l      -> do (np, st2) <- int st i
                                        instr3 st2 i_TESTEQ_I np (findLabel l)
               TESTLT_F  f l      -> do (np, st2) <- float st f
                                        instr3 st2 i_TESTLT_F np (findLabel l)
               TESTEQ_F  f l      -> do (np, st2) <- float st f
                                        instr3 st2 i_TESTEQ_F np (findLabel l)
               TESTLT_D  d l      -> do (np, st2) <- double st d
                                        instr3 st2 i_TESTLT_D np (findLabel l)
               TESTEQ_D  d l      -> do (np, st2) <- double st d
                                        instr3 st2 i_TESTEQ_D np (findLabel l)
               TESTLT_P  i l      -> do (np, st2) <- int st i
                                        instr3 st2 i_TESTLT_P np (findLabel l)
               TESTEQ_P  i l      -> do (np, st2) <- int st i
                                        instr3 st2 i_TESTEQ_P np (findLabel l)
               CASEFAIL           -> instr1 st i_CASEFAIL
               ENTER              -> instr1 st i_ENTER
               RETURN             -> instr1 st i_RETURN

       i2s :: Int -> Word16
       i2s = fromIntegral

       instr1 (st_i0,st_l0,st_p0,st_I0) i1
          = do st_i1 <- addToXIOUArray st_i0 (i2s i1)
               return (st_i1,st_l0,st_p0,st_I0)

       instr2 (st_i0,st_l0,st_p0,st_I0) i1 i2
          = do st_i1 <- addToXIOUArray st_i0 (i2s i1)
               st_i2 <- addToXIOUArray st_i1 (i2s i2)
               return (st_i2,st_l0,st_p0,st_I0)

       instr3 (st_i0,st_l0,st_p0,st_I0) i1 i2 i3
          = do st_i1 <- addToXIOUArray st_i0 (i2s i1)
               st_i2 <- addToXIOUArray st_i1 (i2s i2)
               st_i3 <- addToXIOUArray st_i2 (i2s i3)
               return (st_i3,st_l0,st_p0,st_I0)

       instr4 (st_i0,st_l0,st_p0,st_I0) i1 i2 i3 i4
          = do st_i1 <- addToXIOUArray st_i0 (i2s i1)
               st_i2 <- addToXIOUArray st_i1 (i2s i2)
               st_i3 <- addToXIOUArray st_i2 (i2s i3)
               st_i4 <- addToXIOUArray st_i3 (i2s i4)
               return (st_i4,st_l0,st_p0,st_I0)

       float (st_i0,st_l0,st_p0,st_I0) f
          = do let w32s = mkLitF f
               st_l1 <- addListToXIOUArray st_l0 w32s
               return (usedXIOU st_l0, (st_i0,st_l1,st_p0,st_I0))

       double (st_i0,st_l0,st_p0,st_I0) d
          = do let w32s = mkLitD d
               st_l1 <- addListToXIOUArray st_l0 w32s
               return (usedXIOU st_l0, (st_i0,st_l1,st_p0,st_I0))

       int (st_i0,st_l0,st_p0,st_I0) i
          = do let w32s = mkLitI i
               st_l1 <- addListToXIOUArray st_l0 w32s
               return (usedXIOU st_l0, (st_i0,st_l1,st_p0,st_I0))

       addr (st_i0,st_l0,st_p0,st_I0) a
          = do let w32s = mkLitA a
               st_l1 <- addListToXIOUArray st_l0 w32s
               return (usedXIOU st_l0, (st_i0,st_l1,st_p0,st_I0))

       ptr (st_i0,st_l0,st_p0,st_I0) p
          = do st_p1 <- addToXIOArray st_p0 p
               return (usedXIO st_p0, (st_i0,st_l0,st_p1,st_I0))

       itbl (st_i0,st_l0,st_p0,st_I0) dcon
          = do st_I1 <- addToXIOArray st_I0 (getName dcon)
               return (usedXIO st_I0, (st_i0,st_l0,st_p0,st_I1))

       literal st (MachInt j)    = int st (fromIntegral j)
       literal st (MachFloat r)  = float st (fromRational r)
       literal st (MachDouble r) = double st (fromRational r)

       ret_itbl st pk
          = addr st ret_itbl_addr
            where
               ret_itbl_addr 
                  = case pk of
                       IntRep    -> stg_ret_R1_info
                       FloatRep  -> stg_ret_F1_info
                       DoubleRep -> stg_ret_D1_info
                    where  -- TEMP HACK
                       stg_ret_R1_info = nullAddr
                       stg_ret_F1_info = nullAddr
                       stg_ret_D1_info = nullAddr
                     
--foreign label "stg_ret_R1_info" stg_ret_R1_info :: Addr
--foreign label "stg_ret_F1_info" stg_ret_F1_info :: Addr
--foreign label "stg_ret_D1_info" stg_ret_D1_info :: Addr

-- The size in bytes of an instruction.
instrSizeB :: BCInstr -> Int
instrSizeB instr
   = case instr of
        ARGCHECK _     -> 4
        PUSH_L   _     -> 4
        PUSH_LL  _ _   -> 6
        PUSH_LLL _ _ _ -> 8
        PUSH_G   _     -> 4
        SLIDE    _ _   -> 6
        ALLOC    _     -> 4
        MKAP     _ _   -> 6
        UNPACK   _     -> 4
        PACK     _ _   -> 6
        LABEL    _     -> 4
        TESTLT_I _ _   -> 6
        TESTEQ_I _ _   -> 6
        TESTLT_F _ _   -> 6
        TESTEQ_F _ _   -> 6
        TESTLT_D _ _   -> 6
        TESTEQ_D _ _   -> 6
        TESTLT_P _ _   -> 6
        TESTEQ_P _ _   -> 6
        CASEFAIL       -> 2
        ENTER          -> 2
        RETURN         -> 2


-- Sizes of Int, Float and Double literals, in units of 32-bitses
intLitSz32s, floatLitSz32s, doubleLitSz32s, addrLitSz32s :: Int
intLitSz32s    = wORD_SIZE `div` 4
floatLitSz32s  = 1	-- Assume IEEE floats
doubleLitSz32s = 2
addrLitSz32s   = intLitSz32s

-- Make lists of 32-bit words for literals, so that when the
-- words are placed in memory at increasing addresses, the
-- bit pattern is correct for the host's word size and endianness.
mkLitI :: Int    -> [Word32]
mkLitF :: Float  -> [Word32]
mkLitD :: Double -> [Word32]
mkLitA :: Addr   -> [Word32]

mkLitF f
   = runST (do
        arr <- newFloatArray ((0::Int),0)
        writeFloatArray arr 0 f
        f_arr <- castSTUArray arr
        w0 <- readWord32Array f_arr 0
        return [w0]
     )

mkLitD d
   = runST (do
        arr <- newDoubleArray ((0::Int),0)
        writeDoubleArray arr 0 d
        d_arr <- castSTUArray arr
        w0 <- readWord32Array d_arr 0
        w1 <- readWord32Array d_arr 1
        return [w0,w1]
     )

mkLitI i
   | wORD_SIZE == 4
   = runST (do
        arr <- newIntArray ((0::Int),0)
        writeIntArray arr 0 i
        i_arr <- castSTUArray arr
        w0 <- readWord32Array i_arr 0
        return [w0]
     )
   | wORD_SIZE == 8
   = runST (do
        arr <- newIntArray ((0::Int),0)
        writeIntArray arr 0 i
        i_arr <- castSTUArray arr
        w0 <- readWord32Array i_arr 0
        w1 <- readWord32Array i_arr 1
        return [w0,w1]
     )
   
mkLitA a
   | wORD_SIZE == 4
   = runST (do
        arr <- newAddrArray ((0::Int),0)
        writeAddrArray arr 0 a
        a_arr <- castSTUArray arr
        w0 <- readWord32Array a_arr 0
        return [w0]
     )
   | wORD_SIZE == 8
   = runST (do
        arr <- newAddrArray ((0::Int),0)
        writeAddrArray arr 0 a
        a_arr <- castSTUArray arr
        w0 <- readWord32Array a_arr 0
        w1 <- readWord32Array a_arr 1
        return [w0,w1]
     )
   


-- Zero-based expandable arrays
data XIOUArray ele 
   = XIOUArray { usedXIOU :: Int, stuffXIOU :: (IOUArray Int ele) }
data XIOArray ele 
   = XIOArray { usedXIO :: Int , stuffXIO :: (IOArray Int ele) }

newXIOUArray size
   = do arr <- newArray (0, size-1)
        return (XIOUArray 0 arr)

addListToXIOUArray xarr []
   = return xarr
addListToXIOUArray xarr (x:xs)
   = addToXIOUArray xarr x >>= \ xarr' -> addListToXIOUArray xarr' xs


addToXIOUArray :: MArray IOUArray a IO
                  => XIOUArray a -> a -> IO (XIOUArray a)
addToXIOUArray (XIOUArray n_arr arr) x
   = case bounds arr of
        (lo, hi) -> ASSERT(lo == 0)
                    if   n_arr > hi
                    then do new_arr <- newArray (0, 2*hi-1)
                            copy hi arr new_arr
                            addToXIOUArray (XIOUArray n_arr new_arr) x
                    else do writeArray arr n_arr x
                            return (XIOUArray (n_arr+1) arr)
     where
        copy :: MArray IOUArray a IO
                => Int -> IOUArray Int a -> IOUArray Int a -> IO ()
        copy n src dst
           | n < 0     = return ()
           | otherwise = do nx <- readArray src n
                            writeArray dst n nx
                            copy (n-1) src dst



newXIOArray size
   = do arr <- newArray (0, size-1)
        return (XIOArray 0 arr)

addToXIOArray :: XIOArray a -> a -> IO (XIOArray a)
addToXIOArray (XIOArray n_arr arr) x
   = case bounds arr of
        (lo, hi) -> ASSERT(lo == 0)
                    if   n_arr > hi
                    then do new_arr <- newArray (0, 2*hi-1)
                            copy hi arr new_arr
                            addToXIOArray (XIOArray n_arr new_arr) x
                    else do writeArray arr n_arr x
                            return (XIOArray (n_arr+1) arr)
     where
        copy :: Int -> IOArray Int a -> IOArray Int a -> IO ()
        copy n src dst
           | n < 0     = return ()
           | otherwise = do nx <- readArray src n
                            writeArray dst n nx
                            copy (n-1) src dst

\end{code}

%************************************************************************
%*									*
\subsection{Manufacturing of info tables for DataCons}
%*									*
%************************************************************************

\begin{code}

#if __GLASGOW_HASKELL__ <= 408
type ItblPtr = Addr
#else
type ItblPtr = Ptr StgInfoTable
#endif

-- Make info tables for the data decls in this module
mkITbls :: [TyCon] -> IO ItblEnv
mkITbls [] = return emptyFM
mkITbls (tc:tcs) = do itbls  <- mkITbl tc
                      itbls2 <- mkITbls tcs
                      return (itbls `plusFM` itbls2)

mkITbl :: TyCon -> IO ItblEnv
mkITbl tc
--   | trace ("TYCON: " ++ showSDoc (ppr tc)) False
--   = error "?!?!"
   | not (isDataTyCon tc) 
   = return emptyFM
   | n == length dcs  -- paranoia; this is an assertion.
   = make_constr_itbls dcs
     where
        dcs = tyConDataCons tc
        n   = tyConFamilySize tc

cONSTR :: Int
cONSTR = 1  -- as defined in ghc/includes/ClosureTypes.h

-- Assumes constructors are numbered from zero, not one
make_constr_itbls :: [DataCon] -> IO ItblEnv
make_constr_itbls cons
   | length cons <= 8
   = do is <- mapM mk_vecret_itbl (zip cons [0..])
	return (listToFM is)
   | otherwise
   = do is <- mapM mk_dirret_itbl (zip cons [0..])
	return (listToFM is)
     where
        mk_vecret_itbl (dcon, conNo)
           = mk_itbl dcon conNo (vecret_entry conNo)
        mk_dirret_itbl (dcon, conNo)
           = mk_itbl dcon conNo mci_constr_entry

        mk_itbl :: DataCon -> Int -> Addr -> IO (Name,ItblPtr)
        mk_itbl dcon conNo entry_addr
           = let (tot_wds, ptr_wds, _) 
                    = mkVirtHeapOffsets typePrimRep (dataConRepArgTys dcon)
                 ptrs = ptr_wds
                 nptrs  = tot_wds - ptr_wds
                 itbl  = StgInfoTable {
                           ptrs = fromIntegral ptrs, nptrs = fromIntegral nptrs,
                           tipe = fromIntegral cONSTR,
                           srtlen = fromIntegral conNo,
                           code0 = fromIntegral code0, code1 = fromIntegral code1,
                           code2 = fromIntegral code2, code3 = fromIntegral code3,
                           code4 = fromIntegral code4, code5 = fromIntegral code5,
                           code6 = fromIntegral code6, code7 = fromIntegral code7 
                        }
                 -- Make a piece of code to jump to "entry_label".
                 -- This is the only arch-dependent bit.
                 -- On x86, if entry_label has an address 0xWWXXYYZZ,
                 -- emit   movl $0xWWXXYYZZ,%eax  ;  jmp *%eax
                 -- which is
                 -- B8 ZZ YY XX WW FF E0
                 (code0,code1,code2,code3,code4,code5,code6,code7)
                    = (0xB8, byte 0 entry_addr_w, byte 1 entry_addr_w, 
                             byte 2 entry_addr_w, byte 3 entry_addr_w, 
                       0xFF, 0xE0, 
                       0x90 {-nop-})

                 entry_addr_w :: Word32
                 entry_addr_w = fromIntegral (addrToInt entry_addr)
             in
                 do addr <- malloc
                    --putStrLn ("SIZE of itbl is " ++ show (sizeOf itbl))
                    --putStrLn ("# ptrs  of itbl is " ++ show ptrs)
                    --putStrLn ("# nptrs of itbl is " ++ show nptrs)
                    poke addr itbl
                    return (getName dcon, addr `plusPtr` 8)


byte :: Int -> Word32 -> Word32
byte 0 w = w .&. 0xFF
byte 1 w = (w `shiftR` 8) .&. 0xFF
byte 2 w = (w `shiftR` 16) .&. 0xFF
byte 3 w = (w `shiftR` 24) .&. 0xFF


vecret_entry 0 = mci_constr1_entry
vecret_entry 1 = mci_constr2_entry
vecret_entry 2 = mci_constr3_entry
vecret_entry 3 = mci_constr4_entry
vecret_entry 4 = mci_constr5_entry
vecret_entry 5 = mci_constr6_entry
vecret_entry 6 = mci_constr7_entry
vecret_entry 7 = mci_constr8_entry

-- entry point for direct returns for created constr itbls
foreign label "stg_mci_constr_entry" mci_constr_entry :: Addr
-- and the 8 vectored ones
foreign label "stg_mci_constr1_entry" mci_constr1_entry :: Addr
foreign label "stg_mci_constr2_entry" mci_constr2_entry :: Addr
foreign label "stg_mci_constr3_entry" mci_constr3_entry :: Addr
foreign label "stg_mci_constr4_entry" mci_constr4_entry :: Addr
foreign label "stg_mci_constr5_entry" mci_constr5_entry :: Addr
foreign label "stg_mci_constr6_entry" mci_constr6_entry :: Addr
foreign label "stg_mci_constr7_entry" mci_constr7_entry :: Addr
foreign label "stg_mci_constr8_entry" mci_constr8_entry :: Addr



data Constructor = Constructor Int{-ptrs-} Int{-nptrs-}


-- Ultra-minimalist version specially for constructors
data StgInfoTable = StgInfoTable {
   ptrs :: Word16,
   nptrs :: Word16,
   srtlen :: Word16,
   tipe :: Word16,
   code0, code1, code2, code3, code4, code5, code6, code7 :: Word8
}


instance Storable StgInfoTable where

   sizeOf itbl 
      = (sum . map (\f -> f itbl))
        [fieldSz ptrs, fieldSz nptrs, fieldSz srtlen, fieldSz tipe,
         fieldSz code0, fieldSz code1, fieldSz code2, fieldSz code3, 
         fieldSz code4, fieldSz code5, fieldSz code6, fieldSz code7]

   alignment itbl 
      = (sum . map (\f -> f itbl))
        [fieldAl ptrs, fieldAl nptrs, fieldAl srtlen, fieldAl tipe,
         fieldAl code0, fieldAl code1, fieldAl code2, fieldAl code3, 
         fieldAl code4, fieldAl code5, fieldAl code6, fieldAl code7]

   poke a0 itbl
      = do a1 <- store (ptrs   itbl) (castPtr a0)
           a2 <- store (nptrs  itbl) a1
           a3 <- store (tipe   itbl) a2
           a4 <- store (srtlen itbl) a3
           a5 <- store (code0  itbl) a4
           a6 <- store (code1  itbl) a5
           a7 <- store (code2  itbl) a6
           a8 <- store (code3  itbl) a7
           a9 <- store (code4  itbl) a8
           aA <- store (code5  itbl) a9
           aB <- store (code6  itbl) aA
           aC <- store (code7  itbl) aB
           return ()

   peek a0
      = do (a1,ptrs)   <- load (castPtr a0)
           (a2,nptrs)  <- load a1
           (a3,tipe)   <- load a2
           (a4,srtlen) <- load a3
           (a5,code0)  <- load a4
           (a6,code1)  <- load a5
           (a7,code2)  <- load a6
           (a8,code3)  <- load a7
           (a9,code4)  <- load a8
           (aA,code5)  <- load a9
           (aB,code6)  <- load aA
           (aC,code7)  <- load aB
           return StgInfoTable { ptrs = ptrs, nptrs = nptrs, 
                                 srtlen = srtlen, tipe = tipe,
                                 code0 = code0, code1 = code1, code2 = code2,
                                 code3 = code3, code4 = code4, code5 = code5,
                                 code6 = code6, code7 = code7 }

fieldSz :: (Storable a, Storable b) => (a -> b) -> a -> Int
fieldSz sel x = sizeOf (sel x)

fieldAl :: (Storable a, Storable b) => (a -> b) -> a -> Int
fieldAl sel x = alignment (sel x)

store :: Storable a => a -> Ptr a -> IO (Ptr b)
store x addr = do poke addr x
                  return (castPtr (addr `plusPtr` sizeOf x))

load :: Storable a => Ptr a -> IO (Ptr b, a)
load addr = do x <- peek addr
               return (castPtr (addr `plusPtr` sizeOf x), x)

\end{code}

%************************************************************************
%*									*
\subsection{Connect to actual values for bytecode opcodes}
%*									*
%************************************************************************

\begin{code}

#include "Bytecodes.h"

i_ARGCHECK = (bci_ARGCHECK :: Int)
i_PUSH_L   = (bci_PUSH_L :: Int)
i_PUSH_LL  = (bci_PUSH_LL :: Int)
i_PUSH_LLL = (bci_PUSH_LLL :: Int)
i_PUSH_G   = (bci_PUSH_G :: Int)
i_PUSH_AS  = (bci_PUSH_AS :: Int)
i_PUSH_UBX = (bci_PUSH_UBX :: Int)
i_PUSH_TAG = (bci_PUSH_TAG :: Int)
i_SLIDE    = (bci_SLIDE :: Int)
i_ALLOC    = (bci_ALLOC :: Int)
i_MKAP     = (bci_MKAP :: Int)
i_UNPACK   = (bci_UNPACK :: Int)
i_UPK_TAG  = (bci_UPK_TAG :: Int)
i_PACK     = (bci_PACK :: Int)
i_LABEL    = (bci_LABEL :: Int)
i_TESTLT_I = (bci_TESTLT_I :: Int)
i_TESTEQ_I = (bci_TESTEQ_I :: Int)
i_TESTLT_F = (bci_TESTLT_F :: Int)
i_TESTEQ_F = (bci_TESTEQ_F :: Int)
i_TESTLT_D = (bci_TESTLT_D :: Int)
i_TESTEQ_D = (bci_TESTEQ_D :: Int)
i_TESTLT_P = (bci_TESTLT_P :: Int)
i_TESTEQ_P = (bci_TESTEQ_P :: Int)
i_CASEFAIL = (bci_CASEFAIL :: Int)
i_ENTER    = (bci_ENTER :: Int)
i_RETURN   = (bci_RETURN :: Int)

\end{code}
