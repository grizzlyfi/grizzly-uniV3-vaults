// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

// solhint-disable max-line-length
import { IUniswapV3MintCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import { IUniswapV3SwapCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import { GrizzlyVaultStorage } from "./abstract/GrizzlyVaultStorage.sol";
import { TickMath } from "./uniswap/TickMath.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { prbSqrt } from "@prb/math/src/Common.sol";
import { FullMath, LiquidityAmounts } from "./uniswap/LiquidityAmounts.sol";

contract GrizzlyVault is IUniswapV3MintCallback, IUniswapV3SwapCallback, GrizzlyVaultStorage {
	using SafeERC20 for IERC20;
	using TickMath for int24;

	event Minted(
		address receiver,
		uint256 mintAmount,
		uint256 amount0In,
		uint256 amount1In,
		uint128 liquidityMinted
	);

	event Burned(
		address receiver,
		uint256 burnAmount,
		uint256 amount0Out,
		uint256 amount1Out,
		uint128 liquidityBurned
	);

	event Rebalance(
		int24 lowerTick_,
		int24 upperTick_,
		uint128 liquidityBefore,
		uint128 liquidityAfter
	);

	event FeesEarned(uint256 feesEarned0, uint256 feesEarned1);

	// --- UniV3 callback functions --- //

	/// @notice Uniswap V3 callback function, called back on pool.mint
	function uniswapV3MintCallback(
		uint256 amount0Owed,
		uint256 amount1Owed,
		bytes calldata /*_data*/
	) external override {
		require(msg.sender == address(pool), "callback caller");

		if (amount0Owed > 0) token0.safeTransfer(msg.sender, amount0Owed);
		if (amount1Owed > 0) token1.safeTransfer(msg.sender, amount1Owed);
	}

	/// @notice Uniswap v3 callback function, called back on pool.swap
	function uniswapV3SwapCallback(
		int256 amount0Delta,
		int256 amount1Delta,
		bytes calldata /*data*/
	) external override {
		require(msg.sender == address(pool), "callback caller");

		if (amount0Delta > 0) token0.safeTransfer(msg.sender, uint256(amount0Delta));
		if (amount1Delta > 0) token1.safeTransfer(msg.sender, uint256(amount1Delta));
	}

	// --- User functions --- //

	/// @notice Mint fungible Grizzly Vault tokens, fractional shares of a Uniswap V3 position
	/// @dev To compute the amount of tokens necessary to mint `mintAmount` see getMintAmounts
	/// @param mintAmount The number of Grizzly Vault tokens to mint
	/// @param receiver The account to receive the minted tokens
	/// @return amount0 Amount of token0 transferred from msg.sender to mint `mintAmount`
	/// @return amount1 Amount of token1 transferred from msg.sender to mint `mintAmount`
	/// @return liquidityMinted Amount of liquidity added to the underlying Uniswap V3 position
	// solhint-disable-next-line function-max-lines, code-complexity
	function mint(
		uint256 mintAmount,
		address receiver
	) external nonReentrant returns (uint256 amount0, uint256 amount1, uint128 liquidityMinted) {
		require(mintAmount > 0, "mint 0");

		uint256 totalSupply = totalSupply();

		Ticks memory ticks = baseTicks;
		(uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

		if (totalSupply > 0) {
			(uint256 amount0Current, uint256 amount1Current) = getUnderlyingBalances();

			amount0 = FullMath.mulDivRoundingUp(amount0Current, mintAmount, totalSupply);
			amount1 = FullMath.mulDivRoundingUp(amount1Current, mintAmount, totalSupply);
		} else {
			// Prevent first staker from stealing funds of subsequent stakers
			// solhint-disable-next-line max-line-length
			// https://code4rena.com/reports/2022-01-sherlock/#h-01-first-user-can-steal-everyone-elses-tokens
			require(mintAmount > MIN_INITIAL_SHARES, "min shares");

			// If supply is 0 mintAmount == liquidity to deposit
			(amount0, amount1) = _amountsForLiquidity(
				SafeCast.toUint128(mintAmount),
				ticks,
				sqrtRatioX96
			);
		}

		// Transfer amounts owed to contract
		if (amount0 > 0) {
			token0.safeTransferFrom(msg.sender, address(this), amount0);
		}
		if (amount1 > 0) {
			token1.safeTransferFrom(msg.sender, address(this), amount1);
		}

		// Deposit as much new liquidity as possible
		liquidityMinted = _liquidityForAmounts(ticks, sqrtRatioX96, amount0, amount1);

		pool.mint(address(this), ticks.lowerTick, ticks.upperTick, liquidityMinted, "");

		_mint(receiver, mintAmount);
		emit Minted(receiver, mintAmount, amount0, amount1, liquidityMinted);
	}

	/// @notice Burn Grizzly Vault tokens (fractional shares of a UniV3 position) and receive tokens
	/// @param burnAmount The number of Grizzly Vault tokens to burn
	/// @param maxSwapSlippage The maximum slippage authorized by user
	/// @param outputToken  If 0 zaps out with only token0, if 1 zaps out with only token 1,
	/// if everything else it zaps out with both tokens
	/// @param receiver The account to receive the underlying amounts of token0 and token1
	/// @return amount0 Amount of token0 transferred to receiver for burning `burnAmount`
	/// @return amount1 Amount of token1 transferred to receiver for burning `burnAmount`
	/// @return liquidityBurned Amount of liquidity removed from the underlying Uniswap V3 position
	// solhint-disable-next-line function-max-lines
	function burn(
		uint256 burnAmount,
		uint256 maxSwapSlippage,
		uint8 outputToken,
		address receiver
	) external nonReentrant returns (uint256 amount0, uint256 amount1, uint128 liquidityBurned) {
		require(burnAmount > 0, "burn 0");
		require(maxSwapSlippage < basisOne, "max slippage too high");

		LocalVariablesBurn memory vars;

		vars.totalSupply = totalSupply();

		Ticks memory ticks = baseTicks;

		(uint128 liquidity, , , , ) = pool.positions(_getPositionID(ticks));

		_burn(msg.sender, burnAmount);

		vars.liquidityBurnt = FullMath.mulDiv(burnAmount, liquidity, vars.totalSupply);

		liquidityBurned = SafeCast.toUint128(vars.liquidityBurnt);

		(uint256 burn0, uint256 burn1, uint256 fee0, uint256 fee1) = _withdraw(
			ticks,
			liquidityBurned
		);

		(fee0, fee1) = _applyFees(fee0, fee1);

		amount0 =
			burn0 +
			FullMath.mulDiv(
				token0.balanceOf(address(this)) - burn0 - managerBalance0,
				burnAmount,
				vars.totalSupply
			);

		amount1 =
			burn1 +
			FullMath.mulDiv(
				token1.balanceOf(address(this)) - burn1 - managerBalance1,
				burnAmount,
				vars.totalSupply
			);

		// ZapOut logic Note test properly amounts
		if (outputToken == 0) {
			(vars.amount0Delta, vars.amount1Delta) = _swap(amount1, false, maxSwapSlippage);
			amount0 = uint256(SafeCast.toInt256(amount0) - vars.amount0Delta);
			amount1 = uint256(SafeCast.toInt256(amount1) - vars.amount1Delta);
		} else if (outputToken == 1) {
			(vars.amount0Delta, vars.amount1Delta) = _swap(amount0, true, maxSwapSlippage);
			amount0 = uint256(SafeCast.toInt256(amount0) - vars.amount0Delta);
			amount1 = uint256(SafeCast.toInt256(amount1) - vars.amount1Delta);
		}

		_transferAmounts(amount0, amount1, receiver);

		emit Burned(receiver, burnAmount, amount0, amount1, liquidityBurned);
	}

	// --- External manager functions --- // Called by Pool Manager

	/// @notice Change the range of underlying UniswapV3 position, only manager can call
	/// @dev When changing the range the inventory of token0 and token1 may be rebalanced
	/// with a swap to deposit as much liquidity as possible into the new position.
	/// Swap a proportion of this leftover to deposit more liquidity into the position,
	/// since any leftover will be unused and sit idle until the next rebalance
	/// @param newLowerTick The new lower bound of the position's range
	/// @param newUpperTick The new upper bound of the position's range
	/// @param minLiquidity Minimum liquidity of the new position in order to not revert
	// solhint-disable-next-line function-max-lines
	function executiveRebalance(
		int24 newLowerTick,
		int24 newUpperTick,
		uint128 minLiquidity
	) external onlyManager {
		//validate new ticks
		require(
			_validateTickSpacing(address(pool), newLowerTick, newUpperTick),
			"tickSpacing mismatch"
		);

		// First check pool health
		_checkPriceSlippage();

		uint128 liquidity;
		uint128 newLiquidity;

		Ticks memory ticks = baseTicks;
		Ticks memory newTicks = Ticks(newLowerTick, newUpperTick);

		if (totalSupply() > 0) {
			(liquidity, , , , ) = pool.positions(_getPositionID(ticks));
			if (liquidity > 0) {
				(, , uint256 fee0, uint256 fee1) = _withdraw(ticks, liquidity);

				(fee0, fee1) = _applyFees(fee0, fee1);
			}

			// Update storage ticks
			baseTicks = newTicks;

			uint256 reinvest0 = token0.balanceOf(address(this)) - managerBalance0;
			uint256 reinvest1 = token1.balanceOf(address(this)) - managerBalance1;

			(uint256 finalAmount0, uint256 finalAmount1) = _balanceAmounts(
				newTicks,
				reinvest0,
				reinvest1
			);

			_addLiquidity(newTicks, finalAmount0, finalAmount1);

			(newLiquidity, , , , ) = pool.positions(_getPositionID(newTicks));

			require(newLiquidity > minLiquidity, "min liquidity");
		} else {
			// Update storage ticks
			baseTicks = newTicks;
		}

		emit Rebalance(newLowerTick, newUpperTick, liquidity, newLiquidity);
	}

	// --- External authorized functions --- //  Can be automated

	/// @notice Reinvest fees earned into underlying position, only authorized executors can call
	/// @dev As the ticks do not change, liquidity must increase, otherwise will revert
	/// Position bounds CANNOT be altered, only manager may via executiveRebalance
	function rebalance() external onlyAuthorized {
		// First check pool health
		_checkPriceSlippage();

		Ticks memory ticks = baseTicks;

		// In rebalance ticks remain the same
		bytes32 key = _getPositionID(ticks);

		(uint128 liquidity, , , , ) = pool.positions(key);

		_rebalance(liquidity, ticks);

		(uint128 newLiquidity, , , , ) = pool.positions(key);
		require(newLiquidity > liquidity, "liquidity must increase");

		emit Rebalance(ticks.lowerTick, ticks.upperTick, liquidity, newLiquidity);
	}

	/// @notice Withdraw manager fees accrued, only authorized executors can call
	/// Target account to receive fees is managerTreasury, alterable by only manager
	function withdrawManagerBalance() external onlyAuthorized {
		uint256 amount0 = managerBalance0;
		uint256 amount1 = managerBalance1;

		managerBalance0 = 0;
		managerBalance1 = 0;

		_transferAmounts(amount0, amount1, managerTreasury);
	}

	// --- External view functions --- //

	/// @notice Compute max Grizzly Vault tokens that can be minted from `amount0Max` & `amount1Max`
	/// @param amount0Max The maximum amount of token0 to forward on mint
	/// @param amount0Max The maximum amount of token1 to forward on mint
	/// @return amount0 Actual amount of token0 to forward when minting `mintAmount`
	/// @return amount1 Actual amount of token1 to forward when minting `mintAmount`
	/// @return mintAmount Maximum number of Grizzly Vault tokens to mint
	function getMintAmounts(
		uint256 amount0Max,
		uint256 amount1Max
	) external view returns (uint256 amount0, uint256 amount1, uint256 mintAmount) {
		uint256 totalSupply = totalSupply();

		if (totalSupply > 0) {
			(amount0, amount1, mintAmount) = _computeMintAmounts(
				totalSupply,
				amount0Max,
				amount1Max
			);
		} else {
			Ticks memory ticks = baseTicks;
			(uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

			uint128 newLiquidity = _liquidityForAmounts(ticks, sqrtRatioX96, amount0Max, amount1Max);

			mintAmount = uint256(newLiquidity);
			(amount0, amount1) = _amountsForLiquidity(newLiquidity, ticks, sqrtRatioX96);
		}
	}

	/// @notice Compute total underlying holdings of the Grizzly Vault token supply
	/// Includes current liquidity invested in uniswap position, current fees earned
	/// and any uninvested leftover (but does not include manager or Grizzly fees accrued)
	/// @return amount0Current current total underlying balance of token0
	/// @return amount1Current current total underlying balance of token1
	function getUnderlyingBalances()
		public
		view
		returns (uint256 amount0Current, uint256 amount1Current)
	{
		(uint160 sqrtRatioX96, int24 tick, , , , , ) = pool.slot0();
		return _getUnderlyingBalances(sqrtRatioX96, tick);
	}

	function getUnderlyingBalancesAtPrice(
		uint160 sqrtRatioX96
	) external view returns (uint256 amount0Current, uint256 amount1Current) {
		(, int24 tick, , , , , ) = pool.slot0();
		return _getUnderlyingBalances(sqrtRatioX96, tick);
	}

	function estimateFees() external view returns (uint256 token0Fee, uint256 token1Fee) {
		(, int24 currentTick, , , , , ) = pool.slot0();

		Ticks memory ticks = baseTicks;

		(
			uint128 liquidity,
			uint256 feeGrowthInside0Last,
			uint256 feeGrowthInside1Last,
			uint128 tokensOwed0,
			uint128 tokensOwed1
		) = pool.positions(_getPositionID(ticks));

		// Compute current fees earned
		token0Fee =
			_computeFeesEarned(true, feeGrowthInside0Last, currentTick, liquidity, ticks) +
			tokensOwed0;
		token1Fee =
			_computeFeesEarned(false, feeGrowthInside1Last, currentTick, liquidity, ticks) +
			tokensOwed1;
	}

	// --- Internal core functions --- //

	function _rebalance(uint128 liquidity, Ticks memory ticks) internal {
		(, , uint256 feesEarned0, uint256 feesEarned1) = _withdraw(ticks, liquidity);

		(feesEarned0, feesEarned1) = _applyFees(feesEarned0, feesEarned1);

		uint256 leftover0 = token0.balanceOf(address(this)) - managerBalance0;
		uint256 leftover1 = token1.balanceOf(address(this)) - managerBalance1;

		// Note if we balance amounts in _rebalance it can underflow
		// Note check how precise is adding liquidity maintaining the ticks
		_addLiquidity(ticks, leftover0, leftover1);
	}

	function _withdraw(
		Ticks memory ticks,
		uint128 liquidity
	) internal returns (uint256 burn0, uint256 burn1, uint256 fee0, uint256 fee1) {
		uint256 preBalance0 = token0.balanceOf(address(this));
		uint256 preBalance1 = token1.balanceOf(address(this));

		(burn0, burn1) = pool.burn(ticks.lowerTick, ticks.upperTick, liquidity);

		pool.collect(
			address(this),
			ticks.lowerTick,
			ticks.upperTick,
			type(uint128).max,
			type(uint128).max
		);

		fee0 = token0.balanceOf(address(this)) - preBalance0 - burn0;
		fee1 = token1.balanceOf(address(this)) - preBalance1 - burn1;
	}

	function _balanceAmounts(
		Ticks memory ticks,
		uint256 amount0Desired,
		uint256 amount1Desired
	) internal returns (uint256 finalAmount0, uint256 finalAmount1) {
		(uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

		// Get max liquidity for amounts available
		uint128 liquidity = _liquidityForAmounts(
			ticks,
			sqrtRatioX96,
			amount0Desired,
			amount1Desired
		);
		// Get correct amounts of each token for the liquidity we have
		(uint256 amount0, uint256 amount1) = _amountsForLiquidity(liquidity, ticks, sqrtRatioX96);

		// Determine the trade direction
		bool _zeroForOne;
		if (amount1Desired == 0) {
			_zeroForOne = true;
		} else {
			_zeroForOne = _amountsDirection(amount0Desired, amount1Desired, amount0, amount1);
		}

		// Determine the amount to swap, it is not 100% precise but is a very good approximation
		uint256 _amountSpecified = _zeroForOne
			? ((amount0Desired - amount0) * (basisOne + uniPoolFee)) / (2 * basisOne + uniPoolFee)
			: ((amount1Desired - amount1) * (basisOne + uniPoolFee)) / (2 * basisOne + uniPoolFee);

		if (_amountSpecified > 0) {
			(int256 amount0Delta, int256 amount1Delta) = _swap(
				_amountSpecified,
				_zeroForOne,
				slippageRebalanceMax
			);
			finalAmount0 = uint256(SafeCast.toInt256(amount0Desired) - amount0Delta);
			finalAmount1 = uint256(SafeCast.toInt256(amount1Desired) - amount1Delta);
		} else {
			return (amount0, amount1);
		}
	}

	function _addLiquidity(Ticks memory ticks, uint256 amount0, uint256 amount1) internal {
		// As we have made a swap in the pool sqrtRatioX96 changes
		(uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

		uint128 liquidityAfterSwap = _liquidityForAmounts(ticks, sqrtRatioX96, amount0, amount1);

		if (liquidityAfterSwap > 0) {
			pool.mint(address(this), ticks.lowerTick, ticks.upperTick, liquidityAfterSwap, "");
		}
	}

	/// @notice slippageMax variable as argument to differentiate between user and rebalance swaps
	function _swap(
		uint256 amountIn,
		bool zeroForOne,
		uint256 slippageMax
	) internal returns (int256, int256) {
		(uint160 _sqrtPriceX96, , , , , , ) = pool.slot0();

		uint256 _slippageMax = slippageMax == 0 ? slippageUserMax : slippageMax;
		uint256 _slippageSqrt = zeroForOne
			? prbSqrt(basisOne - _slippageMax)
			: prbSqrt(basisOne + _slippageMax);

		return
			pool.swap(
				address(this),
				zeroForOne, // Swap direction, true: token0 -> token1, false: token1 -> token0
				SafeCast.toInt256(amountIn),
				uint160(uint256((_sqrtPriceX96 * _slippageSqrt) / basisOneSqrt)), // sqrtPriceLimitX96
				abi.encode(0)
			);
	}

	function _transferAmounts(uint256 amount0, uint256 amount1, address receiver) internal {
		if (amount0 > 0) {
			token0.safeTransfer(receiver, amount0);
		}

		if (amount1 > 0) {
			token1.safeTransfer(receiver, amount1);
		}
	}

	function _applyFees(
		uint256 rawFee0,
		uint256 rawFee1
	) internal returns (uint256 fee0, uint256 fee1) {
		uint256 managerFee0 = (rawFee0 * managerFee) / basisOne;
		uint256 managerFee1 = (rawFee1 * managerFee) / basisOne;

		managerBalance0 += managerFee0;
		managerBalance1 += managerFee1;

		fee0 = rawFee0 - managerFee0;
		fee1 = rawFee1 - managerFee1;

		emit FeesEarned(fee0, fee1);
	}

	// --- Internal view functions --- //

	function _getUnderlyingBalances(
		uint160 sqrtRatioX96,
		int24 tick
	) internal view returns (uint256 amount0Current, uint256 amount1Current) {
		Ticks memory ticks = baseTicks;

		(
			uint128 liquidity,
			uint256 feeGrowthInside0Last,
			uint256 feeGrowthInside1Last,
			uint128 tokensOwed0,
			uint128 tokensOwed1
		) = pool.positions(_getPositionID(ticks));

		// Compute current holdings from liquidity
		(amount0Current, amount1Current) = _amountsForLiquidity(liquidity, ticks, sqrtRatioX96);

		// Compute current fees earned
		uint256 fee0 = _computeFeesEarned(true, feeGrowthInside0Last, tick, liquidity, ticks) +
			uint256(tokensOwed0);
		uint256 fee1 = _computeFeesEarned(false, feeGrowthInside1Last, tick, liquidity, ticks) +
			uint256(tokensOwed1);

		fee0 = (fee0 * (basisOne - managerFee)) / basisOne;
		fee1 = (fee1 * (basisOne - managerFee)) / basisOne;

		// Add any leftover in contract to current holdings
		amount0Current += fee0 + token0.balanceOf(address(this)) - managerBalance0;
		amount1Current += fee1 + token1.balanceOf(address(this)) - managerBalance1;
	}

	/// @notice Computes the token0 and token1 value for a given amount of liquidity
	function _amountsForLiquidity(
		uint128 liquidity,
		Ticks memory ticks,
		uint160 sqrtRatioX96
	) internal view returns (uint256, uint256) {
		return
			LiquidityAmounts.getAmountsForLiquidity(
				sqrtRatioX96,
				ticks.lowerTick.getSqrtRatioAtTick(),
				ticks.upperTick.getSqrtRatioAtTick(),
				liquidity
			);
	}

	/// @notice Gets the liquidity for the available amounts of token0 and token1
	function _liquidityForAmounts(
		Ticks memory ticks,
		uint160 sqrtRatioX96,
		uint256 amount0,
		uint256 amount1
	) internal view returns (uint128) {
		return
			LiquidityAmounts.getLiquidityForAmounts(
				sqrtRatioX96,
				ticks.lowerTick.getSqrtRatioAtTick(),
				ticks.upperTick.getSqrtRatioAtTick(),
				amount0,
				amount1
			);
	}

	function _computeMintAmounts(
		uint256 totalSupply,
		uint256 amount0Max,
		uint256 amount1Max
	) internal view returns (uint256 amount0, uint256 amount1, uint256 mintAmount) {
		(uint256 amount0Current, uint256 amount1Current) = getUnderlyingBalances();

		// Compute proportional amount of tokens to mint
		if (amount0Current == 0 && amount1Current > 0) {
			mintAmount = FullMath.mulDiv(amount1Max, totalSupply, amount1Current);
		} else if (amount1Current == 0 && amount0Current > 0) {
			mintAmount = FullMath.mulDiv(amount0Max, totalSupply, amount0Current);
		} else if (amount0Current == 0 && amount1Current == 0) {
			revert("no balances");
		} else {
			// Only if both are non-zero
			uint256 amount0Mint = FullMath.mulDiv(amount0Max, totalSupply, amount0Current);
			uint256 amount1Mint = FullMath.mulDiv(amount1Max, totalSupply, amount1Current);
			require(amount0Mint > 0 && amount1Mint > 0, "mint 0");

			mintAmount = amount0Mint < amount1Mint ? amount0Mint : amount1Mint;
		}

		// Compute amounts owed to contract
		amount0 = FullMath.mulDivRoundingUp(mintAmount, amount0Current, totalSupply);
		amount1 = FullMath.mulDivRoundingUp(mintAmount, amount1Current, totalSupply);
	}

	// solhint-disable-next-line function-max-lines
	function _computeFeesEarned(
		bool isZero,
		uint256 feeGrowthInsideLast,
		int24 tick,
		uint128 liquidity,
		Ticks memory ticks
	) internal view returns (uint256 fee) {
		uint256 feeGrowthOutsideLower;
		uint256 feeGrowthOutsideUpper;
		uint256 feeGrowthGlobal;

		if (isZero) {
			feeGrowthGlobal = pool.feeGrowthGlobal0X128();
			(, , feeGrowthOutsideLower, , , , , ) = pool.ticks(ticks.lowerTick);
			(, , feeGrowthOutsideUpper, , , , , ) = pool.ticks(ticks.upperTick);
		} else {
			feeGrowthGlobal = pool.feeGrowthGlobal1X128();
			(, , , feeGrowthOutsideLower, , , , ) = pool.ticks(ticks.lowerTick);
			(, , , feeGrowthOutsideUpper, , , , ) = pool.ticks(ticks.upperTick);
		}

		unchecked {
			// Calculate fee growth below
			uint256 feeGrowthBelow;
			if (tick >= ticks.lowerTick) {
				feeGrowthBelow = feeGrowthOutsideLower;
			} else {
				feeGrowthBelow = feeGrowthGlobal - feeGrowthOutsideLower;
			}

			// Calculate fee growth above
			uint256 feeGrowthAbove;
			if (tick < ticks.upperTick) {
				feeGrowthAbove = feeGrowthOutsideUpper;
			} else {
				feeGrowthAbove = feeGrowthGlobal - feeGrowthOutsideUpper;
			}

			uint256 feeGrowthInside = feeGrowthGlobal - feeGrowthBelow - feeGrowthAbove;
			fee = FullMath.mulDiv(
				liquidity,
				feeGrowthInside - feeGrowthInsideLast,
				0x100000000000000000000000000000000
			);
		}
	}

	/// @dev Needed in case token0 and token1 have different decimals
	function _amountsDirection(
		uint256 amount0Desired,
		uint256 amount1Desired,
		uint256 amount0,
		uint256 amount1
	) internal pure returns (bool zeroGreaterOne) {
		zeroGreaterOne = (amount0Desired - amount0) * amount1Desired >
			(amount1Desired - amount1) * amount0Desired
			? true
			: false;
	}

	function _checkPriceSlippage() internal view {
		uint32[] memory secondsAgo = new uint32[](2);
		secondsAgo[0] = oracleSlippageInterval;
		secondsAgo[1] = 0;

		(int56[] memory tickCumulatives, ) = pool.observe(secondsAgo);

		require(tickCumulatives.length == 2, "array length");
		uint160 avgSqrtRatioX96;
		unchecked {
			int24 avgTick = int24(
				(tickCumulatives[1] - tickCumulatives[0]) / int56(uint56(oracleSlippageInterval))
			);
			avgSqrtRatioX96 = avgTick.getSqrtRatioAtTick();
		}

		(uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

		uint256 oracleSlippageSqrt = avgSqrtRatioX96 < sqrtPriceX96
			? prbSqrt(basisOne + oracleSlippage)
			: prbSqrt(basisOne - oracleSlippage);

		uint160 limitSqrtRatioX96 = uint160((avgSqrtRatioX96 * oracleSlippageSqrt) / basisOneSqrt);

		bool correctBound = avgSqrtRatioX96 < sqrtPriceX96
			? sqrtPriceX96 < limitSqrtRatioX96
			: sqrtPriceX96 > limitSqrtRatioX96;

		require(correctBound, "high slippage");
	}
}
