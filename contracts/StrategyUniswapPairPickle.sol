// SPDX-License-Identifier: AGPLv3

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaultsV2/contracts/BaseStrategy.sol";
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

contract StrategyUniswapPairPickle is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    string public constant override name = "StrategyUniswapPairPickle";
    address public constant chef = 0xbD17B1ce622d73bD438b9E658acA5996dc394b0d;
    address public constant reward = 0x429881672B9AE42b8EbA0E26cD9C73711b891Ca5;
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
        IERC20(reward).safeApprove(uniswap, type(uint256).max);
        IERC20(token0).safeApprove(uniswap, type(uint256).max);
        IERC20(token1).safeApprove(uniswap, type(uint256).max);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    /*
     * Provide an accurate expected value for the return this strategy
     * would provide to the Vault if `report()` was called right now
     */
    function expectedReturn() public override view returns (uint256 _liquidity) {
        uint256 _earned = PickleChef(chef).pendingPickle(pid, address(this));
        if (_earned / 2 == 0) return 0;
        uint256 _amount0 = quote(reward, token0, _earned / 2);
        uint256 _amount1 = quote(reward, token1, _earned / 2);
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
     * NOTE: It is up to governance to use this function in order to correctly order
     *       this strategy relative to its peers in order to minimize losses for the
     *       Vault based on sudden withdrawals. This value should be higher than the
     *       total debt of the strategy and higher than it's expected value to be "safe".
     */
    function estimatedTotalAssets() public override view returns (uint256) {
        // TODO: Build a more accurate estimate using the value of all positions in terms of `want`
        (uint256 _staked, ) = PickleChef(chef).userInfo(pid, address(this));
        uint256 _ratio = PickleJar(jar).getRatio();
        uint256 _staked_want = _staked.mul(_ratio).div(1e18);
        uint256 _unrealized_profit = expectedReturn();
        return want.balanceOf(address(this)).add(_staked_want).add(_unrealized_profit);
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
    function prepareReturn() internal override {
        reserve = want.balanceOf(address(this)).sub(outstanding);
        PickleChef(chef).deposit(pid, 0);
        uint _amount = IERC20(reward).balanceOf(address(this));
        if (_amount < 1 gwei) return;
        swap(reward, token0, _amount / 2);
        _amount = IERC20(reward).balanceOf(address(this));
        swap(reward, token1, _amount);
        add_liquidity();
    }

    /*
     * Perform any adjustments to the core position(s) of this strategy given
     * what change the Vault made in the "investable capital" available to the
     * strategy. Note that all "free capital" in the strategy after the report
     * was made is available for reinvestment. Also note that this number could
     * be 0, and you should handle that scenario accordingly.
     */
    function adjustPosition() internal override {
        reserve = 0;
        uint _amount = want.balanceOf(address(this));
        if (_amount == 0) return;
        // stake lp tokens in pickle jar
        PickleJar(jar).deposit(_amount);
        // stake jar in pickle farm
        _amount = IERC20(jar).balanceOf(address(this));
        if (_amount == 0) return;
        PickleChef(chef).deposit(pid, _amount);
    }

    /*
     * Make as much capital as possible "free" for the Vault to take. Some slippage
     * is allowed, since when this method is called the strategist is no longer receiving
     * their performance fee. The goal is for the strategy to divest as quickly as possible
     * while not suffering exorbitant losses. This function is used during emergency exit
     * instead of `prepareReturn()`
     */
    function exitPosition() internal override {
        // TODO: Do stuff here to free up as much as possible of all positions back into `want`
        (uint256 _staked, ) = PickleChef(chef).userInfo(pid, address(this));
        PickleChef(chef).withdraw(pid, _staked);
        PickleJar(jar).withdraw(IERC20(jar).balanceOf(address(this)));
    }

    /*
     * Liquidate as many assets as possible to `want`, irregardless of slippage,
     * up to `_amount`. Any excess should be re-invested here as well.
     */
    function liquidatePosition(uint256 _amount) internal override {
        // TODO: Do stuff here to free up `_amount` from all positions back into `want`
        (uint256 _staked, ) = PickleChef(chef).userInfo(pid, address(this));
        uint256 _withdraw = _amount.mul(1e18).div(PickleJar(jar).getRatio());
        PickleChef(chef).withdraw(pid, _withdraw);
        PickleJar(jar).withdraw(IERC20(jar).balanceOf(address(this)));
    }

    /*
     * Provide a signal to the keeper that `tend()` should be called. The keeper will provide
     * the estimated gas cost that they would pay to call `tend()`, and this function should
     * use that estimate to make a determination if calling it is "worth it" for the keeper.
     * This is not the only consideration into issuing this trigger, for example if the position
     * would be negatively affected if `tend()` is not called shortly, then this can return `true`
     * even if the keeper might be "at a loss" (keepers are always reimbursed by yEarn)
     *
     * NOTE: this call and `harvestTrigger` should never return `true` at the same time.
     * NOTE: if `tend()` is never intended to be called, it should always return `false`
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
     * even if the keeper might be "at a loss" (keepers are always reimbursed by yEarn)
     *
     * NOTE: this call and `tendTrigger` should never return `true` at the same time.
     */
    function harvestTrigger(uint256 gasCost) public override view returns (bool) {
        uint256 _credit = vault.creditAvailable().mul(wantPrice()).div(1e18);
        uint256 _earned = PickleChef(chef).pendingPickle(pid, address(this));
        uint256 _return = quote(reward, weth, _earned);
        uint256 last_sync = vault.strategies(address(this)).lastSync;
        bool time_trigger = block.number.sub(last_sync) >= interval;
        bool cost_trigger = _return > gasCost.mul(gasFactor);
        bool credit_trigger = _credit > gasCost.mul(gasFactor);
        return time_trigger && (cost_trigger || credit_trigger);
    }

    function setGasFactor(uint256 _gasFactor) public {
        require(msg.sender == strategist || msg.sender == governance());
        gasFactor = _gasFactor;
    }

    function setInterval(uint256 _interval) public {
        require(msg.sender == strategist || msg.sender == governance());
        interval = _interval;
    }

    /*
     * Do anything necesseary to prepare this strategy for migration, such
     * as transfering any reserve or LP tokens, CDPs, or other tokens or stores of value.
     */
    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        exitPosition();
        want.transfer(_newStrategy, want.balanceOf(address(this)));
    }

    // NOTE: Override this if you typically manage tokens inside this contract
    //       that you don't want swept away from you randomly.
    //       By default, only contains `want`
    function protectedTokens() internal override view returns (address[] memory) {
        address[] memory protected = new address[](2);
        protected[0] = address(want);
        protected[1] = reward;
        return protected;
    }

    // ******** HELPER METHODS ************

    // Quote want token in ether.
    function wantPrice() public view returns (uint256) {
        require(token0 == weth || token1 == weth);  // dev: can only quote weth pairs
        (uint112 _reserve0, uint112 _reserve1, ) = UniswapPair(address(want)).getReserves();
        uint256 _supply = IERC20(want).totalSupply();
        return 2e18 * uint256(token0 == weth ? _reserve0 : _reserve1) / _supply;
    }

    function quote(address token_in, address token_out, uint256 amount_in) internal view returns (uint256) {
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
        bool is_weth = token_in == weth || token_out == weth;
        address[] memory path = new address[](is_weth ? 2 : 3);
        path[0] = token_in;
        if (is_weth) {
            path[1] = token_out;
        } else {
            path[1] = weth;
            path[2] = token_out;
        }
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
