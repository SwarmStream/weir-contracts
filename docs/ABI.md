# Weir ABI and integration notes

The compiler export is [abi/Weir.json](abi/Weir.json), a standard JSON ABI array. All addresses are ABI `address` values, including IERC20 and IIntake arguments. Amounts are unsigned integers in the relevant token's minor units. There are no payable Weir functions.

The launch token's compiler export is [abi/LaunchToken.json](abi/LaunchToken.json). `LaunchToken` has a nonpayable constructor with no arguments, ERC-20 metadata (`Weir`, `WEIR`, 18 decimals), and the standard `totalSupply`, `balanceOf`, `transfer`, `approve`, `allowance`, and `transferFrom` functions, `Transfer` and `Approval` events, and ERC-20 custom errors. Exactly `10^27` minor units are minted to the deploying factory at construction. No additional administrative or minting functions are exposed.

## Constructor and configuration

```solidity
constructor(IERC20 weir_, IERC20 imd_, IIntake intake_, address oracleSigner_, uint40 disputeTimeout_, uint256 minHold_)
```

Configuration getters: `weir()`, `imd()`, `intake()`, `oracleSigner()`, `disputeTimeout()`, `minHold()`. The approved launch values are in the root README. Constants: `ORACLE_ACTION`, `ORACLE_PRICE`, `MAX_NOTE_BYTES`, `MAX_TERMS_URI_BYTES`, `MAX_QUESTION_BYTES`, `PANEL_SIZE`, `QUORUM`, `ISSUED_AT_TOLERANCE`.

## User actions

| Function | Caller and requirement | Effect |
|---|---|---|
| `createStream(address,IERC20,uint128,uint128,bytes32,string,bytes32) -> uint256` | Eligible holder, recipient distinct and nonzero, positive rate/amount, nonzero terms hash | Pulls initial principal and emits an ID starting at 1 |
| `deposit(uint256,uint256)` | Client; Active or Disputed | Pulls more principal; snapshots before crediting |
| `pause(uint256)` | Client; Active, running | Saves rate and pauses accrual |
| `restart(uint256,uint128)` | Client; Active, paused; positive rate | Resumes prospectively at the supplied rate |
| `adjust(uint256,uint128)` | Client; Active, running; positive rate | Changes the rate prospectively |
| `refund(uint256,uint256)` | Client; Active; amount at most refundable | Pays unearned principal to client |
| `refundMax(uint256)` | Client; Active | Refunds all currently unearned principal |
| `void(uint256)` | Client; Active | Refunds unearned principal and closes |
| `withdraw(uint256,uint256)` | Recipient; any existing state; amount at most withdrawable | Pays earned principal to recipient |
| `withdrawMax(uint256)` | Recipient; any existing state | Pays all currently earned, unwithdrawn principal |
| `dispute(uint256,string)` | Eligible client or recipient; Active; stake positive | Pulls bond and any caller-paid fee, pauses, sends oracle request |
| `sponsor(uint256)` | Anyone; positive amount | Pulls IMD into courtFund |
| `enforce(uint256)` | Anyone; Ruled | Applies verdict and bond payout |
| `expireDispute(uint256)` | Anyone; Disputed, strictly past deadline | Releases bond to disputer; leaves Active and paused |

Approve **Weir**, not Intake, to pull initial principal, deposits, bonds, and sponsorship. If a fee is caller-paid and the stream token is IMD, the allowance and wallet balance must cover bond plus `5e17`. Exact requested amounts are sufficient. Quotes depend on holdings, stake, fund availability, and transaction ordering; simulate immediately before signing. The fund may be spent by an intervening dispute, causing a caller-fee pull or an allowance/balance revert.

## Reads

| Function | Meaning |
|---|---|
| `streams(uint256) -> Stream` | Full struct, including the dynamic URI |
| `streamCount() -> uint256` | Latest assigned ID |
| `streamed(uint256) -> uint256` | Total earned amount, capped by credited balance |
| `withdrawable(uint256) -> uint256` | Earned amount not yet withdrawn |
| `refundable(uint256) -> uint256` | Unearned principal |
| `stake(uint256) -> uint256` | All principal still in custody |
| `tierBps(address) -> uint16` | Current holding tier, whether or not the caller qualifies to dispute |
| `bondFor(uint256,address) -> uint256` | New dispute bond quote; existing bonds are in `streams(id).bond` |
| `canUse(address) -> bool` | Current holding meets immutable minimum |
| `courtFund() -> uint256` | Unspent credited IMD sponsorship |
| `escrowed(address) -> uint256` | Outstanding principal plus bonds in one token, excluding courtFund |
| `records(address) -> (uint32,uint32,uint32,uint32,uint32)` | clientWon, clientLost, recipientWon, recipientLost, raised |
| `questionOf(uint256) -> bytes32` | Hash of raw question text for latest dispute |
| `questionFor(uint256,address,string) -> string` | Current-block raw question preview for a party |
| `expectedBody(uint256,address,string) -> bytes` | Current-block UTF-8 JSON body preview for a party |
| `expectedBody(uint256,string) -> bytes` | Same preview, using msg.sender as disputer |
| `requestStream(bytes32) -> uint256` | Permanent Intake ID to stream ID association; zero means unknown |
| `consumed(bytes32) -> bool` | Whether an attestation was accepted for that request |
| `attestationDigest(Attestation) -> bytes32` | EIP-712 digest in this consumer's domain |
| `eip712Domain()` | OpenZeppelin IERC5267 domain description |

`Stream` fields, in order: `client address`, `recipient address`, `token address`, `rate uint128`, `pausedRate uint128`, `balance uint256`, `withdrawn uint256`, `snapDebt uint256`, `snapTime uint256`, `state uint8`, `termsHash bytes32`, `termsURI string`, `imdJobId bytes32`, `requestId bytes32`, `disputedAt uint256`, `disputer address`, `bond uint256`, `ruling uint8`.

State encoding: None=0, Active=1, Disputed=2, Ruled=3, Closed=4. Ruling encoding: unset=0, accepted=1, rejected=2. A settled stream retains its latest request/disputer/ruling for inspection; its live `bond` is zero after payout. A new dispute resets `ruling`. After failure/expiry, the rate remains zero even though state is Active.

## Oracle entry points

```solidity
onOracleResult(bytes32 requestId, Attestation a, bytes signature)
submitAttestation(uint256 id, Attestation a, bytes signature)
onFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered, bytes signature)
```

Both callbacks require the immutable Intake as caller. Submission is permissionless and has exactly the same verification and state effects as the result callback. Failure metadata is unsigned and its signature argument is ignored. Status 1 means refusal and status 2 means no panel agreement. Failed and expired requests cannot later accept a result.

`Attestation` is the canonical tuple:

```text
(bytes32 requestId, uint256 chainId, bytes32 questionHash, uint8 answerType,
 bytes answer, uint256 figure, uint64 fromBlock, uint64 toBlock,
 bytes32 blockHash, bytes32 panelJobId, uint16 panelSize, uint16 quorum,
 uint16 agreed, uint64 issuedAt, uint64 expiresAt)
```

The domain name is `IdentityMD Oracle`, version `2`; its chain is `block.chainid`, and verifying contract is the Weir address. Bool answers use answerType 0 and exactly 32 bytes of ABI encoding (0 or 1). See the README's explicit signed-ID/Intake-ID conflict before integrating with a live writer.

## Events and errors

Index `StreamCreated` by client/recipient to construct wallet lists. Index `Disputed` and `QuestionCommitted` by stream ID and request ID for the exact paid question, bond, and fee source. `Verdict` indexes stream ID, request ID and panel job ID, with both parties, disputer, and accepted flag in event data. `Enforced` includes accepted flag, winner, and paid bond. `DisputeFailed` records unsigned reason/counts, and `DisputeExpired` records the timed-out request. Every ordinary stream mutation emits `Deposited`, `Paused`, `Restarted`, `Adjusted`, `Refunded`, `Voided`, or `Withdrawn`; sponsors emit `Sponsored`. Full argument types and indexed flags are in the JSON ABI.

Map errors to user-facing descriptions using the ABI. Common groups are authorization (`NotClient`, `NotRecipient`, `NotParty`, `HoldRequired`, `NotTheIntake`), state (`UnknownStream`, `WrongState`, `AlreadyPaused`, `NotPaused`, `DisputeNotExpired`), amounts/tokens (`ZeroAmount`, `ZeroRate`, `AmountExceedsAvailable`, `NoStake`, `TransferMismatch`, `Insolvent` and SafeERC20 errors), text (`TextTooLong`, `InvalidUTF8`), and oracle verification (`UnknownRequest`, `InvalidRequestId`, `AttestationRequestMismatch`, `AttestationChainMismatch`, `PanelTooWeak`, `WrongAnswerType`, `InvalidBoolAnswer`, `AttestationExpired`, `AttestationNotYetValid`, `BadSignature`, `AlreadyConsumed`, `InvalidFailureStatus`). Other input errors are `InvalidRecipient`, `ZeroTermsHash`, `ZeroAddress`, `ZeroSigner`, and `InvalidConfiguration`. ReentrancyGuard rejects nested mutations with `ReentrancyGuardReentrantCall`. Token-specific reverts can also propagate unchanged.
