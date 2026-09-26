# Application verification

- Date (UTC): 2026-09-26 11:30
- Commit: `51f45a0`
- Image: `ghcr.io/rayenmabrouk/epiconnect:0b3cd06`

## PASS - 3 nodes Ready
```
NAME          STATUS   ROLES           AGE    VERSION        INTERNAL-IP     EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION              CONTAINER-RUNTIME            POOL
k3s-server    Ready    control-plane   115m   v1.36.4+k3s1   192.168.50.10   <none>        Ubuntu 24.04.5 LTS   6.8.0-139-generic (amd64)   containerd://2.3.4-k3s1.36   data
k3s-worker1   Ready    <none>          114m   v1.36.4+k3s1   192.168.50.11   <none>        Ubuntu 24.04.5 LTS   6.8.0-139-generic (amd64)   containerd://2.3.4-k3s1.36   app
k3s-worker2   Ready    <none>          113m   v1.36.4+k3s1   192.168.50.12   <none>        Ubuntu 24.04.5 LTS   6.8.0-139-generic (amd64)   containerd://2.3.4-k3s1.36   app
```

## PASS - PostgreSQL ready on k3s-server with its own volume
```
NAME         READY   STATUS    RESTARTS   AGE   IP          NODE         NOMINATED NODE   READINESS GATES
postgres-0   1/1     Running   0          15m   10.42.0.9   k3s-server   <none>           <none>
NAME              STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
data-postgres-0   Bound    pvc-217c3776-0db2-4787-8a73-9b7109e4be59   2Gi        RWO            local-path     <unset>                 15m
```

## PASS - Migrations applied (Job succeeded, none pending)
```
NAME                 STATUS     COMPLETIONS   DURATION   AGE
epiconnect-migrate   Complete   1/1           40s        14m
unapplied migrations: 0
```

## PASS - 3 web replicas ready, spread over both workers, none on the control plane
```
NAME         READY   UP-TO-DATE   AVAILABLE   AGE
epiconnect   3/3     3            3           13m
epiconnect-568b447bf8-5fglx k3s-worker1
epiconnect-568b447bf8-cmjgm k3s-worker2
epiconnect-568b447bf8-fkfmh k3s-worker2
ready replicas: 3, spread over 2 node(s)
```

## PASS - Probes: every web pod Ready, no restarts
```
POD                           READY   RESTARTS   LIVENESS    READINESS
epiconnect-568b447bf8-5fglx   true    0          /healthz/   /readyz/
epiconnect-568b447bf8-cmjgm   true    0          /healthz/   /readyz/
epiconnect-568b447bf8-fkfmh   true    0          /healthz/   /readyz/
Unhealthy probe events in the last hour: 1
```

## PASS - Database reachable from the app (/readyz/ through the Ingress)
```
GET https://epiconnect.lab/readyz/ -> {"status": "ok", "database": "ok"}
```

## PASS - HTTPS 200 through the Ingress on every node IP
```
https://epiconnect.lab/ via node 192.168.50.10: HTTP 200
https://epiconnect.lab/ via node 192.168.50.11: HTTP 200
https://epiconnect.lab/ via node 192.168.50.12: HTTP 200
```

## PASS - HTTP redirects to HTTPS
```
HTTP/1.1 301 Moved Permanently
Location: https://epiconnect.lab/
```

## PASS - Requests are load-balanced across replicas
```
epiconnect-568b447bf8-5fglx (k3s-worker1): 22 of 30 requests
epiconnect-568b447bf8-cmjgm (k3s-worker2): 20 of 30 requests
epiconnect-568b447bf8-fkfmh (k3s-worker2): 18 of 30 requests
```

## PASS - Uploads volume shared across nodes (ReadWriteMany)
```
write on epiconnect-568b447bf8-5fglx (k3s-worker1), read on epiconnect-568b447bf8-fkfmh (k3s-worker2)
-rw-r--r-- 1 10001 10001 11 Sep 26 11:30 /app/media/rwx-check-1790422244
content read back: 1790422244
```

## PASS - NetworkPolicy: only labelled database clients reach PostgreSQL
```
pod WITHOUT db-client label -> postgres:5432: dns=ok BLOCKED attempts=8 
pod WITH    db-client label -> postgres:5432: dns=ok REACHABLE attempt=2 
```

## PASS - Security: non-root, read-only root filesystem, restricted Pod Security
```
web container UID: 10001
write to the image filesystem: touch: cannot touch '/app/probe': Read-only file system
namespace Pod Security enforce level: restricted
```

---
**12 passed, 0 failed**
