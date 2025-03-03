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

    /**
     * The function serves three main purposes:
     * Validation: Checks if the output token can be bridged (if bridging is requested)
     * Swap Execution: Performs the token swap through the Uniswap V4 pool manager
     * Cleanup: Returns any excess ETH to the sender
     * Note: the manager.unlock() call will trigger a callback to this contract where
     * the actual swap and bridging logic will be executed. This pattern ensures atomic
     * execution of the transaction.
     */
    function swap(
        PoolKey memory key, // includes pool configuration (tokens, fee tier, etc.)
        IPoolManager.SwapParams memory params, // swap parameters (direction, amount)
        SwapSettings memory settings, // bridging preferences
        bytes memory hookData // additional data for any attached hooks
    ) external payable returns (BalanceDelta delta) {
        // Check if user wants to bridge tokens after the swap
        if (settings.bridgeTokens) {
            // Determine which token will be the output token based on swap direction
            // If zeroForOne is true, we're swapping token0 for token1, so token1 is output
            // If zeroForOne is false, we're swapping token1 for token0, so token0 is output
            Currency l1TokenToBridge = params.zeroForOne
                ? key.currency1
                : key.currency0;

            // address(0) is used for the native currency
            if (!l1TokenToBridge.isAddressZero()) {
                // Look up the corresponding L2 token address from the mapping
                address l2Token = l1ToL2TokenAddresses[
                    Currency.unwrap(l1TokenToBridge)
                ];
                // If no L2 token is registered (address(0)), the token can't be bridged
                if (l2Token == address(0)) revert SBO_TokenCannotBeBridged();
            }
        }

        // Execute the swap by unlocking the pool manager
        // This will trigger a callback where the swap logic occurs
        // The callback data includes all necessary information for the swap
        delta = abi.decode(
            manager.unlock(
                abi.encode(
                    CallbackData(msg.sender, settings, key, params, hookData)
                )
            ),
            (BalanceDelta)
        );

        // After the swap is complete, if there's any ETH left in the contract
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0)
            // Send it back to the original sender
            CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, ethBalance);
    }

    /**
     * This function is the core of the swap and bridge logic. It's called by the pool
     * manager during the unlock operation and handles:
     * Security: Ensures only the pool manager can call this function
     * Swap Execution: Performs the actual token swap
     * Settlement:
     * For tokens owed (negative delta): Takes them from the original sender
     * For tokens we receive (positive delta): Either sends them directly to the recipient or
     * bridges them to L2
     * Return: Returns the swap results back to the pool manager
     * The function handles both sides of the swap (token0 and token1) and ensures proper
     * settlement regardless of which direction the swap went. The _take function (called
     * for positive deltas) handles the actual bridging logic if bridgeTokens is set to true.
     */
    function unlockCallback(
        bytes calldata rawData // Encoded callback data from the swap() function
    ) external returns (bytes memory) {
        // Security check: only the pool manager can call this function
        if (msg.sender != address(manager)) revert SBO_CallerNotManager();

        // Decode the callback data that was passed in the swap() function
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        // Execute the swap through the pool manager
        // Returns a BalanceDelta indicating how many tokens were swapped
        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);

        // Get the net token changes for both tokens in the pool
        // Negative means we owe tokens, positive means we receive tokens
        int256 deltaAfter0 = manager.currencyDelta(
            address(this),
            data.key.currency0
        );
        int256 deltaAfter1 = manager.currencyDelta(
            address(this),
            data.key.currency1
        );

        // If we owe token0 (negative delta)
        if (deltaAfter0 < 0) {
            // Settle the payment using tokens from the original sender
            data.key.currency0.settle(
                manager,
                data.sender,
                uint256(-deltaAfter0), // Convert negative to positive
                false
            );
        }

        // Same as above but for token1
        if (deltaAfter1 < 0) {
            data.key.currency1.settle(
                manager,
                data.sender,
                uint256(-deltaAfter1),
                false
            );
        }

        // If we received token0 (positive delta)
        if (deltaAfter0 > 0) {
            // Take the tokens and either send to recipient or bridge them
            _take(
                data.key.currency0,
                data.settings.recipientAddress,
                uint256(deltaAfter0),
                data.settings.bridgeTokens
            );
        }

        // Same as above but for token1
        if (deltaAfter1 > 0) {
            _take(
                data.key.currency1,
                data.settings.recipientAddress,
                uint256(deltaAfter1),
                data.settings.bridgeTokens
            );
        }

        // Return the original swap delta
        return abi.encode(delta);
    }

    /**
     * The bridging takes place in the _take function. "take" means taking money from the PoolManager.
     * Depending on if the user specified they wanted to bridge to the L2 or not in the SwapSettings,
     * we'll either take money from PM and send it directly to the recipient on the L1, or take the
     * money to the router contract first and initiate a bridge transaction for the recipient on the L2.
     */
    function _take(
        Currency currency,
        address recipient,
        uint256 amount,
        bool bridgeToOptimism
    ) internal {
        // If not bridging, just send the tokens to the swapper
        if (!bridgeToOptimism) {
            currency.take(manager, recipient, amount, false);
        } else {
            // If we are bridging, take tokens to this router and then bridge to the recipient address on the L2
            currency.take(manager, address(this), amount, false);

            if (currency.isAddressZero()) {
                l1StandardBridge.depositETHTo{value: amount}(recipient, 0, "");
            } else {
                address l1Token = Currency.unwrap(currency);
                address l2Token = l1ToL2TokenAddresses[l1Token];

                IERC20Minimal(l1Token).approve(
                    address(l1StandardBridge),
                    amount
                );

                l1StandardBridge.depositERC20To(
                    l1Token,
                    l2Token,
                    recipient,
                    amount,
                    0,
                    ""
                );
            }
        }
    }

    ////////////////////////// HELPER FUNCTIONS //////////////////////////
    function addL1ToL2TokenAddress(
        address l1Token,
        address l2Token
    ) external onlyOwner {
        l1ToL2TokenAddresses[l1Token] = l2Token;
    }

    // to accept ETH transfers we define a receive function
    receive() external payable {}
}