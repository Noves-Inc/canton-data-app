# Database query identifiers and I/O timing

For query identifiers and database I/O latency measurements, configure PostgreSQL 18
with these server settings:

```conf
compute_query_id = on
track_io_timing = on
```

For an externally managed database, ask its administrator to apply these values through
the provider's PostgreSQL configuration mechanism. Apply or reload the configuration as
required by that platform, then check a new connection using the application's database
role. Role, database, connection, and session overrides can change the effective values.
These are PostgreSQL settings, not Data App environment variables.

```sql
SHOW compute_query_id;
SHOW track_io_timing;
SELECT query_id IS NOT NULL AND query_id <> 0 AS has_query_id
FROM pg_stat_activity
WHERE pid = pg_backend_pid();
```

The expected results are `on`, `on`, and `true`. PostgreSQL computes query identifiers
itself; this does not require the `pg_stat_statements` extension. Enabling these settings
does not collect execution plans. Query identifiers are diagnostic correlation values,
not durable identifiers to compare across PostgreSQL upgrades.

I/O timing adds operating-system clock calls. Its overhead depends on the host and
workload. Run `pg_test_timing` on the database host and compare representative bounded
workloads with timing disabled and enabled before approving it on latency-sensitive
installations. A local cached-read experiment does not establish production overhead.
See PostgreSQL's [statistics settings](https://www.postgresql.org/docs/18/runtime-config-statistics.html)
and [pg_test_timing](https://www.postgresql.org/docs/18/pgtesttiming.html).

## Bundled database image rollout

Do not assume an existing release's database image enables these settings: verify the
running instance with the SQL above. For the bundled database, these defaults must arrive
through a tested database image in a coordinated Data App release. A custom container
command can override the image's defaults, so verify the effective settings after any
command override or upgrade.

The release must promote the smoke-tested candidate digest to a new immutable version,
then update the chart's database image and both Compose image pins together with the
release manifest. Keep the released tag and digest paired. Reusing an older semantic tag,
substituting `latest`, or inserting an unpublished digest does not deliver a verified
upgrade. This documentation change does not change any released image pin.
