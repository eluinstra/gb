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
- Integration behavior (real DB, HTTP server, TLS) is not covered by unit tests;
  see the docs `example.md` and `file-server-docker` for manual scenarios.

## Where things are documented

- User/operator docs (Docusaurus): `documentation/docs/` — install, configuration,
  examples, migration.
- Release process: `documentation/docs/release.md`.
- Docker usage: `file-server-docker/README.md`.
