// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/Test.sol";
import { FoundrySuperfluidTester } from "@superfluid-finance/ethereum-contracts/test/foundry/FoundrySuperfluidTester.sol";
import { IERC20 } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import { DashboardMacro } from "../src/DashboardMacro.sol";

contract SFAppTest is FoundrySuperfluidTester {
    address payable feeReceiver = payable(address(0x420));
    uint256 feeAmount = 1e15;

    constructor() FoundrySuperfluidTester(5) { }

    function XtestPaidCFAOps() external {
        int96 flowRate1 = 42;
        int96 flowRate2 = 44;

        // alice needs funds for fee payment
        vm.deal(alice, 1 ether);

        DashboardMacro m = new DashboardMacro(feeReceiver, feeAmount);

        vm.startPrank(alice);

        // alice creates a flow to bob
        /*
        sf.macroForwarder.runMacro{value: feeAmount}(
            m,
            m.encodeCreateFlow(superToken, bob, flowRate1)
        );
        assertEq(feeReceiver.balance, feeAmount, "unexpected fee receiver balance");
        assertEq(sf.cfa.getNetFlow(superToken, bob), flowRate1);
        // ... then updates that flow
        sf.macroForwarder.runMacro{value: feeAmount}(
            m,
            m.mUpdateFlow(superToken, bob, flowRate2)
        );
        assertEq(feeReceiver.balance, feeAmount * 2, "unexpected fee receiver balance");
        assertEq(sf.cfa.getNetFlow(superToken, bob), flowRate2);

        // ... and finally deletes it
        sf.macroForwarder.runMacro{value: feeAmount}(
            m,
            m.mDeleteFlow(superToken, alice, bob)
        );
        assertEq(feeReceiver.balance, feeAmount * 3, "unexpected fee receiver balance");
        assertEq(sf.cfa.getNetFlow(superToken, bob), 0);
*/
    }

    // REF: https://book.getfoundry.sh/tutorials/testing-eip712
    function testCreateFlow712() external {
        int96 flowRate = 1157407407407; // 0.1 per day

        VmSafe.Wallet memory signer = vm.createWallet("signer");
        console.log("signer's wallet address %s", signer.addr);

        // fund the signer with native tokens and SuperTokens
        vm.deal(signer.addr, 1 ether);
        vm.startPrank(alice);
        superToken.transfer(signer.addr, 1e18);
        vm.stopPrank();

        DashboardMacro m = new DashboardMacro(feeReceiver, feeAmount);

        vm.startPrank(signer.addr);

        (string memory message, bytes memory paramsToProvide, bytes32 digest) = m.encode712CreateFlow("en", superToken, bob, flowRate);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, digest);
        console.log("message: ", message);

        bytes memory params = abi.encode(paramsToProvide, abi.encode(v, r, s));

        vm.startPrank(signer.addr);
        sf.macroForwarder.runMacro{value: feeAmount}(m, params);
        vm.stopPrank();

        assertEq(feeReceiver.balance, feeAmount, "unexpected fee receiver balance");
    }


    function testUpgrade712() external {
        uint256 amount = 1e17; // 0.1

        VmSafe.Wallet memory signer = vm.createWallet("signer");
        console.log("signer's wallet address %s", signer.addr);

        IERC20 underlying = IERC20(superToken.getUnderlyingToken());
        (uint256 underlyingAmount, uint256 adjustedAmount) = superToken.toUnderlyingAmount(amount);

        // fund the signer with native tokens and SuperTokens
        vm.deal(signer.addr, 1 ether);
        vm.startPrank(alice);
        underlying.transfer(signer.addr, 1e18);
        vm.stopPrank();

        DashboardMacro m = new DashboardMacro(feeReceiver, feeAmount);

        vm.startPrank(signer.addr);

        underlying.approve(address(superToken), underlyingAmount);

        (string memory message, bytes memory paramsToProvide, bytes32 digest) = m.encode712Upgrade("en", superToken, adjustedAmount);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, digest);
        console.log("message: ", message);

        bytes memory params = abi.encode(paramsToProvide, abi.encode(v, r, s));

        vm.startPrank(signer.addr);
        sf.macroForwarder.runMacro{value: feeAmount}(m, params);
        vm.stopPrank();

        assertEq(feeReceiver.balance, feeAmount, "unexpected fee receiver balance");
    }
}
