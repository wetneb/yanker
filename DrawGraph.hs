module DrawGraph where

-- Data structures
import Data.List as List
import Data.Set as Set
import qualified Data.Map.Strict as Map
import OpenGraph as OG
import GraphPresentation

-- GUI / Rendering stuff
import Graphics.Rendering.Cairo
import Control.Concurrent.MVar
import Graphics.UI.Gtk.Gdk.EventM
import Graphics.UI.Gtk.Abstract.Widget


-- Current state of the pointer
data DrawingState = DSelect | DMoving OId | DNode | DEdge | DDrawing OPath Double Double
     deriving (Eq)

-- Current state of the object selection
data ElemSelection = SelectNode OId | SelectEdge OPath | NoSelection

-- Global state of the graph editor
data GraphState = GraphState {
       totalGraph :: OGraph,
       presentation :: GraphPresentation,
       selection :: ElemSelection,
       nodeBB :: (Map.Map OId BoundingBox),
       gateBB :: (Map.Map OPath BoundingBox),
       lastMouse :: (Double,Double) }


seqInt 0 accu = accu
seqInt n accu = seqInt (n-1) (n:accu)

doList f = List.foldl (\ accu elem -> accu >> (f elem)) (return ())
doSet f = Set.foldl (\ accu elem -> accu >> (f elem)) (return ())

-- Draw a node onscreen
drawNode :: Double -> Double -> Int -> Int -> Render ()
drawNode posX posY 0 0 = do
    setSourceRGB 0 0 0
    setLineWidth 1
    
    moveTo posX posY
    relMoveTo 0 (-nodeSemiHeight)
    relLineTo nodeSemiHeight nodeSemiHeight
    relLineTo (-nodeSemiHeight) nodeSemiHeight
    relLineTo (-nodeSemiHeight) (-nodeSemiHeight)
    relLineTo (2*nodeSemiHeight) 0
    relMoveTo (-2*nodeSemiHeight) 0
    relLineTo nodeSemiHeight (-nodeSemiHeight)

    stroke
  
drawNode posX posY nInputs nOutputs = do
    setSourceRGB 0 0 0
    setLineWidth 1
    let height = (nodeSemiHeight*2)
    let topWidth = ((fromIntegral nInputs+1)*nodeGateSpacing)
    let bottomWidth = ((fromIntegral nOutputs+1)*nodeGateSpacing)

    moveTo posX posY
    relMoveTo (topWidth/2) (-nodeSemiHeight)
    relLineTo (bottomWidth/2 - topWidth/2) height
    relLineTo (-bottomWidth) 0
    relLineTo ((bottomWidth - topWidth) /2) (-height)
    relLineTo topWidth 0
    -- closePath

    stroke

    doList (\ x -> do
       moveTo (posX-(bottomWidth/2)+x) (posY+nodeSemiHeight)
       relLineTo 0 nodeGateVertOffset) .
       List.map (* nodeGateSpacing) .
       (List.map fromIntegral) $ (seqInt nOutputs [])

    doList (\ x -> do
       moveTo (posX-(topWidth/2)+x) (posY-nodeSemiHeight)
       relLineTo 0 (-nodeGateVertOffset)) .
       List.map (* nodeGateSpacing) .
       (List.map fromIntegral) $ (seqInt nInputs [])

-- Draw an outer gate
drawGate :: Double -> Double -> Render ()
drawGate posX posY = do
    setSourceRGB 1 0 0
    arc posX posY gateRadius 0 (2*3.14159)
    fill

-- Add indexes to elements of a list
indexList :: Num b => [a] -> [(a,b)]
indexList = indexList_accu 0
   where
     indexList_accu curId [] = []
     indexList_accu curId (h:t) = (h,curId):(indexList_accu (curId+1) t)


-- Draw an edge
drawEdge :: OGraph -> GraphPresentation -> OEdge -> Render ()
drawEdge graph pres (OEdge from to) = do
    let (fromX,fromY) = getGatePos graph pres from
    let (toX,toY) = getGatePos graph pres to
    setSourceRGB 0 0 0
    setLineWidth 1
    moveTo fromX fromY
    lineTo toX toY
    stroke

-- Draw a graph given its presentation
drawGraph g@(OGraph gates nodes edges) presentation = do
    setSourceRGB 1 1 1
    paint
    drawGates topOuterGates (producers gates)
    drawGates bottomOuterGates (consumers gates)
    doList (\ (id,ONode s gates) ->
        let Just (posX,posY) = Map.lookup id presentation in
        drawNode posX posY (fromIntegral . length $ (producers gates))
                           (fromIntegral . length $ (consumers gates)))
           nodes
    doSet (drawEdge g presentation) edges
    where
     drawGates position =
      doList (\ ((OGate s _),id) ->
          drawGate (outerGateOffset + outerGateSpacing*id) position) .
      indexList

-- Find an element in a set satisfying a predicate
findSet predicate = Set.foldl (\ accu elem -> if (predicate elem) then Just elem else accu) Nothing

-- Draw the current selection
drawSelection _ NoSelection = return ()
drawSelection bounds (SelectNode id) =
    case (Map.lookup id bounds) of
     Nothing -> return ()
     Just (BBox startx starty width height) -> do
       setSourceRGB 0.5 0.5 0.5
       moveTo startx starty
       relLineTo width 0
       relLineTo 0 height
       relLineTo (-width) 0
       closePath
       stroke
drawSelection _ _ = return ()

-- Draw the whole scene (graph and selection if any)
drawScene drawStateM gsM = do
    gs <- liftIO (readMVar gsM)
    let (x,y) = lastMouse gs
    drawState <- liftIO (readMVar drawStateM)
    drawGraph (totalGraph gs) (presentation gs)
    drawSelection (nodeBB gs) (selection gs)
    case drawState of
      DDrawing _ origX origY -> do
         setSourceRGB 0 0 0
         setLineWidth 1
         moveTo origX origY
         lineTo x y
         stroke
      DNode -> do
         drawNode x y 0 0
      _ -> return ()

updateScene drawStateM gsM drawWidget = do
    (x,y) <- eventCoordinates
    liftIO $ modifyMVar_ gsM (\gs -> return $ gs { lastMouse = (x,y) })
    drawState <- liftIO $ readMVar drawStateM
    case drawState of
      DDrawing _ _ _ -> liftIO $ widgetQueueDraw drawWidget
      DNode -> liftIO $ widgetQueueDraw drawWidget
      _ -> return ()
    return True


-- Create a new graph state based on an input graph and a presentation
createGraphState g@(OGraph gates nodes edges) pres = 
    GraphState g pres NoSelection nodeBB gateBB (0,0)
    where
      nodeBB = List.foldl (\ m n -> Map.insert (fst n) (boundingBoxFromNode pres n) m)
                         Map.empty
                         nodes
      addGates boundMap nodeId gates = List.foldl (\ bm (OGate n _) ->
            Map.insert (OPath nodeId n) (boundingBoxFromGate g pres (OPath nodeId n)) bm)
                       boundMap
                       gates
      gateBB = List.foldl (\ m (id,ONode _ gates) -> addGates m id gates) outerGatesBB nodes
      outerGatesBB = addGates Map.empty boundaryId gates


-- Make an edge out of two gates, if there is one
-- (one has to be producer, the other consumer)
-- and no edge is currently bound to the consumer
makeEdge graph path1 path2 =
    case (getGate path1 graph, getGate path2 graph) of
     (Just True, Just False) ->
         if checkAddEdge graph (OEdge path1 path2) then
           Just $ OEdge path1 path2
         else
           Nothing 
     (Just False, Just True) ->
         if checkAddEdge graph (OEdge path2 path1) then
           Just $ OEdge path2 path1
         else
           Nothing
     _ -> Nothing

-- Handle a click based on the current state
handleClick drawStateM gsM drawWidget= do
    coords <- eventCoordinates
    let (x,y) = coords
    st <- liftIO (readMVar drawStateM)
    gs <- liftIO (readMVar gsM)
    let gotoState newState = modifyMVar_ drawStateM (\_ -> return newState)
    let setGS newGS = modifyMVar_ gsM (\_ -> return newGS)

    liftIO $ case st of
      DNode -> do
        let (OGraph gates nodes edges) = totalGraph gs
        let pres = presentation gs
        let newId = maxOId nodes + 1
        let newGraph = OGraph gates ((newId,(ONode "" [])):nodes) edges
        let newPres = Map.insert newId coords pres
        let newNodeBB = Map.insert newId (makeNodeBoundingBox 0 0 x y) (nodeBB gs)
        setGS (gs { totalGraph = newGraph,
                    presentation = newPres,
                    nodeBB = newNodeBB })
        widgetQueueDraw drawWidget
      DSelect -> do
        let searchResult = findBoundingBox x y (nodeBB gs)
        newSelection <- return (case searchResult of
          Nothing -> NoSelection
          Just id -> SelectNode id)
        setGS (gs { selection = newSelection })
        widgetQueueDraw drawWidget
      DEdge -> do
        let searchResult = findBoundingBox x y (gateBB gs)
        gotoState $ case searchResult of
          Nothing -> DEdge
          Just path -> DDrawing path x y
      DDrawing gate _ _ -> do
        let searchResult = findBoundingBox x y (gateBB gs)
        let graph = totalGraph gs
        case (searchResult >>= (makeEdge graph gate)) of
          Nothing ->
             gotoState DEdge
          Just edge -> do
             putStrLn ("Current edges list is "++(show $ edgesList graph))
             let graph = totalGraph gs
             setGS (gs { totalGraph = graph { edgesList=Set.insert edge (edgesList graph) } })
             gotoState DEdge
        widgetQueueDraw drawWidget
      _ -> putStrLn ("Click handled at position " ++ (show coords))
    return True
