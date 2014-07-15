module Main where

import Graphics.UI.Gtk
import Graphics.UI.Gtk.Gdk.EventM
import Graphics.UI.Gtk.ModelView as Model
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.State
import Text.ParserCombinators.Parsec
import Data.Set as Set
import Data.Map as Map
import Data.Foldable as Fold
import Control.Concurrent.MVar
import Control.Concurrent.MVar

import DrawGraph
import OpenGraph
import TypeHierarchy
import TypeDatabase
import Data.List as List

-- The type of an entry in the type list,
-- storing its number of occurrences, visibility
-- and the index of the first skeleton matching it
data TypeEntry = TypeEntry {
    nbOccurrences :: Int
  , lambekType :: LambekFun
  , currentlyVisible :: Bool
  , firstSkelIndex :: Int }

defaultGraphState :: GraphState
defaultGraphState =
    let initSkel = LSVar 1 in
    createGraphState (emptyGraphFromSkel initSkel) Map.empty initSkel

emptyGraphFromSkel :: LambekSkel -> OGraph
emptyGraphFromSkel sk =
  OGraph (reverse gates) [] (Set.empty)
  where
    (gates,_) = dfs [] 1 False sk
    dfs :: [OGate] -> Int -> Bool -> LambekSkel -> ([OGate],Int)
    dfs accu count productive (LSAtom base _) =
      ((OGate (base ++ (show count)) productive):accu, count+1)
    dfs accu count productive (LSVar name) =
      ((OGate ((show name) ++ "-" ++ (show count)) productive):accu, count+1)
    dfs accu count productive (LSLeft body argument) =
      let (accu2,count2) = dfs accu count (not productive) argument in
      dfs accu2 count2 productive body
    dfs accu count productive (LSRight body argument) =
      let (accu2,count2) = dfs accu count productive body in
      dfs accu2 count2 (not productive) argument

loadTypeDatabase :: IO [TypeEntry]
loadTypeDatabase = do
    typeFile <- readFile "data/short.types.db"
    typeLines <- return $ lines typeFile
    let typeDB = sequence . List.map (parse parserWithEof "") $ typeLines
    case typeDB of
       Left error -> do
         print error
         return []
       Right db -> do
         -- putStrLn (show db)
         return db
    where
      parserWithEof = do
        (a,b) <- parserLineDB
        eof
        return $ TypeEntry a b True 0 -- True is the default visibility

createAddDialog builder skelStore typeStore = do -- skelUniqueId = do
    builderAddFromFile builder "gui/add-skeleton-dialog.glade"
    addSkeletonDialog <- builderGetObject builder castToDialog "dialog1"
    cancelButton <- builderGetObject builder castToButton "buttoncancel"
    addButton <- builderGetObject builder castToButton "buttonadd"
    lineEntry <- builderGetObject builder castToEntry "entry1"
    -- Connect signals to callbacks (add dialog)
    on addSkeletonDialog objectDestroy (widgetHide addSkeletonDialog)
    on cancelButton buttonActivated (widgetHide addSkeletonDialog)
    on addButton buttonActivated (tryAdd addSkeletonDialog lineEntry)
    widgetShowAll addSkeletonDialog
    where
      tryAdd dialog lineEntry = do
        contents <- entryGetText lineEntry
        let parseResult = parse parserLS "(unknown)" contents
        case parseResult of
          Left error -> print error
          Right lambekSkel -> do
            appendToStore lambekSkel
            putStrLn (show lambekSkel)
            widgetHide dialog
      appendToStore lambekSkel = do
        listStoreAppend skelStore lambekSkel
        updateSkelIndices typeStore skelStore

createAboutDialog builder = do
    builderAddFromFile builder "gui/about-dialog.glade"
    aboutDialog <- builderGetObject builder castToDialog "aboutdialog"
    widgetShowAll aboutDialog

-- This function actually does 2 things:
     -- Update the list of types matching the selected skeleton
     -- Update the graphical editor with the corresponding graph
updateTypesAndEditor modelTypes modelSkel viewSkel gsM drawWidget = do
    selection <- treeViewGetSelection viewSkel
    selected <- treeSelectionGetSelected selection
    Fold.forM_ selected $ \treeIter -> do
      -- Update the current types
      let idx = listStoreIterToIndex treeIter
      skel <- listStoreGetValue modelSkel idx
      nbTypes <- listStoreGetSize modelTypes
      forNTimes nbTypes $ \i -> do
        entry <- listStoreGetValue modelTypes i
        let newVis = firstSkelIndex entry == idx
        listStoreSetValue modelTypes i $ entry { currentlyVisible = newVis }
        
      -- Update the graphical editor
      gs <- readMVar gsM
      let newGs = createGraphState (emptyGraphFromSkel skel) Map.empty skel
      modifyMVar_ gsM (\_ -> return newGs)
      widgetQueueDraw drawWidget

forNTimes n =
   Control.Monad.State.forM_ (List.reverse . seq $ n)
   where
     seq :: Int -> [Int]
     seq 0 = []
     seq n = (n-1):(seq $ n-1)

updateSkelIndices modelTypes modelSkel = do
    nbSkels <- listStoreGetSize modelSkel
    nbTypes <- listStoreGetSize modelTypes
    -- for each type
    forNTimes nbTypes $ \i -> do
      entry <- listStoreGetValue modelTypes i
      -- reset its current skeleton
      listStoreSetValue modelTypes i (entry { firstSkelIndex = -1 })
    
    -- for each skeleton
    forNTimes nbSkels $ \j -> do
      skel <- listStoreGetValue modelSkel j
      -- for each type
      forNTimes nbTypes $ \i -> do
        entry <- listStoreGetValue modelTypes i
        if firstSkelIndex entry == -1 && lambekType entry `isMatchedBy` skel then
            listStoreSetValue modelTypes i (entry { firstSkelIndex = j })
        else
            return ()

deleteCurrentSkel skelStore skelView = do
   selection <- treeViewGetSelection skelView
   selected <- treeSelectionGetSelected selection
   Fold.forM_ selected $ \treeIter -> do
     listStoreRemove skelStore $ listStoreIterToIndex treeIter

visCol :: ColumnId TypeEntry Bool
visCol = makeColumnIdBool 0

main :: IO ()
main = do
    -- State of the interface
    graphState <- newMVar defaultGraphState
    drawState <- newMVar DSelect
    -- skelUniqueId <- newMVar 1 -- next unique id for skeletons
    
    let changeState = changeDrawingState graphState drawState

    -- Create stores and lists
    skelStore <- listStoreNew []
    typeList <- loadTypeDatabase
    typeStore <- listStoreNew typeList

    -- GUI setup
    initGUI
    builder <- builderNew
    builderAddFromFile builder "gui/interface.glade"

    -- Get interesting widgets (main window)
    window <- builderGetObject builder castToWindow "window1"
    drawWidget <- builderGetObject builder castToDrawingArea "drawingarea1"
    selectButton <- builderGetObject builder castToToolButton "selectbutton"
    nodeButton <- builderGetObject builder castToToolButton "nodebutton"
    edgeButton <- builderGetObject builder castToToolButton "edgebutton"
    delElemButton <- builderGetObject builder castToToolButton "deleteelement"
    treeViewTypes <- builderGetObject builder castToTreeView "treeview2"
    treeViewSkels <- builderGetObject builder castToTreeView "treeview1"
    addSkelButton <- builderGetObject builder castToButton "buttonaddrule"
    delSkelButton <- builderGetObject builder castToButton "buttondelrule"
    quitButton <- builderGetObject builder castToImageMenuItem "imagemenuitem-quit"
    aboutButton <- builderGetObject builder castToImageMenuItem "imagemenuitem-about"

    -- Connect signals to callbacks (main window)
    on window objectDestroy mainQuit
    widgetAddEvents drawWidget [PointerMotionMask, ButtonPressMask]
    on drawWidget draw (drawScene drawState graphState)
    on drawWidget motionNotifyEvent (updateScene drawState graphState drawWidget)
    on drawWidget buttonPressEvent (handleClick drawState graphState drawWidget)
    on drawWidget buttonReleaseEvent (handleRelease drawState graphState drawWidget)
    on treeViewSkels cursorChanged (updateTypesAndEditor typeStore skelStore treeViewSkels graphState drawWidget)
    on skelStore rowsReordered (\ _ _ _ -> updateSkelIndices typeStore skelStore)
    on skelStore rowInserted (\ _ _ -> updateSkelIndices typeStore skelStore)
    on skelStore rowDeleted (\ _ -> updateSkelIndices typeStore skelStore)
      
    -- Buttons
    selectButton `onToolButtonClicked` (changeState DSelect)
    nodeButton `onToolButtonClicked` (changeState DNode)
    edgeButton `onToolButtonClicked` (changeState DEdge)
    delElemButton `onToolButtonClicked` (changeState DDelete)
    on addSkelButton buttonActivated (createAddDialog builder skelStore typeStore)
    on delSkelButton buttonActivated (deleteCurrentSkel skelStore treeViewSkels)

    -- Menu items
    on quitButton menuItemActivated (exitApplication window)
    on aboutButton menuItemActivated (createAboutDialog builder)

    -- Load type database
    colOccur <- Model.treeViewColumnNew
    Model.treeViewColumnSetTitle colOccur "Num"
    renderer <- Model.cellRendererTextNew
    Model.cellLayoutPackStart colOccur renderer False
    Model.cellLayoutSetAttributes colOccur renderer typeStore
           $ (\entry -> [Model.cellText := show . nbOccurrences $ entry])
    Model.treeViewAppendColumn treeViewTypes colOccur
    
    col <- Model.treeViewColumnNew
    Model.treeViewColumnSetTitle col "Type"
    renderer <- Model.cellRendererTextNew
    Model.cellLayoutPackStart col renderer False
    Model.cellLayoutSetAttributes col renderer typeStore
           $ (\entry -> [Model.cellText := renderLF . lambekType $ entry])
    Model.treeViewAppendColumn treeViewTypes col

    fModel <- treeModelFilterNew typeStore []
    customStoreSetColumn typeStore visCol currentlyVisible
    treeModelFilterSetVisibleColumn fModel visCol
    
    treeViewSetModel treeViewTypes fModel

    -- Add skeleton list
    treeViewSetModel treeViewSkels skelStore

    colSkel <- Model.treeViewColumnNew
    Model.treeViewColumnSetTitle colSkel "Pattern"
    Model.cellLayoutPackStart colSkel renderer False
    Model.cellLayoutSetAttributes colSkel renderer skelStore
           $ (\tp -> [Model.cellText := renderLS tp])
    Model.treeViewAppendColumn treeViewSkels colSkel
    
    widgetShowAll window
    mainGUI

    where
      exitApplication window = do
        widgetHide window
        mainQuit