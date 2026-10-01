# Demo 4 - Database persistence across pod loss

- Date (UTC): 2026-10-01 14:14
- Row written before: `written 2026-10-01T14:13:55Z nonce 236d49a9d796`
- Row read back from the new pod: `written 2026-10-01T14:13:55Z nonce 236d49a9d796`
- Application users (users_user table): 1 before, 1 after

| | Before | After |
|---|---|---|
| Pod | pod uid bf3f43b7-e386-437a-a475-e07e7ad9c3b9, node k3s-server, started 2026-10-01T14:12:14Z | pod uid 088ea66f-e3ae-4a32-87be-110213f75483, node k3s-server, started 2026-10-01T14:14:04Z |
| Storage | claim data-postgres-0 -> volume pvc-217c3776-0db2-4787-8a73-9b7109e4be59, path /var/lib/rancher/k3s/storage/pvc-217c3776-0db2-4787-8a73-9b7109e4be59_epiconnect_data-postgres-0, reclaim policy Delete | claim data-postgres-0 -> volume pvc-217c3776-0db2-4787-8a73-9b7109e4be59, path /var/lib/rancher/k3s/storage/pvc-217c3776-0db2-4787-8a73-9b7109e4be59_epiconnect_data-postgres-0, reclaim policy Delete |

- New postgres-0 Ready after: **8 s**; all web pods Ready again after: 12 s
- Requests during the test: 200 x50  500 x35  503 x13  
  (one database instance, so requests fail while it restarts: the web pods report not ready and leave the Service, then return by themselves, as in demo 2. High availability would need a replicated database, e.g. a PostgreSQL operator or a managed service.)

```
15:13:56.483 web 3/3 ready, restarts 0, on k3s-worker1:3 | postgres-0 ready
15:14:04.911 web 3/3 ready, restarts 0, on k3s-worker1:3 | postgres-0 not ready/absent
15:14:11.422 web 0/3 ready, restarts 0, on k3s-worker1:3 | postgres-0 ready
15:14:15.975 web 3/3 ready, restarts 0, on k3s-worker1:3 | postgres-0 ready
```

**Result: PASS** - new pod, same volume, data intact.
