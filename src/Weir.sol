// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {OracleText} from "./libraries/OracleText.sol";

/// @title Weir
/// @notice Ownerless, per-second ERC-20 streams with a single-question IdentityMD dispute process.
/// @dev Only exact-transfer, non-rebasing tokens are supported. All amounts and rates are token minor units.
contract Weir is OracleAttestationConsumer, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;
    using Strings for address;

    enum State {
        None,
        Active,
        Disputed,
        Ruled,
        Closed
    }

    struct Stream {
        address client;
        address recipient;
        IERC20 token;
        uint128 rate;
        uint128 pausedRate;
        uint256 balance;
        uint256 withdrawn;
        uint256 snapDebt;
        uint256 snapTime;
        State state;
        bytes32 termsHash;
        string termsURI;
        bytes32 imdJobId;
        bytes32 requestId;
        uint256 disputedAt;
        address disputer;
        uint256 bond;
        uint8 ruling;
    }

    struct Record {
        uint32 clientWon;
        uint32 clientLost;
        uint32 recipientWon;
        uint32 recipientLost;
        uint32 raised;
    }

    error ZeroAddress();
    error InvalidConfiguration();
    error InvalidRecipient();
    error ZeroAmount();
    error ZeroRate();
    error ZeroTermsHash();
    error UnknownStream(uint256 id);
    error WrongState(State actual);
    error NotClient();
    error NotRecipient();
    error NotParty();
    error HoldRequired();
    error AlreadyPaused();
    error NotPaused();
    error AmountExceedsAvailable(uint256 amount, uint256 available);
    error NoStake();
    error TransferMismatch(address token);
    error Insolvent(address token);
    error NotTheIntake();
    error UnknownRequest(bytes32 requestId);
    error InvalidRequestId(bytes32 requestId);
    error AttestationRequestMismatch();
    error AttestationChainMismatch();
    error PanelTooWeak();
    error InvalidBoolAnswer();
    error InvalidFailureStatus();
    error DisputeNotExpired();
    error AlreadyAccepted();
    error BondExceedsLimit(uint256 bond, uint256 maxBond);
    error OraclePriceOutOfRange(uint256 price);
    error NothingToClaim();

    event StreamCreated(
        uint256 indexed id,
        address indexed client,
        address indexed recipient,
        address token,
        uint128 rate,
        uint256 amount,
        bytes32 termsHash,
        string termsURI,
        bytes32 imdJobId
    );
    event Accepted(uint256 indexed id, address indexed recipient, bytes32 termsHash);
    event Deposited(uint256 indexed id, uint256 amount);
    event PayoutDeferred(uint256 indexed id, address indexed token, address indexed account, uint256 amount);
    event Claimed(address indexed token, address indexed account, uint256 amount);
    event Paused(uint256 indexed id, uint128 pausedRate);
    event Restarted(uint256 indexed id, uint128 rate);
    event Adjusted(uint256 indexed id, uint128 oldRate, uint128 newRate);
    event Refunded(uint256 indexed id, uint256 amount);
    event Voided(uint256 indexed id, uint256 refunded);
    event Withdrawn(uint256 indexed id, uint256 amount);
    event Sponsored(address indexed sponsor, uint256 amount);
    event Disputed(
        uint256 indexed id, bytes32 indexed requestId, address indexed disputer, uint256 bond, bool fundPaid
    );
    event QuestionCommitted(uint256 indexed id, bytes32 indexed requestId, bytes32 questionHash, string question);
    event Verdict(
        uint256 indexed streamId,
        bytes32 indexed requestId,
        bytes32 indexed panelJobId,
        bool accepted,
        address client,
        address recipient,
        address disputer
    );
    event Enforced(uint256 indexed id, bool accepted, address indexed winner, uint256 bond);
    event DisputeFailed(
        uint256 indexed id, bytes32 indexed requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered
    );
    event DisputeExpired(uint256 indexed id, bytes32 indexed requestId);

    bytes32 public constant ORACLE_ACTION = bytes32("oracle.request@oracle-1");
    /// @notice The action's price at launch, for reference. The live price is read from the Intake per dispute.
    uint256 public constant ORACLE_PRICE = 5e17;
    /// @notice Highest live price a dispute will pay; protects disputers and the fund from a mispriced action.
    uint256 public constant MAX_ORACLE_PRICE = 5e18;
    uint256 public constant MAX_NOTE_BYTES = 280;
    uint256 public constant MAX_TERMS_URI_BYTES = 512;
    uint256 public constant MAX_QUESTION_BYTES = 2000;
    uint16 public constant PANEL_SIZE = 5;
    uint16 public constant QUORUM = 4;

    IERC20 public immutable weir;
    IERC20 public immutable imd;
    IIntake public immutable intake;
    uint40 public immutable disputeTimeout;
    uint256 public immutable minHold;

    uint256 public streamCount;
    /// @notice Only IMD credited through sponsor(); never includes stream principal or dispute bonds.
    uint256 public courtFund;
    mapping(uint256 => Stream) private _streams;
    mapping(address => Record) public records;
    /// @notice Hash of the raw question text of the latest dispute, not the oracle's canonical question document.
    mapping(uint256 => bytes32) public questionOf;
    /// @notice Stream principal still in custody plus outstanding bonds, per token; excludes courtFund.
    mapping(address => uint256) public escrowed;
    /// @dev Retained permanently to reject reused request ids, including after failure or expiry.
    mapping(bytes32 => uint256) public requestStream;
    /// @notice When the recipient accepted the stream's terms (accept() or a withdrawal); zero until then.
    mapping(uint256 => uint256) public acceptedAt;
    /// @notice Payouts the token refused to deliver, claimable by the owed account; token => account => amount.
    mapping(address => mapping(address => uint256)) public claimable;
    /// @notice Sum of claimable amounts per token; a custody obligation beside escrowed and courtFund.
    mapping(address => uint256) public unclaimed;

    constructor(
        IERC20 weir_,
        IERC20 imd_,
        IIntake intake_,
        address oracleSigner_,
        uint40 disputeTimeout_,
        uint256 minHold_
    ) OracleAttestationConsumer(oracleSigner_) {
        if (address(weir_) == address(0) || address(imd_) == address(0) || address(intake_) == address(0)) {
            revert ZeroAddress();
        }
        if (disputeTimeout_ == 0 || minHold_ == 0) revert InvalidConfiguration();
        weir = weir_;
        imd = imd_;
        intake = intake_;
        disputeTimeout = disputeTimeout_;
        minHold = minHold_;
    }

    function createStream(
        address recipient,
        IERC20 token,
        uint128 rate,
        uint128 amount,
        bytes32 termsHash,
        string calldata termsURI,
        bytes32 imdJobId
    ) external nonReentrant returns (uint256 id) {
        _holdGate();
        if (recipient == address(0) || recipient == msg.sender || recipient == address(this)) {
            revert InvalidRecipient();
        }
        if (address(token) == address(0)) revert ZeroAddress();
        if (rate == 0) revert ZeroRate();
        if (amount == 0) revert ZeroAmount();
        if (termsHash == bytes32(0)) revert ZeroTermsHash();
        OracleText.validate(termsURI, MAX_TERMS_URI_BYTES);
        // Incoming funds are credited only after checking their actual receipt. The guard covers the pull.
        _pullExact(token, msg.sender, amount);
        id = ++streamCount;
        Stream storage s = _streams[id];
        s.client = msg.sender;
        s.recipient = recipient;
        s.token = token;
        s.rate = rate;
        s.balance = amount;
        s.snapTime = block.timestamp;
        s.state = State.Active;
        s.termsHash = termsHash;
        s.termsURI = termsURI;
        s.imdJobId = imdJobId;
        escrowed[address(token)] += amount;
        _assertSolvent(token);
        _emitCreated(id, s);
    }

    /// @notice The recipient's assent to the stream's terms. A ruling is counted in both parties' records only
    /// on a stream its recipient accepted; a recipient's withdrawal or dispute counts as acceptance too.
    function accept(uint256 id) external nonReentrant {
        Stream storage s = _get(id);
        if (msg.sender != s.recipient) revert NotRecipient();
        _requireState(s, State.Active);
        if (acceptedAt[id] != 0) revert AlreadyAccepted();
        _accept(id, s);
    }

    /// @notice Adds funds from the client, including while a dispute is awaiting a ruling.
    function deposit(uint256 id, uint256 amount) external nonReentrant {
        Stream storage s = _get(id);
        _onlyClient(s);
        if (s.state != State.Active && s.state != State.Disputed) revert WrongState(s.state);
        if (amount == 0) revert ZeroAmount();
        _snapshot(s);
        _pullExact(s.token, msg.sender, amount);
        s.balance += amount;
        escrowed[address(s.token)] += amount;
        _assertSolvent(s.token);
        emit Deposited(id, amount);
    }

    function pause(uint256 id) external nonReentrant {
        Stream storage s = _activeClient(id);
        if (s.rate == 0) revert AlreadyPaused();
        _snapshot(s);
        s.pausedRate = s.rate;
        s.rate = 0;
        emit Paused(id, s.pausedRate);
    }

    /// @notice Resumes a paused Active stream at a new positive rate.
    function restart(uint256 id, uint128 rate) external nonReentrant {
        Stream storage s = _activeClient(id);
        if (s.rate != 0) revert NotPaused();
        if (rate == 0) revert ZeroRate();
        _snapshot(s);
        s.rate = rate;
        s.pausedRate = 0;
        emit Restarted(id, rate);
    }

    /// @notice Changes a running Active stream's positive rate prospectively.
    function adjust(uint256 id, uint128 rate) external nonReentrant {
        Stream storage s = _activeClient(id);
        if (s.rate == 0) revert AlreadyPaused();
        if (rate == 0) revert ZeroRate();
        _snapshot(s);
        uint128 oldRate = s.rate;
        s.rate = rate;
        emit Adjusted(id, oldRate, rate);
    }

    function refund(uint256 id, uint256 amount) external nonReentrant {
        Stream storage s = _activeClient(id);
        _refund(id, s, amount);
    }

    function refundMax(uint256 id) external nonReentrant {
        Stream storage s = _activeClient(id);
        _refund(id, s, s.balance - _streamed(s));
    }

    /// @notice Closes the stream and refunds only unearned funds. Earned funds remain withdrawable.
    function void(uint256 id) external nonReentrant {
        Stream storage s = _activeClient(id);
        uint256 amount = _close(s);
        emit Voided(id, amount);
        _pushExact(s.token, s.client, amount);
    }

    function withdraw(uint256 id, uint256 amount) external nonReentrant {
        Stream storage s = _get(id);
        _withdraw(id, s, amount);
    }

    function withdrawMax(uint256 id) external nonReentrant {
        Stream storage s = _get(id);
        _withdraw(id, s, _streamed(s) - s.withdrawn);
    }

    function sponsor(uint256 imdAmount) external nonReentrant {
        if (imdAmount == 0) revert ZeroAmount();
        _pullExact(imd, msg.sender, imdAmount);
        courtFund += imdAmount;
        _assertSolvent(imd);
        emit Sponsored(msg.sender, imdAmount);
    }

    /// @notice Raises a dispute with no bond limit. Prefer the overload with `maxBond`: the stake, and so the
    /// bond, can rise through a client deposit between a bondFor quote and this call.
    function dispute(uint256 id, string calldata note) external nonReentrant {
        _dispute(id, note, type(uint256).max);
    }

    /// @notice Raises a dispute, reverting if the bond at execution exceeds `maxBond` (pass the bondFor quote).
    function dispute(uint256 id, string calldata note, uint256 maxBond) external nonReentrant {
        _dispute(id, note, maxBond);
    }

    function _dispute(uint256 id, string calldata note, uint256 maxBond) private {
        Stream storage s = _get(id);
        _requireState(s, State.Active);
        _party(s, msg.sender);
        _holdGate();
        if (s.balance == s.withdrawn) revert NoStake();
        if (msg.sender == s.recipient && acceptedAt[id] == 0) _accept(id, s);
        string memory question = questionFor(id, msg.sender, note);
        uint256 bond = bondFor(id, msg.sender);
        if (bond > maxBond) revert BondExceedsLimit(bond, maxBond);
        _snapshot(s);
        if (s.rate != 0) s.pausedRate = s.rate;
        s.rate = 0;
        s.state = State.Disputed;
        s.disputedAt = block.timestamp;
        s.disputer = msg.sender;
        s.ruling = 0;
        questionOf[id] = keccak256(bytes(question));
        if (bond != 0) {
            _pullExact(s.token, msg.sender, bond);
            s.bond = bond;
            escrowed[address(s.token)] += bond;
            _assertSolvent(s.token);
        }
        (bytes32 requestId, bool fundPaid) = _request(_body(question));
        if (requestId == bytes32(0) || requestStream[requestId] != 0) revert InvalidRequestId(requestId);
        s.requestId = requestId;
        requestStream[requestId] = id;
        emit Disputed(id, requestId, msg.sender, bond, fundPaid);
        emit QuestionCommitted(id, requestId, questionOf[id], question);
    }

    /// @notice Verifies and records a ruling within the Intake callback stipend; transfers no tokens.
    /// @dev `requestId` is the Intake's receipt id, which pairs the answer to this contract's own pending
    /// request. `a.requestId` is the oracle's distinct request UUID; it is consumed, never compared to the receipt.
    function onOracleResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
    {
        if (msg.sender != address(intake)) revert NotTheIntake();
        uint256 id = _pendingRequest(requestId);
        _rule(id, _streams[id], a, signature);
    }

    /// @notice Anyone may deliver a signed ruling whose signed request id is the stream's stored request id.
    /// @dev The only association a permissionless caller can prove is `a.requestId == stream.requestId`. The
    /// relative-window question hash cannot be computed on chain, so no other signed answer is accepted here.
    function submitAttestation(uint256 id, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
    {
        Stream storage s = _get(id);
        _requireState(s, State.Disputed);
        if (a.requestId != s.requestId) revert AttestationRequestMismatch();
        _rule(id, s, a, signature);
    }

    /// @notice An authenticated failure releases only the matching pending request's bond.
    /// @dev Counts and reason are unsigned metadata, never used to choose a winner.
    function onFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered, bytes calldata)
        external
        nonReentrant
    {
        if (msg.sender != address(intake)) revert NotTheIntake();
        uint256 id = _pendingRequest(requestId);
        if (status != 1 && status != 2) revert InvalidFailureStatus();
        Stream storage s = _streams[id];
        uint256 bond = _releaseDispute(s);
        emit DisputeFailed(id, requestId, status, reason, agreed, answered);
        _pushOrDefer(id, s.token, s.disputer, bond);
    }

    function enforce(uint256 id) external nonReentrant {
        Stream storage s = _get(id);
        _requireState(s, State.Ruled);
        bool accepted = s.ruling == 1;
        address winner = accepted ? s.recipient : s.client;
        uint256 bond = _takeBond(s);
        uint256 refundAmount;
        if (accepted) {
            _snapshot(s);
            s.rate = s.pausedRate;
            s.pausedRate = 0;
            s.state = State.Active;
        } else {
            refundAmount = _close(s);
        }
        emit Enforced(id, accepted, winner, bond);
        _pushOrDefer(id, s.token, s.client, refundAmount);
        _pushOrDefer(id, s.token, winner, bond);
    }

    function expireDispute(uint256 id) external nonReentrant {
        Stream storage s = _get(id);
        _requireState(s, State.Disputed);
        if (block.timestamp - s.disputedAt <= disputeTimeout) revert DisputeNotExpired();
        uint256 bond = _releaseDispute(s);
        emit DisputeExpired(id, s.requestId);
        _pushOrDefer(id, s.token, s.disputer, bond);
    }

    /// @notice Pays out a settlement amount the token refused to deliver at the time (see PayoutDeferred).
    function claim(IERC20 token) external nonReentrant {
        uint256 amount = claimable[address(token)][msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimable[address(token)][msg.sender] = 0;
        unclaimed[address(token)] -= amount;
        emit Claimed(address(token), msg.sender, amount);
        _pushExact(token, msg.sender, amount);
    }

    /// @notice Full struct getter, including termsURI. Unknown ids have State.None.
    function streams(uint256 id) external view returns (Stream memory) {
        return _streams[id];
    }

    function streamed(uint256 id) public view returns (uint256) {
        return _streamed(_streams[id]);
    }

    function withdrawable(uint256 id) public view returns (uint256) {
        return _streamed(_streams[id]) - _streams[id].withdrawn;
    }

    function refundable(uint256 id) public view returns (uint256) {
        return _streams[id].balance - _streamed(_streams[id]);
    }

    function stake(uint256 id) public view returns (uint256) {
        return _streams[id].balance - _streams[id].withdrawn;
    }

    function tierBps(address account) public view returns (uint16) {
        uint256 holding = weir.balanceOf(account);
        if (holding >= 10_000_000e18) return 0;
        if (holding >= 1_000_000e18) return 100;
        if (holding >= 100_000e18) return 250;
        return 500;
    }

    /// @notice Quote at the current holdings and stream stake; an existing dispute keeps its original bond.
    function bondFor(uint256 id, address account) public view returns (uint256) {
        return Math.mulDiv(stake(id), tierBps(account), 10_000);
    }

    function canUse(address account) public view returns (bool) {
        return weir.balanceOf(account) >= minHold;
    }

    /// @notice The IMD a dispute pays right now, read from the Intake; reverts if the action is not sold or
    /// priced above MAX_ORACLE_PRICE, in which case dispute() reverts the same way.
    function oraclePrice() public view returns (uint256 price) {
        price = intake.priceOf(ORACLE_ACTION, address(imd));
        if (price == 0 || price > MAX_ORACLE_PRICE) revert OraclePriceOutOfRange(price);
    }

    /// @notice Preview for a specified party at the current block, including when called by an RPC reader.
    function expectedBody(uint256 id, address disputer, string calldata note) external view returns (bytes memory) {
        return _body(questionFor(id, disputer, note));
    }

    /// @notice Preview with msg.sender as the disputer. Set `from` to the user's address when simulating.
    function expectedBody(uint256 id, string calldata note) external view returns (bytes memory) {
        return _body(questionFor(id, msg.sender, note));
    }

    function questionFor(uint256 id, address disputer, string memory note) public view returns (string memory) {
        Stream storage s = _get(id);
        _party(s, disputer);
        OracleText.validate(note, MAX_NOTE_BYTES);
        string memory question = string.concat(
            "Weir stream ",
            id.toString(),
            " at ",
            address(this).toHexString(),
            " on chain ",
            block.chainid.toString(),
            ". Client ",
            s.client.toHexString()
        );
        question = string.concat(
            question,
            " streams ",
            address(s.token).toHexString(),
            " to recipient ",
            s.recipient.toHexString(),
            " under the terms at ",
            s.termsURI,
            " (keccak256 ",
            uint256(s.termsHash).toHexString(32),
            ")"
        );
        if (s.imdJobId != bytes32(0)) {
            question = string.concat(question, ", IMD job ", uint256(s.imdJobId).toHexString(32));
        }
        question = string.concat(
            question,
            ". Dispute raised by the ",
            disputer == s.client ? "client" : "recipient",
            " with note: ",
            note,
            ". As of block ",
            block.number.toString(),
            ", has the recipient delivered the work those terms describe to the standard a reasonable client would accept? Answer true if yes, false if no."
        );
        if (bytes(question).length > MAX_QUESTION_BYTES) {
            revert OracleText.TextTooLong(bytes(question).length, MAX_QUESTION_BYTES);
        }
        return question;
    }

    function _body(string memory question) private view returns (bytes memory) {
        return bytes(
            string.concat(
                '{"v":1,"question":"',
                OracleText.escape(question),
                '","chainId":',
                block.chainid.toString(),
                ',"window":{"hours":24},"answerType":"bool","panelSize":5,"quorum":4,"validForSeconds":604800,"evidence":"panel","consumer":{"chainId":',
                block.chainid.toString(),
                ',"verifyingContract":"',
                address(this).toHexString(),
                '"}}'
            )
        );
    }

    function _request(bytes memory body) private returns (bytes32 requestId, bool fundPaid) {
        uint256 price = oraclePrice();
        fundPaid = courtFund >= price;
        if (fundPaid) courtFund -= price;
        else _pullExact(imd, msg.sender, price);
        uint256 beforeBalance = imd.balanceOf(address(this));
        imd.forceApprove(address(intake), price);
        requestId = intake.requestWithFailure(
            ORACLE_ACTION,
            body,
            IIntake.Callback(address(this), this.onOracleResult.selector),
            this.onFailure.selector,
            address(imd),
            price
        );
        // Even an Intake that under-pulls cannot retain an allowance against stream escrow.
        imd.forceApprove(address(intake), 0);
        uint256 afterBalance = imd.balanceOf(address(this));
        if (afterBalance > beforeBalance || beforeBalance - afterBalance != price) {
            revert TransferMismatch(address(imd));
        }
        _assertSolvent(imd);
    }

    /// @dev The caller has already paired `s` with the attestation; this verifies, consumes the signed oracle
    /// request id once, and records the ruling. It moves no tokens and makes no call that can re-enter (the
    /// signature check is a staticcall at most), so it carries no reentrancy guard and stays cheap for the
    /// Intake's callback stipend. Records are only written when the recipient accepted the stream's terms:
    /// a verdict on terms one side never agreed to is enforced economically but is nobody's public record.
    function _rule(uint256 id, Stream storage s, OracleAttestation.Attestation calldata a, bytes calldata signature)
        private
    {
        if (a.chainId != block.chainid) revert AttestationChainMismatch();
        if (a.panelSize < PANEL_SIZE || a.quorum < QUORUM || a.agreed < a.quorum || a.agreed > a.panelSize) {
            revert PanelTooWeak();
        }
        _verifyAttestation(a, signature);
        if (a.answerType != OracleAttestation.ANSWER_BOOL) {
            revert WrongAnswerType(OracleAttestation.ANSWER_BOOL, a.answerType);
        }
        if (a.answer.length != 32 || abi.decode(a.answer, (uint256)) > 1) revert InvalidBoolAnswer();
        bool accepted = decodeBool(a);
        _consume(a.requestId);
        s.ruling = accepted ? 1 : 2;
        s.state = State.Ruled;
        if (acceptedAt[id] != 0) {
            if (accepted) {
                ++records[s.client].clientLost;
                ++records[s.recipient].recipientWon;
            } else {
                ++records[s.client].clientWon;
                ++records[s.recipient].recipientLost;
            }
            ++records[s.disputer].raised;
        }
        emit Verdict(id, s.requestId, a.panelJobId, accepted, s.client, s.recipient, s.disputer);
    }

    function _streamed(Stream storage s) private view returns (uint256) {
        uint256 debt = s.snapDebt;
        uint256 rate = s.rate;
        if (rate == 0 || debt == s.balance) return debt;
        uint256 elapsed = block.timestamp - s.snapTime;
        uint256 remaining = s.balance - debt;
        // Cap before multiplication, including extreme timestamps, without overflowing rate * elapsed.
        if (elapsed > remaining / rate) return s.balance;
        return debt + rate * elapsed;
    }

    function _snapshot(Stream storage s) private {
        s.snapDebt = _streamed(s);
        s.snapTime = block.timestamp;
    }

    function _refund(uint256 id, Stream storage s, uint256 amount) private {
        _snapshot(s);
        uint256 available = s.balance - s.snapDebt;
        if (amount > available) revert AmountExceedsAvailable(amount, available);
        s.balance -= amount;
        escrowed[address(s.token)] -= amount;
        emit Refunded(id, amount);
        _pushExact(s.token, s.client, amount);
    }

    function _accept(uint256 id, Stream storage s) private {
        acceptedAt[id] = block.timestamp;
        emit Accepted(id, s.recipient, s.termsHash);
    }

    function _withdraw(uint256 id, Stream storage s, uint256 amount) private {
        if (msg.sender != s.recipient) revert NotRecipient();
        if (acceptedAt[id] == 0) _accept(id, s);
        uint256 available = _streamed(s) - s.withdrawn;
        if (amount > available) revert AmountExceedsAvailable(amount, available);
        s.withdrawn += amount;
        escrowed[address(s.token)] -= amount;
        emit Withdrawn(id, amount);
        _pushExact(s.token, s.recipient, amount);
    }

    function _close(Stream storage s) private returns (uint256 amount) {
        _snapshot(s);
        amount = s.balance - s.snapDebt;
        s.balance = s.snapDebt;
        s.rate = 0;
        s.pausedRate = 0;
        s.state = State.Closed;
        escrowed[address(s.token)] -= amount;
    }

    function _takeBond(Stream storage s) private returns (uint256 bond) {
        bond = s.bond;
        s.bond = 0;
        escrowed[address(s.token)] -= bond;
    }

    function _releaseDispute(Stream storage s) private returns (uint256 bond) {
        bond = _takeBond(s);
        s.state = State.Active;
        // rate remains zero and pausedRate is preserved for an explicit client restart.
    }

    function _pendingRequest(bytes32 requestId) private view returns (uint256 id) {
        id = requestStream[requestId];
        if (id == 0 || _streams[id].requestId != requestId) revert UnknownRequest(requestId);
        _requireState(_streams[id], State.Disputed);
    }

    function _get(uint256 id) private view returns (Stream storage s) {
        s = _streams[id];
        if (s.state == State.None) revert UnknownStream(id);
    }

    function _activeClient(uint256 id) private view returns (Stream storage s) {
        s = _get(id);
        _onlyClient(s);
        _requireState(s, State.Active);
    }

    function _onlyClient(Stream storage s) private view {
        if (msg.sender != s.client) revert NotClient();
    }

    function _party(Stream storage s, address account) private view {
        if (account != s.client && account != s.recipient) revert NotParty();
    }

    function _holdGate() private view {
        if (!canUse(msg.sender)) revert HoldRequired();
    }

    function _requireState(Stream storage s, State required) private view {
        if (s.state != required) revert WrongState(s.state);
    }

    function _pullExact(IERC20 token, address from, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) {
            revert TransferMismatch(address(token));
        }
    }

    function _pushExact(IERC20 token, address to, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 beforeRecipient = token.balanceOf(to);
        token.safeTransfer(to, amount);
        uint256 afterBalance = token.balanceOf(address(this));
        uint256 afterRecipient = token.balanceOf(to);
        if (
            afterBalance > beforeBalance || beforeBalance - afterBalance != amount || afterRecipient < beforeRecipient
                || afterRecipient - beforeRecipient != amount
        ) revert TransferMismatch(address(token));
        _assertSolvent(token);
    }

    /// @dev Settlement payout that must never block a state transition: if the token reverts the transfer
    /// (a blocklist, a pause), nothing moved and the amount becomes claimable by `to` instead. A transfer that
    /// succeeds but moves the wrong amount still reverts, as every other payout does.
    function _pushOrDefer(uint256 id, IERC20 token, address to, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 beforeRecipient = token.balanceOf(to);
        (bool ok, bytes memory returndata) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) {
            claimable[address(token)][to] += amount;
            unclaimed[address(token)] += amount;
            emit PayoutDeferred(id, address(token), to, amount);
            _assertSolvent(token);
            return;
        }
        uint256 afterBalance = token.balanceOf(address(this));
        uint256 afterRecipient = token.balanceOf(to);
        if (
            (returndata.length != 0 && (returndata.length < 32 || !abi.decode(returndata, (bool))))
                || afterBalance > beforeBalance || beforeBalance - afterBalance != amount
                || afterRecipient < beforeRecipient || afterRecipient - beforeRecipient != amount
        ) revert TransferMismatch(address(token));
        _assertSolvent(token);
    }

    function _assertSolvent(IERC20 token) private view {
        uint256 required = escrowed[address(token)] + unclaimed[address(token)];
        if (token == imd) required += courtFund;
        if (token.balanceOf(address(this)) < required) revert Insolvent(address(token));
    }

    function _emitCreated(uint256 id, Stream storage s) private {
        emit StreamCreated(
            id, s.client, s.recipient, address(s.token), s.rate, s.balance, s.termsHash, s.termsURI, s.imdJobId
        );
    }
}
