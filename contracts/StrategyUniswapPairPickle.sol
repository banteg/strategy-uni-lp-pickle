// SPDX-License-Identifier: AGPLv3

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "./BaseStrategy.sol";
import "@openzeppelinV3/contracts/token/ERC20/IERC20.sol";
import "@openzeppelinV3/contracts/math/SafeMath.sol";
import "@openzeppelinV3/contracts/utils/Address.sol";
import "@openzeppelinV3/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelinV3/contracts/math/Math.sol";

interface PickleJar {
    function deposit(uint256 _amount) external;
    function withdraw(uint256 _shares) external;
    function token() external view returns (address);
    function getRatio() external view returns (uint256);
}

interface PickleChef {
    function deposit(uint256 _pid, uint256 _amount) external;
    function withdraw(uint256 _pid, uint256 _amount) external;
    function poolInfo(uint256 _pid) external view returns (address, uint256, uint256, uint256);
    function pendingPickle(uint256 _pid, address _user) external view returns (uint256);
    function userInfo(uint256 _pid, address _user) external view returns (uint256, uint256);
}

interface PickleStaking {
    function earned(address account) external view returns (uint256);
    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward() external;
    function exit() external;
}

interface UniswapPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface Uniswap {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function getAmountsOut(uint amountIn, address[] memory path) external view returns (uint[] memory amounts);
}

/*
    Uniswap LP => Pickle Jar => Pickle Farm => Pickle Staking => WETH rewards

    Builds up a Pickle position in Pickle Staking.
*/

contract StrategyUniswapPairPickle is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    string public constant override name = "StrategyUniswapPairPickle";
    address public constant chef = 0xbD17B1ce622d73bD438b9E658acA5996dc394b0d;
    address public constant staking = 0xa17a8883dA1aBd57c690DF9Ebf58fC194eDAb66F;
    address public constant pickle = 0x429881672B9AE42b8EbA0E26cD9C73711b891Ca5;
    address public constant uniswap = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address public constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public jar;
    uint256 public pid;
    address token0;
    address token1;
    uint256 gasFactor = 200;
    uint256 interval = 1000;

    constructor(address _vault, address _jar, uint256 _pid) public BaseStrategy(_vault) {
        jar = _jar;
        pid = _pid;

        require(PickleJar(jar).token() == address(want), "wrong jar");
        (address lp,,,) = PickleChef(chef).poolInfo(pid);
        require(lp == jar, "wrong pid");

        token0 = UniswapPair(address(want)).token0();
        token1 = UniswapPair(address(want)).token1();
        want.safeApprove(jar, type(uint256).max);
        IERC20(jar).safeApprove(chef, type(uint256).max);
        IERC20(pickle).safeApprove(staking, type(uint256).max);
        IERC20(token0).safeApprove(uniswap, type(uint256).max);
        IERC20(token1).safeApprove(uniswap, type(uint256).max);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function expectedReturn() public view returns (uint256) {
        uint256 _earned = PickleStaking(staking).earned(address(this));
        if (_earned / 2 == 0) return 0;
        uint256 _amount0 = quote(weth, token0, _earned / 2);
        uint256 _amount1 = quote(weth, token1, _earned / 2);
        (uint112 _reserve0, uint112 _reserve1, ) = UniswapPair(address(want)).getReserves();
        uint256 _supply = IERC20(want).totalSupply();
        return Math.min(
            _amount0.mul(_supply).div(_reserve0),
            _amount1.mul(_supply).div(_reserve1)
        );
    }

    /*
     * Provide an accurate estimate for the total amount of assets (principle + return)
     * that this strategy is currently managing, denominated in terms of `want` tokens.
     * This total should be "realizable" e.g. the total value that could *actually* be
     * obtained from this strategy if it were to divest it's entire position based on
     * current on-chain conditions.
     *
     * NOTE: care must be taken in using this function, since it relies on external
     *       systems, which could be manipulated by the attacker to give an inflated
     *       (or reduced) value produced by this function, based on current on-chain
     *       conditions (e.g. this function is possible to influence through flashloan
     *       attacks, oracle manipulations, or other DeFi attack mechanisms).
     *
     * NOTE: It is up to governance to use this function to correctly order this strategy
     *       relative to its peers in the withdrawal queue to minimize losses for the Vault
     *       based on sudden withdrawals. This value should be higher than the total debt of
     *       the strategy and higher than it's expected value to be "safe".
     */
    function estimatedTotalAssets() public override view returns (uint256) {
        uint256 _want = want.balanceOf(address(this));
        (uint256 _staked, ) = PickleChef(chef).userInfo(pid, address(this));
        uint256 _ratio = PickleJar(jar).getRatio();
        uint256 _earned = expectedReturn();
        return _want.add(_staked.mul(_ratio).div(1e18)).add(_earned);
    }

    /*
     * Perform any strategy unwinding or other calls necessary to capture
     * the "free return" this strategy has generated since the last time it's
     * core position(s) were adusted. Examples include unwrapping extra rewards.
     * This call is only used during "normal operation" of a Strategy, and should
     * be optimized to minimize losses as much as possible. It is okay to report
     * "no returns", however this will affect the credit limit extended to the
     * strategy and reduce it's overall position if lower than expected returns
     * are sustained for long periods of time.
     */
    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss) {
        // Claim Pickle rewards from Pickle Chef
        PickleChef(chef).deposit(pid, 0);
        // Claim WETH rewards from Pickle Staking
        PickleStaking(staking).getReward();
        // Swap WETH to LP token underlying and add liquidity
        uint _weth = IERC20(weth).balanceOf(address(this));
        if (_weth > 1 gwei) {
            swap(weth, token0, _weth / 2);
            swap(weth, token1, _weth / 2);
            add_liquidity();
        }

        uint256 totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 totalAssets = estimatedTotalAssets();

        uint256 looseBalance = want.balanceOf(address(this));
        uint256 neededLooseBalance;

        if (totalAssets < totalDebt) {
            _loss = totalDebt.sub(totalAssets);
            neededLooseBalance = _debtOutstanding;
        } else {
            _profit = totalAssets.sub(totalDebt);
            neededLooseBalance = _debtOutstanding.add(_profit);
        }

        if (neededLooseBalance > looseBalance) liquidatePosition(neededLooseBalance.sub(looseBalance));

        looseBalance = want.balanceOf(address(this));
        if (looseBalance > neededLooseBalance) {
            setReserve(looseBalance.sub(neededLooseBalance));
        } else {
            setReserve(0);
        }
    }

    /*
     * Perform any adjustments to the core position(s) of this strategy given
     * what change the Vault made in the "investable capital" available to the
     * strategy. Note that all "free capital" in the strategy after the report
     * was made is available for reinvestment. Also note that this number could
     * be 0, and you should handle that scenario accordingly.
     */
    function adjustPosition(uint256 _debtOutstanding) internal override {
        setReserve(0);
        // Stake LP tokens into Pickle Jar
        uint _want = want.balanceOf(address(this));
        _want = _want.sub(Math.min(_want, _debtOutstanding));
        if (_want > 0) PickleJar(jar).deposit(_want);
        // Stake Jar tokens into Pickle Farm
        uint _jar = IERC20(jar).balanceOf(address(this));
        if (_jar > 0) PickleChef(chef).deposit(pid, _jar);
        // Stake Pickle into Pickle Staking
        uint _pickle = IERC20(pickle).balanceOf(address(this));
        if (_pickle > 0) PickleStaking(staking).stake(_pickle);
    }

    /*
     * Make as much capital as possible "free" for the Vault to take. Some slippage
     * is allowed, since when this method is called the strategist is no longer receiving
     * their performance fee. The goal is for the strategy to divest as quickly as possible
     * while not suffering exorbitant losses. This function is used during emergency exit
     * instead of `prepareReturn()`
     */
    function exitPosition() internal override returns (uint256 _loss) {
        // Withdraw Jar tokens from Pickle Chef
        (uint _staked, ) = PickleChef(chef).userInfo(pid, address(this));
        PickleChef(chef).withdraw(pid, _staked);
        // Withdraw LP tokens from Jar
        uint _jar = IERC20(jar).balanceOf(address(this));
        if (_jar > 0) PickleJar(jar).withdraw(_jar);
        // Withdraw Pickle from Pickle Staking and transfer to governance
        uint _pickle_staked = IERC20(staking).balanceOf(address(this));
        if (_pickle_staked > 0) PickleStaking(staking).exit();
        uint _pickle = IERC20(pickle).balanceOf(address(this));
        if (_pickle > 0) IERC20(pickle).safeTransfer(governance(), _pickle);
        return 0;
    }
    /*
     * Liquidate as many assets as possible to `want`, irregardless of slippage,
     * up to `_amountNeeded`. Any excess should be re-invested here as well.
     */
    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _amountFreed) {
        uint _before = want.balanceOf(address(this));
        (uint _staked, ) = PickleChef(chef).userInfo(pid, address(this));
        // This could result in less amount freed because of rounding error
        uint _withdraw = _amountNeeded.mul(1e18).div(PickleJar(jar).getRatio());
        PickleChef(chef).withdraw(pid, Math.min(_staked, _withdraw));
        // This could result in less amount freed because of withdrawal fees
        uint _jar = IERC20(jar).balanceOf(address(this));
        PickleJar(jar).withdraw(_jar);
        return Math.min(want.balanceOf(address(this)).sub(_before), _amountNeeded);
    }

    /*
     * Provide a signal to the keeper that `tend()` should be called. The keeper will provide
     * the estimated gas cost that they would pay to call `tend()`, and this function should
     * use that estimate to make a determination if calling it is "worth it" for the keeper.
     * This is not the only consideration into issuing this trigger, for example if the position
     * would be negatively affected if `tend()` is not called shortly, then this can return `true`
     * even if the keeper might be "at a loss" (keepers are always reimbursed by Yearn)
     *
     * NOTE: `callCost` must be priced in terms of `want`
     *
     * NOTE: this call and `harvestTrigger` should never return `true` at the same time.
     */
    function tendTrigger(uint256 gasCost) public override view returns (bool) {
        return false;
    }

    /*
     * Provide a signal to the keeper that `harvest()` should be called. The keeper will provide
     * the estimated gas cost that they would pay to call `harvest()`, and this function should
     * use that estimate to make a determination if calling it is "worth it" for the keeper.
     * This is not the only consideration into issuing this trigger, for example if the position
     * would be negatively affected if `harvest()` is not called shortly, then this can return `true`
     * even if the keeper might be "at a loss" (keepers are always reimbursed by Yearn)
     *
     * NOTE: `callCost` must be priced in terms of `want`
     *
     * NOTE: this call and `tendTrigger` should never return `true` at the same time.
     */
    function harvestTrigger(uint256 gasCost) public override view returns (bool) {
        uint256 _credit = vault.creditAvailable().mul(wantPrice()).div(1e18);
        uint256 _earned = PickleChef(chef).pendingPickle(pid, address(this));
        uint256 _return = quote(pickle, weth, _earned);
        uint256 last_sync = vault.strategies(address(this)).lastReport;
        bool time_trigger = block.number.sub(last_sync) >= interval;
        bool cost_trigger = _return > gasCost.mul(gasFactor);
        bool credit_trigger = _credit > gasCost.mul(gasFactor);
        return time_trigger && (cost_trigger || credit_trigger);
    }

    /*
     * Do anything necesseary to prepare this strategy for migration, such
     * as transfering any reserve or LP tokens, CDPs, or other tokens or stores of value.
     */
    function prepareMigration(address _newStrategy) internal override {
        // Pickle is unstaked and sent to governance in this call
        exitPosition();
        want.transfer(_newStrategy, want.balanceOf(address(this)));
    }

    function protectedTokens() internal override view returns (address[] memory) {
        address[] memory protected = new address[](5);
        protected[0] = address(want);
        protected[1] = pickle;
        protected[2] = jar;
        protected[3] = token0;
        protected[4] = token1;
        return protected;
    }

    function setGasFactor(uint256 _gasFactor) public {
        require(msg.sender == strategist || msg.sender == governance());
        gasFactor = _gasFactor;
    }

    function setInterval(uint256 _interval) public {
        require(msg.sender == strategist || msg.sender == governance());
        interval = _interval;
    }

    // ******** HELPER METHODS ************

    // Quote want token in ether.
    function wantPrice() public view returns (uint256) {
        require(token0 == weth || token1 == weth);  // dev: can only quote weth pairs
        (uint112 _reserve0, uint112 _reserve1, ) = UniswapPair(address(want)).getReserves();
        uint256 _supply = IERC20(want).totalSupply();
        // Assume that pool is perfectly balanced
        return 2e18 * uint256(token0 == weth ? _reserve0 : _reserve1) / _supply;
    }

    function quote(address token_in, address token_out, uint256 amount_in) internal view returns (uint256) {
        if (token_in == token_out) return amount_in;
        bool is_weth = token_in == weth || token_out == weth;
        address[] memory path = new address[](is_weth ? 2 : 3);
        path[0] = token_in;
        if (is_weth) {
            path[1] = token_out;
        } else {
            path[1] = weth;
            path[2] = token_out;
        }
        uint256[] memory amounts = Uniswap(uniswap).getAmountsOut(amount_in, path);
        return amounts[amounts.length - 1];
    }

    function swap(address token_in, address token_out, uint amount_in) internal {
        if (token_in == token_out) return;
        bool is_weth = token_in == weth || token_out == weth;
        address[] memory path = new address[](is_weth ? 2 : 3);
        path[0] = token_in;
        if (is_weth) {
            path[1] = token_out;
        } else {
            path[1] = weth;
            path[2] = token_out;
        }
        if (IERC20(token_in).allowance(address(this), uniswap) < amount_in)
            IERC20(token_in).safeApprove(uniswap, type(uint256).max);
        Uniswap(uniswap).swapExactTokensForTokens(
            amount_in,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function add_liquidity() internal {
        Uniswap(uniswap).addLiquidity(
            token0,
            token1,
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            0, 0,
            address(this),
            block.timestamp
        );
    }

}
