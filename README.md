emitter 0.1
===========

## haskell pipes example

This is a work-in-progress example app for the haskell pipes and pipes-concurrent libraries.

## install

1. Build the library

```
cabal configure && cabal build && cabal install
```

2. Fire up the server:

```
emitter-server
```

3. Open the client.html page

4. Click and slide the not very pretty controllers


## the basics

The emitter is designed using Controller/Model/View (mvc) design ideas that are emerging from Gabe's brain bank:
 - it sets up a core stream using pushed-based pipes and an `Arrow`s instance (model), avoiding IO monad usage.
 - multiple incoming effects (controllers) are monoidal and kept separate using Input mailboxes via pipes-concurrency technology.
 - multiple outgoing effects (views) are are also monoidal and pushed out using Output mailboxes.
 
 The actual example usage:
 - listens for stdin and browser effects (via javascript and websockets).
 - sends the end result of a random-walk stream to stdout and the browser via websockets and charts the result using the js `rickshaw` library.

## design ideas

### purity

With complete separation of pure code from effects, the core stream (and any stream designed this way) is amenable to the full toolkit available to leverage haskell, like QuickCheck, criterion, GHC aggression, distribution etc etc.

### effect monoids

Effect sources and sinks can be easily plugged in with <> and such.  The emitter, for example, can be run using the terminal or the browser (or both at once, or pure code!) making debugging that much better.  

### websockets

The emitter highjacks the haskell `websocket` library. Most of the websocket code is lifted straight from example code in that library.

The very nice thing about web sockets is that it's a fully bi-directional socket system - no Ajax, no JSON and no callbacks required!

### horses-for-courses

`pipes`-style development allows the free mixing and matching of computational niceties and use of sugary-sweet front-ends like css/js/html5 and awesome chart packages like `rickshaw` versus the ghetto of haskell GUI choices.

### ema

Along the pipe, there is an experiment of using a monoidal exponential moving average calculation to smooth the random stream.

