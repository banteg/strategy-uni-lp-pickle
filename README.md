# StrategyUniswapPairPickle

## Abstract

- Uniswap LP is staked into Uniswap reward distributor
- Pickle harvests and recycles UNI rewards with Pickle Jar
- Pickle Jar is staked into Pickle Farm to receive Pickle
- This strategy harvests and recycles Pickle

## Supported configurations

- Uniswap v2 USDT-WETH Pool
- Uniswap v2 USDC-WETH Pool
- Uniswap v2 DAI-WETH Pool
- Uniswap v2 WBTC-WETH Pool

## Deploy

```
brownie run deploy
```

## Tests

```
brownie test -s
```
