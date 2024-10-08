// SPDX-License-Identifier: AGPLv3
pragma solidity ^0.8.26;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import { MacroForwarder, IUserDefinedMacro } from "@superfluid-finance/ethereum-contracts/contracts/utils/MacroForwarder.sol";
import { ISuperfluid, BatchOperation, IERC20Metadata } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/superfluid/SuperToken.sol";
import { IConstantFlowAgreementV1 } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";
import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";

using SuperTokenV1Library for ISuperToken;

/*
TODO:
- Implement "Ownable" for reverse ENS
- implement delete action
*/
contract DashboardMacro is EIP712, IUserDefinedMacro {

    uint8 constant ACTION_CREATE_FLOW = 1;
    uint8 constant ACTION_UPGRADE = 2;

    bytes32 constant public CREATE_FLOW_TYPEHASH = keccak256(bytes("SuperfluidCreateFlow(string action,address token,address receiver,int96 flowRate)"));
    bytes32 constant public UPGRADE_TYPEHASH = keccak256(bytes("SuperfluidUpgrade(string action,address token,uint256 amount)"));

    address payable immutable FEE_RECEIVER;
    uint256 immutable FEE_AMOUNT;

    error UnknownActionCode(uint8 actionCode);
    error FeeOverpaid();
    error UnsupportedLanguage();
    error InvalidSignature();

    constructor(address payable feeReceiver, uint256 feeAmount)
        EIP712("app.superfluid", "0.1.0")
    {
        FEE_RECEIVER = feeReceiver;
        FEE_AMOUNT = feeAmount;
    }

    function buildBatchOperations(ISuperfluid host, bytes memory params, address msgSender) external override view
        returns (ISuperfluid.Operation[] memory operations)
    {
        IConstantFlowAgreementV1 cfa = IConstantFlowAgreementV1(address(host.getAgreementClass(
            keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1")
        )));

        // first we seperate the provided params from the signature
        (bytes memory providedParams, bytes memory signatureVRS) = abi.decode(params, (bytes, bytes));

        // now we get the action code so we can dispatch
        uint8 actionCode;
        assembly {
            actionCode := mload(add(providedParams, 32)) // load the first word (actionCode) from the params array
        }

        if (actionCode == ACTION_CREATE_FLOW) {
            // Extract the action arguments
            (string memory lang, ISuperToken token, address receiver, int96 flowRate) = decode712CreateFlow(providedParams);

            // now we verify the signature
            validateCreateFlow(lang, token, receiver, flowRate, signatureVRS, msgSender);

            operations = new ISuperfluid.Operation[](2);
            // for this action, we take a fee
            operations[0] = ISuperfluid.Operation({
                operationType: BatchOperation.OPERATION_TYPE_SIMPLE_FORWARD_CALL,
                target: address(this),
                data: abi.encodeCall(this.takeFee, (FEE_AMOUNT))
            });
            operations[1] = ISuperfluid.Operation({
                operationType: BatchOperation.OPERATION_TYPE_SUPERFLUID_CALL_AGREEMENT,
                target: address(cfa),
                data: abi.encode(
                    abi.encodeCall(
                        cfa.createFlow,
                        (token, receiver, flowRate, new bytes(0))
                    ),
                    new bytes(0) // userdata
                )
            });
        } else if (actionCode == ACTION_UPGRADE) {
            (string memory lang, ISuperToken token, uint256 amount) = decode712Upgrade(providedParams);

            validateUpgrade(lang, token, amount, signatureVRS, msgSender);

            operations = new ISuperfluid.Operation[](1);
            operations[0] = ISuperfluid.Operation({
                operationType: BatchOperation.OPERATION_TYPE_SUPERTOKEN_UPGRADE,
                target: address(token),
                data: abi.encode(amount)
            });
        } else {
            revert UnknownActionCode(actionCode);
        }
    }

    // Forwards a fee in native tokens to the FEE_RECEIVER.
    // Will fail if less than `amount` is provided.
    function takeFee(uint256 amount) external payable {
        FEE_RECEIVER.transfer(amount);
    }

    // Don't allow native tokens in excess of the required fee
    // Note: this is safe only as long as this contract can't receive native tokens through other means,
    // e.g. by implementing a fallback or receive function.
    function postCheck(ISuperfluid /*host*/, bytes memory /*params*/, address /*msgSender*/) external view {
        if (address(this).balance != 0) revert FeeOverpaid();
    }

    function getHumanReadableFlowRateStr(int96 flowRate) public view returns(string memory) {
        // Convert flow rate from wei/second to tokens/day. We know it's 18 decimals for all SuperTokens
        int256 absFlowRate = (flowRate < 0) ? -flowRate : flowRate;
        uint256 tokensPerDay = uint256(absFlowRate) * 86400;
        string memory frAbs = getHumanReadableAmount(tokensPerDay);
        return (flowRate < 0) ? string.concat("-", frAbs) : frAbs;
    }

    function getHumanReadableAmount(uint256 amount) public view returns(string memory) {
        // 1e18 - 1e6 = 1e12
        uint256 microTokens = amount / 1e12;
        // Add half of the smallest unit to get a rounded result
        microTokens += 5;
        // Format the amount to have 5 decimals
        string memory intPart = Strings.toString(microTokens / 1e6);
        // the last digit is cut off to remove the rounding artifact introduced before
        string memory fracPart = Strings.toString((microTokens % 1e6) / 10);
        // Add leading zeroes to the fractional part if there's any
        while (bytes(fracPart).length < 5) {
            fracPart = string.concat("0", fracPart);
        }
        return string.concat(intPart, ".", fracPart);
    }

    // ====== CREATE FLOW ======

    // get params to sign and digest for createFlow, for use with EIP-712
    function encode712CreateFlow(string memory lang, ISuperToken token, address receiver, int96 flowRate)
        public view
        returns (string memory message, bytes memory paramsToProvide, bytes32 digest)
    {
        // the message is constructed based on the selected language and action arguments
        if (Strings.equal(lang, "en")) {
            message = string(abi.encodePacked("Create a new flow of ", getHumanReadableFlowRateStr(flowRate), " ", token.symbol(), "/day"));
        } else revert UnsupportedLanguage();

        paramsToProvide = abi.encode(
            ACTION_CREATE_FLOW,
            lang,
            token, receiver, flowRate
        );

        digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    CREATE_FLOW_TYPEHASH,
                    keccak256(bytes(message)),
                    token, receiver, flowRate
                )
            )
        );
    }

    function decode712CreateFlow(bytes memory providedParams)
        public view
        returns(string memory lang, ISuperToken token, address receiver, int96 flowRate)
    {
        // skip action
        (, lang, token, receiver, flowRate) =
                abi.decode(providedParams, (uint8, string, ISuperToken, address, int96));
    }

    // taking the signed params, validate the signature
    function validateCreateFlow(string memory lang, ISuperToken token, address receiver, int96 flowRate, bytes memory signatureVRS, address msgSender) public view returns (bool) {
        (, , bytes32 digest) = encode712CreateFlow(lang, token, receiver, flowRate);

        // validate the signature
        (uint8 v, bytes32 r, bytes32 s) = abi.decode(signatureVRS, (uint8, bytes32, bytes32));
        address signer = ecrecover(digest, v, r, s);
        if (signer != msgSender) revert InvalidSignature();
    }

    // ====== UPGRADE ======

    function encode712Upgrade(string memory lang, ISuperToken token, uint256 amount)
        public view
        returns(string memory message, bytes memory paramsToProvide, bytes32 digest)
    {
        address underlyingToken = token.getUnderlyingToken();
        if (Strings.equal(lang, "en")) {
            message = string(abi.encodePacked("Upgrade ", getHumanReadableAmount(amount), " ", IERC20Metadata(underlyingToken).symbol(), " to ", token.symbol()));
        } else revert UnsupportedLanguage();

        paramsToProvide = abi.encode(
            ACTION_UPGRADE,
            lang,
            token, amount
        );

        digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    UPGRADE_TYPEHASH,
                    keccak256(bytes(message)),
                    token, amount
                )
            )
        );
    }

    function decode712Upgrade(bytes memory providedParams)
        public view
        returns(string memory lang, ISuperToken token, uint256 amount)
    {
        // skip action
        (, lang, token, amount) =
                abi.decode(providedParams, (uint8, string, ISuperToken, uint256));
    }

    // taking the signed params, validate the signature
    function validateUpgrade(string memory lang, ISuperToken token, uint256 amount, bytes memory signatureVRS, address msgSender) public view returns (bool) {
        (, , bytes32 digest) = encode712Upgrade(lang, token, amount);

        // validate the signature
        (uint8 v, bytes32 r, bytes32 s) = abi.decode(signatureVRS, (uint8, bytes32, bytes32));
        address signer = ecrecover(digest, v, r, s);
        if (signer != msgSender) revert InvalidSignature();
    }
}