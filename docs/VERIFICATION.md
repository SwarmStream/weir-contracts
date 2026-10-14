# Verification scope

This is implementation testing and a local correctness review, not an independent audit. The separate workflow review must examine accepted source and the later manifest. No claim of independent agents or live oracle execution is made here.

Final local checks: `forge build` succeeded with Solidity 0.8.26; `forge test` passed **61 tests across seven suites**, with no failures or skips, using the required seed; `forge fmt --check` passed. The invariant suite completed 24,576 calls with zero handler reverts. Weir's deployed runtime is **21,412 bytes** and LaunchToken's is **1,723 bytes**, both below the 24,576-byte limit; both runtime opcode tests passed. Both exported ABIs match the compiler artifacts. Weir has exactly six flat constructor inputs; LaunchToken has none. The creation/runtime artifacts have no library link references. These are the contributor's local results, not independent verification.

Foundry's remaining lint notices concern Solidity's default-zero local initialization, deliberate per-byte validation reverts, the short literal action-to-bytes32 cast, guarded events after external calls, and timestamp-based stream/deadline arithmetic. They were inspected in the local review; the build has no compiler errors. Test timestamp optimizer notices were addressed with Foundry clock accessors.

## Test coverage

| Suite | Coverage |
|---|---|
| LaunchToken | Approved metadata and fixed supply, exact transfers, allowance bounds, invalid transfer rejection, no mint/admin entry points for deployer or other callers, factory construction of token and application without moving launch supply, real WEIR holding gate and stream withdrawals, runtime size and forbidden opcode checks |
| WeirEngine | Six-decimal streams, snapshots, exhaustion/deposit restart, partial claims/refunds, pause/restart/adjust, closed claims, caller/hold gates, malformed creation, empty-code token, incoming/outgoing transfer taxes, no-result and false-result tokens, reentrancy, empty-chain constructor execution, extreme timestamps |
| WeirDisputes | All four disputer/verdict bond outcomes, pending deposits/withdrawals, IMD principal/bond/fund isolation, full and partial sponsorship, dust and zero bonds, tier boundaries, records, all dispute exits, strict timeout boundary, stale callbacks, duplicate request IDs, Intake failure/underpayment rollback, reentrancy, transfer failures |
| WeirAttestation | Sender/request/chain checks, distinct oracle UUID versus Intake receipt pairing, cross-stream UUID consumption, quorum/panel/count thresholds, canonical bool encoding, expiration and future-issued tolerance, tampering, wrong key, wrong consumer/chain domain, malleability, replay across callback/submission/failure paths |
| OracleConsumerConformance | Unchanged protocol digest and signature constants, canonical callback selector, same vector key signing a bool accepted through the real consumer callback under a 200,000-gas limit |
| WeirQuestion | Exact workflow text and compact JSON, optional job clause, role text, URI/note escaping, JSON injection attempts, all control bytes, UTF-8 boundaries and malformed encodings, maximum text lengths |
| WeirInvariant | Independent earned/unearned cash-flow model across multiple streams and tokens, all lifecycle actions, rate and holdings changes, court fund, bond payouts, records, exact aggregate backing, zero residual Intake allowance |

Arithmetic, bond-routing, and ASCII/JSON fuzz tests each use 1,000 runs. The invariant campaign uses 256 runs of 96 calls with fail-on-revert enabled (24,576 handler calls). Its model transfers value between earned and unearned buckets when time advances instead of duplicating the contract's snapshot-debt calculation. A deterministic handler test exercises every dispute exit as well.

The required fuzz seed is `0x56b8ba92d00416c8f19c62ec194b5746c200a1ddf94687c04427d28eb99f95dd`. The fixed-vector test is independent of signatures generated from the implementation's own digest. The canonical vector is a bytes32-list answer about a different chain, so its untouched signature tests the canonical verifier while a fresh bool signature tests Weir's stricter callback policy.

Time-dependent tests use Foundry's clock accessor around `vm.warp` to avoid Solidity's assumption that a transaction's timestamp is constant. Stipend tests explicitly mark the consumer, signer or token as cold before delivering the callback.

## Local review considerations

The review traced every production entry point through caller checks, state changes, snapshots, transfer accounting, and request replay handling. It checked the internal JSON encoder, UTF-8 validator, copied attestation digest, immutable configuration, rate/balance arithmetic, bond rounding, zero-amount branches, asynchronous exits, and same-token IMD funding. Exact outgoing transfers are checked after CEI updates. Incoming principal/bonds are credited only after a verified pull, under the shared guard. Pending requests cannot be reopened by a late callback or reused Intake ID.

The signed oracle request UUID and the Intake receipt ID are distinct values, as the protocol reference specifies. The result callback pairs the answer with its pending stream by the receipt ID the Intake passes and consumes the signed UUID; the attestation tests and the conformance test deliver attestations whose UUID differs from the receipt, and check that a consumed UUID cannot settle a second stream and that an unknown receipt is refused even with a valid signature. The permissionless `submitAttestation` keeps the `a.requestId == stream.requestId` association, the only one it can authenticate, and the README says what that means for recovery. The reference's mutable configuration and failure-hook recommendations were superseded by the explicit immutable v2 design.

The immutable oracle signer and Intake are trusted external dependencies. Exact-transfer and non-rebasing token behavior is assumed; mutable malicious assets can invalidate custody assumptions. Holding-based gates are not resistant to borrowed holdings or multiple identities. Repeated eligible disputes can consume sponsorship, and successful rulings preserve ordinary client controls afterward. These are properties of the requested design, not powers added to the implementation.

No live-chain fork, paid oracle request, Slither, Mythril, deployment, source publication, or independent audit was performed. A token that blocks a payout can delay enforcement or bond release; the ruling remains stored for a later retry. Expiry handles missing results, and permissionless submission handles a missed result callback when a compatible valid signature is available.
