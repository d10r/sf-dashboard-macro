// SPDX-License-Identifier: AGPLv3
pragma solidity ^0.8.26;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import { MacroForwarder, IUserDefinedMacro } from "@superfluid-finance/ethereum-contracts/contracts/utils/MacroForwarder.sol";
import { ISuperfluid, BatchOperation } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
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

    bytes32 constant ACTION_CODE_CREATE_FLOW = keccak256(bytes("cfa.createFlow"));

    bytes32 constant public CREATE_FLOW_TYPEHASH = keccak256(bytes("SuperfluidCreateFlow(string actionCode,string lang,string message,address token,address receiver,int96 flowRate)"));

    address payable immutable FEE_RECEIVER;
    uint256 immutable FEE_AMOUNT;

    error UnknownActionCode(bytes32 actionCode);
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

        // first we parse the signed params and the signature
        (bytes memory signedParams, bytes memory signatureVRS) = abi.decode(params, (bytes, bytes));

        // now we get the action code so we can dispatch
        bytes32 actionCode;
        assembly {
            actionCode := mload(add(signedParams, 32)) // load the first element (action) from the params array
        }

        operations = new ISuperfluid.Operation[](2);

        // first operation: take fee
        operations[0] = ISuperfluid.Operation({
            operationType: BatchOperation.OPERATION_TYPE_SIMPLE_FORWARD_CALL,
            target: address(this),
            data: abi.encodeCall(this.takeFee, (FEE_AMOUNT))
        });

        // second operation: manage flow
        if (actionCode == ACTION_CODE_CREATE_FLOW) {
            // Extract the action arguments
            (string memory lang, ISuperToken token, address receiver, int96 flowRate) = decode721CreateFlow(signedParams);

            // now we verify the signature
            validateCreateFlow(lang, token, receiver, flowRate, signatureVRS, msgSender);

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
        uint256 microTokensPerDay = uint256(absFlowRate) * 86400 / 1e12;

        // Add half of the smallest unit to get a rounded result
        microTokensPerDay += 5;

        // Format the flow rate to have 5 decimal place
        string memory frIntPartStr = Strings.toString(microTokensPerDay / 1e6);
        // the last digit is cut off to remove the rounding artifact introduced before
        string memory frFracPartStr = Strings.toString((microTokensPerDay % 1e6) / 10);
        // Add leading zeroes to the fractional part if there's any
        while (bytes(frFracPartStr).length < 5) {
            frFracPartStr = string.concat("0", frFracPartStr);
        }
        string memory frAbs = string.concat(frIntPartStr, ".", frFracPartStr);

        return (flowRate < 0) ? string.concat("-", frAbs) : frAbs;
    }

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
            ACTION_CODE_CREATE_FLOW,
            lang,
            token, receiver, flowRate
        );

        digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    CREATE_FLOW_TYPEHASH,
                    ACTION_CODE_CREATE_FLOW,
                    keccak256(bytes(lang)),
                    keccak256(bytes(message)),
                    token, receiver, flowRate
                )
            )
        );
    }

    function decode721CreateFlow(bytes memory signedParams)
        public view
        returns(string memory lang, ISuperToken token, address receiver, int96 flowRate)
    {
        // skip action, lang, message
        (, lang, token, receiver, flowRate) =
                abi.decode(signedParams, (bytes32, string, ISuperToken, address, int96));
    }

    // taking the signed params, validate the signature
    function validateCreateFlow(string memory lang, ISuperToken token, address receiver, int96 flowRate, bytes memory signatureVRS, address msgSender) public view returns (bool) {
        (, , bytes32 digest) = encode712CreateFlow(lang, token, receiver, flowRate);

        // validate the signature
        (uint8 v, bytes32 r, bytes32 s) = abi.decode(signatureVRS, (uint8, bytes32, bytes32));
        address signer = ecrecover(digest, v, r, s);
        if (signer != msgSender) revert InvalidSignature();
    }
}