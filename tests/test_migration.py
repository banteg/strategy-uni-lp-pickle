def test_migration(
    chain,
    vault,
    strategy,
    succ_strategy,
    gov,
    whale,
    pickle_staking,
    pickle,
    pickle_strategy,
):
    def harvest(strat):
        chain.sleep(3600)
        chain.mine(100)
        pickle_strategy.harvest({"from": whale})
        strat.harvest()

    pickle_before = pickle.balanceOf(whale) / 2
    pickle.transfer(strategy, pickle_before, {"from": whale})

    strategy.harvest()
    assert pickle_staking.balanceOf(strategy) == pickle_before
    assets_before = strategy.estimatedTotalAssets()

    harvest(strategy)
    assert pickle_staking.balanceOf(strategy) > pickle_before
    pickle_after = pickle_staking.balanceOf(strategy)
    assets_after = strategy.estimatedTotalAssets()
    price_after = vault.pricePerShare()
    assert pickle_after > pickle_before
    assert assets_after > assets_before

    vault.migrateStrategy(strategy, succ_strategy, {"from": gov})
    assert strategy.estimatedTotalAssets() == 0
    assert succ_strategy.estimatedTotalAssets() >= assets_after
    assert pickle.balanceOf(vault.governance()) >= pickle_after

    harvest(succ_strategy)
    assert succ_strategy.estimatedTotalAssets() > assets_after
    harvest(succ_strategy)
    harvest(succ_strategy)
    assert vault.pricePerShare() > price_after
