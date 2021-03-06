{-# LANGUAGE DeriveGeneric #-}

module OpenGraph where

import Data.List
import Data.Maybe
import Data.Binary
import Control.Exception
import qualified Data.Set as Set
import GHC.Generics as GGen
import Data.Serialize
import Utilities

-- Internal identifiers (pointers) for nodes
type OId = Int
boundaryId = 0

-- Gate in a node of a graph: produces or consumes an entity. True when it produces
data OGate = OGate String Bool
   deriving (Eq, Show, GGen.Generic)
instance Binary OGate

-- Negates a gate
neg :: OGate -> OGate
neg (OGate s b) = OGate s (not b)
-- Selects only producer (resp. consumer) gates in a list
producers :: [OGate] -> [OGate]
producers = filter (\ (OGate _ b) -> b)
consumers :: [OGate] -> [OGate]
consumers = filter (\ (OGate _ b) -> not b)

-- Node in a graph: a name (not used internally) and a bunch of gates
data ONode = ONode String [OGate]
   deriving (Eq,Show, GGen.Generic)
instance Binary ONode

-- Turns a node upside down: negates its gates
flip :: ONode -> ONode
flip (ONode name gates) = ONode name (map neg gates)

-- Path in a graph: the identifier of a node plus the name of the corresponding gate
data OPath = OPath OId String
   deriving (Eq,Ord,Show,GGen.Generic)
instance Binary OPath

-- Edge in a graph: path to a producer and path to a consumer
data OEdge = OEdge OPath OPath
   deriving (Eq,Ord,Show,GGen.Generic)
instance Binary OEdge

-- Open graph: a list of gates as boundaries, a list of nodes, and a list of edges
data OGraph = OGraph {
     boundaryGates :: [OGate],
     nodesList :: [(OId,ONode)],
     edgesList :: (Set.Set OEdge)}
   deriving (Eq,Show,GGen.Generic)
instance Binary OGraph
-- All the nodes, including a fake node for the boundary
nodesAndBoundary :: OGraph -> [(OId,ONode)]
nodesAndBoundary (OGraph boundary nodes _) =
   (boundaryId,(ONode "" boundary)):nodes

-- Get the polarity of a gate (if it exists)
getGate :: OPath -> OGraph -> Maybe Bool
getGate (OPath nodeId gateName) (OGraph boundaryGates nodes _) =
   find (\ (id,_) -> id == nodeId) ((boundaryId,(ONode "" boundaryGates)):nodes)
   >>= (\ (_,(ONode _ gates)) -> find (\ (OGate s b) -> s == gateName) gates)
   >>= (\ (OGate _ b) -> Just b)


hasEdge edges path productive =
   if productive then
       countSet (\ (OEdge from to) -> from == path) edges >= 1
   else
       countSet (\ (OEdge from to) -> to == path) edges == 1

-- Check that a graph is valid, i.e. that:
-- 1/ all edges are linked to valid nodes
-- 2/ all producer gates are linked to at least one consumer gate
-- 3/ all consumer gates are linked to exactly one producer gate
checkGraph g@(OGraph boundary nodes edges) =
    allSet isValidEdge edges &&
    all (\ (nodeId,(ONode _ gates)) ->
          all (\ (OGate gateName productive) ->
                hasEdge edges (OPath nodeId gateName) productive)
              gates)
        allNodes
    where
      isValidEdge (OEdge from to) =
        (polarityFrom >>= (return . not)) == polarityTo
        where polarityFrom = getGate from g
              polarityTo = getGate to g

      allNodes = nodesAndBoundary g
      
-- Check if we can add an edge to the graph
checkAddEdge g@(OGraph _ _ edges) (OEdge from to) =
    (countSet (\ (OEdge f t) -> t == to)  edges) == 0

-- Get a fresh name of a gate for a specific node
freshGateName g@(OGraph _ nodes _) oid =
    find (\(id,_) -> id == oid) nodes
    >>= (\ (_,ONode _ gates) ->
     (return $ foldl (\ accu (OGate name _) ->
                 case (maybeRead name :: (Maybe Int)) of
                   Just num -> if accu <= num then (num+1) else accu
                   Nothing -> accu)
                0
                gates))
     >>= return . show

-- Get the maximum id attributed to a node
maxOId nodesList =
  maximum (0:(map fst nodesList))

-- Shift the indices of a graph (but the boundary)
shiftGraph offset (OGraph bound nodes edges) =
  OGraph bound newNodes newEdges
  where
      translateId id = if id == boundaryId then id else id + offset
      translatePath (OPath id gate) = OPath (translateId id) gate
      translateEdge (OEdge from to) = OEdge (translatePath from) (translatePath to)
      translateNode (id,node) = (translateId id,node)
      newNodes = map translateNode nodes
      newEdges = Set.map translateEdge edges

-- Vertical composition of two open graphs (if defined)
(vertComp) (OGraph boundA nodesA edgesA) b@(OGraph boundB nodesB edgesB) =
  if producers boundA /= consumers boundB then
    Nothing
  else
    Just (OGraph newBound newNodes newEdges) -- newNodes newEdges
    where
      OGraph _ nodesBShifted edgesBShifted = shiftGraph (maxOId nodesA) b
      newBound = (consumers boundA) ++ (producers boundB)
      newEdgesB = concatSet . Set.map (joinPath edgesA False) $ edgesBShifted
      newEdgesA = concatSet . Set.map (joinPath edgesB True) $ edgesA
      newEdges = Set.union newEdgesA newEdgesB
      newNodes = nodesA ++ nodesBShifted
      joinPath otherEdges productive edge = case edge of
        -- fromPath -> fromGate -> to
        OEdge fromGate@(OPath boundaryId _) to | (not productive) ->
          Set.map (\ (OEdge fromPath _) -> OEdge fromPath to)
              (Set.filter (\ (OEdge _ eTo) -> eTo == fromGate) otherEdges)
        -- from -> toGate -> toPath
        OEdge from toGate@(OPath boundaryId _) | productive ->
          Set.map (\ (OEdge _ toPath) -> OEdge from toPath)
              (Set.filter (\ (OEdge eFrom _) -> eFrom == toGate) otherEdges)
        another -> Set.singleton another

-- Horizontal composition of two open graphs (always defined)
(horiComp) (OGraph boundA nodesA edgesA) (OGraph boundB nodesB edgesB) =
  OGraph bound nodes edges
  where
    bound = (map (\ (OGate name b) -> (OGate ("0"++name) b)) boundA) ++
            (map (\ (OGate name b) -> (OGate ("1"++name) b)) boundB)
    nodes = nodesA ++ nodesB
    edges = Set.union (Set.map (translateEdge "0") edgesA) (Set.map (translateEdge "1") edgesB)
    translateEdge prefix (OEdge from to) = OEdge (translatePath prefix from)
                                                 (translatePath prefix to)
    translatePath prefix (OPath id name) =
       if id == boundaryId then
          OPath id (prefix ++ name)
       else
          OPath id name

-- Get the position (and whether it is a producer or not) of a gate given its name
-- and the list of gates of its node
    -- BOUNDARY VERSION
findGateNameBoundary :: Num a => String -> [OGate] -> Maybe (a,Bool)
findGateNameBoundary = findGateName_accu 0
  where
    findGateName_accu accu name [] = Nothing
    findGateName_accu accu name ((OGate s b):t) =
      if s == name then Just (accu, b)
      else
        findGateName_accu (accu+1) name t

-- Get the position (and whether it is a producer or not) of a gate given its name
-- and the list of gates of its node
findGateName :: Num a => String -> [OGate] -> Maybe (a,Bool)
findGateName = findGateName_accu (0,0)
  where
    findGateName_accu accu name [] = Nothing
    findGateName_accu (accu1,accu2) name ((OGate s b):t) =
      if s == name then Just (if b then accu1 else accu2, b)
      else if b then
        findGateName_accu (accu1+1,accu2) name t
      else
        findGateName_accu (accu1,accu2+1) name t

-- Outputs the graph to dotty
toDotty (OGraph bound nodes edges) =
   "/* Output generated by http://github.com/wetneb/yanker */\ndigraph G {\n" ++
   (Set.foldl (\ accu (OEdge from to) -> "\"" ++ (pPath from) ++ "\" -> \"" ++ (pPath to) ++"\";\n") "" edges) ++
   "}\n"
   where
    pPath (OPath id gate) = show id


      
        