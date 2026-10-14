# Dependency provenance

Production dependencies are the imported source closure of **OpenZeppelin Contracts v5.5.0**, vendored under `lib/openzeppelin-contracts/contracts/`. The sources are from the tagged upstream repository:

https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.5.0/contracts

The upstream MIT license is at `lib/openzeppelin-contracts/LICENSE`. The source was retrieved from the corresponding `raw.githubusercontent.com` URLs as plain text. Blank-line layout may differ from the archive; functionality is unchanged. There is no npm install, node_modules directory, external linked library, or submodule. All library calls in production are internal/inlined.

Tests use **forge-std v1.9.7**, with its imported source closure under `lib/forge-std/src/`:

https://github.com/foundry-rs/forge-std/tree/v1.9.7/src

Its MIT and Apache licenses are preserved in that directory's parent. The unused `safeconsole` convenience import was omitted from the vendored `Test.sol`; no assertion or cheatcode behavior was modified. Tests never read or modify environment variables, call FFI, access files, create RPC forks, or need network access. The supplied fuzz seed is passed by the invoking shell.

`src/OracleAttestation.sol` copies the supplied canonical protocol library and verifier. Its only functional adaptation is immutable `oracleSigner` initialization in the constructor and removal of the internal rotation hook, as required by Weir's ownerless design. The struct, type hash, domain, signature check, time tolerance, and decoding functions retain the reference behavior. This source is MIT, as marked in the supplied file. The fixed protocol vector is covered by `test/OracleConsumerConformance.t.sol`.

`dependencies.sha256` records SHA-256 digests of the delivered vendor files. The Solidity compiler is a runtime prerequisite at version 0.8.26, not a vendored binary. No source fetch is needed for verification.
