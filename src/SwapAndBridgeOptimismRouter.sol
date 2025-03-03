// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

interface IL1StandardBridge {

    function depositETHTo(
        address _to,
        uint32 _minGasLimit,
        bytes calldata _extraData
    ) external payable;

    function depositERC20To(
        address _l1Token,
        address _l2Token,
        address _to,
        uint256 _amount,
        uint32 _minGasLimit,
        bytes calldata _extraData
    ) external;
}

// This router contract can bridge output tokens from a swap to another chain. By
// integrating with Optimism's native bridging contracts and swapping a token through
// the pool manager, it bridges the output token from L1 to an Optimism L2, combining
// the swap + bridge action in a single transaction.
contract SwapAndBridgeOptimismRouter is Ownable {
	using CurrencyLibrary for Currency;
	using CurrencySettler for Currency;
	using TransientStateLibrary for IPoolManager;

    //////////////////////////////// ERRORS ////////////////////////////////
    error SBO_CallerNotManager();
    error SBO_TokenCannotBeBridged();

	IPoolManager public immutable manager;
    IL1StandardBridge public immutable l1StandardBridge;

    /////////////////////////// DATA STRUCTURES ///////////////////////////
    struct CallbackData {
        address sender;
        SwapSettings settings;
        PoolKey key;
        IPoolManager.SwapParams params;
        bytes hookData;
    }

    struct SwapSettings {
        bool bridgeTokens;
        address recipientAddress;
    }

    // we want to bridge tokens if and only if they're supported by the native bridge:
    // maintain a mapping of token contract addresses on L1 and their equivalent on the L2,
    // which can only be updated by the owner of the contract
    mapping(address l1Token => address l2Token) public l1ToL2TokenAddresses;

	constructor(
        IPoolManager _manager,
        IL1StandardBridge _l1StandardBridge
    ) Ownable(msg.sender) {
        manager = _manager;
        l1StandardBridge = _l1StandardBridge;
    }

    function swap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        SwapSettings memory settings,
        bytes memory hookData
    ) external payable returns (BalanceDelta delta) {
        // If user requested a bridge of the output tokens
        // make sure the output token can be bridged at all
        // otherwise revert the transaction early
        if (settings.bridgeTokens) {
            Currency l1TokenToBridge = params.zeroForOne
                ? key.currency1
                : key.currency0;

            // address(0) is used for the native currency
            if (!l1TokenToBridge.isAddressZero()) {
            //if (!l1TokenToBridge.isNative()) {
                address l2Token = l1ToL2TokenAddresses[
                    Currency.unwrap(l1TokenToBridge)
                ];
                if (l2Token == address(0)) revert SBO_TokenCannotBeBridged();
            }
        }

        // Unlock the pool manager which will trigger a callback
        delta = abi.decode(
            manager.unlock(
                abi.encode(
                    CallbackData(msg.sender, settings, key, params, hookData)
                )
            ),
            (BalanceDelta)
        );

        // Send any left over ETH to the sender
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0)
            CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, ethBalance);
    }

    ////////////////////////// HELPER FUNCTIONS //////////////////////////
    function addL1ToL2TokenAddress(
        address l1Token,
        address l2Token
    ) external onlyOwner {
        l1ToL2TokenAddresses[l1Token] = l2Token;
    }
}