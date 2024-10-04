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


contract DashboardMacro is EIP712, IUserDefinedMacro {

    uint8 constant ACTION_CREATE_FLOW = 0;
    uint8 constant ACTION_UPDATE_FLOW = 1;
    uint8 constant ACTION_DELETE_FLOW = 2;

    bytes32 constant public CREATE_FLOW_TYPEHASH = keccak256(bytes("createFlow(address token,address receiver,int96 flowRate)"));

    address payable immutable FEE_RECEIVER;
    uint256 immutable FEE_AMOUNT;

    error UnknownAction(uint8 action);
    error FeeOverpaid();
    error UnsupportedLanguage();

    constructor(address payable feeReceiver, uint256 feeAmount)
        EIP712("app.superfluid", "0.1.0")
    {
        FEE_RECEIVER = feeReceiver;
        FEE_AMOUNT = feeAmount;
    }

    function buildBatchOperations(ISuperfluid host, bytes memory params, address /*msgSender*/) external override view
        returns (ISuperfluid.Operation[] memory operations)
    {
        IConstantFlowAgreementV1 cfa = IConstantFlowAgreementV1(address(host.getAgreementClass(
            keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1")
        )));

        // first we parse the signed params and the signature
        (bytes memory signedParams, bytes memory signatureVRS) = abi.decode(params, (bytes, bytes));

        // now we verify the signature
        // TODO

        // now we get the action code so we can dispatch
        uint8 action;
        assembly {
            action := mload(add(signedParams, 32)) // load the first element (action) from the params array
        }
        //(uint8 action, bytes memory actionArgs) = abi.decode(signedParams, (uint8, bytes));

        // first operation: take fee

        operations = new ISuperfluid.Operation[](2);

        operations[0] = ISuperfluid.Operation({
            operationType: BatchOperation.OPERATION_TYPE_SIMPLE_FORWARD_CALL,
            target: address(this),
            data: abi.encodeCall(this.takeFee, (FEE_AMOUNT))
        });

        // second operation: manage flow
        if (action == ACTION_CREATE_FLOW) {
            // Extract the action arguments by skipping the first byte (action code)
            (ISuperToken token, address receiver, int96 flowRate) = decode721CreateFlow(signedParams);

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
            revert UnknownAction(action);
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

    // recommended view functions for parameter construction
    // since this is a multi-method macro, a dispatch logic using action codes is applied.

    // get params for createFlow
    function encodeCreateFlow(ISuperToken token, address receiver, int96 flowRate) public pure returns (bytes memory) {
        return abi.encode(
            ACTION_CREATE_FLOW, // action
            abi.encode(token, receiver, flowRate) // actionArgs
        );
    }

    // get params to sign and digest for createFlow, for use with EIP-712
    function encode712CreateFlow(ISuperToken token, address receiver, int96 flowRate)
        external view
        returns (bytes memory paramsToSign, bytes32 digest)
    {
        paramsToSign = abi.encode(
            ACTION_CREATE_FLOW,
            token, receiver, flowRate
        );

        digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    CREATE_FLOW_TYPEHASH,
                    ACTION_CREATE_FLOW,
                    token, receiver, flowRate
                )
            )
        );
    }

    function decode721CreateFlow(bytes memory signedParams)
        public view
        returns(ISuperToken token, address receiver, int96 flowRate)
    {
        (, token, receiver, flowRate) =
                abi.decode(signedParams, (uint8, ISuperToken, address, int96));
    }
}