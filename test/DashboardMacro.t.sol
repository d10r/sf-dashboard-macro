// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/Test.sol";
import { FoundrySuperfluidTester } from "@superfluid-finance/ethereum-contracts/test/foundry/FoundrySuperfluidTester.sol";
import { IERC20, ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";

import { DashboardMacro } from "../src/DashboardMacro.sol";

using SuperTokenV1Library for ISuperToken;

contract DashboardMacroTest is FoundrySuperfluidTester {
    int96 constant DEFAULT_FLOWRATE = 1157407407407; // 0.1 per day
    uint256 constant FEE_AMOUNT = 1e15;
    address payable feeReceiver = payable(address(0x420));
    VmSafe.Wallet signer;
    DashboardMacro m;

    constructor() FoundrySuperfluidTester(5) { }

    function setUp() public override {
        super.setUp();

        signer = vm.createWallet("signer");
        console.log("signer's wallet address %s", signer.addr);

        // fund the signer with native tokens
        vm.deal(signer.addr, 1 ether);

        m = new DashboardMacro(sf.host, feeReceiver, FEE_AMOUNT);
    }

    function _fundSignerWithSuperTokens(uint256 amount) internal {
        vm.startPrank(alice);
        superToken.transfer(signer.addr, amount);
        vm.stopPrank();
    }

    function _signMessage(bytes32 digest) internal returns (bytes memory signatureVRS) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, digest);
        return abi.encode(v, r, s);
    }

    function _createFlow(ISuperToken token, address receiver, int96 flowRate) internal {
        vm.startPrank(signer.addr);
        superToken.createFlow(receiver, flowRate);
        vm.stopPrank();
    }

    // run macro using message, paramsToProvide, digest
    function _runMacro(uint256 feeAmount, string memory message, bytes memory paramsToProvide, bytes32 digest) internal {
        console.log("message: ", message);
        bytes memory signatureVRS = _signMessage(digest);
        bytes memory params = abi.encode(paramsToProvide, signatureVRS);

        vm.startPrank(signer.addr);
        sf.macroForwarder.runMacro{value: feeAmount}(m, params);
        vm.stopPrank();
    }

    // REF: https://book.getfoundry.sh/tutorials/testing-eip712
    function testCreateFlow712() external {
        _fundSignerWithSuperTokens(1e18);

        (string memory message, bytes memory paramsToProvide, bytes32 digest) =
            m.encode712CreateFlow("en", DashboardMacro.CreateFlowParams(superToken, bob, DEFAULT_FLOWRATE));

        _runMacro(FEE_AMOUNT, message, paramsToProvide, digest);

        assertEq(feeReceiver.balance, FEE_AMOUNT, "unexpected fee receiver balance");
        assertEq(superToken.getFlowRate(signer.addr, bob), DEFAULT_FLOWRATE, "unexpected flow rate");
    }

    function testUpdateFlow712() external {
        int96 newFlowRate = 2 * DEFAULT_FLOWRATE;

        _fundSignerWithSuperTokens(1e18);
        _createFlow(superToken, bob, DEFAULT_FLOWRATE);

        (string memory message, bytes memory paramsToProvide, bytes32 digest) = m.encode712UpdateFlow("en", DashboardMacro.UpdateFlowParams(superToken, bob, newFlowRate));
        _runMacro(0, message, paramsToProvide, digest);

        assertEq(superToken.getFlowRate(signer.addr, bob), newFlowRate, "unexpected flow rate");
    }

    function testDeleteFlow712() external {
        _fundSignerWithSuperTokens(1e18);

        _createFlow(superToken, bob, DEFAULT_FLOWRATE);

        (string memory message, bytes memory paramsToProvide, bytes32 digest) = m.encode712DeleteFlow("en", DashboardMacro.DeleteFlowParams(superToken, signer.addr, bob));
        _runMacro(0, message, paramsToProvide, digest);

        assertEq(superToken.getFlowRate(signer.addr, bob), 0, "unexpected flow rate");
    }

    function testUpgrade712() external {
        uint256 amountToUpgrade = 1e17; // 0.1

        IERC20 underlying = IERC20(superToken.getUnderlyingToken());
        (uint256 underlyingAmount, uint256 adjustedAmount) = superToken.toUnderlyingAmount(amountToUpgrade);
        console.log("underlyingAmount", underlyingAmount);
        console.log("adjustedAmount", adjustedAmount);

        // fund the signer with underlying tokens
        vm.deal(signer.addr, 1 ether);
        vm.startPrank(alice);
        underlying.transfer(signer.addr, 1e18);
        vm.stopPrank();

        vm.startPrank(signer.addr);
        underlying.approve(address(superToken), underlyingAmount);
        vm.stopPrank();

        (string memory message, bytes memory paramsToProvide, bytes32 digest) = m.encode712Upgrade("en", DashboardMacro.UpgradeParams(superToken, adjustedAmount));
        _runMacro(0, message, paramsToProvide, digest);

        assertEq(superToken.balanceOf(signer.addr), adjustedAmount, "unexpected SuperToken balance");
    }

    function testDowngrade712() external {
        uint256 fundingAmount = 1e18;
        uint256 amountToDowngrade = 1e17; // 0.1

        _fundSignerWithSuperTokens(fundingAmount);

        (string memory message, bytes memory paramsToProvide, bytes32 digest) = m.encode712Downgrade("en", DashboardMacro.DowngradeParams(superToken, amountToDowngrade));
        _runMacro(0, message, paramsToProvide, digest);

        assertEq(superToken.balanceOf(signer.addr), fundingAmount - amountToDowngrade, "unexpected SuperToken balance");
    }

    function testApprove712() external {
        uint256 allowanceAmount = 1e17;
        _fundSignerWithSuperTokens(1e18);

        (string memory message, bytes memory paramsToProvide, bytes32 digest) = m.encode712Approve("en", DashboardMacro.ApproveParams(superToken, bob, allowanceAmount));
        _runMacro(0, message, paramsToProvide, digest);

        assertEq(superToken.allowance(signer.addr, bob), allowanceAmount, "unexpected allowance");
    }

    function testTransfer712() external {
        uint256 transferAmount = 1e17;
        _fundSignerWithSuperTokens(1e18);

        uint256 bobBalance = superToken.balanceOf(bob);
        (string memory message, bytes memory paramsToProvide, bytes32 digest) = m.encode712Transfer("en", DashboardMacro.TransferParams(superToken, bob, transferAmount));
        _runMacro(0, message, paramsToProvide, digest);

        assertEq(superToken.balanceOf(signer.addr), 1e18 - transferAmount, "unexpected SuperToken balance");
        assertEq(superToken.balanceOf(bob), bobBalance + transferAmount, "unexpected SuperToken balance");
    }   
}
