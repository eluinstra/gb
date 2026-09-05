# Agent Guide

Guidance for AI agents (and humans) working in this repository. Read this before
making changes. The goal is for an agent to be able to build the project, run the
checks, and know when a change is correct.

## What this project is

**GB File Server / Client** is a Java 17 Maven multi-module project for secure,
resumable file transfer. Clients upload files over the [tus protocol](https://tus.io/)
and download over HTTP range requests; authentication is via SSL client certificates.
It doubles as the **Grote Berichten** (Digikoppeling) file-transfer integration.

Upstream home: `https://github.com/eluinstra/gb`.

## Layout

This is an **aggregator** repo. The buildable source lives in git submodules, each
its own GitHub repo pinned to the `dev` branch:

| Module              | Package root                  | Role                                             | Has `main`? |
| ------------------- | ----------------------------- | ------------------------------------------------ | ----------- |
| `file-server-core`  | `dev.luin.file.server.core`   | Server domain logic (tus/HTTP, DB, filesystem)   | no          |
| `file-server`       | `dev.luin.file.server`        | Server executable (`Start`, `StartGB`)           | yes         |
| `file-client-core`  | `dev.luin.file.client.core`   | Client domain logic (upload/download, DB)        | no          |
| `file-client`       | `dev.luin.file.client`        | Client executable (`Start`, `StartGB`)           | yes         |
| `gb-server-core`/`gb-server` | `dev.luin.digikoppeling.gb.*` | Grote Berichten server extension | yes         |
| `gb-client-core`/`gb-client` | `dev.luin.digikoppeling.gb.*` | Grote Berichten client extension | yes         |

Build order (Maven reactor): `file-client-core` -> `gb-client` -> `file-client` ->
`file-server-core` -> `gb-server` -> `file-server`.

Submodule list lives in `.gitmodules`. The Docusaurus docs site is the
`documentation` submodule; `file-server-docker` holds Docker examples.

## Build & test

Toolchain: **JDK 17**, **Maven 3.8+**. The repo ships a `.devcontainer` with these
preinstalled (Java 17 + Maven + Node for the docs site). There is **no Maven wrapper**
in the repo, so rely on a system/CI `mvn`.

```bash
# Full build: compiles all modules, runs Checkstyle, tests and JaCoCo coverage
mvn verify

# Compile only (fast)
mvn -DskipTests compile

# Run one module's tests
mvn -pl file-server-core test

# Run a single test class
mvn -pl file-client-core test -Dtest=VirtualPathTest

# Build a single module (and its in-repo deps)
mvn -pl file-server -am -DskipTests package
```

`mvn verify` is the source of truth for CI and should be green before a change
is considered done: it runs **Checkstyle, PMD and SpotBugs**, compiles all
modules, runs the test suite, and produces a JaCoCo coverage report.

### Static analysis (Checkstyle, PMD, SpotBugs)

All three static-analysis tools run on every build, are inherited by all six
modules (the root aggregator has no sources and skips them via `*.skip`), and
**fail the build on findings**.

| Tool | Goal | Phase | Baseline | What it gates |
|------|------|-------|----------|---------------|
| Checkstyle | `checkstyle:check` | `validate` | 0 violations | Style; hand-written `src/main/java` only |
| PMD | `pmd:check` | `process-classes` | 0 violations | Static analysis (unused code, style, bugs) |
| SpotBugs | `spotbugs:check` | `process-classes` | FindSecBugs SECURITY baseline | Security findings (SSRF, path traversal, CRLF injection, weak crypto, …) |

- **Checkstyle** is Checkstyle-clean: each module's `pom.xml` sets
  `<checkstyle.maxAllowedViolations>` to `0`. Config is `resources/reporting/checkstyle.xml`
  (mirrored per module; canonical copy at repo root `reporting/checkstyle.xml`).
  It lints only hand-written main sources (`src/main/java` via `sourceDirectories`),
  so generated code is never linted and test sources (which were never linted) are
  out of scope.
- **PMD** is also clean (0). It runs at `process-classes` (post-compile) because
  its usage analysis needs the compiled classpath; pre-compile it reports false
  `UnusedPrivateMethod` findings. Generated sources are excluded. A few
  value-object classes use the project's deliberate fluent static-import style and
  carry a targeted `@SuppressWarnings("PMD.TooManyStaticImports")`.
- **SpotBugs** runs FindSecBugs (the `findsecbugs` plugin) with a SECURITY include
  filter (`resources/reporting/spotbugs-security-include.xml`) and suppresses the
  pre-existing findings via a per-module baseline
  (`resources/reporting/spotbugs-security-suppressions.xml`). It gates on **new**
  security findings only. The baseline still holds ~114 pre-existing security
  findings (7 high-priority: SSRF, path traversal, weak MD5, XSS) — work through
  the suppressions file to retire them, deleting each `<Match>` as you fix it.

To temporarily disable a gate: `mvn -Dcheckstyle.skip=true`,
`-Dpmd.skip=true`, or `-Dspotbugs.skip=true`.

### Submodules (important for agents)

- `git submodule update --init --recursive` is required after a fresh clone before
  the build will find the module sources.
- Each submodule is a **separate repository**. A change to module code is committed
  inside that submodule's own repo (branch `dev`), then the aggregator's gitlink is
  bumped here. Do **not** edit submodule code and expect a single commit to cover it.
- Keep submodule pointers on the `dev` branch unless told otherwise.

## Code conventions

- **Indentation: tabs** (not spaces). Match the existing `.java` files.
- Every `.java` file starts with the Apache-2.0 license header
  (see `resources/license/header.txt`). Keep it when adding/editing files.
- Uses **Lombok** (`@Value`, `@FieldDefaults`, `@NonNull`, etc.) and **Vavr**
  (`Try`, `Stream`) for value objects.
- Domain "value objects" implement `ValueObject<T>` with a `getValue()`.
- Source encoding is ISO-8859-1 (set in `maven-compiler-plugin`).
- Follow existing naming (`XxxTest` for tests, `Xxx` for classes).

## Testing

- JUnit 5 (Jupiter) + AssertJ + Mockito. Existing tests are in
  `file-server-core/src/test` — see
  `dev.luin.file.server.core.server.upload.header.*Test` for the house style
  (`@TestInstance(Lifecycle.PER_CLASS)`, `@ParameterizedTest` + `@MethodSource` using
  Vavr `Stream.of(arguments(...))`).
- Coverage is currently concentrated in `file-server-core`. The client-side modules
  had little/no tests; when touching them, add focused unit tests for the value
  objects and pure logic you change (no DB/network needed for those).
- Integration behavior (real DB, Jetty, TLS/mTLS) is **not** covered by unit tests;
  it is manual only. See below.

### Manual mTLS / integration testing

There is no automated integration test for the live stack, so verify TLS changes
(mTLS auth, download/upload over HTTPS) by hand.

**Authentication is mTLS:** the client presents a certificate that the server's
trust store must trust, and each user's certificate is registered on the server
(`createUser`) before that user can up-/download files. The upload base URL is
`https://localhost:8443/files/upload`; a file's download URL is returned by the
server (in the `uploadFile` response `path` / the GB `getExternalDataReference`
`senderUrl`), so always use the URL the server hands back.

**Test artifacts (all checked in; PKCS12 keystores use the password `password`):**

| File | Where | Purpose |
|------|-------|---------|
| server keystore | `file-server-core/resources/ssl/keystore.p12` (alias `localhost`, a private-key entry) | the cert the server serves on `https://localhost:8443` |
| server truststore | `file-server-core/resources/ssl/truststore.p12` | the client cert(s) the server will trust |
| client cert | `file-server-core/resources/ssl/localhost.pem` (certificate only) | the client certificate presented during mTLS / registered per user |
| client key bundle | `file-server-core/resources/ssl/keystore.pem` (cert + private key in PEM) | use `--cert`/`--key` if you need the key form |

**Fastest path — the Docker demo** (server + client + Postgres, certs pre-wired):

```bash
cd file-server-docker/examples/demo-pg
docker compose up
```

Then follow the numbered flow in `file-server-docker/README.md` (or `documentation/docs/example.md`):
create user with its certificate → `uploadFile` → `getExternalDataReference` →
`downloadFile`. Use SoapUI (`file-server-soapui-project.xml` / `file-client-soapui-project.xml`)
or the VS Code REST Client files (`file-server.rest` / `file-client.rest`).

**curl against a locally started server** — because the server cert is
self-signed and the endpoint requires a client cert, trust the server cert
(`--cacert`) *and* present the client cert:

```bash
curl --cacert <server-crt.pem> \
     --cert file-server-core/resources/ssl/localhost.pem \
     "<download-url-returned-by-the-server>" -o file.txt
```

(For the full cert + key PEM bundle, use `--cert <cert>` `--key <key>` instead of
a single `--cert`. Use `-k` only as a throwaway way to skip server-cert trust while
debugging — never as the intended configuration.)

## Where things are documented

- User/operator docs (Docusaurus): `documentation/docs/` — install, configuration,
  examples, migration.
- Release process: `documentation/docs/release.md`.
- Docker usage: `file-server-docker/README.md`.
