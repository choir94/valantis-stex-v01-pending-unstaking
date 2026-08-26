# Valantis STEX Bug Bounty Report: Pending-Unstaking Balance Recording Flaw

Finding for the [Valantis STEX bug bounty program](https://r.xyz/bug-bounty/programs/valantis-stex) hosted on Remedy.

**Severity:** High (RVSS 7.5) | **Weakness:** CWE-682 Incorrect Calculation | **Status:** Ready for submission
**Audited commit:** `27b5c748db73d5b5e7d7aeaee902b70c2b74a829` (main)
**Mainnet deployment:** withdrawal module `0x69e487aA3132708d08a979b2d07c5119Bb77F698` (HyperEVM, chain 999)

## The bug in one sentence

`stHYPEWithdrawalModule.unstakeToken0Reserves()` records the module's ENTIRE token0
balance as pending-unstaking instead of the requested unstake amount, so any stHYPE
donated to the module by anyone inflates the share-pricing denominator in
`STEXAMM.deposit()`/`withdraw()`, diluting every depositor during the inflation window.

## Root cause

```solidity
function unstakeToken0Reserves(uint256 _unstakeAmountToken0) external ... onlyOwner {
    stexInterface.unstakeToken0Reserves(_unstakeAmountToken0);  // pulls requested amount

    address token0 = stexInterface.token0();
    uint256 amountToken0 = IstHYPE(token0).balanceOf(address(this));  // BUG: whole balance
    _amountToken0PendingUnstaking += amountToken0;                    // records whole balance
}
```

The value feeds the pricing denominator:

```solidity
uint256 reserve0Total = reserve0Pool + _withdrawalModule.amountToken0PendingUnstaking();
```

## Attack path (permissionless trigger)

1. Attacker transfers D stHYPE directly to the withdrawal module (no guard against incoming token0).
2. At the next legitimate keeper/owner unstake of X, the module records X + D as pending-unstaking.
3. Every deposit priced during this window is diluted by roughly D/(total accounting).
4. Phantom persists until burn settles AND keeper calls `redeemBurnsAndUpdate()`; LST exit queues take days, repeatable indefinitely.

## Measured impact

Full-stack PoC with the real STEXAMM, Sovereign Pool and withdrawal module contracts:

| Metric | Value |
|---|---|
| Module recorded as pending | 50 stHYPE (actual unstake: 10) |
| Victim deposit | 100 WHYPE |
| Shares minted | 52.63 |
| Fair shares | 66.67 |
| **Victim loss** | **14.03 shares = 21% of deposit value** |
| LP extraction during window | 11.79 stHYPE + 26.21 WHYPE per 20% of supply |

Live mainnet state (read-only RPC): storage claims 35,145 stHYPE pending while the module
holds 0 stHYPE; the view feeding live pricing returns 32,382, which is 65.7% of the total
share-pricing denominator.

## Repository layout

```
PoC/V01Deep.t.sol     Full-stack Foundry test: real STEXAMM + SovereignPool + module
PoC/StexHunt.t.sol    Supplementary tests: claim FIFO integrity, update() donation absorption
Report/report.md      Submission body (Remedy format)
```

## Reproducing

```bash
git clone https://github.com/ValantisLabs/valantis-stex.git
cd valantis-stex && npm/pnpm setup per foundry.toml (libs included via submodules)
cp /path/to/V01Deep.t.sol test/
forge test --match-test "test_V01_full_economic_impact" -vv
```

Expected result: PASS with victim losing 14.03 shares of a 100 WHYPE deposit.

## Duplicate check

All four public audits in the repository were full-text searched (Hexens Mar-2025,
Hexens May-2025, Zenith Mar-2025, Zenith Aug-2025). None cover balance-based recording
in `unstakeToken0Reserves` or donation-driven dilution through that path. Closest prior
finding is Hexens' Critical on a STALE `amountToken1PendingLPWithdrawal` getter; ours is
a WRONG WRITE at record time, a different variable and mechanism.
