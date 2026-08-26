## Bug Description

`stHYPEWithdrawalModule.unstakeToken0Reserves()` records the module's ENTIRE token0 balance as pending-unstaking instead of the requested unstake amount. Any stHYPE donated or sent to the module by third parties is then counted as locked reserves in `STEXAMM.deposit()`/`withdraw()` share pricing, diluting every depositor during the inflation window. Full details and live mainnet state are provided in the attached report.

The recording line:

```solidity
function unstakeToken0Reserves(uint256 _unstakeAmountToken0)
    external override nonReentrant onlyOwner {
    ISTEXAMM stexInterface = ISTEXAMM(stex);
    stexInterface.unstakeToken0Reserves(_unstakeAmountToken0);  // pulls requested amount

    address token0 = stexInterface.token0();
    uint256 amountToken0 = IstHYPE(token0).balanceOf(address(this));  // BUG: whole balance
    _amountToken0PendingUnstaking += amountToken0;                    // records whole balance
    ...
}
```

Attack path (fully permissionless for the trigger):

1. Attacker transfers D stHYPE directly to `stHYPEWithdrawalModule` (the contract has no guard against incoming token0).
2. At the next legitimate keeper/owner unstake of X, the module records X + D as pending-unstaking.
3. Every deposit priced during this window is diluted by roughly D/(total accounting).
4. The phantom persists until the burn settles in the Overseer queue AND the keeper calls `redeemBurnsAndUpdate()`. LST exit queues run on multi-day horizons, so the window lasts days per attack and can be repeated indefinitely by re-donating.

Measured impact (full-stack Foundry PoC, real STEXAMM + Sovereign Pool): a victim depositing 100 WHYPE during the inflated window receives 52.63 shares against a fair value of 66.67, losing 21% of the deposit's value to pre-existing LP positions.

## Risk Breakdown

Difficulty to Exploit: Easy
Weakness: CWE-682 Incorrect Calculation (recording whole balance instead of requested amount); share-price dilution / ERC-4626-style inflation vector
Remedy Vulnerability Scoring System 1.0 Score: 7.5 (High)

Exploit complexity: one ordinary ERC20 transfer to trigger; attacker profits by holding LP shares across subsequent deposits (standard sandwich economics). No privileged access needed at any step. The only capital at risk is the donated stHYPE, which stays accounted to nobody but does not return to the attacker.

## Recommendation

Record the requested amount rather than the resulting balance:

```solidity
// pull only what was asked for, then track exactly that
stexInterface.unstakeToken0Reserves(_unstakeAmountToken0);
_amountToken0PendingUnstaking += _unstakeAmountToken0;
```

Further hardening options:

1. Convert any surplus token0 balance in the module to native via the Overseer inside `update()` (or sweep it), so stray balances cannot accumulate.
2. Consider rejecting inbound token0 transfers when they are not part of an owner action (e.g., balance snapshot diff before/after external calls), since stHYPE is rebase and donations are otherwise indistinguishable from settled amounts.

## References

Audited commit: ValantisLabs/valantis-stex@27b5c748db73d5b5e7d7aeaee902b70c2b74a829 (main)
Mainnet deployment (HyperEVM): withdrawal module 0x69e487aA3132708d08a979b2d07c5119Bb77F698, STEXAMM 0x39694eFF3b02248929120c73F90347013Aec834d, pool 0x5365b6EF09253C7aBc0A9286eC578A9f4B413B7D

Duplicate check performed against all four public audit reports in the repository:

- Hexens Mar-2025 (11 findings): closest is the Critical stale `amountToken1PendingLPWithdrawal` getter causing share miscalculation. That finding concerns stale state between settlements; this report concerns wrong data written at record time (`balanceOf` vs the requested amount). Different variable, different mechanism.
- Hexens May-2025 (2 findings, kHYPE module): delayed state updates and sweep token risk. Unrelated.
- Zenith Mar-2025 (6 findings): excess native not counted in `amountToken1PendingLPWithdrawal`. Same variable family as the Hexens fix, still a staleness issue, not balance-vs-requested recording.
- Zenith Aug-2025 (lending modules): lending module donation blocking replacement (DoS). Different contract and different impact class.

None of the four reports cover balance-based recording in `unstakeToken0Reserves`, nor donation-driven share-price dilution through that path.

## Proof Of Concept

Full-stack Foundry test (`test/V01Deep.t.sol`) using the repository's own ProtocolFactory, SovereignPool, STEXAMM, StepwiseFeeModule, MockOverseer and MockStHype contracts. No mocks replace the audited logic; the pool and AMM are the real deployed code.

```
forge test --match-test "test_V01_full_economic_impact" -vv

[PASS] test_V01_full_economic_impact() (gas: 694939)
Logs:
  [seed] LP shares minted: 99999999999999999000
  [seed] pool reserve0: 50000000000000000000
  [seed] pool reserve1: 100000000000000000000
  [attack] pendingUnstaking recorded: 50000000000000000000
  [attack] expected (unstaked only): 10000000000000000000
  [victim] shares minted for 100 WETH: 52631578947368421052
  [victim] FAIR shares: 66666666666666666666
  [victim] shares LOST to inflation: 14035087719298245614
  [attacker] token0 withdrawn: 11793103448275861951
  [attacker] token1 withdrawn: 26206896551724137669

Suite result: ok. 1 passed; 0 failed; 0 skipped
```

Step-by-step:

1. Deploy the real stack via the repo's ProtocolFactory/SovereignPoolFactory. Configure a flat minimal swap fee so the math is clean.
2. Seed with an honest LP deposit of 100 WHYPE. Simulate secondary-market activity so the pool holds 50 stHYPE and 100 WHYPE.
3. Attacker donates 40 stHYPE directly to the withdrawal module.
4. Owner unstakes 10 through the normal entry point. The test asserts the module records 50 (whole balance) rather than 10 (requested amount).
5. Victim deposits 100 WHYPE and receives 52.63 shares against a fair value of 66.67, a 21% dilution asserted in the test.
6. A pre-existing LP withdrawing 20% of supply during the inflated window extracts 11.79 stHYPE plus 26.21 WHYPE, demonstrating the extraction side of the value transfer.

Additional verification tests in the same file cover claim-ordering FIFO integrity and donation absorption mechanics in `update()`; both confirmed the surrounding accounting behaves as documented, isolating the root cause to the recording line.

Suntani
