def test_deploy(config, Vault, StrategyUniswapPairPickle, gov, rewards, guardian):
    vault = Vault.deploy(
        config["want"],
        gov,
        rewards,
        config["name"],
        config["symbol"],
        {"from": guardian},
    )
    strategy = StrategyUniswapPairPickle.deploy(
        vault, config["jar"], config["pid"], {"from": guardian}
    )
