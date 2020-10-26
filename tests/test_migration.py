def test_migration(chain, vault, strategy, succ_strategy, gov):
    chain.mine(100)
    strategy.harvest()
    before = strategy.estimatedTotalAssets().to('ether')
    vault.migrateStrategy(strategy, succ_strategy, {'from': gov})
    assert strategy.estimatedTotalAssets().to('ether') == 0
    assert succ_strategy.estimatedTotalAssets().to('ether') >= before
