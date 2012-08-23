{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RankNTypes #-}

module HMine.Evaluation.Crossvalidation
    where

import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map as Map
import qualified Data.Set as S
-- import qualified Data.Vector as V

import Control.DeepSeq
import Control.Exception
import Control.Monad
import Control.Monad.ST
import Data.Array.ST
import Data.Binary
import Data.List
import Data.Monoid
import Debug.Trace
import System.IO
import System.IO.Unsafe

import HMine.Base
import HMine.DataContainers
import HMine.Classifiers.TypeClasses
import HMine.Classifiers.Ensemble
import HMine.Evaluation.Metrics
import HMine.MiscUtils

-------------------------------------------------------------------------------

class (NFData a) => Averageable a where
    ave :: [a] -> (a,a)
    
instance Averageable Double where
    ave = meanstddev
    
instance Averageable [Double] where
    ave xs = (map mean $ transpose xs, map stddev $ transpose xs)

meanstddev :: (Floating a) => [a] -> (a,a)
meanstddev xs = (mean xs, stddev xs)

-------------------------------------------------------------------------------
-- standard k-fold cross validation

crossValidation :: 
    ( NFData model
    , Averageable measure
    , DataSparse label ds label
    , DataSparse label ds DPS
    , DataSparse label ds (LDPS label)
    , DataSparse label ds (WLDPS label)
    , BatchTrainer modelparams model label
    ) =>
     (model -> ds (LDPS label) -> measure)
     -> modelparams
     -> ds (LDPS label)
     -> Double
     -> Int
     -> HMine (measure,measure)
crossValidation metric modelparams trainingdata trainingRatio rounds = do
    res <- sequence [ do
            (trainingdata,testdata) <- randSplit trainingRatio trainingdata
            ret <- runTest metric modelparams trainingdata testdata
            return $ deepseq ret  ret
        | i <- [1..rounds]
        ]
    return $ ave res

runTest metric modelparams trainingdata testdata = do
    model <- trainBatch modelparams trainingdata
    return $ deepseq model $ metric model testdata

-------------------------------------------------------------------------------
-- Monoidal cross validation

crossValidation_monoidal ::
    ( MutableTrainer modelparams model modelST label
    , ProbabilityClassifier model label
    , Monoid model
    , DataSparse label ds (LDPS label)
    , DataSparse label ds (UDPS label)
    , DataSparse label ds [(label,Probability)]
    , DataSparse label ds label
    , NFData model
    ) =>
    modelparams -> ds (LDPS label) -> Int -> [Double]
crossValidation_monoidal modelparams lds folds = [logloss (modelItr modelL i) (testdata ldsL i) | i<-[0..folds-1]]
    where
        foldLen = ceiling $ (fromIntegral $ getNumObs lds)/(fromIntegral folds)
        ldsL = splitds foldLen lds
        modelL = map (trainST modelparams) ldsL
        
{-        testdata :: 
            ( DataSparse label ds (LDPS label)
            , DataSparse label ds (UDPS label)
            , DataSparse label ds [(label,Probability)]
            ) => 
            Int -> ds (LDPS label)-}
        testdata :: [a] -> Int -> a
        testdata ldsL itr = snd . head $ filter ((==) itr . fst) $ zip [0..] ldsL
--         testdata ldsL itr = ldsL !! itr

        modelItr :: (Monoid model) => [model] -> Int -> model
        modelItr modelL itr = mconcat $ map snd $ filter ((/=) itr . fst) $ zip [0..] modelL
            