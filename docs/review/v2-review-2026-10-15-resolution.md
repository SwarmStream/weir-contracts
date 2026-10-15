# Resolution of the v2 review (2026-10-15)

Review: `docs/review/v2-review-2026-10-15.md` at commit `d43d9c2`. Every finding was addressed in the next commit.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | Low | `onFailure` still read the stream token's `balanceOf` through `_defer` | Removed the redundant solvency check from `_defer`; regression test with a gas-burning `balanceOf` (`test_failureCallbackFitsItsStipendEvenWhenTheTokensBalanceOfBurnsGas`), confirmed to fail on the old code |
| 2 | Low | A non-bool 32-byte return word from `transfer` reverted settlement | The return word is decoded as an integer, so any value other than 1 counts as a refusal and defers; regression test `test_aNonBoolReturnWordDefersInsteadOfBlockingEnforcement`, confirmed to fail on the old code |
| 3 | Info | README named a `disputeEndedAt` getter that did not exist | The mapping is now public; the two daily-subsidy counters stay internal for size and the README says so |
| 4 | Info | Dead rate guard before `Restarted` | Removed |
| 5 | Info | Daily subsidy allowance doubles across the UTC day boundary | Documented in the README (up to 4 IMD in seconds, for 1 IMD of the attacker's own); accepted as the property of a fixed window |
| 6 | Info | Control bytes survived `neutralize`; Unicode quote lookalikes pass | Control bytes below 0x20 now become spaces (test added); lookalike quotes documented |
| 7 | Info | The cooldown also follows oracle failures that are not the disputer's fault | Documented in the README as a design consequence |
| 8 | Info | `forge build --sizes` fails on a test harness | Documented (`--skip test`) |

State after the fixes: 166 tests pass; the Weir runtime is 24,533 bytes (limit 24,576).
