# local-test-harness Specification

## Purpose

Defines how contributors provision the Toxiproxy proxy and Phoenix backend required by the integration suite, how failures in that provisioning surface, and how the suite behaves when those services are absent.

## Requirements

### Requirement: One command provisions and runs integration dependencies

The repository SHALL provide a documented command that starts the Toxiproxy proxy and the example Phoenix backend, waits until both are ready, runs the integration suite, tears the services down, and exits with the suite's result.

#### Scenario: Services start and suite runs

- **WHEN** a contributor runs the documented harness command with no services running
- **THEN** Toxiproxy and the Phoenix backend are started, readiness is confirmed before the suite runs, and the command exits with the test result

#### Scenario: Services are torn down

- **WHEN** the harness command finishes, whether tests pass or fail
- **THEN** the services it started are stopped

#### Scenario: Test failure propagates

- **WHEN** an integration test fails
- **THEN** the command exits non-zero

### Requirement: Harness failures are actionable and never silent

If a required runtime, image, or port is unavailable, or a service exits during startup, the harness SHALL exit non-zero and print which service failed together with a remediation hint. It MUST NOT report success when the dependencies were never ready.

#### Scenario: Container runtime missing

- **WHEN** no container runtime is available
- **THEN** the command exits non-zero and names the missing runtime with setup guidance

#### Scenario: Port already in use

- **WHEN** a required port is already bound
- **THEN** the command exits non-zero and reports the conflicting port

#### Scenario: Backend crashes during startup

- **WHEN** the Phoenix backend exits before becoming ready
- **THEN** the command exits non-zero and surfaces the backend exit reason

### Requirement: Suites degrade safely without the harness

Unit tests SHALL always run without external services. When the harness services are unavailable, integration tests MUST be skipped with an explicit reason that names the missing dependency and points at the harness command, rather than failing or passing silently.

#### Scenario: No services running

- **WHEN** the test suite runs on a machine without Toxiproxy or the backend
- **THEN** unit tests run normally and integration tests are reported as skipped with an actionable reason

#### Scenario: Partial availability

- **WHEN** Toxiproxy is reachable but the backend is not
- **THEN** only the integration tests that require the backend are skipped and the reason identifies the backend

### Requirement: Harness artifacts stay out of the published package

Harness scripts, compose files, and fixtures SHALL NOT become runtime dependencies and SHALL NOT be required for building or using the library. Any added dependency MUST be development-only.

#### Scenario: Package consumers unaffected

- **WHEN** the package is consumed by an application
- **THEN** no harness file is imported and no harness-only dependency is resolved at runtime

#### Scenario: Analyzer scope

- **WHEN** static analysis runs for the library and unit tests
- **THEN** the analysis passes without requiring the harness services
