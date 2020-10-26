import json
import pytest


with open("configurations.json") as f:
    configurations = json.load(f)


@pytest.fixture(scope="function", autouse=True)
def shared_setup(fn_isolation):
    pass


@pytest.fixture(scope="module", params=configurations["vaults"][:1])
def config(request):
    return {**configurations["common"], **request.param}


@pytest.fixture
def vault(config, Vault, gov, rewards, guardian):
    return Vault.deploy(
        config["want"],
        gov,
        rewards,
        config["name"],
        config["symbol"],
        {"from": guardian},
    )


@pytest.fixture
def strategy(config, StrategyUniswapPairPickle, vault, strategist, keeper):
    strategy = StrategyUniswapPairPickle.deploy(
        vault, config["jar"], config["pid"], {"from": strategist}
    )
    strategy.setKeeper(keeper, {"from": strategist})
    return strategy


@pytest.fixture
def gov(accounts):
    return accounts[1]


@pytest.fixture
def rewards(gov):
    return gov


@pytest.fixture
def guardian(accounts):
    return accounts[2]


@pytest.fixture
def strategist(accounts):
    return accounts[3]


@pytest.fixture
def keeper(accounts):
    return accounts[4]
