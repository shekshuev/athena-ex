# MinIO behind HTTPS nginx

Athena uses two endpoints: the server uses the internal endpoint for deletion,
copying and storage checks; the browser uses the public endpoint for signed PUT
and GET requests. When nginx terminates TLS, MinIO itself can keep using HTTP.

All bucket prefixes must remain private. Follow [private storage deployment](private-storage.md)
to audit existing links, back up/remove old policies and verify signed access.

## Environment

For the test deployment at `10.0.109.60`, where Athena and MinIO are reachable
from the host via `localhost`, use these values (keep existing credentials):

```dotenv
MINIO_HOST=localhost
MINIO_PORT=9000
MINIO_SCHEME=http://
MINIO_PUBLIC_HOST=10.0.109.60
MINIO_PUBLIC_PORT=443
MINIO_PUBLIC_SCHEME=https://
MINIO_PORT_EXTERNAL=9000
MINIO_BUCKET=athena
```

`MINIO_PUBLIC_PORT` is the browser-facing nginx port. `MINIO_PORT_EXTERNAL`
remains the Docker host port mapped to MinIO's port 9000. Do not map MinIO to
443 when nginx already listens there. In a container network, use the MinIO
service name instead of `localhost` for `MINIO_HOST`.

If `MINIO_PUBLIC_SCHEME` is absent, Athena preserves the previous behavior and
uses `MINIO_SCHEME` for signing. If `MINIO_PUBLIC_PORT` is absent, it falls back
to `MINIO_PORT_EXTERNAL`. Set both public variables explicitly for TLS termination.

Rebuild/deploy the updated release and restart Athena after changing its environment.
Recreate the MinIO container only if its Docker port mapping changed; preserve its
existing data volume.

## nginx

With `MINIO_BUCKET=athena`, every browser S3 request stays under `/athena/`,
including `/athena/courses/...`, `/athena/library/...`, `/athena/personal/...`,
`/athena/avatars/...` and `/athena/submissions/...`. These are object-key prefixes
inside one bucket, so no separate nginx locations are needed for them.
An application link such as `/media/submissions/...` first goes to Phoenix for
authorization, then redirects to a signed `/athena/submissions/...` URL.
Keep the MinIO administrative API and console on their internal endpoints;
the public nginx location only needs to serve this bucket's signed object requests.

Inside the existing HTTPS `server` block, replace `location /athena/` with:

```nginx
# /athena is the actual S3 bucket name, retained in the upstream URI.
location ^~ /athena/ {
    client_max_body_size 2g;
    client_body_timeout 3600s;

    proxy_pass http://127.0.0.1:9000;
    proxy_http_version 1.1;
    proxy_set_header Host $http_host;
    proxy_set_header Connection "";
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_request_buffering off;
    proxy_buffering off;
    proxy_connect_timeout 60s;
    proxy_send_timeout 3600s;
    proxy_read_timeout 3600s;
}
```

The global `client_max_body_size 50M` can stay: this location overrides it for
S3 transfers. `2g` matches Athena's 2 GiB (2,147,483,648 bytes) limit.
`proxy_request_buffering off` streams uploads directly to MinIO without first
spooling the entire file to nginx's temporary directory. The timeouts cover
inactivity between reads/writes, not a total transfer duration.

Keep `proxy_pass` without a trailing slash: `/athena/` is a bucket path, not an
extra S3 API prefix. Preserve `Host` for signature verification. `^~` prevents
the existing global `.wasm` regex location from intercepting stored objects.
If the bucket name changes, update the location to match.

Also add the following to the existing Phoenix `location /` so an otherwise
idle LiveView WebSocket is not closed after nginx's default read timeout:

```nginx
proxy_read_timeout 3600s;
proxy_send_timeout 3600s;
```

Validate and reload on the deployment host:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

## Verification

1. Upload and save a small `.7z` from a browser that sends an empty MIME type.
   It must remain available after reloading the page.
2. Upload a 1.5 GiB file to course attachments, an assignment, or personal files.
   Personal storage still requires a sufficient role quota (default 100 MiB).
   A file larger than 2 GiB must be rejected before upload.
3. Download and delete a test file. Deletion uses the internal HTTP endpoint.
4. Inspect the browser Network tab and nginx error log if a transfer fails:
   `413` indicates a body limit; `SignatureDoesNotMatch` indicates the host or
   URI changed; TLS errors to `localhost:9000` indicate an incorrect internal scheme.

General uploads (attachments, assignments and personal files) share one extension
list and a 2 GiB maximum per file. Video blocks also allow 2 GiB, restricted to
video formats. Images retain 25 MiB and avatars 5 MiB; question imports retain
5,000,000 bytes and their parser-supported `.txt`, `.gift`, `.xml` formats.

References: [nginx proxy module](https://nginx.org/en/docs/http/ngx_http_proxy_module.html),
[nginx body size limit](https://nginx.org/en/docs/http/ngx_http_core_module.html#client_max_body_size),
[MinIO nginx example](https://github.com/minio/minio/blob/master/docs/orchestration/docker-compose/nginx.conf).
