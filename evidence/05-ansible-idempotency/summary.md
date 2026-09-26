# Demo 5 - Ansible idempotency

- Date (UTC): 2026-09-26 09:38
- Commit: `4d9110d`
- Started from the fresh checkpoint: yes

## Run 1 (254 s)
```
k3s-server                 : ok=53   changed=32   unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   
k3s-worker1                : ok=41   changed=26   unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   
k3s-worker2                : ok=41   changed=26   unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   
```
## Run 2 (53 s)
```
k3s-server                 : ok=49   changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   
k3s-worker1                : ok=38   changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   
k3s-worker2                : ok=38   changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   
```

**Result: PASS** - the second run changed nothing on any node.
