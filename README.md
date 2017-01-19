[![Hackage](https://img.shields.io/hackage/v/pipes-fluid.svg)](https://hackage.haskell.org/package/pipes-fluid)
[![Build Status](https://secure.travis-ci.org/louispan/pipes-fluid.png?branch=master)](http://travis-ci.org/louispan/pipes-fluid)

Applicative instances that allows reactively combining 'Pipes.Producer's so that a value is yielded when either Producer yields a value. This can be used to create a FRP-like reactive signal-network.

See [Main.hs](app/Main.hs) for example usage.

See [glazier-tutorial](https://github.com/louispan/glazier-tutorial/blob/08d24800c58c6ec683b618bf2e4061e58aac1753/src/Glazier/Tutorial/Console.hs#L306) for a working console example.

See also [slides](http://www.slideshare.net/LouisPan3/composable-widgets-with-reactive-pipes).