def test_shutdown(vault, token, strategy, chain):
    chain.mine(100)
    before = token.balanceOf(vault)
    assert strategy.estimatedTotalAssets() == 0
    strategy.harvest()
    assert token.balanceOf(vault) == 0
    assert strategy.estimatedTotalAssets() > before * 0.999
    strategy.setEmergencyExit()
    assert strategy.estimatedTotalAssets() == 0
    after = token.balanceOf(vault)
    assert after > before * 0.999
    print(f"loss: {(before - after).to('ether')} {after / before - 1:.18%}")
