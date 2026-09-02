# GB File Server | Client

**GB File Server / Client** is a Java 17 Maven multi-module project for secure,
resumable file transfer between parties. Clients upload files using the
[tus protocol](https://tus.io/) and download using HTTP range requests; both are
resumable. Clients authenticate to the server with **SSL client certificates**.
The project also provides the **Grote Berichten** (Digikoppeling) file-transfer
integration as a server and client extension.

- Upstream: <https://github.com/eluinstra/gb>
- Docs site (Docusaurus): `documentation/` (install, configuration, examples, migration)
- Docker examples: `file-server-docker/`
- License: [Apache License 2.0](LICENSE)

## Modules

| Module            | Description                                                        |
| ----------------- | ------------------------------------------------------------------ |
| `file-server-core`| Server domain logic (tus/HTTP endpoints, database, filesystem)     |
| `file-server`     | Server executable (REST/SOAP + tus)                                |
| `file-client-core`| Client domain logic (upload/download, database, filesystem)        |
| `file-client`     | Client executable                                                   |
| `gb-server`       | Grote Berichten server extension                                    |
| `gb-client`       | Grote Berichten client extension                                    |

This repo is an **aggregator**: each module is a git submodule pinned to its own
GitHub repo's `dev` branch (see `.gitmodules`).

## Prerequisites

- **JDK 17**
- **Maven 3.8+**
- A relational database (PostgreSQL is the documented default) for the executables

A ready-made dev environment is provided in [.devcontainer](.devcontainer)
(Java 17, Maven, Node for the docs). See [AGENTS.md](AGENTS.md) for contributor
and agent guidance.

## Getting the source

```bash
git clone https://github.com/eluinstra/gb.git
cd gb
git submodule update --init --recursive
```

The submodule checkout is required before building.

## Build

```bash
# Full build: compiles all modules and runs tests + JaCoCo coverage
mvn verify

# Compile only
mvn -DskipTests compile

# Build a single module and its in-repo dependencies
mvn -pl file-server -am -DskipTests package
```

## Tests

```bash
# All tests
mvn test

# One module
mvn -pl file-server-core test

# A single test class
mvn -pl file-client-core test -Dtest=VirtualPathTest
```

Tests use JUnit 5, AssertJ and Mockito. `mvn verify` runs the full test suite with
JaCoCo coverage, and **Checkstyle** is enforced on every build (bound to the
`validate` phase). The build tolerates a per-module baseline of pre-existing
Checkstyle errors and fails if a change introduces a new one — lower the module's
`checkstyle.maxAllowedViolations` as you fix violations. (PMD and SpotBugs are
configured but not yet wired into the build — see [AGENTS.md](AGENTS.md).)

## Running the executables

The server and client are configured through properties files and require a
database and, for the server, a keystore of registered client certificates.
See the documentation for details:

- Server install & config: `documentation/docs/installation/file-server.md`
- Client install & config: `documentation/docs/installation/file-client.md`
- End-to-end example: `documentation/docs/example.md`
- Dockerized server: `file-server-docker/README.md`

## Documentation

The Docusaurus documentation site lives in `documentation/`. To build it locally:

```bash
cd documentation
yarn install
yarn start   # dev server
yarn build   # static site in build/
```
