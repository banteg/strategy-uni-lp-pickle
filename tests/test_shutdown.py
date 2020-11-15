def test_shutdown(vault, token, strategy, whale, pickle):
    pickle_before = pickle.balanceOf(whale) / 2
    pickle.transfer(strategy, pickle_before, {"from": whale})
    before = token.balanceOf(vault)
    # acceptable loss
    loss = 10 ** 6
    strategy.harvest()
    assert strategy.estimatedTotalAssets() >= before - loss
    # pulled to strategy first
    strategy.setEmergencyExit()
    assert pickle.balanceOf(vault.governance()) >= pickle_before - loss
    assert token.balanceOf(strategy) >= before - loss
    # pulled to vault on harvest
    strategy.harvest()
    assert token.balanceOf(vault) >= before - loss
