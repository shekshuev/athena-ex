# Go compiler cache helper

This standard-library-only command implements the SDK's official `GOCACHEPROG`
protocol (`cmd/go/internal/cacheprog`). It avoids the disk cache's close/Trim
file locks without changing Go or isolate's seccomp policy.

Build in the Go toolchain image:

```sh
go build -o /usr/local/bin/athena-go-cache docker/execution/go-cache/main.go
```

The compiler wrapper should set an absolute, sandbox-writable `GOCACHE` and
`GOCACHEPROG=/usr/local/bin/athena-go-cache` before invoking `go build`.
No Go module or third-party dependency is required. To test this directory:

```sh
GO111MODULE=off go test ./docker/execution/go-cache
```

Each helper process creates a private directory beneath `$GOCACHE/athena-cache`
and maintains only its own in-memory action index. Artifacts remain available
after the close response; sandbox cleanup removes them. This intentionally does
not reuse entries between builds and needs no locks or network access. Standard
output contains only protocol responses; fatal diagnostics go to standard error.

Artifact bodies are streamed from their separate base64 JSON values to files,
not buffered in memory. Limits are 16 KiB per request header, 512 MiB per artifact,
768 MiB of cumulative put bodies, and 65,536 indexed actions. Invalid or excessive
put requests produce a correlated error and terminate, avoiding protocol
resynchronization after malformed bodies.
