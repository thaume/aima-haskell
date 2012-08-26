{-# LANGUAGE ScopedTypeVariables #-}

module AI.Learning.NeuralNetwork where

import Control.Monad.Random hiding (fromList)
import Numeric.LinearAlgebra
import Numeric.LinearAlgebra.Util
import Numeric.GSL.Minimization
import System.IO.Unsafe

import AI.Util.Matrix

-- |Representation for a single-hidden-layer neural network. If the network
--  has K input nodes, H hidden nodes and L output layers then the dimensions
--  of the matrices theta0 and theta1 are
--
--  * size theta0 = (K+1) x H
--  * size theta1 = (H+1) x L
--
--  the (+1)s account for the addition of bias nodes in the input layer and
--  the hidden layer. Therefore the total number of parameters is
--  H(K + L + 1) + L
data NeuralNetwork = NN (Matrix Double) (Matrix Double)

type NNShape = (Int,Int,Int)

instance Show NeuralNetwork where
    show (NN theta0 theta1) = "Neural Net:\n\n" ++ dispf 3 theta0 ++
                                           "\n" ++ dispf 3 theta1

-- |Make a prediction using a neural network.
nnPredict :: NeuralNetwork -> Matrix Double -> Matrix Double
nnPredict nn x = h where (_,_,h) = nnForwardProp nn x

-- |Perform forward propagation through a neural network, returning the matrices
--  created in the process.
nnForwardProp :: NeuralNetwork                                 -- neural net
              -> Matrix Double                                 -- design matrix (x)
              -> (Matrix Double, Matrix Double, Matrix Double) -- results of fwd prop
nnForwardProp (NN theta0 theta1) x = (a0,a1,a2)
    where a0 = addOnes $ x
          a1 = addOnes $ sigmoid (a0 <> theta0)
          a2 = sigmoid (a1 <> theta1)

-- |Perform backward propagiation through a neural network. You must supply the
--  target values and the results of forward propagation for each layer, and
--  the function returns the gradient matrices for the neural network.
nnBackProp :: NeuralNetwork                                 -- neural net
           -> Matrix Double                                 -- target (y)
           -> (Matrix Double, Matrix Double, Matrix Double) -- results of fwd prop
           -> (Matrix Double, Matrix Double)                -- gradient (delta0, delta1)
nnBackProp (NN _ theta1) y (a0,a1,a2) = (dropColumns 1 delta0, delta1)
    where
        d2     = a2 - y
        d1     = (d2 <> trans theta1) * a1 * (1 - a1)
        delta0 = trans a0 <> d1
        delta1 = trans a1 <> d2

-- |Perform back and forward propagation through a neural network, returning the
--  final predictions (variable /a2/) and the gradient matrices (variables
--  /delta0/ and /delta1/) produced.
nnFwdBackProp :: NeuralNetwork -> Matrix Double -> Matrix Double -> (Matrix Double, Matrix Double, Matrix Double)
nnFwdBackProp nn@(NN theta0 theta1) y x = (a2, delta0, delta1)
    where
        (a0,a1,a2)      = nnForwardProp nn x
        (delta0,delta1) = nnBackProp nn y (a0,a1,a2)

fromVector :: NNShape -> Vector Double -> NeuralNetwork
fromVector (k,h,l) vec = NN theta0 theta1
    where theta0 = reshape h $ takeVector ((k + 1) * h) vec
          theta1 = reshape l $ dropVector ((k + 1) * h) vec

toVector :: Matrix Double -> Matrix Double -> Vector Double
toVector theta0 theta1 = join [flatten theta0, flatten theta1]

-- |Back-propagation. Used to compute the cost function and gradient for the
--  neural network. The size of the matrices is as follows:
--
--  * theta0 is (K+1) x H
--  * theta1 is (H+1) x L
--  * a0 is T x K
--  * a1 is T x H
--  * a2 is T x L
--  * d2 is T x L
--  * d1 is T x (H+1)
--  * delta0 is (K+1) x (H+1)
--  * delta1 is (H+1) x L
nnCostGradient :: NNShape                   -- (K,H,L)
               -> Matrix Double             -- targets (y)
               -> Matrix Double             -- design matrix (x)
               -> Double                    -- regularization parameter (lambda)
               -> Vector Double             -- neural network
               -> (Double, Vector Double)   -- (cost, gradient)
nnCostGradient shape y x lambda vec = (cost, grad)
    where
        m = fromIntegral (rows x)
        nn@(NN theta0 theta1) = fromVector shape vec
        (h, delta0, delta1)   = nnFwdBackProp nn y x

        cost  = (cost1 + cost2) / m
        cost1 = negate $ sumMatrix $ y * log h + (1-y) * log (1-h)
        cost2 = lambda/2 * (normMatrix theta0 + normMatrix theta1)

        grad  = (1/m) `scale` (grad1 + grad2)
        grad1 = toVector delta0 delta1
        grad2 = lambda `scale` toVector (vertcat [0, dropRows 1 theta0]) (vertcat [0, dropRows 1 theta1])

        normMatrix m = sumMatrix $ (dropRows 1 m) ^ 2

nnCost :: NNShape -> Matrix Double -> Matrix Double -> Double -> Vector Double -> Double
nnCost shape y x lambda vec = cost
    where
        m = fromIntegral (rows x)
        nn@(NN theta0 theta1) = fromVector shape vec
        h = nnPredict nn x

        cost = (cost1 + cost2) / m
        cost1 = negate $ sumMatrix $ y * log h + (1-y) * log (1-h)
        cost2 = lambda/2 * (normMatrix theta0 + normMatrix theta1)

        normMatrix m = sumMatrix $ (dropRows 1 m) ^ 2 

nnGradApprox :: NNShape -> Matrix Double -> Matrix Double -> Double -> Vector Double -> Vector Double
nnGradApprox shape y x lambda vec = fromList $ g `map` [0..n-1]
    where
        h = 1e-4
        n = dim vec
        f v = nnCost shape y x lambda v
        g i = (f (vec + e i) - f (vec - e i)) / (2*h)
        e i = fromList $ replicate i 0 ++ [h] ++ replicate (n-i-1) 0


--nnCost shape y x lambda (NN a b) = fst $ nnCostGradient shape y x lambda (toVector a b)
--nnGrad shape y x lambda (NN a b) = snd $ nnCostGradient shape y x lambda (toVector a b)

-- |Train a neural network from input vectors.
nnTrain :: NNShape -> Matrix Double -> Matrix Double -> Double -> IO NeuralNetwork
nnTrain shape y x lambda = do
    let prec    = 1e-9
        niter   = 1000
        sz1     = 0.1
        tol     = 0.1
        cost    = fst . nnCostGradient shape y x lambda
        grad    = snd . nnCostGradient shape y x lambda
        -- cost    = nnCost shape y x lambda
        -- grad    = nnGrad shape y x lambda
    vec0 <- initialVec shape
    let vec = fst $ minimizeVD VectorBFGS2 prec niter sz1 tol cost grad vec0
    return $ fromVector shape vec

initialVec :: NNShape -> IO (Vector Double)
initialVec (k,h,l) = do
    let len = h * (k + l) + h + l
    xs <- getRandomRs (0.0, 0.01)
    return . fromList $ take len xs

---------------
-- Utilities --
---------------

-- |Sigmoid function that acts on matrices.
sigmoid :: Floating a => a -> a
sigmoid x = 1 / (1 + exp (-x))

-------------
-- Testing --
-------------

testNN :: NeuralNetwork
testNN = NN t0 t1
    where t0 = fromLists [[11.9934, -5.1396], [-7.7162, 10.1512], [-7.668, 10.1835]]
          t1 = fromLists [[-16.8806], [10.0445], [8.7476]]

testFwdProp :: IO ()
testFwdProp = do
    putStrLn "***\nCompare forward propagation to the MATLAB implementation.\n"
    let theta0 = fromLists [[0], [-10]]
        theta1 = fromLists [[5],[-10]]
        nn = NN theta0 theta1
        x = fromLists [[-1],[0],[1]]
    -- sigmoid [10, 0, -10] = [1, 0.5, 0]
    -- sigmoid [-5, 0, 5]  = [0.0, 0.5, 1]
    let y = nnPredict nn x
    putStrLn "Predictions (should be roughly 0.0, 0.5, 1.0)"
    disp 2 y
    
testBackProp :: IO ()
testBackProp = do
    putStrLn "***\nCompare back propagation to the MATLAB implementation.\n"
    let nn = testNN
        x  = fromLists [[0, 0], [0, 1], [1, 0], [1, 1]]
        y  = fromLists [[0], [1], [1], [0]]
        (h, delta0, delta1) = nnFwdBackProp nn y x
    putStrLn "Predictions (should be 0.0011, 0.8487, 0.8476, 0.0004)"
    disp 4 h
    putStrLn "Delta 0 (should be -0.0401, -0.0171, -0.0205, -0.0088, -0.0195, -0.0084)"
    disp 4 delta0
    putStrLn "Delta 1 (should be -0.3022, -0.2985, -0.3013)"
    disp 4 delta1

testCostGradient :: IO ()
testCostGradient = do
    putStrLn "***\nTest cost/gradient against the MATLAB implementation.\n"
    let nn@(NN theta0 theta1) = testNN
        x = fromLists [[0, 0], [0, 1], [1, 0], [1, 1]]
        y = fromLists [[0], [1], [1], [0]]
        lambda = 1e-4
        (cost, grad) = nnCostGradient (2,2,1) y x lambda (toVector theta0 theta1)
    putStrLn "Cost (should be around 0.0890)"
    print cost
    putStrLn "Gradient (should be -0.0100, -0.0043, -0.0053, -0.0019, -0.0051, -0.0019, -0.0755, -0.0744, -0.0751)"
    disp 4 (column grad)

test :: Int -> Double -> IO ()
test n lambda = do
    putStrLn "***\nLearning XOR function.\n"
    x <- rand n 2
    e <- fmap (0.01*) (rand n 1)
    let y = mapMatrix (\x -> if x > 0.5 then 1.0 else 0.0) (xor x)
    nn <- nnTrain (2,4,1) y x lambda
    let ypred = nnPredict nn x
    -- Show predictions
    putStrLn "Predictions:"
    disp 2 $ takeRows 10 $ horzcat [x, y, ypred]
    -- Show neural net
    print nn
    -- Final test; should approximately compute xor function
    let xx = fromLists [[0,0],[0,1],[1,0],[1,1]]
        yy = nnPredict nn xx
    putStrLn "Exclusive or:"
    disp 2 $ horzcat [xx,yy]
    
xor :: Matrix Double -> Matrix Double
xor x = let [u,v] = toColumns x in column (u + v - 2 * u * v)
    