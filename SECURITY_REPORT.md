# Security Scan — gb (GB File Server / Client)

Date: 2026-09-04 · Scope: aggregator + 6 submodules (`dev` branch), JDK 17, Maven.
Methods: OSV.dev dependency scan (134 runtime deps), SpotBugs/FindSecBugs (107 baseline
findings), manual review of the auth/TLS/file/network/credential surface, and a secrets
scan. All repos are **public on GitHub**.

**Verdict: 0 CRITICAL, 2 HIGH, 3 MEDIUM, several LOW/hardening.** The codebase has
solid input validation in the file APIs. The main real risks are weak password hashing
(unsalted MD5), Jackson 3 with known high-severity deserialization bypasses, and a few
dependency CVEs. Several items that initially looked higher-severity (the committed TLS
test keys, the trust-all hostname verifier, and the docker demo credentials) are
**testing/dev conveniences, overridden or unused in production** — reclassified to
hygiene/low below.

---

## 1. MEDIUM — Bundled TLS test keys shipped in a public repo *as the startup default*

`keystore.p12` / `keystore.jks` contain a **`PrivateKeyEntry`** (private key, alias
`localhost`, created 2020) and open with the password `password`, which is also committed:

| Repo | Committed private-key file |
|---|---|
| `file-server-core` | `resources/ssl/keystore.p12`, `keystore.jks`, `keystore.pem`, `localhost.pem` |
| `file-client-core` | `src/main/resources/dev/luin/file/client/core/keystore.p12` |

**Context (per maintainer): these keystores are test-only.** Production deployments
always pass `--keyStorePath/--keyStorePassword` (and a production truststore), so these
test certs are **not** the production identity and production truststores do not include
them — the mTLS impersonation scenario is therefore **not exploitable**.

The residual issue is the **default-fallback**: `WebServer.addKeyStore` (and the client
`Client`/`SSLFactoryManager` builders) fall back to the bundled keystore + `password`
when no option is supplied:
```java
val keyStorePath = cmd.getOptionValue(KEY_STORE_PATH, DefaultValue.KEYSTORE_FILE.value); // bundled keystore.p12
val keyStorePassword = cmd.getOptionValue(KEY_STORE_PASSWORD, DefaultValue.KEYSTORE_PASSWORD.value); // "password"
```
So a demo/local/misconfigured start silently presents a public, extractable key, and the
files were committed before `.gitignore` added `*.p12`/`*.jks`, so they remain tracked.
- Impact: low in practice (test-only, overridden in prod); a foot-gun and a hygiene issue.
- Fix (recommended): (a) don't auto-default to a bundled key — require an explicit
  `--keyStorePath`/`--keyStorePassword` and fail fast if absent, or default to a
  clearly-marked dev placeholder; (b) optionally purge the tracked `*.p12`/`*.jks`/`*.pem`
  from history and regenerate fresh test material so it's unambiguous they're throwaway.

## 2. HIGH — Weak password hashing (unsalted MD5) for web basic-auth

`WebAuthentication.java` (both `file-server` and `file-client`) stores the admin/basic-auth
realm password as `MD5:<hex>` via `DigestUtils.md5Hex(s)` (no salt, single iteration).
- `realm.properties` (generated at first run) then contains a reversible-lookup MD5 hash.
- An attacker who reads the file (or brute-forces over the network) recovers the password
  trivially.
- Fix: use a salted, slow KDF (BCrypt/SCrypt/Argon2) or a PBKDF2-based Jetty `HashLoginService`.

## 3. HIGH — Jackson 3 (tools.jackson) with high-severity deserialization bypasses

`tools.jackson.core:jackson-databind:3.1.1` is a **compile-scope runtime** dependency
(pulled by swagger-core-jakarta). Two 7.5 (High) deserialization bypasses apply to 3.1.1:

| ID | CVSS | Issue | Fixed in |
|---|---|---|---|
| GHSA-j3rv-43j4-c7qm | 7.5 | PolymorphicTypeValidator bypass via generic type params → arbitrary class instantiation | 3.2.1 |
| GHSA-rmj7-2vxq-3g9f | 7.5 | BasicPolymorphicTypeValidator array-subtype allowlist bypass | 3.2.1 |
| (others in 3.1.x) | 1.8–3.2 | @JsonView / @JsonIgnore / @JsonIgnoreProperties bypasses; InetSocketAddress DNS (SSRF) | 3.2.1 |

Also `com.fasterxml.jackson.core:jackson-databind:2.22.0` (the 2.x line used by the app):
- GHSA-5gvw-p9qm-jgwh 4.6 — @JsonView bypass for @JsonUnwrapped → fix **2.22.1**
- GHSA-5jmj-h7xm-6q6v 1.8 — case-insensitive @JsonIgnoreProperties bypass → fix **2.22.1**

Exposure depends on whether untrusted JSON is deserialized into polymorphic/typed beans;
the JAX-RS/SOAP endpoints do, so treat as reachable.
- Fix: `tools.jackson` 3.1.1 → **3.2.1**, `com.fasterxml` 2.22.0 → **2.22.1**, and enable a
  restrictive `PolymorphicTypeValidator` (deny-by-default) on every `ObjectMapper`.

## 4. MEDIUM — Dependency CVEs (OSV.dev, 134 deps scanned)

| Dependency (ver) | Severity | Issue | Fix |
|---|---|---|---|
| `tools.jackson.core:jackson-core:3.1.1` | High* | GHSA-r7wm-3cxj-wff9 async parser maxNumberLength bypass (DoS) | 3.2.1 |
| `org.postgresql:postgresql:42.7.11` | Medium | GHSA-j92g-9f8w-j867 silent channel-binding auth downgrade | 42.7.12 |
| `org.apache.logging.log4j:log4j-api:2.25.4` | Low | GHSA-qv9r-c865-cp47 MapMessage JSON non-finite float (log injection) | 2.26.1 |

Everything else (Jetty 12.1.10, Spring 7.0.8, CXF 4.2.2, log4j-core 2.25.4, Guava, SnakeYAML
2.6, Flyway 12.9.0, HikariCP 7.1.0, HSQLDB 2.7.4) is current with **no known CVEs**.
- Fix: bump jackson 3 → 3.2.1, postgres → 42.7.12, log4j-api → 2.26.1. (log4j-core is fine;
  only `log4j-api` has the low advisory.)

## 5. LOW / hardening — Optional client-side trust-all hostname verification (testing)

`SSLFactoryManager.getHostnameVerifier()` returns `verifyHostnames ? default : (h,s)->true`
— a **trust-all** verifier.

**Context (per maintainer): this is a testing convenience, not a code defect.** It is an
*explicit* builder parameter (`verifyHostnames`); the example `Client.main` sets it to
`true`. It exists so local/dev testing against locally-signed test certs can skip hostname
matching. The risk only materializes if a *production* connection is built with
`verifyHostnames=false`.
- Recommendation (low): document it as dev-only; optionally log a prominent warning when the
  trust-all verifier is active so an accidental production use is visible.

## 6. MEDIUM — Client-side SSRF / arbitrary-URL download

`file-client-core.download.Client` / `Url` open an `HttpURLConnection` to whatever URL is
supplied (FindSecBugs `URLCONNECTION_SSRF_FD`, 2 findings). The client can be pointed at
`http://169.254.169.254/` (cloud metadata) or internal services.
- Fix: restrict schemes (HTTPS-only) and add a deny-list / allow-list for host + resolved IP
  (block link-local/loopback/private ranges).

## 7. LOW / hardening — Demo credentials in example docker-compose (testing)

`file-server-docker/examples/demo-pg/.env` contains `*_DB_PASSWORD=file-server` /
`file-client` (and the keystore default above).

**Context (per maintainer): these are demo/test credentials for the local docker-compose
example only.** Not a code defect and not used in real deployments.
- Recommendation (low): keep them clearly labelled as demo values and document that they
  must be replaced (via env vars) for any non-local run.

## 8. LOW / hardening

- **`CRLF_INJECTION_LOGS` (53)** and **`SERVLET_HEADER`/`SERVLET_CONTENT_TYPE`** (FindSecBugs):
  user/file-derived values (filename, path, user agent) are passed into log statements and
  response headers. `VirtualPath` (regex `^[a-zA-Z0-9]+$`) and `Filename` (blocks
  `\ / : * ? " < > |`) largely neutralize them, but log-injection via un-sanitized metadata
  fields is worth confirming; prefer structured logging (MDC/params) over `log.info("x {}", val)`.
- **`XSS_SERVLET`** (`DownloadResponseImpl.write`) and **`INFORMATION_EXPOSURE_THROUGH_AN_ERROR_MESSAGE`**
  (2): response bodies/error pages can reflect data. Ensure `Content-Type` is always set and
  error responses don't echo request data; add `X-Content-Type-Options: nosniff`.
- **`WEAK_MESSAGE_DIGEST_MD5`** for file checksums (`Md5Checksum`, GB `ExternalDataReference`):
  MD5 is non-collision-resistant. This is dictated by the Digikoppeling/GB message spec
  (contextId/checksum), so keep MD5 for protocol conformance but rely on the **SHA-256**
  checksum the upload API already carries (`sha256Checksum`) for integrity; never use the MD5
  for security decisions.
- **`PATH_TRAVERSAL_IN` (11)**: largely defense-in-depth notes — `VirtualPath` and
  `NewFSFileFromFsImpl.validateFilename` (`Path.startsWith` component check) are sound.
  Keep them; the remaining hits are on config/keystore path inputs which are operator-supplied.
- **`JAXRS_ENDPOINT` (27)**: informational (endpoints exposed). Ensure all of `/*` sit behind
  the auth filter and TLS; the SOAP + tus endpoints are broad attack surface — confirm no
  endpoint is reachable without the cert/basic-auth constraint.

## 9. What looks good

- **AuthZ model**: mTLS client-certificate filter + `ClientCertificateAuthenticationFilter`
  (trust-store membership check) and an optional basic-auth constraint on `/*`. Cert-based
  primary auth is appropriate for this domain.
- **Input validation**: `VirtualPath`/`Filename`/`ContentType` are validated value objects —
  path traversal and most header-injection are blocked at the boundary.
- **Integrity**: upload API enforces SHA-256 checksums; downloads are resumable/tus-based.
- **Dependency hygiene**: no stale/critical transitive CVEs besides the Jackson 3 line;
  current major versions across Jetty/Spring/CXF/log4j.

## Recommended remediation order (production-relevant first)

1. Replace MD5 basic-auth hashing with a salted KDF.
2. Bump `tools.jackson` 3.1.1 → 3.2.1 and `com.fasterxml` 2.22.0 → 2.22.1; add a
   deny-by-default `PolymorphicTypeValidator`.
3. Bump postgres → 42.7.12, log4j-api → 2.26.1.
4. Add URL scheme/host/IP allow-listing to the client downloader (SSRF).

*Dev/test-only conveniences (low, not production risks — address for hygiene):*
5. Log a warning / document that `verifyHostnames=false` is dev-only.
6. Label the docker demo credentials as demo values to be replaced for any non-local run.
7. Fail fast when no explicit `--keyStorePath`/`--keyStorePassword` is given (instead of
   defaulting to the bundled test key); optionally purge the tracked `*.p12`/`*.jks`/`*.pem`
   from history.

*Note on tooling: OWASP Dependency-Check could not complete (NVD full-DB sync rate-limited,
HTTP 429). The dependency results above come from a direct OSV.dev batch query, which covers
the same advisories. A CI integration of OSV.dev (or `dependency-check` with the NVD API key
and `nvdApiEnabled`) is recommended to make this a standing gate, matching the existing
Checkstyle/PMD/SpotBugs gates.*
