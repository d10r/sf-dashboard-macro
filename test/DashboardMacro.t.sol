// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/Test.sol";
import { FoundrySuperfluidTester } from "@superfluid-finance/ethereum-contracts/test/foundry/FoundrySuperfluidTester.sol";
import { IERC20 } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import { DashboardMacro } from "../src/DashboardMacro.sol";

contract DashboardMacroTest is FoundrySuperfluidTester {
    address payable feeReceiver = payable(address(0x420));
    uint256 feeAmount = 1e15;

    constructor() FoundrySuperfluidTester(5) { }

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

        DashboardMacro m = new DashboardMacro(sf.host, feeReceiver, feeAmount);

        vm.startPrank(signer.addr);

        (string memory message, bytes memory paramsToProvide, bytes32 digest) =
            m.encode712CreateFlow("en", DashboardMacro.CreateFlowParams(superToken, bob, flowRate));
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
        console.log("underlyingAmount", underlyingAmount);
        console.log("adjustedAmount", adjustedAmount);

        // fund the signer with native tokens and SuperTokens
        vm.deal(signer.addr, 1 ether);
        vm.startPrank(alice);
        underlying.transfer(signer.addr, 1e18);
        vm.stopPrank();

        DashboardMacro m = new DashboardMacro(sf.host, feeReceiver, feeAmount);

        vm.startPrank(signer.addr);

        underlying.approve(address(superToken), underlyingAmount);

        (string memory message, bytes memory paramsToProvide, bytes32 digest) = m.encode712Upgrade("en", DashboardMacro.UpgradeParams(superToken, adjustedAmount));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, digest);
        console.log("message: ", message);

        bytes memory params = abi.encode(paramsToProvide, abi.encode(v, r, s));

        console.log("signer balance pre:", superToken.balanceOf(signer.addr));

        vm.startPrank(signer.addr);
        sf.macroForwarder.runMacro(m, params);
        vm.stopPrank();

        console.log("signer balance post:", superToken.balanceOf(signer.addr));

        assertEq(superToken.balanceOf(signer.addr), adjustedAmount, "unexpected SuperToken balance");
    }
}
