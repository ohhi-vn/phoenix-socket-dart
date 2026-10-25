# phoenix_socket

[![ci-test](https://github.com/braverhealth/phoenix-socket-dart/actions/workflows/test.yaml/badge.svg)](https://github.com/braverhealth/phoenix-socket-dart/actions/workflows/test.yaml)
[![pub-package](https://img.shields.io/pub/v/phoenix_socket.svg)](https://pub.dev/packages/phoenix_socket)
![Pub Points](https://img.shields.io/pub/points/phoenix_socket?color=blue&label=pub%20points)

Dart library to interact with [Phoenix][1] [Channels][2] ([Presence][3] support is currently _experimental_) over WebSockets.

This library uses [web_socket_channel][4] for WebSockets, making the API consistent across web and native
environments.

## Getting Started

Look at the [example project][5] for an example on how to use this library. The API was designed to
look like javascript's as much as possible, but leveraging Dart's unique native advantages like Streams
and Futures.

## Running the tests

```bash
dart test                      # unit tests, no services required
tool/coverage.sh               # same suite with per-file line coverage for lib/
tool/integration_test.sh       # starts Toxiproxy + the example backend, runs everything
dart run tool/benchmark_codec.dart
```

`tool/coverage.sh` is advisory: it prints coverage and writes `coverage/lcov.info`,
but CI does not enforce a threshold.

The harness needs Docker (compose plugin), `docker-compose`, or podman compose.
It fails fast with a remediation hint when the runtime or a port is unavailable,
and integration tests skip with an actionable reason when it is not running.

[1]: https://www.phoenixframework.org/
[2]: https://hexdocs.pm/phoenix/Phoenix.Channel.html#content
[3]: https://hexdocs.pm/phoenix/Phoenix.Presence.html#content
[4]: https://pub.dev/packages/web_socket_channel
[5]: https://github.com/matehat/phoenix-socket-dart/tree/master/example
