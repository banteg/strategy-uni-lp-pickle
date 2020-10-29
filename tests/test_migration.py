def test_migration(chain, vault, strategy, succ_strategy, gov):
    chain.mine(100)
    strategy.harvest()
    before = strategy.estimatedTotalAssets().to('ether')
    print('estimatedTotalAssets before', before)
    print('pricePerShare', vault.pricePerShare().to('ether'))
    vault.migrateStrategy(strategy, succ_strategy, {'from': gov})
    assert strategy.estimatedTotalAssets().to('ether') == 0
    assert succ_strategy.estimatedTotalAssets().to('ether') >= before
    print('estimatedTotalAssets migrate', succ_strategy.estimatedTotalAssets().to('ether'))
    print('pricePerShare', vault.pricePerShare().to('ether'))
    succ_strategy.harvest()
    print('estimatedTotalAssets harvest', succ_strategy.estimatedTotalAssets().to('ether'))
    print('pricePerShare', vault.pricePerShare().to('ether'))
    assert vault.pricePerShare() < '1.5 ether'
    assert succ_strategy.estimatedTotalAssets() >= before
