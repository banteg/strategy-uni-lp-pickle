import json

from brownie import StrategyUniswapPairPickle, Vault, accounts, interface, web3
from click import secho
from eth_utils import is_checksum_address


def get_address(label):
    addr = input(f"{label}: ")
    if is_checksum_address(addr):
        return addr
    resolved = web3.ens.address(addr)
    if resolved:
        print(f"{addr} -> {resolved}")
        return resolved
    raise ValueError("invalid address or ens")


def main():
    configurations = json.load(open("configurations.json"))
    for i, config in enumerate(configurations["vaults"]):
        print(f"[{i}] {config['name']}")
    config = configurations["vaults"][int(input("choose configuration to deploy: "))]
    deployer = accounts.load(input("deployer account: "))
    gov = get_address("gov")
    rewards = get_address("rewards")
    vault = Vault.deploy(
        config["want"],
        gov,
        rewards,
        config["name"],
        config["symbol"],
        {"from": deployer},
    )
    strategy = StrategyUniswapPairPickle.deploy(
        vault, config["jar"], config["pid"], {"from": deployer}
    )
    secho(
        f"deployed {config['symbol']}\nvault: {vault}\nstrategy: {strategy}\n",
        fg="green",
    )
