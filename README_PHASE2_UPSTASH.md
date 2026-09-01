# Phase 2 — Verified Hardware Mode (Upstash Redis)

Supabase has been removed from Phase 2.

## Architecture

Student Browser → Vercel FastAPI → Upstash Redis hardware queue
                                      ↑
                               MATLAB Gateway
                                      ↓
                           AFG-2225 → BNC → GDS-1102B

The MATLAB gateway continues to call the SAME Vercel endpoints. It does not
need Upstash credentials and does not connect directly to Redis.

## Why Redis is used here

Phase 2 needs a short-lived job queue and gateway heartbeat, not a relational
student-record database. Redis is therefore a smaller dependency for this stage.

Keys used by the application:

- `dt:hardware:pending` — FIFO list of pending job IDs
- `dt:hardware:job:<id>` — job/result JSON, 24-hour TTL
- `dt:hardware:gateway:<gateway_id>` — heartbeat JSON, 90-second TTL
- `dt:hardware:last_gateway` — latest gateway ID, 90-second TTL

Virtual Lab routes do not depend on Redis. If Upstash is unavailable, Virtual
Mode continues to work; Verified Hardware mode reports the queue as unavailable.

## Vercel environment variables

Preferred:

- `UPSTASH_REDIS_REST_URL`
- `UPSTASH_REDIS_REST_TOKEN`
- `GATEWAY_SHARED_KEY`

The backend also accepts Vercel integration aliases:

- `KV_REST_API_URL`
- `KV_REST_API_TOKEN`

Do not put Redis tokens in browser JavaScript or MATLAB.
