# Demo 3 - Worker node failure and rescheduling

- Date (UTC): 2026-10-01 14:10
- Node powered off (hard, Hyper-V TurnOff): **k3s-worker2** at 15:07:58.432
- Node marked NotReady after: **46 s**
- 3 web pods Ready again on the surviving nodes after: **81 s** (15:09:19.298)

## Client view

One HTTPS request every 0.2 s through Traefik on k3s-server:

- Requests: 215; not 200: **14** (000 x14  200 x201  )
- Failures between 15:08:02.118 and 15:08:46.688: requests routed to pods on the dead node until it was declared NotReady (`000` = no answer within 3 s)
- Last 10 requests: 10 x 200

## Timeline

```
15:07:53.643 k3s-server=Ready  k3s-worker1=Ready  k3s-worker2=Ready  
15:07:53.794 web 3/3 ready, restarts 0, on k3s-worker1:1 k3s-worker2:2 | postgres-0 ready
15:08:43.579 k3s-server=Ready  k3s-worker1=Ready  k3s-worker2=NotReady  
15:09:14.428 web 3/5 ready, restarts 0, on k3s-worker1:3 | postgres-0 ready
15:09:18.779 web 5/5 ready, restarts 0, on k3s-worker1:3 | postgres-0 ready
```

## Pods

Before:

```
NAME                          READY   STATUS    RESTARTS   AGE   IP           NODE          NOMINATED NODE   READINESS GATES
epiconnect-58886b5656-9gx8w   1/1     Running   0          95s   10.42.2.30   k3s-worker2   <none>           <none>
epiconnect-58886b5656-g65h5   1/1     Running   0          89s   10.42.2.31   k3s-worker2   <none>           <none>
epiconnect-58886b5656-ss6hw   1/1     Running   0          84s   10.42.1.33   k3s-worker1   <none>           <none>
```
After rescheduling, k3s-worker2 still down (its pods cannot be confirmed stopped, so they stay Terminating):

```
NAME                          READY   STATUS        RESTARTS   AGE     IP           NODE          NOMINATED NODE   READINESS GATES
epiconnect-58886b5656-9gx8w   1/1     Terminating   0          3m13s   10.42.2.30   k3s-worker2   <none>           <none>
epiconnect-58886b5656-g65h5   1/1     Terminating   0          3m7s    10.42.2.31   k3s-worker2   <none>           <none>
epiconnect-58886b5656-ss6hw   1/1     Running       0          3m2s    10.42.1.33   k3s-worker1   <none>           <none>
epiconnect-58886b5656-w9rt9   1/1     Running       0          17s     10.42.1.35   k3s-worker1   <none>           <none>
epiconnect-58886b5656-wgsbv   1/1     Running       0          17s     10.42.1.34   k3s-worker1   <none>           <none>
```
After k3s-worker2 came back (Kubernetes does not move running pods back: no automatic rebalancing):

```
NAME                          READY   STATUS    RESTARTS   AGE     IP           NODE          NOMINATED NODE   READINESS GATES
epiconnect-58886b5656-ss6hw   1/1     Running   0          3m30s   10.42.1.33   k3s-worker1   <none>           <none>
epiconnect-58886b5656-w9rt9   1/1     Running   0          45s     10.42.1.35   k3s-worker1   <none>           <none>
epiconnect-58886b5656-wgsbv   1/1     Running   0          45s     10.42.1.34   k3s-worker1   <none>           <none>
```

Single-replica platform pods at the start (k3s defaults; a node hosting them was not chosen):

```
traefik-59b7647586-6vwqs   1/1   Running   2 (38m ago)   5d4h   10.42.1.29   k3s-worker1   <none>   <none>
coredns-54996dc9b4-cbmnq   1/1   Running   2 (2d ago)   5d4h   10.42.0.19   k3s-server   <none>   <none>
```

**Result: PASS** - the web tier recovered on the surviving worker without intervention.
