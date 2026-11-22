# Private object storage

Athena never needs anonymous bucket access. New uploads use signed PUT URLs;
saved content stores stable `/media/<key>` URLs; downloads check resource access
in Athena and redirect to signed GET URLs valid for 15 minutes. Server-side
copy, delete and storage inspection use authenticated S3 requests.

`MINIO_PUBLIC_HOST` means the browser-facing endpoint, not a public bucket.
The personal-file “public” flag still means visible to authenticated Athena
accounts; it does not enable anonymous S3 access.

For `MINIO_BUCKET=athena`, all object requests use the existing nginx
`location /athena/`. The new answer key `submissions/<account_id>/<course_id>/...`
produces `/athena/submissions/<account_id>/<course_id>/...`; it does not require
a `/submissions/` nginx location or another bucket. `/media/...` URLs belong to
Phoenix and redirect to these signed bucket URLs after authorization.

## Deploy the application first

Before deploying, extend the application's existing scoped IAM policy to allow
`s3:GetObject`, `s3:PutObject` and `s3:DeleteObject` on
`arn:aws:s3:::<bucket>/submissions/*`. This is the new answer namespace; keep the
existing course/library/avatar/personal permissions. Do not grant policy-admin
permissions to the application. If custom S3 CORS rules are in use, ensure the
Athena origin may send PUT requests with the `Content-Type` header.

Deploy the updated server and compiled/digested JavaScript together. All browser
uploaders now send the Content-Type selected and signed by the server. Old open
tabs may need reloading. Keep the existing volume and object keys.

Replace the production compose file too: the old `minio-init` ran
`mc anonymous set public` on the whole bucket and would reopen it on rerun.
The updated init uses the internal `minio:9000` service endpoint, creates the
bucket with `--ignore-existing`, applies `anonymous set none` and propagates errors.
During this rollout, restart only the web service (for example,
`docker compose -f docker-compose.prod.yml up -d --no-deps athena_web`). Do not
recreate/run `minio-init` until the backed-up hardening command below has finished;
otherwise init would remove the old policy before it can be backed up.

Course and library files follow current resource permissions. Student course
media also follows visibility, schedule and progression gates. New answer uploads
use `submissions/<account_id>/<course_id>/`; old unregistered answer files remain
available through their stored submissions. Graders use their existing grading
scope. Exam question images are authorized through the server-generated paper.
An old unregistered answer file referenced by unrelated account scopes is denied
instead of treating a pasted link as a new access grant. Review and re-upload
such ambiguous files under the correct owner; a shared team counts as one scope.

Raster images, audio and video render inline. Documents, source files and SVG
download with `application/octet-stream` and `Content-Disposition: attachment`.
HTML uploads are rejected; previously stored HTML is also forced to download.
SVG remains available as a file attachment, not an inline image. Prefer raster
formats for inline illustrations. Do not proxy untrusted object bytes around
these response overrides.

## Audit existing saved links

Against the running web release (no changes to data):

```bash
docker exec athena_web /app/bin/web rpc 'IO.inspect(Athena.Release.audit_storage_links(), limit: :infinity)'
```

The result lists IDs and counts for course blocks, library templates, submissions
and profile avatars containing direct URLs to the configured internal/browser
storage hosts and buckets. Signed URLs themselves are never printed. Empty lists
mean no such legacy links were found. Third-party URLs are outside this audit.
Resolve any reported direct links to stable `/media/<key>` references in their
owning resource before closing the bucket; the audit does not rewrite data.

## Inspect and close existing buckets

This operation removes bucket policies entirely, including any old public prefix.
Keep the application's scoped service-account IAM policy separate. The operator
needs S3 bucket inspection and policy read/delete permissions; the application
service account should not receive these administrative permissions.

Use `eval` with storage-admin credentials for this one process. This does not
change the credentials or configuration of the running web node. The container
already supplies the remaining release environment. On the host, enter the admin
access key and secret without putting them into command history:

```bash
read -r MINIO_ACCESS_KEY
read -rs MINIO_SECRET_KEY
export MINIO_ACCESS_KEY MINIO_SECRET_KEY

# Dry-run: inspect configured buckets, do not change policies.
docker exec -e MINIO_ACCESS_KEY -e MINIO_SECRET_KEY athena_web /app/bin/web eval 'IO.inspect(Athena.Release.harden_storage())'

# Apply: save every old policy before modifying any bucket, then remove policies
# and verify that they are absent. An error causes a non-zero exit.
docker exec -e MINIO_ACCESS_KEY -e MINIO_SECRET_KEY athena_web /app/bin/web eval 'IO.inspect(Athena.Release.harden_storage(apply: true, backup_dir: "/tmp/athena-storage-policy-backups"))'

docker cp athena_web:/tmp/athena-storage-policy-backups ./athena-storage-policy-backups
unset MINIO_ACCESS_KEY MINIO_SECRET_KEY
```

Backups are JSON files with the bucket name and original policy (null if absent),
mode `0600`, under a fresh run subdirectory. Copy them off the container before
recreating it. Repeating apply creates another backup and leaves buckets private.
It does not move or delete objects. If necessary, pass `buckets: ["actual-name"]`
to select explicitly; otherwise the configured bucket list or `MINIO_BUCKET` is
used. This is not a database migration and is never run automatically at boot.

For a checkout with Mix, the equivalent administrative commands are:

```bash
mix athena.storage.harden
mix athena.storage.harden --apply --backup-dir /secure/athena-storage-policy-backups
```

`mix athena.storage.setup` creates missing configured buckets and enforces the
same private state. Failures stop the task instead of merely logging success.

## Verify using the application identity

After applying, run this against the running node, using the real bucket name:

```bash
docker exec athena_web /app/bin/web rpc 'IO.inspect(Athena.Release.verify_storage("athena"))'
```

The check creates a unique temporary object via signed PUT, reads it via signed
GET, requires anonymous GET/list/PUT/DELETE to return 403, and removes only its
own object through the authenticated S3 API. Success returns `:ok`; any unexpected
response raises. It uses the configured browser endpoint, so it also checks nginx
and the application's actual service credentials. Run it for every selected
bucket. The Mix task also supports `--verify`.

Finally check avatars, character images, course/library images, video playback
(including seeking), personal files/shares, new and existing assignment answers,
and both exam types from a real student session. A logged-in account without
resource access must get 403 through `/media`; a raw object URL without a signature
must also get 403. Policy removal does not revoke previously issued signed URLs;
existing signatures expire after at most 15 minutes. Review storage logs and the
integrity of previously exposed course/exam material separately.
