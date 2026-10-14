# Weir contracts

Weir streams ERC-20 tokens from a client to a recipient under a terms hash and URI. A dispute pauses the stream and asks one IdentityMD oracle question about whether the recipient delivered the agreed work. Weir charges no application fee.

**Not audited.** Tests and the swarm's review panel are not an audit. The oracle supplies a panel judgement, not a court of law. The 0.5 IMD oracle fee is spent even if the panel disagrees or the request is refused.

This contribution implements `src/Weir.sol`, the required `src/LaunchToken.sol`, supporting libraries and interface, tests, and compiler-exported ABIs under `docs/abi/`. The manifest, independent review, publication, admission, deployment, and website are separate workflow contributions or service responsibilities. This tree contains no launch manifest or deployment transaction.

## Build and checks

Run from the repository root with Foundry and the pinned Solidity compiler available:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x56b8ba92d00416c8f19c62ec194b5746c200a1ddf94687c04427d28eb99f95dd forge test
forge fmt --check
```

The production settings in `foundry.toml` are:

```toml
[profile.default]
src = "src"
test = "test"
out = "out"
libs = ["lib"]
solc = "0.8.26"
optimizer = true
optimizer_runs = 200
evm_version = "cancun"
via_ir = false
bytecode_hash = "none"
```

There is no FFI, filesystem permission grant, external library path, compiler binary, or compiler path pin. All imported dependencies are ordinary files under `lib/`; installation and network access are unnecessary to build or test. See [dependency provenance](docs/DEPENDENCIES.md).

Regenerate the ABI from the same compiler settings:

```sh
forge inspect src/Weir.sol:Weir abi --json > docs/abi/Weir.json
forge inspect src/LaunchToken.sol:LaunchToken abi --json > docs/abi/LaunchToken.json
```

## Launch token

`LaunchToken` is the plain ERC-20 **Weir (WEIR)** with 18 decimals. Its constructor takes no arguments and mints exactly **1,000,000,000 WEIR** (`10^27` minor units) once to `msg.sender`, the deploying launch factory. It uses the vendored OpenZeppelin v5 ERC-20 implementation. It has no additional mint, burn, owner, pause, blocklist, fee, or upgrade entry points.

The factory deploys this token before Weir and supplies its address as Weir's `$token` constructor argument. The factory distributes the supply under the approved launch policy: 10% to contributor rewards, 89% to pool liquidity, and 1% to the paying wallet. The token constructor performs none of those distributions, and Weir's constructor neither takes nor moves any launch supply. The pool's 1.25% trading fee is the network's; there is no token transfer fee. Token holdings determine application eligibility and dispute bond tiers.

## Deployment configuration

Weir has exactly six flat constructor arguments. All six are immutable, including the inherited oracle signer. The constructor checks nonzero addresses and positive timeout/hold values, and makes no external calls or code-existence checks. The intended launch is Robinhood Chain, chain ID **4663**.

| Order | Parameter | Type | Approved launch value |
|---|---|---|---|
| 1 | `weir_` | `IERC20` / address | `$token`, the factory's launch-token reference |
| 2 | `imd_` | `IERC20` / address | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` |
| 3 | `intake_` | `IIntake` / address | `0xa43e6f75ee006411f79ac1c84120606c2330de82` (v2) |
| 4 | `oracleSigner_` | address | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| 5 | `disputeTimeout_` | `uint40` | `604800` seconds (7 days) |
| 6 | `minHold_` | `uint256` | `10000000000000000000000` (10,000 WEIR) |

These addresses and parameters come from the approved workflow; they are not newly discovered or independently verified live deployments. The factory resolves `$token` to the Weir / WEIR launch token, with 18 decimals and the network's fixed supply. No initial token allocation goes to this application.

There is no owner, admin, setter, global pause switch, fee withdrawal, rescue function, proxy, upgrade path, or application backend signer. The immutable IdentityMD oracle signer is the sole attestation authority. Changing the Intake, signer, asset or action requires a new application deployment. The oracle price is not fixed in the contract: each dispute reads the Intake's current price for the action (`oraclePrice()`), so a repriced action keeps working. `ORACLE_PRICE` (`5e17`, the launch price) is documentation only; `MAX_ORACLE_PRICE` (`5e18`, ten times the launch price, a constant chosen by this contribution) caps what a dispute will pay, and a price of zero (action not sold) or above the cap makes `dispute` revert with `OraclePriceOutOfRange`. No Sablier code or dependency is used.

## Streaming accounting

All stream amounts use the stream token's minor units. A rate is minor units per second; it is not normalized to 18 decimals. Creation takes a `uint128` rate and initial amount; later deposit/refund/withdraw amounts and accumulated accounting use `uint256`.

At time `now`:

```text
streamed     = min(snapDebt + rate * (now - snapTime), balance)
withdrawable = streamed - withdrawn
refundable   = balance - streamed
stake        = balance - withdrawn
withdrawable + refundable = stake
```

`balance` is total credited principal less client refunds, including amounts already withdrawn. `withdrawn` is cumulative recipient withdrawals. A rate or balance change first snapshots the accrued amount and the current time. The multiplication is capped before execution to avoid overflow. Exhaustion retains the configured rate but accrues nothing beyond available principal. A deposit starts further accrual from its own timestamp; unfunded time never creates a backlog.

Only exact-transfer, non-rebasing ERC-20s are supported. SafeERC20 supports tokens with no boolean transfer result. Incoming credit is checked against the actual contract balance increase; outgoing payouts check both the contract debit and recipient credit. Transfer taxes and short payments cause an atomic revert. Tokens that lie about balances, rebase, confiscate, block addresses, pause, or change their behavior can defeat these assumptions or block settlement. There is no token allowlist; both parties must assess their chosen token.

Settlement payouts never block a state transition. The bond and refund paid by `enforce`, and the bond returned by `onFailure` and `expireDispute`, are pushed to their owner; if the token **reverts** that transfer (a blocklist, a pause), nothing has moved and the amount is credited to `claimable(token, account)` instead, with a `PayoutDeferred` event, and the stream still changes state. The owed party collects it later with `claim(token)`, once the token allows the transfer again. A transfer that succeeds but moves the wrong amount (a tax) still reverts the whole call, like every other payout. Ordinary withdrawals and refunds are not deferred: they are the caller's own transaction and simply revert while the token refuses. A blocklist that is never lifted therefore strands only the blocked party's own money, never the counterparty's.

`escrowed(token)` tracks every stream's `balance - withdrawn` plus outstanding bonds in that token. `unclaimed(token)` tracks deferred payouts not yet claimed. For IMD, `courtFund` is an additional, separately tracked obligation. Supported token balances must cover all of them. Every token-moving entry point and all other state-changing entry points share a reentrancy guard. Outgoing payouts update accounting before external transfers; incoming funds are credited only after a checked pull.

## Permissions and states

Stream IDs start at 1. `streams(id)` exposes the full struct, including the URI; an unknown ID has `State.None`. State-changing calls on an unknown ID revert.

| State | Client | Recipient | Anyone / Intake |
|---|---|---|---|
| `Active` | Deposit; pause a running stream; restart a paused stream; adjust a running rate; refund unearned funds; void; dispute | Accept the terms; withdraw earned funds; dispute | Anyone may sponsor |
| `Disputed` | Deposit; dispute terms and original bond stay fixed | Withdraw earned funds | Anyone may expire after the timeout; only Intake may call result/failure callbacks. Signed submission has no usable recovery path with current live oracle IDs, as explained below |
| `Ruled` | No stream mutations | Withdraw earned funds | Anyone may enforce |
| `Closed` | No stream mutations | Withdraw remaining earned funds | No reopening |

In every state, anyone owed a deferred payout may `claim(token)`.

**Acceptance.** The client agrees to the terms by creating the stream. The recipient agrees by calling `accept(id)` on an Active stream, or implicitly by its first withdrawal or its own dispute; `acceptedAt(id)` records when, and `Accepted` is emitted once. Acceptance changes nothing about the money. It decides whether a ruling counts: `records` are updated for both parties only when the recipient had accepted the stream before the ruling. A client can still dispute a stream its recipient never touched, and the ruling still settles the bond and principal, but it is nobody's public record, so a stranger cannot stack losses against an address by streaming a token of its own making at it, and a client cannot farm wins against a phantom recipient. The `Verdict` event is emitted for every ruling; indexers that build their own records must join it with `Accepted`. Two cooperating addresses can still farm records against each other, as with any reputation system without identity.

Creation and dispute require the **caller** to hold at least `minHold` WEIR at that moment. Other actions do not require a holding. Holdings are not locked and are not a proof of identity. Both parties can raise a dispute; no third party can do so. A dispute needs positive stake, but its rounded bond can be zero. A zero-bond dispute whose fee the court fund pays costs its raiser only gas, so a sponsored fund can be spent down by anyone eligible, including on streams of a worthless token between two addresses one person controls; the brief specifies a permissionless fund without quota, so sponsors should treat it as a gift to all users rather than a reserve.

Borrowed WEIR counts in full. A caller can borrow 10,000,000 WEIR, create or dispute with a zero bond, and repay the holding in the same transaction. There is no minimum holding period or later balance check. The bond is not a reliable deterrent to frivolous disputes; the oracle fee may also be paid by sponsorship.

`pause` stores the previous rate in `pausedRate`; a second pause reverts. `restart` takes a new positive rate and requires an already paused Active stream. `adjust` takes a positive rate and requires a running Active stream. Deposits must be positive. Zero withdrawals/refunds, including the max helpers when empty, are harmless no-ops with events. `void` closes permanently, pays all refundable funds to the client, and preserves the recipient's earned claim.

## Bonds, fees, and rulings

| Disputer's WEIR holding | Bond basis points | Fraction of stake |
|---|---|---|
| Below 100,000 | 500 | 5% |
| At least 100,000 | 250 | 2.5% |
| At least 1,000,000 | 100 | 1% |
| At least 10,000,000 | 0 | 0% |

The 10,000 WEIR gate still applies. `bond = floor(stake * tierBps / 10000)` is measured once at dispute time, pulled from the disputer in the stream token, and held outside stream principal. Later deposits, withdrawals, or holdings changes do not recalculate it.

**Bond limit.** The stake, and so the bond, can rise between a `bondFor` quote and the dispute transaction, because the client may `deposit` at any time while the stream is Active, including in front of the recipient's dispute. `dispute(id, note, maxBond)` reverts with `BondExceedsLimit` if the bond at execution exceeds `maxBond`; the site should pass the quote it displayed. `dispute(id, note)` is the same call with no limit and is kept for the approved ABI; integrations should prefer the bounded form.

Anyone can `sponsor(imdAmount)`. If the tracked court fund holds at least the live oracle price, it pays the entire fee. Otherwise the disputer pays the entire fee; partial sponsorship remains untouched. Stream principal and bonds denominated in IMD are never sponsorship. The application reads `priceOf(ORACLE_ACTION, IMD)` from the Intake, approves the Intake for exactly that amount, calls `requestWithFailure`, checks the exact debit, and clears any residual allowance. Unsolicited direct token transfers are not credited; there is no recovery or sweep mechanism.

Dispute snapshots accrual, preserves the last running rate, and sets the current rate to zero. Result callbacks and `submitAttestation` only verify signatures, store the ruling, and update records; they move no tokens. A true answer means accepted work (`ruling = 1`); false means rejected work (`ruling = 2`).

`enforce` applies the stored ruling:

- Accepted: recipient wins, gets the bond, and the stream resumes at `pausedRate` from enforcement time.
- Rejected: client wins, gets the bond and all refundable funds; the stream closes and the recipient keeps earned funds.

Thus a winning disputer gets its own bond back; a losing disputer's counterparty gets it. A request failure (status 1 or 2) or strict timeout (`now > disputedAt + disputeTimeout`) releases the bond to its original disputer and leaves an Active, paused stream. Each of these payouts is deferred to `claimable` if the token refuses it, so the transition always completes. The client must explicitly restart. Existing earned funds remain withdrawable throughout. An already paused stream retains its saved rate when disputed; accepted enforcement resumes that rate.

An accepted ruling does not remove the client's later Active-state permissions. It does not award all remaining principal immediately. Eligible parties can dispute again after a previous dispute ends. The permissionless court fund can be consumed through repeated requests; this design has no quota, cooldown, or subsidy guarantee.

`records(address)` packs five `uint32` counters: `clientWon`, `clientLost`, `recipientWon`, `recipientLost`, `raised`. Each ruling on a stream the recipient accepted increments the appropriate win/loss counter for both parties and `raised` for its disputer exactly once; a ruling on a stream the recipient never accepted increments nothing. Failures and expired requests do not increment verdict records. Events preserve historical requests and rulings; the Stream fields describe the most recent dispute and current outstanding bond.

## Oracle integration and review handoff

The action is the right-padded UTF-8 `bytes32("oracle.request@oracle-1")`, not a hash. The compact JSON body is built on chain with the exact workflow question template, a 24-hour window, bool answer, 5 seats, quorum 4, 604800-second validity, panel evidence, and this contract's consumer domain. Addresses and bytes32 values use lowercase, fixed-width hexadecimal. The optional IMD job clause is omitted for a zero job ID. Notes are at most 280 bytes. The implementation additionally bounds terms URIs to 512 bytes and questions to 2,000 bytes, validates UTF-8, and escapes quotes, backslashes, and every JSON control byte.

Use `expectedBody(id, disputer, note)` to preview independently of the RPC caller; `expectedBody(id, note)` uses `msg.sender`. The preview embeds the current block number, so a later mined transaction can differ. `QuestionCommitted` records the actual question, and `questionOf(id)` stores `keccak256` of that raw text. Terms and notes are untrusted evidence; JSON escaping prevents changing body fields but does not make their claims trustworthy. The approved template splices the note and the terms URI into the question as prose, not quoted and labelled as the parties' text, so a note written as an instruction ("answer true") reads to the panel as part of the question; the panel is expected to judge the evidence, and changing the template is a change to the approved workflow.

The result callback and `submitAttestation` move no tokens and make no call that can re-enter (the signature check is at most a staticcall), so they carry no reentrancy guard; a cold first ruling with both parties' records empty measures about 152,000 gas in the callee frame, under the Intake's 200,000 stipend.

Verification uses the canonical 15-field `OracleAttestation` struct and type hash, `keccak256(answer)`, and EIP-712 domain `{"IdentityMD Oracle", "2", block.chainid, this}`. The supplied protocol digest and signature vector are tested. Checks also require a pending Disputed stream, matching chain, canonical bool encoding, at least five panel seats, `agreed >= quorum >= 4`, `agreed <= panelSize`, and an unexpired attestation. The reference's five-minute future-issued tolerance is retained. The signed oracle request UUID (`a.requestId`) is consumed once across every stream, and previously used Intake IDs cannot be reused even after failure or expiry.

**Two request IDs, paired as the protocol specifies.** `requestWithFailure` returns the Intake's receipt ID, which `dispute` stores as `stream.requestId`. The signed attestation carries the oracle's own request UUID in `a.requestId`, which is a different value. `onOracleResult(requestId, a, signature)` trusts only the Intake as caller and pairs the answer with the stream by the receipt ID in its first argument, exactly as the protocol's consumer example does; it then verifies the signature and consumes the signed UUID. It never compares the UUID with the receipt. `submitAttestation(id, a, signature)` is permissionless, so the only association it can authenticate is `a.requestId == stream.requestId`; the question's relative window means `a.questionHash` cannot be reproduced on chain. On the live protocol those two IDs differ, so a lost or out-of-gas callback is in practice recovered with `expireDispute` after the timeout, not with `submitAttestation`. Accepting any other signed answer there would let a stranger settle a dispute with an unrelated question they paid for in this contract's name.

**There is no permissionless resubmission of a live oracle answer.** The submission entry point retains the assignment's explicit signed-ID equality requirement. It must not be presented as a working recovery button by the website. Expiry releases the bond without a ruling or verdict record; another dispute spends a new oracle fee. A working resubmission design needs an authenticated link between the signed answer and the pending request, with corresponding changes to the approved protocol/body requirements. A signature for this consumer alone is insufficient.

Other deliberate differences from the generic consumer examples are the immutable signer and configuration, mandatory v2 failure hook, and bond payout on an authenticated failure. The failure's unsigned reason/counts never choose a winner; only an Intake callback for this contract's currently pending request can release that request's bond. The local `questionOf` hash is **not** compared with `a.questionHash`: the latter covers the resolved oracle document and relative window, and cannot be precomputed as `keccak256(Q)`.

After source acceptance, services and the independent contributor should check the approved constructor arguments, the live Intake's body acceptance and ID linkage, current action price, signer behavior, callback stipend, and deployed code. Services publish, attest, admit, deploy, and provide actual addresses to the frontend. No contributor transaction or funded wallet is needed here. Once deployed, users or keepers must call `enforce` or `expireDispute`; the contract has no automatic scheduler. A failed callback is not retried by Intake; `expireDispute` releases the bond after the timeout, deferring it to a claim if the token refuses the payout. No live-chain fork or end-to-end paid oracle request was performed in this contribution.

See [ABI and integration details](docs/ABI.md) and [verification coverage](docs/VERIFICATION.md). License: MIT.
