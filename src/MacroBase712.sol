// SPDX-License-Identifier: AGPLv3
pragma solidity ^0.8.26;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import { ISuperfluid } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { IUserDefinedMacro } from "@superfluid-finance/ethereum-contracts/contracts/utils/MacroForwarder.sol";

/**
 * @title Abstract contract that extends EIP712 and implements IUserDefinedMacro.
 *
 * This contract provides a base for handling actions with associated operations and validation
 *  using EIP712 signatures.
 * The contract maintains a mapping of action codes to `Action` structs and provides functions to
 *  build batch operations and handle post-checks per action.
 *
 * @dev The `batchParams` format is as follows:
 * - `actionCode` (uint8): The unique code identifying the action.
 * - `lang` (bytes32): The language code for the message.
 * - `actionParams` (bytes): Arbitrary data for building operations and validation.
 * - `signatureVRS` (bytes): The signature in VRS format.
 */
abstract contract MacroBase712 is EIP712, IUserDefinedMacro {
    error UnknownActionCode(uint8 actionCode);
    error ActionCodeZeroNotAllowed();
    error InvalidSignature();
    error UnsupportedLanguage();

    /**
     * @dev Represents an action with associated operations and validation.
     */
    struct Action {
        /**
         * @dev Id of the action, used for dispatching. Must be non-zero!
         */
        uint8 actionCode;
        /**
         * @dev Function to build operations for the action.
         * @param host The Superfluid instance.
         * @param actionParams Arbitrary data for building operations.
         * @param msgSender The address associated with the action.
         * @return operations Array of operations.
         */
        function(ISuperfluid /*host*/, bytes memory /*actionParams*/, address /*msgSender*/)
            internal view returns (ISuperfluid.Operation[] memory) buildOperations;
        /**
         * @dev Function to get the digest for the the signature validation.
         * @param actionParams Arbitrary data for creating the digest.
         * @param lang The language code for the message.
         * @return digest The digest for the action.
         */
        function(bytes memory /*actionParams*/, bytes32 /*lang*/)
            internal view returns (bytes32) getDigest;
        /**
         * @dev Function to handle post-check operations for the action.
         *      Use `_noPostCheck` for an empty implementation.
         * @param host The Superfluid instance.
         * @param actionParams Arbitrary data for post-check handling.
         * @param msgSender The address associated with the action.
         */
        function(ISuperfluid /*host*/, bytes memory /*actionParams*/, address /*msgSender*/)
            internal view postCheck;
    }

    mapping(uint8 => Action) internal _actionHandlers;

    constructor(string memory name, string memory version) EIP712(name, version) {
        Action[] memory actions = _getActions();

        for (uint256 i = 0; i < actions.length; i++) {
            // We don't allow 0 as actionCode so we can use it
            // to check if a mapping entry exists.
            if (actions[i].actionCode == 0) revert ActionCodeZeroNotAllowed();
            _actionHandlers[actions[i].actionCode] = actions[i];
        }
    }

    /**
     * @dev Abstract function that enforces child classes to provide the actions supported.
     * This function should be overridden by any contract that inherits from this base contract.
     * It is intended to return an array of Action structs, where each Action represents an action
     * that the child contract supports.
     *
     * @return An array of Action structs representing the supported actions.
     */
    function _getActions() internal view virtual returns (Action[] memory);

    function buildBatchOperations(ISuperfluid host, bytes memory params, address msgSender)
        external
        view
        override
        returns (ISuperfluid.Operation[] memory operations)
    {
        (uint8 actionCode, bytes32 lang, bytes memory actionParams, bytes memory signatureVRS) =
            _decodeBatchParams(params);

        if (_actionHandlers[actionCode].actionCode == 0) {
            revert UnknownActionCode(actionCode);
        }

        bytes32 digest = _actionHandlers[actionCode].getDigest(actionParams, lang);
        if (!_validateSignature(digest, signatureVRS, msgSender)) {
            revert InvalidSignature();
        }

        return _actionHandlers[actionCode].buildOperations(host, actionParams, msgSender);
    }

    function postCheck(ISuperfluid host, bytes memory params, address msgSender) external view override {
        (uint8 actionCode, /*lang*/, bytes memory actionParams, /*signatureVRS*/ ) = _decodeBatchParams(params);

        if (_actionHandlers[actionCode].actionCode == 0) {
            revert UnknownActionCode(actionCode);
        }

        _actionHandlers[actionCode].postCheck(host, actionParams, msgSender);
    }

    function _validateSignature(bytes32 digest, bytes memory signatureVRS, address msgSender)
        private
        view
        returns (bool)
    {
        (uint8 v, bytes32 r, bytes32 s) = abi.decode(signatureVRS, (uint8, bytes32, bytes32));
        return SignatureChecker.isValidSignatureNow(msgSender, digest, abi.encodePacked(r,s,v));
    }

    function _decodeBatchParams(bytes memory batchParams)
        private
        pure
        returns (uint8 actionCode, bytes32 lang, bytes memory actionParams, bytes memory signatureVRS)
    {
        bytes memory providedParams;
        (providedParams, signatureVRS) = abi.decode(batchParams, (bytes, bytes));
        (actionCode, lang, actionParams) = abi.decode(providedParams, (uint8, bytes32, bytes));
    }

    /// to be used as dummy post check which does nothing
    function _noPostCheck(ISuperfluid, bytes memory, address) internal view {}
}
