# Demo 1 - Rolling update without downtime

- Date (UTC): 2026-09-26 22:41
- Version A: `ghcr.io/rayenmabrouk/epiconnect:0b3cd06`
- Version B: `ghcr.io/rayenmabrouk/epiconnect:b38f31a` (built, scanned and smoke-tested by CI)
- Strategy: RollingUpdate, maxSurge 1, maxUnavailable 0; readiness on `/readyz/`; preStop sleep 5 s
- Upgrade (`make deploy-helm ARGS="--set image.tag=b38f31a"`, incl. migration Job): 27 s

## Client view

One HTTPS request every 0.2 s through Traefik, from 5 s before the upgrade until 5 s after the last old pod had terminated:

- Requests: 227
- HTTP 200: 227
- Failed or non-200: 0

## Pods, as they changed

```
23:40:35.445 0b3cd06: 3 pods, 3 ready   
23:40:45.598 b38f31a: 1 pods, 0 ready   0b3cd06: 3 pods, 3 ready   
23:40:52.699 b38f31a: 2 pods, 1 ready   0b3cd06: 3 pods, 3 ready   
23:41:01.062 b38f31a: 2 pods, 2 ready   0b3cd06: 3 pods, 3 ready   
23:41:02.465 b38f31a: 3 pods, 2 ready   0b3cd06: 3 pods, 3 ready   
23:41:07.038 b38f31a: 3 pods, 3 ready   0b3cd06: 3 pods, 3 ready   
23:41:08.881 b38f31a: 3 pods, 3 ready   0b3cd06: 3 pods, 2 ready   
23:41:17.943 b38f31a: 3 pods, 3 ready   0b3cd06: 3 pods, 1 ready   
23:41:19.284 b38f31a: 3 pods, 3 ready   0b3cd06: 2 pods, 1 ready   
23:41:22.075 b38f31a: 3 pods, 3 ready   0b3cd06: 2 pods, 0 ready   
23:41:26.317 b38f31a: 3 pods, 3 ready   0b3cd06: 1 pods, 0 ready   
23:41:33.423 b38f31a: 3 pods, 3 ready   
```

## After

```
      3 ghcr.io/rayenmabrouk/epiconnect:b38f31a
Ready: 3/3
REVISION	UPDATED                 	STATUS    	CHART           	APP VERSION	DESCRIPTION     
3       	Sat Sep 26 23:36:24 2026	superseded	epiconnect-0.1.0	0b3cd06    	Upgrade complete
4       	Sat Sep 26 23:39:38 2026	superseded	epiconnect-0.1.0	0b3cd06    	Upgrade complete
5       	Sat Sep 26 23:40:43 2026	deployed  	epiconnect-0.1.0	0b3cd06    	Upgrade complete
```

(APP VERSION in the history is the chart's default appVersion; the image actually deployed is the image.tag value: helm -n epiconnect get values epiconnect)

**Result: PASS** - every web pod runs b38f31a, and none of the 227 requests failed during the update.
