// SPDX-License-Identifier: AGPLv3
pragma solidity ^0.8.26;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { MacroForwarder, IUserDefinedMacro } from "@superfluid-finance/ethereum-contracts/contracts/utils/MacroForwarder.sol";
import { ISuperfluid, BatchOperation, IERC20Metadata } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/superfluid/SuperToken.sol";
import { IConstantFlowAgreementV1 } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";
import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";

import { MacroBase712 } from "./MacroBase712.sol";
import { FlowRateFormatter, AmountFormatter } from "./FormatterLibs.sol";

using SuperTokenV1Library for ISuperToken;
using FlowRateFormatter for int96;
using AmountFormatter for uint256;

/*
TODO:
-[X] Implement "Ownable" for reverse ENS
-[ ] implement all "core actions"
*/
contract DashboardMacro is MacroBase712, Ownable {
    uint8 constant ACTION_CREATE_FLOW = 1;
    uint8 constant ACTION_UPGRADE = 2;

    bytes32 constant public TYPEHASH_CREATE_FLOW = keccak256(bytes("SuperfluidCreateFlow(string action,address token,address receiver,int96 flowRate)"));
    bytes32 constant public TYPEHASH_UPGRADE = keccak256(bytes("SuperfluidUpgrade(string action,address token,uint256 amount)"));

    address payable immutable FEE_RECEIVER;
    uint256 immutable FEE_AMOUNT;
    IConstantFlowAgreementV1 _cfa;

    constructor(ISuperfluid host, address payable feeReceiver, uint256 feeAmount)
        MacroBase712("app.superfluid", "0.1.0")
    {
        FEE_RECEIVER = feeReceiver;
        FEE_AMOUNT = feeAmount;

        _cfa = IConstantFlowAgreementV1(address(host.getAgreementClass(
            keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1")
        )));
    }

    function _getActions() internal pure override returns (Action[] memory) {
        Action[] memory actions = new Action[](2);
        actions[0] = Action({
            actionCode: ACTION_CREATE_FLOW,
            buildOperations: _buildOperationsForCreateFlow,
            getDigest: _getDigestForCreateFlow,
            postCheck: _noPostCheck
        });
        actions[1] = Action({
            actionCode: ACTION_UPGRADE,
            buildOperations: _buildOperationsForUpgrade,
            getDigest: _getDigestForUpgrade,
            postCheck: _noPostCheck
        });

        return actions;
    }

    // ACTION_CREATE_FLOW

    struct CreateFlowParams {
        ISuperToken superToken;
        address receiver;
        int96 flowRate;
    }

    function _buildOperationsForCreateFlow(ISuperfluid host, bytes memory actionParams, address msgSender)
        internal view returns (ISuperfluid.Operation[] memory operations)
    {
        CreateFlowParams memory p = abi.decode(actionParams, (CreateFlowParams));

        operations = new ISuperfluid.Operation[](2);
        // for this action, we take a fee
        operations[0] = ISuperfluid.Operation({
            operationType: BatchOperation.OPERATION_TYPE_SIMPLE_FORWARD_CALL,
            target: address(FEE_RECEIVER),
            data: new bytes(0) // simple ETH transfer
        });
        operations[1] = ISuperfluid.Operation({
            operationType: BatchOperation.OPERATION_TYPE_SUPERFLUID_CALL_AGREEMENT,
            target: address(_cfa),
            data: abi.encode(
                abi.encodeCall(
                    _cfa.createFlow,
                    (p.superToken, p.receiver, p.flowRate, new bytes(0))
                ),
                new bytes(0) // userdata
            )
        });
    }

    function _getDigestForCreateFlow(bytes memory actionParams, bytes32 lang)
        internal view returns (bytes32 digest)
    {
        CreateFlowParams memory params = abi.decode(actionParams, (CreateFlowParams));
        (, , digest) = encode712CreateFlow(lang, params);
    }

    function encode712CreateFlow(bytes32 lang, CreateFlowParams memory p)
        public view
        returns (string memory message, bytes memory paramsToProvide, bytes32 digest)
    {
        if (lang == "en") {
            message = string(abi.encodePacked("Create a new flow of ", p.flowRate.toFlowRatePerDay(), " ", p.superToken.symbol(), "/day"));
        } else revert UnsupportedLanguage();

        paramsToProvide = abi.encode(
            ACTION_CREATE_FLOW,
            lang,
            abi.encode(p.superToken, p.receiver, p.flowRate)
        );

        digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    TYPEHASH_CREATE_FLOW,
                    keccak256(bytes(message)),
                    p.superToken, p.receiver, p.flowRate
                )
            )
        );
    }

    // ACTION_UPGRADE

    struct UpgradeParams {
        ISuperToken superToken;
        uint256 amount;
    }

    function _buildOperationsForUpgrade(ISuperfluid host, bytes memory actionParams, address msgSender)
        internal view returns (ISuperfluid.Operation[] memory operations)
    {
        UpgradeParams memory p = abi.decode(actionParams, (UpgradeParams));

        operations = new ISuperfluid.Operation[](1);
        operations[0] = ISuperfluid.Operation({
            operationType: BatchOperation.OPERATION_TYPE_SUPERTOKEN_UPGRADE,
            target: address(p.superToken),
            data: abi.encode(p.amount)
        });
    }

    function _getDigestForUpgrade(bytes memory actionParams, bytes32 lang)
        internal view returns (bytes32 digest)
    {
        UpgradeParams memory params = abi.decode(actionParams, (UpgradeParams));
        (, , digest) = encode712Upgrade(lang, params);
    }

    function encode712Upgrade(bytes32 lang, UpgradeParams memory p)
        public view
        returns (string memory message, bytes memory paramsToProvide, bytes32 digest)
    {
        address underlyingToken = p.superToken.getUnderlyingToken();
        if (lang == "en") {
            message = string(abi.encodePacked("Upgrade ", p.amount.toHumanReadable(), " ", IERC20Metadata(underlyingToken).symbol(), " to ", p.superToken.symbol()));
        } else revert UnsupportedLanguage();

        paramsToProvide = abi.encode(
            ACTION_UPGRADE,
            lang,
            abi.encode(p.superToken, p.amount)
        );

        digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    TYPEHASH_UPGRADE,
                    keccak256(bytes(message)),
                    p.superToken, p.amount
                )
            )
        );
    }
}