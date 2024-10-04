// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/Test.sol";
import { FoundrySuperfluidTester } from "@superfluid-finance/ethereum-contracts/test/foundry/FoundrySuperfluidTester.sol";
import { DashboardMacro } from "../src/DashboardMacro.sol";

contract SFAppTest is FoundrySuperfluidTester {
    address payable feeReceiver = payable(address(0x420));
    uint256 feeAmount = 1e15;

    constructor() FoundrySuperfluidTester(5) { }

    function testGetHostTimestamp() public {
        uint256 hostTS = sf.host.getNow();
        assertGt(hostTS, 0, "host timestamp is 0");
    }

    function XtestPaidCFAOps() external {
        int96 flowRate1 = 42;
        int96 flowRate2 = 44;

        // alice needs funds for fee payment
        vm.deal(alice, 1 ether);

        DashboardMacro m = new DashboardMacro(feeReceiver, feeAmount);

        vm.startPrank(alice);

        // alice creates a flow to bob
        sf.macroForwarder.runMacro{value: feeAmount}(
            m,
            m.encodeCreateFlow(superToken, bob, flowRate1)
        );
        assertEq(feeReceiver.balance, feeAmount, "unexpected fee receiver balance");
        assertEq(sf.cfa.getNetFlow(superToken, bob), flowRate1);
/*
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

        (string memory message, bytes memory paramsToSign, bytes32 digest) = m.encode712CreateFlow("en", superToken, bob, flowRate);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, digest);
        console.log("message: ", message);

        bytes memory params = abi.encode(paramsToSign, abi.encode(v, r, s));

        vm.startPrank(signer.addr);
        sf.macroForwarder.runMacro{value: feeAmount}(m, params);
        vm.stopPrank();

        assertEq(feeReceiver.balance, feeAmount, "unexpected fee receiver balance");
    }
}

/*
params:
abi.encode(
    abi.encode(
        // EIP-712
        TYPEHASH,
        // EIP-712-plus
        lang,
        message
        // actionCode
        ACTION_CREATE_FLOW,
        token,
        receiver,
        flowrate
        ), // actionArgs
    ), // paramsToSign
)   // signature
*/
