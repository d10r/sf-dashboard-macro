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
-[X] implement all "core actions"
*/
contract DashboardMacro is MacroBase712, Ownable {
    uint8 constant ACTION_CREATE_FLOW = 1;
    uint8 constant ACTION_UPDATE_FLOW = 2;
    uint8 constant ACTION_DELETE_FLOW = 3;
    uint8 constant ACTION_UPGRADE = 4;
    uint8 constant ACTION_DOWNGRADE = 5;
    uint8 constant ACTION_APPROVE = 6;
    uint8 constant ACTION_TRANSFER = 7;

    bytes32 constant public TYPEHASH_CREATE_FLOW = keccak256(bytes("SuperfluidCreateFlow(string action,address token,address receiver,int96 flowRate)"));
    bytes32 constant public TYPEHASH_UPDATE_FLOW = keccak256(bytes("SuperfluidUpdateFlow(string action,address token,address receiver,int96 flowRate)"));
    bytes32 constant public TYPEHASH_DELETE_FLOW = keccak256(bytes("SuperfluidDeleteFlow(string action,address token,address sender,address receiver)"));
    bytes32 constant public TYPEHASH_UPGRADE = keccak256(bytes("SuperfluidUpgrade(string action,address token,uint256 amount)"));
    bytes32 constant public TYPEHASH_DOWNGRADE = keccak256(bytes("SuperfluidDowngrade(string action,address token,uint256 amount)"));
    bytes32 constant public TYPEHASH_APPROVE = keccak256(bytes("SuperfluidApprove(string action,address token,address spender,uint256 amount)"));
    bytes32 constant public TYPEHASH_TRANSFER = keccak256(bytes("SuperfluidTransfer(string action,address token,address receiver,uint256 amount)"));
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
        Action[] memory actions = new Action[](7);
        actions[0] = Action({
            actionCode: ACTION_CREATE_FLOW,
            buildOperations: _buildOperationsForCreateFlow,
            getDigest: _getDigestForCreateFlow,
            postCheck: _noPostCheck
        });
        actions[1] = Action({
            actionCode: ACTION_UPDATE_FLOW,
            buildOperations: _buildOperationsForUpdateFlow,
            getDigest: _getDigestForUpdateFlow,
            postCheck: _noPostCheck
        });
        actions[2] = Action({
            actionCode: ACTION_DELETE_FLOW,
            buildOperations: _buildOperationsForDeleteFlow,
            getDigest: _getDigestForDeleteFlow,
            postCheck: _noPostCheck
        });
        actions[3] = Action({
            actionCode: ACTION_UPGRADE,
            buildOperations: _buildOperationsForUpgrade,
            getDigest: _getDigestForUpgrade,
            postCheck: _noPostCheck
        });
        actions[4] = Action({
            actionCode: ACTION_DOWNGRADE,
            buildOperations: _buildOperationsForDowngrade,
            getDigest: _getDigestForDowngrade,
            postCheck: _noPostCheck
        });
        actions[5] = Action({
            actionCode: ACTION_APPROVE,
            buildOperations: _buildOperationsForApprove,
            getDigest: _getDigestForApprove,
            postCheck: _noPostCheck
        });
        actions[6] = Action({
            actionCode: ACTION_TRANSFER,
            buildOperations: _buildOperationsForTransfer,
            getDigest: _getDigestForTransfer,
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

    // ACTION_UPDATE_FLOW

    struct UpdateFlowParams {
        ISuperToken superToken;
        address receiver;
        int96 flowRate;
    }

    function _buildOperationsForUpdateFlow(ISuperfluid host, bytes memory actionParams, address msgSender)
        internal view returns (ISuperfluid.Operation[] memory operations)
    {
        UpdateFlowParams memory p = abi.decode(actionParams, (UpdateFlowParams));

        operations = new ISuperfluid.Operation[](1);
        operations[0] = ISuperfluid.Operation({
            operationType: BatchOperation.OPERATION_TYPE_SUPERFLUID_CALL_AGREEMENT,
            target: address(_cfa),
            data: abi.encode(
                abi.encodeCall(
                    _cfa.updateFlow,
                    (p.superToken, p.receiver, p.flowRate, new bytes(0))
                ),
                new bytes(0) // userdata
            )
        });
    }

    function _getDigestForUpdateFlow(bytes memory actionParams, bytes32 lang)
        internal view returns (bytes32 digest)
    {
        UpdateFlowParams memory params = abi.decode(actionParams, (UpdateFlowParams));
        (, , digest) = encode712UpdateFlow(lang, params);
    }

    function encode712UpdateFlow(bytes32 lang, UpdateFlowParams memory p)
        public view
        returns (string memory message, bytes memory paramsToProvide, bytes32 digest)
    {
        if (lang == "en") {
            message = string(abi.encodePacked("Update flow to ", p.flowRate.toFlowRatePerDay(), " ", p.superToken.symbol(), "/day"));
        } else revert UnsupportedLanguage();

        paramsToProvide = abi.encode(
            ACTION_UPDATE_FLOW,
            lang,
            abi.encode(p.superToken, p.receiver, p.flowRate)
        );

        digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    TYPEHASH_UPDATE_FLOW,
                    keccak256(bytes(message)),
                    p.superToken, p.receiver, p.flowRate
                )
            )
        );
    }

    // ACTION_DELETE_FLOW

    struct DeleteFlowParams {
        ISuperToken superToken;
        address sender;
        address receiver;
    }

    function _buildOperationsForDeleteFlow(ISuperfluid host, bytes memory actionParams, address msgSender)
        internal view returns (ISuperfluid.Operation[] memory operations)
    {
        DeleteFlowParams memory p = abi.decode(actionParams, (DeleteFlowParams));

        operations = new ISuperfluid.Operation[](1);
        operations[0] = ISuperfluid.Operation({
            operationType: BatchOperation.OPERATION_TYPE_SUPERFLUID_CALL_AGREEMENT,
            target: address(_cfa),
            data: abi.encode(
                abi.encodeCall(
                    _cfa.deleteFlow,
                    (p.superToken, p.sender, p.receiver, new bytes(0))
                ),
                new bytes(0) // userdata
            )
        });
    }

    function _getDigestForDeleteFlow(bytes memory actionParams, bytes32 lang)
        internal view returns (bytes32 digest)
    {
        DeleteFlowParams memory params = abi.decode(actionParams, (DeleteFlowParams));
        (, , digest) = encode712DeleteFlow(lang, params);
    }

    function encode712DeleteFlow(bytes32 lang, DeleteFlowParams memory p)
        public view
        returns (string memory message, bytes memory paramsToProvide, bytes32 digest)
    {
        if (lang == "en") {
            message = string(abi.encodePacked("Delete flow of ", p.superToken.symbol()));
        } else revert UnsupportedLanguage();

        paramsToProvide = abi.encode(
            ACTION_DELETE_FLOW,
            lang,
            abi.encode(p.superToken, p.sender, p.receiver)
        );

        digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    TYPEHASH_DELETE_FLOW,
                    keccak256(bytes(message)),
                    p.superToken, p.sender, p.receiver
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

    // ACTION_DOWNGRADE

    struct DowngradeParams {
        ISuperToken superToken;
        uint256 amount;
    }

    function _buildOperationsForDowngrade(ISuperfluid host, bytes memory actionParams, address msgSender)
        internal view returns (ISuperfluid.Operation[] memory operations)
    {
        DowngradeParams memory p = abi.decode(actionParams, (DowngradeParams));

        operations = new ISuperfluid.Operation[](1);
        operations[0] = ISuperfluid.Operation({
            operationType: BatchOperation.OPERATION_TYPE_SUPERTOKEN_DOWNGRADE,
            target: address(p.superToken),
            data: abi.encode(p.amount)
        });
    }

    function _getDigestForDowngrade(bytes memory actionParams, bytes32 lang)
        internal view returns (bytes32 digest)
    {
        DowngradeParams memory params = abi.decode(actionParams, (DowngradeParams));
        (, , digest) = encode712Downgrade(lang, params);
    }

    function encode712Downgrade(bytes32 lang, DowngradeParams memory p)
        public view
        returns (string memory message, bytes memory paramsToProvide, bytes32 digest)
    {
        address underlyingToken = p.superToken.getUnderlyingToken();
        if (lang == "en") {
            message = string(abi.encodePacked("Downgrade ", p.amount.toHumanReadable(), " ", p.superToken.symbol(), " to ", IERC20Metadata(underlyingToken).symbol()));
        } else revert UnsupportedLanguage();

        paramsToProvide = abi.encode(
            ACTION_DOWNGRADE,
            lang,
            abi.encode(p.superToken, p.amount)
        );

        digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    TYPEHASH_DOWNGRADE,
                    keccak256(bytes(message)),
                    p.superToken, p.amount
                )
            )
        );
    }

    // ACTION_APPROVE

    struct ApproveParams {
        ISuperToken superToken;
        address spender;
        uint256 amount;
    }

    function _buildOperationsForApprove(ISuperfluid host, bytes memory actionParams, address msgSender)
        internal view returns (ISuperfluid.Operation[] memory operations)
    {
        ApproveParams memory p = abi.decode(actionParams, (ApproveParams));

        operations = new ISuperfluid.Operation[](1);
        operations[0] = ISuperfluid.Operation({
            operationType: BatchOperation.OPERATION_TYPE_ERC20_APPROVE,
            target: address(p.superToken),
            data: abi.encode(p.spender, p.amount)
        });
    }

    function _getDigestForApprove(bytes memory actionParams, bytes32 lang)
        internal view returns (bytes32 digest)
    {
        ApproveParams memory params = abi.decode(actionParams, (ApproveParams));
        (, , digest) = encode712Approve(lang, params);
    }

    function encode712Approve(bytes32 lang, ApproveParams memory p)
        public view
        returns (string memory message, bytes memory paramsToProvide, bytes32 digest)
    {
        if (lang == "en") {
            message = string(abi.encodePacked("Approve spender for an allowance of", p.amount.toHumanReadable(), " ", p.superToken.symbol()));
        } else revert UnsupportedLanguage();

        paramsToProvide = abi.encode(
            ACTION_APPROVE,
            lang,
            abi.encode(p.superToken, p.spender, p.amount)
        );

        digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    TYPEHASH_APPROVE,
                    keccak256(bytes(message)),
                    p.superToken, p.spender, p.amount
                )
            )
        );
    }

    // ACTION_TRANSFER

    struct TransferParams {
        ISuperToken superToken;
        address receiver;
        uint256 amount;
    }

    function _buildOperationsForTransfer(ISuperfluid host, bytes memory actionParams, address msgSender)
        internal view returns (ISuperfluid.Operation[] memory operations)
    {
        TransferParams memory p = abi.decode(actionParams, (TransferParams));

        operations = new ISuperfluid.Operation[](1);
        operations[0] = ISuperfluid.Operation({
            operationType: BatchOperation.OPERATION_TYPE_ERC20_TRANSFER_FROM    ,
            target: address(p.superToken),
            data: abi.encode(msgSender,p.receiver, p.amount)
        });
    }

    function _getDigestForTransfer(bytes memory actionParams, bytes32 lang)
        internal view returns (bytes32 digest)
    {
        TransferParams memory params = abi.decode(actionParams, (TransferParams));
        (, , digest) = encode712Transfer(lang, params);
    }

    function encode712Transfer(bytes32 lang, TransferParams memory p)
        public view
        returns (string memory message, bytes memory paramsToProvide, bytes32 digest)
    {
        if (lang == "en") {
            message = string(abi.encodePacked("Transfer ", p.amount.toHumanReadable(), " ", p.superToken.symbol()));
        } else revert UnsupportedLanguage();

        paramsToProvide = abi.encode(
            ACTION_TRANSFER,
            lang,
            abi.encode(p.superToken, p.receiver, p.amount)
        );

        digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    TYPEHASH_TRANSFER,
                    keccak256(bytes(message)),
                    p.superToken, p.receiver, p.amount
                )
            )
        );
    }
}
