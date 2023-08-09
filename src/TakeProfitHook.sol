// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BaseHook} from "periphery-next/BaseHook.sol";
import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/libraries/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/contracts/libraries/CurrencyLibrary.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

contract TakeProfitHook is BaseHook, ERC1155 {
    using PoolIdLibrary for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    mapping(PoolId poolId => int24 tickLower) public tickLowerLasts;
    mapping(PoolId poolId => mapping(int256 tick => mapping(bool zeroForOne => int256 amount)))
        public takeProfitPositions;
    mapping(uint256 tokenId => bool exists) public tokenIdExists;
    mapping(uint256 tokenId => uint256 claimable) public tokenIdClaimable;
    mapping(uint256 tokenId => uint256 supply) public tokenIdToSupply;
    mapping(uint256 tokenId => TokenData) public tokenIdData;

    struct TokenData {
        IPoolManager.PoolKey poolkey;
        int24 tick;
        bool zeroForOne;
    }

    constructor(
        IPoolManager _poolManager,
        string memory _uri
    ) BaseHook(_poolManager) ERC1155(_uri) {}

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return
            Hooks.Calls({
                beforeInitialize: false,
                afterInitialize: true,
                beforeModifyPosition: false,
                afterModiftyPosisiton: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false
            });
    }

    function _setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLast[poolId] = tickLower;
    }

    function _getTickLower(
        int24 actualTick,
        int24 tickSpacing
    ) private pure returns (int24) {
        int24 interval = actualTick / tickSpacing;
        if (actualTick < 0 && actualTick % tickSpacing != 0) interval--;
        return interval * tickSpacing;
    }

    function afterInitialize(
        address,
        IPoolManager.PoolKey calldata key,
        uint160,
        int24 tick
    ) external override poolManagerOnly returns (bytes4) {
        _setTickLowerLast(key.toId(), _getTickLower(tick, key.tickSpacing));
        return TakeProfitHook.afterInitialize.selector;
    }

    function getTokenId(
        IPoolManager.PoolKey calldata key,
        int24,
        int24 tickLower,
        bool zeroForOne
    ) public pure returns (uint256) {
        return
            uint256(
                keccak256(abi.encodepacked(key.toId().tickLower, zeroForOne))
            );
    }

    function placeOrder(
        IPoolManager.PoolKey calldata key,
        int24 tick,
        uint256 amountIn,
        bool zeroForOne
    ) external returns (int24) {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        takeProfitPositions[key.toId()][tickLower][zeroForOne] += int256(
            amountIn
        );
        uint256 tokenId = getTokenId(key, tickLower, zeroForOne);

        //If Token Id does not exist add it to mapping
        //not Every Order create new token ids, exisitng user can add more tokrn to exising token id mappping
        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdData[tokenId] = TokenData(key, tickLower, zeroForOne);
        }

        _mint(msg.sender, tokenId, amountIn, "");
        tokenIdTotalSupply[tokenId] += amountIn;

        address tokenToSoldContract = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);

        IERC20(tokenToSoldContract).transferFrom(
            msg.sender,
            address(this),
            amountIn
        );
        return tickLower;
    }

    function cancleOrder(
        IPoolManager.PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) external {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        uint256 tokenId = getTokenId(key, tickLower, zeroForOne);
        uint256 amountIn = balanceOf(msg.sender, tokenId);
        require(amountIn > 0, "TakeProfitHook: No Order To Cancle.");
        takeProfitPositions[key.toId()][tickLower][zeroForOne] -= int256(
            amountIn
        );
        tokenIdTotalSupply[tokenId] -= amountIn;
        _burn(msg.sender, tokenId, amountIn);

        address tokenToSoldContract = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);

        IERC20(tokenToSoldContract).transferFrom(
            address(this),
            msg.sender,
            amountIn
        );
    }

    function _handleSwap(
        IPoolManager.PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) external returns (BalanceDelta) {
        BalanceDelta delta = poolManager.swap(key, params);

        if (params.zeroForOne) {
            if (delta.amount0() > 0) {
                IERC20(Currency.unwrap(key.currency0)).transfer(
                    address(poolManager),
                    uint128(delta.amount0())
                );
                poolManager.settle(key.currency0);
            }

            if (delta.amount1() < 0) {
                poolManager.take(
                    key.currency1,
                    address(this),
                    uint128(-delta.amount1())
                );
            }
        } else {
            if (delta.amount1() > 0) {
                IERC20(Currency.unwrap(key.currency1)).transfer(
                    address(poolManager),
                    uint128(delta.amount1())
                );
                poolManager.settle(key.currency1);
            }
            if (delta.amount0() < 0) {
                poolManager.take(
                    key.currency0,
                    address(this),
                    uint128(-delta.amount0())
                );
            }
        }
        return delta;
    }
}
