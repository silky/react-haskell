{-# LANGUAGE OverloadedStrings, FlexibleInstances, CPP, LambdaCase,
  MultiParamTypeClasses, FlexibleContexts #-}

module React
    ( module X
    , ReactNode(..)
    , ReactM(..)

    , div
    , input
    , pre

    , getDomNode
    , render

    , (<!)
    , (<!?)

    , className

    , onChange
    , onKeyDown
    , onKeyPress
    , onKeyUp
    , onClick
    ) where

import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Writer
import Data.String

#ifdef __HASTE__
import Haste hiding (fromString)
import Haste.Foreign
import Haste.JSON
import Haste.Prim
#endif

import Prelude hiding (div)

import React.Types as X
import React.Events as X
import React.Imports as X

-- TODO
-- * restricted monads
-- * store elem in monad
-- * store state in monad / provide better help
-- * provide alternative names for div, span, others?
-- * helpers for e.g. className
-- * rename away from "React"

{-
class MonadReact m where

instance MonadReact ReactSansChildren where

instance MonadReact ReactWithChildren where

class ReactAttr a where
-}

type Attrs = [(JSString, JSON)]
type Handlers = [EventHandler]

data ReactNode = Parent JSString Attrs Handlers [ReactNode]
               | Leaf JSString Attrs Handlers
               -- | Pre Attrs Handlers [ReactNode] -- it'd be super cool to restrict this to a string somehow (restrict the underlying monad so it can only set attrs and string?)
               | Text String -- TODO(joel) JSString?

{-
instance Show ReactNode where
    show (Div as _ children) = "(Div " ++ show as ++ " " ++ show children ++ ")"
    show (Input as _) = "(Input " ++ show as ++ ")"
    show (Pre as _ children) = "(Pre " ++ show as ++ " " ++ show children ++ ")"
    show (Text str) = str
-}

data ReactM a = ReactM
    { attrs :: Attrs
    , handlers :: Handlers
    , children :: [ReactNode]
    , other :: a
    }

type React = ReactM ()

instance Functor ReactM where
    f `fmap` react@ReactM{other=a} = react{other=f a}

instance Applicative ReactM where
    pure = ReactM [] [] []
    (ReactM af hf nf f) <*> (ReactM aa ha na a) =
        ReactM (af <> aa) (hf <> ha) (nf <> na) (f a)

instance Monad ReactM where
    return = pure
    (ReactM aa ha na a) >>= nf =
        let ReactM as hs ns a' = nf a
        in ReactM (aa <> as) (ha <> hs) (na <> ns) a'

instance IsString (ReactM a) where
    fromString str = ReactM [] [] [Text str] (error "this shouldn't be accessed")

class Attributable h a where
    (<!) :: h -> a -> h

(<!?) :: Attributable h a => h -> (Bool, a) -> h
h <!? (True, a) = h <! a
h <!? (False, _) = h

(<!>) :: [ReactNode] -> (JSString, JSON) -> [ReactNode]
[elem] <!> attr = [go elem] where
    go (Parent name as hs cs)  = Parent name (attr:as) hs cs
    go (Leaf name as hs)   = Leaf name (attr:as) hs
    go (Text str)      = Text str
_ <!> _ = error "attr applied to multiple elems!"

(<!<) :: [ReactNode] -> EventHandler -> [ReactNode]
[elem] <!< hndl = [go elem] where
    go (Parent name as hs cs)  = Parent name as (hndl:hs) cs
    go (Leaf name as hs)   = Leaf name as (hndl:hs)
    go (Text str)      = Text str

instance Attributable (ReactM b) (JSString, JSON) where
    (ReactM as hs ns x) <! attr = ReactM as hs (ns <!> attr) x

-- TODO thinking there should be some notion of single / multiple?
-- We should only ever apply an attribute / handler to one element here.
--
-- div <! attr $ ...
--
-- vs
--
-- (div >> div) <! attr
--
-- in fact, I think we should only ever apply attrs to
-- `React -> React`
--
-- except things with no children?
--
-- input <! attr
instance Attributable (ReactM b) EventHandler where
    (ReactM as hs ns x) <! hndl = ReactM as hs (ns <!< hndl) x

instance Attributable (ReactM c) a =>
         Attributable (ReactM b -> ReactM c) a where
    f <! attr = (<! attr) . f

className :: JSString -> (JSString, JSON)
className str = ("className", Str str)

mkParent :: JSString -> React -> React
mkParent str (ReactM _ _ children _) = ReactM [] [] [Parent str [] [] children] ()

mkLeaf :: JSString -> React
mkLeaf str = ReactM [] [] [Leaf str [] []] ()

div = mkParent "div"
pre = mkParent "pre"
span = mkParent "span"

input = mkLeaf "input"

interpret :: React -> IO ForeignNode
interpret (ReactM _ _ (node:_) _) = interpret' node

interpret' :: ReactNode -> IO ForeignNode
interpret' = \case
    Parent name as hs children -> element js_React_DOM_parent name as hs =<< forM children interpret'
    Leaf name as hs -> voidElement js_React_DOM_leaf name as hs
    Text str -> js_React_DOM_text (toJSStr str)

element :: (JSString -> RawAttrs -> ReactArray -> IO ForeignNode)
        -> JSString
        -> Attrs
        -> Handlers
        -> [ForeignNode]
        -> IO ForeignNode
element constructor name attrs handlers content = do
    attr <- js_empty_object
    mapM_ (setField attr) attrs
    mapM_ (($ attr) . unEventHandler) handlers

    children <- js_ReactArray_empty
    mapM_ (js_ReactArray_push children) content
    constructor name attr children

voidElement :: (JSString -> RawAttrs -> IO ForeignNode)
            -> JSString
            -> Attrs
            -> Handlers
            -> IO ForeignNode
voidElement constructor name attrs handlers =
    element (\n a c -> constructor n a) name attrs handlers []

setField :: RawAttrs -> (JSString, JSON) -> IO ()
setField attr (fld, Str v) = js_set_field_String attr fld v
setField attr (fld, Dict vs) = do
    subObj <- js_empty_object
    mapM_ (setField subObj) vs
    js_set_field_Obj attr fld subObj
setField attr (fld, Num v) = js_set_field_Double attr fld v
setField attr (fld, Bool True) = js_set_field_True attr fld
setField attr (fld, Bool False) = js_set_field_False attr fld

-- TODO this seems wrong
setField attr (fld, Null) = return ()

getDomNode :: ForeignNode -> IO (Maybe Elem)
getDomNode r = fmap fromPtr (js_React_getDomNode r)

render :: Elem -> React -> IO ()
render elem r = do
    r' <- interpret r
    render' elem r'

render' :: Elem -> ForeignNode -> IO ()
render' = ffi (toJSStr "(function(e,r){React.render(r,e);})")

-- newtype RawAttrs = RawAttrs JSAny  deriving (Pack, Unpack)
-- EventHandler :: (RawAttrs -> IO (}) -> EventHandler
-- js_set_onChange :: Ptr (RawChangeEvent -> IO ()) -> RawAttrs -> IO ()

makeHandler :: EventHandler -> React
makeHandler handler = ReactM [] [handler] [] ()

onChange :: (ChangeEvent -> IO ()) -> React
onChange = makeHandler . onChange'

onChange' :: (ChangeEvent -> IO ()) -> EventHandler
onChange' cb = EventHandler $ js_set_onChange $ toPtr $
    cb . fromPtr . js_parseChangeEvent

onKeyDown :: (KeyboardEvent -> IO ()) -> EventHandler
onKeyDown cb = EventHandler $ js_set_onKeyDown $ toPtr $
    cb . fromPtr . js_parseKeyboardEvent

onKeyPress :: (KeyboardEvent -> IO ()) -> EventHandler
onKeyPress cb = EventHandler $ js_set_onKeyPress $ toPtr $
    cb . fromPtr . js_parseKeyboardEvent

onKeyUp :: (KeyboardEvent -> IO ()) -> EventHandler
onKeyUp cb = EventHandler $ js_set_onKeyUp $ toPtr $
    cb . fromPtr . js_parseKeyboardEvent

onClick :: (MouseEvent -> IO ()) -> EventHandler
onClick cb = EventHandler $ js_set_onClick $ toPtr $
    cb . fromPtr . js_parseMouseEvent


-- targetValue :: RawChangeEvent -> IO JSString
-- targetValue = ffi "(function(event) { return event.target.value; })"
