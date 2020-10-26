blocks_per_year = 6525 * 365
seconds_per_block = (86400 * 365) / blocks_per_year
sample = 200


def sleep(chain):
    chain.mine(sample)
    chain.sleep(int(sample * seconds_per_block))


def test_vault_deposit(vault, token, whale):
    token.approve(vault, token.balanceOf(whale), {"from": whale})
    before = vault.balanceOf(whale)
    deposit = token.balanceOf(whale)
    vault.deposit(deposit, {"from": whale})
    assert vault.balanceOf(whale) == before + deposit
    assert token.balanceOf(vault) == before + deposit
    assert vault.totalDebt() == 0
    assert vault.pricePerShare() == 10 ** token.decimals()  # 1:1 price


def test_vault_withdraw(vault, token, whale):
    balance = token.balanceOf(whale) + vault.balanceOf(whale)
    vault.withdraw(vault.balanceOf(whale), {"from": whale})
    assert vault.totalSupply() == token.balanceOf(vault) == 0
    assert vault.totalDebt() == 0
    assert token.balanceOf(whale) == balance


def test_strategy_harvest(strategy, vault, token, whale, chain, jar, pickle_strategy):
    print('vault:', vault.name())
    user_before = token.balanceOf(whale) + vault.balanceOf(whale)
    token.approve(vault, token.balanceOf(whale), {"from": whale})
    vault.deposit(token.balanceOf(whale), {"from": whale})
    sleep(chain)
    print("share price before:", vault.pricePerShare().to("ether"))
    assert vault.creditAvailable(strategy) > 0
    # harvest pickle so its unrealized profits don't mess with the calculation
    pickle_strategy.harvest({"from": whale})
    # give the strategy some debt
    strategy.harvest()
    before = strategy.estimatedTotalAssets()
    # run strategy for some time
    sleep(chain)
    jar_ratio_before = jar.getRatio().to("ether")
    pickle_strategy.harvest({"from": whale})
    jar_ratio_after = jar.getRatio().to("ether")
    assert jar_ratio_after > jar_ratio_before
    strategy.harvest()
    after = strategy.estimatedTotalAssets()
    assert after > before
    print("share price after: ", vault.pricePerShare().to("ether"))
    # print(f"implied apy: {(after / before - 1) / (sample / blocks_per_year):.5%}")
    # user withdraws all funds
    vault.withdraw(vault.balanceOf(whale), {"from": whale})
    assert token.balanceOf(whale) >= user_before


def test_strategy_withdraw(strategy, vault, token, whale, gov, chain, pickle_strategy):
    user_before = token.balanceOf(whale) + vault.balanceOf(whale)
    token.approve(vault, token.balanceOf(whale), {"from": whale})
    vault.deposit(token.balanceOf(whale), {"from": whale})
    # first harvest adds initial deposits
    sleep(chain)
    strategy.harvest()
    initial_deposits = strategy.estimatedTotalAssets().to("ether")
    # second harvest secures some profits
    sleep(chain)
    pickle_strategy.harvest({"from": gov})
    strategy.harvest()
    deposits_after_savings = strategy.estimatedTotalAssets().to("ether")
    assert deposits_after_savings > initial_deposits
    # user withdraws funds
    vault.withdraw(vault.balanceOf(whale), {"from": whale})
    assert token.balanceOf(whale) >= user_before
