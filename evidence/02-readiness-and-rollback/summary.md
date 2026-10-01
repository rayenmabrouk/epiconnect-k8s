# Demo 2 - Readiness failure and recovery, bad release and rollback

- Date (UTC): 2026-10-01 13:47
- Image: `ghcr.io/rayenmabrouk/epiconnect:b38f31a`
- Probes: readiness `/readyz/` (runs `SELECT 1`) every 5 s, 2 failures; liveness `/healthz/` (no database)

## A. PostgreSQL outage

| Phase | Requests (HTTP code x count) |
|---|---|
| before (database up) | 200 x21   |
| database stopping, pods leaving the Service | 200 x1  500 x43   |
| outage (no Ready pod) | 500 x3  503 x134   |
| database restarting, pods rejoining | 200 x12  503 x40   |
| after | 200 x21   |

- Ready web pods during the outage: **0** (all removed from the Service: Traefik answers 503 immediately)
- Web container restarts: 3 before, **3 after** (liveness does not depend on the database)
- Recovered without intervention on the web tier: yes

```
14:43:17.048 web 3/3 ready, restarts 3, on k3s-worker1:2 k3s-worker2:1 | postgres-0 ready
14:43:25.951 web 3/3 ready, restarts 3, on k3s-worker1:2 k3s-worker2:1 | postgres-0 not ready/absent
14:43:32.322 web 2/3 ready, restarts 3, on k3s-worker1:2 k3s-worker2:1 | postgres-0 not ready/absent
14:43:34.071 web 0/3 ready, restarts 3, on k3s-worker1:2 k3s-worker2:1 | postgres-0 not ready/absent
14:44:14.463 web 0/3 ready, restarts 3, on k3s-worker1:2 k3s-worker2:1 | postgres-0 ready
14:44:16.338 web 1/3 ready, restarts 3, on k3s-worker1:2 k3s-worker2:1 | postgres-0 ready
14:44:18.202 web 3/3 ready, restarts 3, on k3s-worker1:2 k3s-worker2:1 | postgres-0 ready
```

**Part A: PASS**

## B. Bad release (DB_HOST=postgres-typo), then rollback

- `helm upgrade` exit code: 1 (failed after its 2 min timeout: new pods never became Ready)
- Ready web pods while the bad release was stuck: 3 (the old pods, maxUnavailable 0)
- Requests during the whole part: 579, not 200: **0**
- After `helm rollback`: DB_HOST=`postgres`, image `epiconnect:b38f31a`

```
14:44:41.044 web 3/3 ready, restarts 3, on k3s-worker1:2 k3s-worker2:1 | postgres-0 ready
14:44:50.147 web 3/4 ready, restarts 3, on k3s-worker1:2 k3s-worker2:2 | postgres-0 ready
14:47:01.862 web 3/4 ready, restarts 3, on k3s-worker1:2 k3s-worker2:1 | postgres-0 ready
```

Pods while the bad release was stuck:

```
NAME                                 READY   STATUS     RESTARTS      AGE     IP           NODE          NOMINATED NODE   READINESS GATES
epiconnect-7bb8db57cc-rq4mz          0/1     Init:0/1   0             2m10s   10.42.2.23   k3s-worker2   <none>           <none>
epiconnect-86b58dc64d-6vxss          1/1     Running    1 (17m ago)   4d15h   10.42.2.22   k3s-worker2   <none>           <none>
epiconnect-86b58dc64d-hj64g          1/1     Running    1 (17m ago)   4d15h   10.42.1.30   k3s-worker1   <none>           <none>
epiconnect-86b58dc64d-vdsh2          1/1     Running    1 (17m ago)   4d15h   10.42.1.31   k3s-worker1   <none>           <none>
epiconnect-bootstrap-admin-6-9crk5   0/1     Error      0             53s     10.42.2.27   k3s-worker2   <none>           <none>
epiconnect-bootstrap-admin-6-hwqnp   0/1     Error      0             117s    10.42.2.25   k3s-worker2   <none>           <none>
epiconnect-bootstrap-admin-6-zdmfs   0/1     Error      0             2m10s   10.42.0.25   k3s-server    <none>           <none>
epiconnect-bootstrap-admin-6-zl8xb   0/1     Error      0             95s     10.42.0.27   k3s-server    <none>           <none>
epiconnect-migrate-6-2rl75           0/1     Error      0             2m10s   10.42.2.24   k3s-worker2   <none>           <none>
epiconnect-migrate-6-cmgzd           0/1     Error      0             117s    10.42.0.26   k3s-server    <none>           <none>
epiconnect-migrate-6-qbfsl           0/1     Error      0             95s     10.42.2.26   k3s-worker2   <none>           <none>
epiconnect-migrate-6-wpc8w           0/1     Error      0             53s     10.42.0.28   k3s-server    <none>           <none>
postgres-0                           1/1     Running    0             2m52s   10.42.0.24   k3s-server    <none>           <none>
```

```
REVISION	UPDATED                 	STATUS    	CHART           	APP VERSION	DESCRIPTION                                                                                                                
5       	Sat Sep 26 23:40:43 2026	superseded	epiconnect-0.1.0	0b3cd06    	Upgrade complete                                                                                                           
6       	Thu Oct  1 14:44:47 2026	failed    	epiconnect-0.1.0	0b3cd06    	Upgrade "epiconnect" failed: resource Deployment/epiconnect/epiconnect not ready. status: InProgress, message: Updated: ...
7       	Thu Oct  1 14:47:00 2026	deployed  	epiconnect-0.1.0	0b3cd06    	Rollback to 5                                                                                                              
```

**Part B: PASS**

**Result: PASS**
