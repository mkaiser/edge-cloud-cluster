---
name: loki-query
description: Query cluster logs from Loki — use whenever you need logs from inside the cluster, especially for a deleted pod, a completed Job, or anything that ran before the logging stack came up, and whenever kubectl logs is unavailable or returns nothing. Also use before concluding that Loki is empty or broken.
---

# Querying Loki

`logs/` in the repo is LOCAL command output. Logs from inside the cluster come from Loki:
Alloy tails every node's on-disk kubelet **files** and ships them.

**So `kubectl logs` failing is NOT a reason logs are missing.** A deleted pod, a completed
Job, and anything that ran before the logging stack came up are all still in Loki. That is
the main reason to reach for Loki over `kubectl logs`.

## Connect

Loki is not publicly routed. Port-forward and send the tenant header:

```bash
nohup kubectl -n loki port-forward svc/loki-gateway 3100:80 --address=127.0.0.1 \
  >/tmp/pf-loki.log 2>&1 & disown
sleep 5
H='X-Scope-OrgID: fake'
curl -s -H "$H" http://127.0.0.1:3100/loki/api/v1/labels   # /ready 404s — use this
```

⚠ `curl` printing nothing with `HTTP:000` is a **DEAD PORT-FORWARD** (usually port 3100
already taken), not an empty Loki. Always pass `-w "\nHTTP:%{http_code}\n"` before
concluding anything.

⚠ Never `pkill -f "port-forward..."` — it matches your own agent shell and kills the tool
call.

## The label schema is the trap

Only five stream labels exist:

```
app   cluster   container   namespace   service_name
```

There is deliberately **no `pod` and no `node` label** (cardinality). Consequences:

- `{namespace="x",pod="y"}` → **0 rows, no error.** That is not evidence of missing logs.
- Find a pod by name with a **line filter**: ``{namespace!="loki"} |= `my-pod-abc` ``.
- Query Jobs by `container`, not `app` — most Jobs have no `app` label, and the container
  name is usually NOT the Job name. Read it from the pod spec.
- `detected_level` is **structured metadata**: `| detected_level="error"` works; putting it
  inside `{}` silently returns nothing.

## Two calls cover most needs

Discover the real label sets first, then read:

```bash
curl -s -H "$H" -G http://127.0.0.1:3100/loki/api/v1/series \
  --data-urlencode 'match[]={namespace="argocd-infra"}'

curl -s -H "$H" -G http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="loki",container="ensure-buckets"}' \
  --data-urlencode "start=$(date -u -d '2 hours ago' +%s)000000000" \
  --data-urlencode "end=$(date -u +%s)000000000" \
  --data-urlencode 'direction=forward' --data-urlencode 'limit=100' \
| jq -r '.data.result[] | .stream.container as $c | .values[]
         | "\(.[0]|tonumber/1e9|todate) [\($c)] \(.[1])"'
```

- Timestamps are **nanoseconds**. A seconds-resolution `start` silently returns nothing.
- `direction=forward` gives a Job's START, which is the interesting part.

## When Loki looks empty

Suspect, in this order: **the query**, **the time range**, then Loki itself. Check
per-node shipping via Alloy's metrics (script in `doc/logging-loki.md`) — never with
`sum by (node)`, that label does not exist.

`tests/lokiQueryChecks.sh` exercises the query path end to end (pod readiness, scheduler
ring, a real range query, and logs of an already-GC'd Job pod). It asserts a query and
never `/ready`, because **Loki reports Synced/Healthy with its query path dead.**

## Writing log-based checks

Window by TIME (`--since=5m`), **never** by `--tail=N`, and also assert the positive
recovery signal ("did it connect at least once") so a component that never started is
caught too.

Healthy infra components log almost nothing after startup, so startup errors stay inside
`--tail=N` for hours and the check reports a fault on a working cluster. Measured
2026-09-07: `tests/lokiQueryChecks.sh` reported 33 empty-ring lines from 11:21 as "still
logging" at 13:38 on a fully healthy, freshly recreated cluster.

Use `kubectl logs --since=<window>` for "is it broken NOW", plus a separate full-history
grep for "did it ever work". Verify both the positive and negative case before committing
a check.

## Reference

- `doc/logging-loki.md` — querying, Alloy per-node shipping check.
- `doc/logging.md` — architecture.
