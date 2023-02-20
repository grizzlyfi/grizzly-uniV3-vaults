// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.4;

import { OwnableUninitialized } from "./OwnableUninitialized.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { IGrizzlyVaultStorage } from "../interfaces/IGrizzlyVaultStorage.sol";

/// @dev Single Global upgradeable state var storage base
/// @dev Add all inherited contracts with state vars here
/// @dev ERC20Upgradable Includes Initialize
// solhint-disable-next-line max-states-count
abstract contract GrizzlyVaultStorage is
	IGrizzlyVaultStorage,
	ERC20Upgradeable,
	ReentrancyGuardUpgradeable,
	OwnableUninitialized
{
	string public constant version = "1.0.0";

	Ticks public baseTicks;

	uint16 public oracleSlippageBPS;
	uint32 public oracleSlippageInterval;

	uint16 public managerFeeBPS;
	address public managerTreasury;

	uint256 public managerBalance0;
	uint256 public managerBalance1;

	IUniswapV3Pool public pool;
	IERC20 public token0;
	IERC20 public token1;
	uint24 public uniPoolFee;

	uint256 internal constant MIN_INITIAL_SHARES = 1e9;
	uint256 internal constant basisOne = 10000;

	// In bps, how much slippage we allow between swaps -> 50 = 0.5% slippage
	uint256 public slippageUserMax = 100;
	uint256 public slippageRebalanceMax = 100;

	address public immutable factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

	address public keeperAddress;

	event UpdateGelatoParams(uint16 oracleSlippageBPS, uint32 oracleSlippageInterval);
	event SetManagerFee(uint16 managerFee);

	modifier onlyAuthorized() {
		require(msg.sender == manager() || msg.sender == keeperAddress, "not authorized");
		_;
	}

	/// @notice Initialize storage variables on a new G-UNI pool, only called once
	/// @param _name Name of G-UNI token
	/// @param _symbol Symbol of G-UNI token
	/// @param _pool Address of Uniswap V3 pool
	/// @param _managerFeeBPS Proportion of fees earned that go to manager treasury
	/// Note that the 4 above params are NOT UPDATABLE AFTER INITIALIZATION
	/// @param _lowerTick Initial lowerTick (only changeable with executiveRebalance)
	/// @param _lowerTick Initial upperTick (only changeable with executiveRebalance)
	/// @param _manager_ Address of manager (ownership can be transferred)
	function initialize(
		string memory _name,
		string memory _symbol,
		address _pool,
		uint16 _managerFeeBPS,
		int24 _lowerTick,
		int24 _upperTick,
		address _manager_
	) external override initializer {
		require(_managerFeeBPS <= 10000, "bps");

		// These variables are immutable after initialization
		pool = IUniswapV3Pool(_pool);
		token0 = IERC20(pool.token0());
		token1 = IERC20(pool.token1());
		uniPoolFee = pool.fee();
		managerFeeBPS = _managerFeeBPS; // if set to 0 here manager can still initialize later

		// These variables can be updated by the manager
		oracleSlippageInterval = 5 minutes; // default: last five minutes;
		oracleSlippageBPS = 500; // default: 5% slippage

		managerTreasury = _manager_; // default: treasury is admin

		baseTicks.lowerTick = _lowerTick;
		baseTicks.upperTick = _upperTick;

		_manager = _manager_;

		// e.g. "Grizzly Uniswap USDC/DAI LP" and "hsUSDC-DAI"
		__ERC20_init(_name, _symbol);
		__ReentrancyGuard_init();
	}

	/// @notice Change configurable parameters, only manager can call
	/// @param newOracleSlippageBPS Maximum slippage on swaps during gelato rebalance
	/// @param newOracleSlippageInterval Length of time for TWAP used in computing slippage on swaps
	/// @param newTreasury Address where managerFee withdrawals are sent
	function updateConfigParams(
		uint16 newOracleSlippageBPS,
		uint32 newOracleSlippageInterval,
		address newTreasury
	) external onlyManager {
		require(newOracleSlippageBPS <= 10000, "bps");

		if (newOracleSlippageBPS != 0) oracleSlippageBPS = newOracleSlippageBPS;
		if (newOracleSlippageInterval != 0) oracleSlippageInterval = newOracleSlippageInterval;
		emit UpdateGelatoParams(newOracleSlippageBPS, newOracleSlippageInterval);

		if (newTreasury != address(0)) managerTreasury = newTreasury;
	}

	/// @notice setManagerFee sets a managerFee, only manager can call
	/// @param _managerFeeBPS Proportion of fees earned that are credited to manager in Basis Points
	function setManagerFee(uint16 _managerFeeBPS) external onlyManager {
		require(_managerFeeBPS > 0 && _managerFeeBPS <= 10000, "bps");
		emit SetManagerFee(_managerFeeBPS);
		managerFeeBPS = _managerFeeBPS;
	}

	function getPositionID() external view returns (bytes32 positionID) {
		return _getPositionID(baseTicks);
	}

	function _getPositionID(Ticks memory _ticks) internal view returns (bytes32 positionID) {
		return keccak256(abi.encodePacked(address(this), _ticks.lowerTick, _ticks.upperTick));
	}

	function setKeeperAddress(address _keeperAddress) external onlyManager {
		require(_keeperAddress != address(0), "zeroAddress");
		keeperAddress = _keeperAddress;
	}

	function setManagerParams(uint256 _slippageUserMax, uint256 _slippageRebalanceMax)
		external
		onlyManager
	{
		require(_slippageUserMax <= basisOne && _slippageRebalanceMax <= basisOne, "wrong inputs");
		slippageUserMax = _slippageUserMax;
		slippageRebalanceMax = _slippageRebalanceMax;
	}
}