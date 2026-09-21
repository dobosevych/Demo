# meetings

A monorepo holding one backend service, one frontend app, and the compose file that runs
them together. This document describes the **structure** of the repository: what each folder
is for, and the contracts between the parts. It contains no implementation code.

A new developer installs Docker Desktop and runs:

```
docker compose up
```

That is the only command. It builds all three images, starts Postgres, applies migrations,
starts the API, and starts the Vite dev server.

---

## Top level

```
meetings/
├── .github/workflows/
├── backend/
├── frontend/
├── infra/
├── docker-compose.yml
├── Makefile
├── .env.example
├── .gitignore
└── PROJECT.md
```

| Path                 | What it is for                                                                 |
| -------------------- | ------------------------------------------------------------------------------ |
| `.github/workflows/` | CI: linting on every push, backend deployment on demand.                         |
| `backend/`           | The FastAPI service. Owns the database schema and the HTTP API.                  |
| `frontend/`          | The React + Vite single-page app. Owns everything the user sees.                 |
| `infra/`             | CloudFormation templates. One file per deployable stack.                         |
| `docker-compose.yml` | The entry point for running locally. Three services and how they wait on each other.|
| `Makefile`           | The entry point for deploying. Reads credentials from `.env`.                    |
| `.env.example`       | The shape of `.env`. Copy it; `.env` itself is never committed.                  |
| `.gitignore`         | Keeps `.env`, `node_modules/` and build output out of the repository.            |
| `PROJECT.md`         | This file.                                                                      |

Nothing else lives at the root. The two applications do not import from each other; their
only contract is the HTTP API described under *Contracts* below.

---

## `backend/`

Python service. Pinned versions:

| Thing      | Version | Installed as         |
| ---------- | ------- | -------------------- |
| Python     | 3.12    | base image           |
| FastAPI    | 0.115.6 | `fastapi`            |
| Uvicorn    | 0.34.0  | `uvicorn[standard]`  |
| SQLAlchemy | 2.0.36  | `sqlalchemy`         |
| Alembic    | 1.14.0  | `alembic`            |
| psycopg    | 3.2.3   | `psycopg[binary]`    |
| Pydantic   | 2.10.4  | `pydantic`           |

Every pin is exact (`==`), and these seven are the whole dependency list. Email addresses are
validated by a regex in `app/schemas/`, so `email-validator` is not needed; settings are read
from `os.environ` in `app/config.py`, so `pydantic-settings` is not either.

```
backend/
├── app/
│   ├── main.py         # FastAPI application object; mounts the router, sets CORS
│   ├── api/            # HTTP layer: routers, request handlers
│   ├── models/         # SQLAlchemy ORM classes — the shape of the tables
│   ├── schemas/        # Pydantic models — the shape of the JSON on the wire
│   ├── db.py           # Engine, session factory, session dependency
│   └── config.py       # Settings read from environment variables
├── alembic/
│   ├── versions/       # One file per migration, ordered by revision chain
│   ├── env.py          # Wires Alembic to the ORM metadata and DATABASE_URL
│   └── script.py.mako  # Template new migrations are generated from
├── alembic.ini         # Alembic configuration
├── pyproject.toml      # Dependency pins
├── .dockerignore       # Keeps __pycache__ and .venv out of the build context
└── Dockerfile          # Builds the backend image
```

**What each folder is for**

- `app/api/` — the only place that knows about HTTP. Routers declare paths, status codes,
  and which schema goes in and out. Handlers take a database session as a dependency.
- `app/models/` — the only place that knows about tables and columns. These classes are the
  single source of truth for the schema; Alembic reads their metadata to generate migrations.
- `app/schemas/` — the boundary between the API and the ORM. Requests are parsed into these
  before a handler sees them; responses are serialized from these. A model never leaves the
  service directly.
- `app/db.py` — creates the engine from `DATABASE_URL` and hands out a per-request session.
- `app/config.py` — reads environment variables once, so nothing else calls `os.environ`.
- `alembic/versions/` — the migration history. The schema in the running database is whatever
  this chain produces; nothing creates tables at startup.

**Contract with the database.** The backend expects to reach Postgres at `DATABASE_URL`. It
owns that database exclusively — no other service reads or writes it.

**Contract with Alembic.** Migrations are the only way the schema changes. The backend
container runs `alembic upgrade head` before starting Uvicorn, so the API never serves traffic
against an out-of-date schema.

---

## `frontend/`

Browser app. Pinned versions:

| Thing        | Version | Why it is here                                                   |
| ------------ | ------- | ---------------------------------------------------------------- |
| Node         | 22      | Base image                                                       |
| React        | 19.0.0  | `react` and `react-dom`                                          |
| Vite         | 6.0.7   | Dev server and build                                             |
| TypeScript   | 5.7.2   | Typecheck; `npm run build` runs `tsc -b` before `vite build`     |
| Tailwind CSS | 4.0.0   | `tailwindcss` plus the `@tailwindcss/vite` plugin                |
| shadcn/ui    | CLI 2.1.8 | Components are copied into the repo, not a dependency          |

The shadcn/ui components are vendored source, but they import a small runtime the repo must
still install:

| Package                     | Version  | Used by                                     |
| --------------------------- | -------- | ------------------------------------------- |
| `clsx`                      | 2.1.1    | `cn()` in `src/lib/utils.ts`                |
| `tailwind-merge`            | 2.6.0    | `cn()` in `src/lib/utils.ts`                |
| `class-variance-authority`  | 0.7.1    | Variants on `button` and `badge`            |
| `lucide-react`              | 0.469.0  | Icons, the library `components.json` names  |
| `@radix-ui/react-slot`      | 1.1.1    | `button`'s `asChild`                        |
| `@radix-ui/react-label`     | 2.1.1    | `label`                                     |

Build-time only: `@vitejs/plugin-react` 4.3.4, `@tailwindcss/vite` 4.0.0, `@types/react`
19.0.2, `@types/react-dom` 19.0.2, and `@types/node` 22.10.5 — the last of which types the
`node:url` import in `vite.config.ts`.

**One `overrides` block is load-bearing.** `@tailwindcss/vite` 4.0.0 depends on
`@tailwindcss/node` by range, which resolves a second, newer `tailwindcss` alongside the pinned
one; the mismatched native scanner then fails `vite build` with `Cannot convert undefined or
null to object`. `package.json` therefore pins `tailwindcss`, `@tailwindcss/node` and
`@tailwindcss/oxide` to 4.0.0 under `overrides`. The dev server works without it; the
production build does not. Do not drop it when bumping Tailwind — replace it.

```
frontend/
├── src/
│   ├── main.tsx        # Mounts React onto the page
│   ├── App.tsx         # The single page: the list and the form
│   ├── components/
│   │   └── ui/         # shadcn/ui components, vendored into the repo
│   ├── lib/            # API client and shared helpers
│   └── index.css       # Tailwind entry point
├── index.html          # Vite's HTML entry
├── dist/               # Build output. Created by `make frontend-build`, not committed
├── vite.config.ts      # Dev server host/port, path aliases, Tailwind plugin
├── components.json     # shadcn/ui configuration: where components are written
├── tsconfig.json       # TypeScript configuration and the `@/` alias
├── package.json        # Dependency pins, and the Tailwind `overrides` block
├── .dockerignore       # Keeps node_modules and dist out of the build context
└── Dockerfile          # Three stages: base, build (static bundle), dev (the server)
```

**What each folder is for**

- `src/components/ui/` — shadcn/ui primitives. These are *copied source*, owned by this repo
  and editable; they are not installed from npm and are not upgraded automatically.
- `src/lib/` — the API client. The only place that knows the backend's URL and its response
  shapes. Components call it; they never call `fetch` themselves. It also decides, from whether
  `VITE_API_URL` was set at build time, if this build has a backend at all.
- `src/App.tsx` — the one page in this slice: a list of meetings and a form that creates one.
- `src/index.css` — imports Tailwind. There is no other global stylesheet.

**Contract with the backend.** The frontend reads the API base URL from the build-time
environment variable `VITE_API_URL` and talks to it over HTTP only, using the endpoints below.
It shares no types, no code, and no database access with the backend.

---

## Contracts

### The `Meeting` resource

A meeting carries the fields a calendar invitation normally has: what it is called, what it
is about, when it runs, and who is invited.

| Field          | Type                     | Required on create | Notes                                        |
| -------------- | ------------------------ | ------------------ | -------------------------------------------- |
| `id`           | UUID (version 4)         | no — server sets it | Primary key. Unique. Assigned by the backend |
| `title`        | string, 1–200 chars      | yes                | The line shown in a calendar slot            |
| `description`  | string, 0–2000 chars     | no — defaults `""` | Free text: agenda, notes, dial-in details    |
| `starts_at`    | timestamp, ISO 8601, UTC | yes                |                                              |
| `ends_at`      | timestamp, ISO 8601, UTC | yes                | Must be strictly after `starts_at`           |
| `participants` | array of `Participant`   | no — defaults `[]` | The invitee list. Order is not meaningful    |

`id` is the table's **primary key** and carries a **unique** constraint, so no two meetings
ever share one. It is stored in Postgres as a native `uuid` column, generated by the backend
when the meeting is created, and never changes afterwards. On the wire it is the canonical
lowercase hyphenated string form, for example `3f1a8c9e-7b2d-4e51-9c3a-1d6f0b5e2a47`.

`participants` is not a column on `meetings`. It is the join described below, serialized into
the response.

### The `Participant` resource

A participant is a person, not an invitation. One row per human, shared by every meeting they
attend — inviting the same address to a second meeting reuses the existing row rather than
copying the name and address again.

| Field          | Type                        | Required on create | Notes                                        |
| -------------- | --------------------------- | ------------------ | -------------------------------------------- |
| `id`           | UUID (version 4)            | no — server sets it | Primary key. Unique                          |
| `email`        | string, valid email address | yes                | **Globally unique** across all participants  |
| `display_name` | string, 0–200 chars         | no — defaults `""` | Shown instead of the address when present    |

`email` carries a **unique** constraint on the table and is stored lowercased, so
`Ada@Example.com` and `ada@example.com` are the same participant. It is the natural key: the
API looks a person up by address, and `id` is what the join stores.

### The `meeting_participants` join

Meetings and participants are **many-to-many**: a meeting has many participants, a participant
attends many meetings. The link is its own table and holds nothing else.

| Column           | Type | Notes                                                    |
| ---------------- | ---- | -------------------------------------------------------- |
| `meeting_id`     | UUID | Foreign key → `meetings.id`, `ON DELETE CASCADE`         |
| `participant_id` | UUID | Foreign key → `participants.id`, `ON DELETE CASCADE`     |

The **composite primary key** is (`meeting_id`, `participant_id`), which makes a duplicate
invitation impossible and gives the index used to list a meeting's people. A second index on
(`participant_id`, `meeting_id`) serves the other direction — every meeting one person is in —
without a table scan. There is no surrogate `id` on this table and no payload column, so a link
costs two UUIDs and nothing else.

Deleting a meeting removes its links and leaves the participants alone; deleting a participant
removes their links and leaves the meetings alone. Rows in `participants` are never deleted as
a side effect of un-inviting someone.

The same field names are used in the tables, in the JSON, and in the frontend. There is no
renaming at any boundary.

### HTTP API

Base path `/api`. Every request and response body is JSON, encoded UTF-8. All timestamps go
over the wire as ISO 8601 with an explicit `Z`, for example `2026-03-04T09:30:00Z`; the
backend rejects a timestamp without a timezone.

#### Endpoints

| Method   | Path                                    | Body                | Success                         |
| -------- | --------------------------------------- | ------------------- | ------------------------------- |
| `GET`    | `/api/meetings`                         | —                   | `200` + array of meetings       |
| `POST`   | `/api/meetings`                         | `MeetingCreate`     | `201` + the created meeting     |
| `GET`    | `/api/meetings/{id}`                    | —                   | `200` + one meeting             |
| `PATCH`  | `/api/meetings/{id}`                    | `MeetingUpdate`     | `200` + the updated meeting     |
| `DELETE` | `/api/meetings/{id}`                    | —                   | `204`, empty body               |
| `PUT`    | `/api/meetings/{id}/participants/{pid}` | —                   | `204` — invite, idempotent      |
| `DELETE` | `/api/meetings/{id}/participants/{pid}` | —                   | `204` — un-invite, idempotent   |
| `GET`    | `/api/participants`                     | —                   | `200` + array of participants   |
| `POST`   | `/api/participants`                     | `ParticipantCreate` | `201` + the created participant |
| `GET`    | `/api/participants/{pid}`               | —                   | `200` + one participant         |
| `PATCH`  | `/api/participants/{pid}`               | `ParticipantUpdate` | `200` + the updated participant |
| `DELETE` | `/api/participants/{pid}`               | —                   | `204`, empty body               |

`{id}` and `{pid}` are UUIDs. A path segment that is not a valid UUID is a `422`, not a `404`.

The two `/api/meetings/{id}/participants/{pid}` verbs write one join row and nothing else. Both
are idempotent: inviting someone already invited, or removing someone who is not, still answers
`204`. They never create or delete a participant.

#### `GET /api/meetings`

Query parameters, all optional:

| Parameter        | Type                     | Default | Meaning                                       |
| ---------------- | ------------------------ | ------- | --------------------------------------------- |
| `from`           | timestamp, ISO 8601, UTC | —       | Only meetings with `ends_at` at or after this |
| `to`             | timestamp, ISO 8601, UTC | —       | Only meetings with `starts_at` before this    |
| `participant_id` | UUID                     | —       | Only meetings this participant attends        |
| `limit`          | integer, 1–200           | `50`    | Page size                                     |
| `offset`         | integer, ≥ 0             | `0`     | Rows skipped                                  |

Results are ordered by `starts_at` ascending, then `id` ascending, so paging is stable. Each
meeting in the array carries its full `participants` list, loaded for the whole page in one
query across the join — never one query per meeting.

`GET /api/participants` takes `email` (exact match), `limit` and `offset`, and orders by
`email` ascending.

#### Request bodies

`MeetingCreate` — every meeting field except `id`. `participants` is a list of **email
addresses**, not objects: the backend looks each one up and creates the participant only if
that address is new, then writes the join rows, all in one transaction.

```json
{
  "title": "Sprint planning",
  "description": "Groom the backlog, size the top ten items.",
  "starts_at": "2026-03-04T09:30:00Z",
  "ends_at": "2026-03-04T10:30:00Z",
  "participants": ["ada@example.com", "alan@example.com"]
}
```

`MeetingUpdate` — the same fields, all optional; only the keys present are changed. Sending
`participants` **replaces the whole invitee list**: addresses not yet on the meeting are
linked, links to addresses absent from the array are deleted. The participant rows themselves
are untouched either way. Omit the key to leave the list alone.

`ParticipantCreate` — `email` and optional `display_name`. `ParticipantUpdate` — `display_name`
only; `email` is immutable, because it is the key the rest of the API resolves people by.

#### Responses

A meeting response embeds its participants in full:

```json
{
  "id": "3f1a8c9e-7b2d-4e51-9c3a-1d6f0b5e2a47",
  "title": "Sprint planning",
  "description": "Groom the backlog, size the top ten items.",
  "starts_at": "2026-03-04T09:30:00Z",
  "ends_at": "2026-03-04T10:30:00Z",
  "participants": [
    {
      "id": "b1d3c7a0-5e64-4f19-8a2b-0c9e7d4f6132",
      "email": "ada@example.com",
      "display_name": "Ada Lovelace"
    },
    {
      "id": "c8e2f501-9a7b-4c3d-b6e1-2f4a8d0b5c93",
      "email": "alan@example.com",
      "display_name": "Alan Turing"
    }
  ]
}
```

A participant response is the three fields on their own, with no meeting list attached; use
`GET /api/meetings?participant_id=…` for that.

#### Errors

| Status | When                                                                            |
| ------ | ------------------------------------------------------------------------------- |
| `404`  | No meeting or participant with that UUID                                         |
| `409`  | `POST /api/participants` with an `email` that already exists                      |
| `422`  | The body or a path/query parameter fails validation — including `ends_at` not after `starts_at`, a naive timestamp, a malformed UUID, or a bad email |

Every error body has the same shape, so the frontend parses one thing:

```json
{ "detail": "ends_at must be after starts_at" }
```

`422` from FastAPI's own validation keeps FastAPI's list form under the same `detail` key.

These endpoints are the entire surface between the two applications.

### Environment variables

| Variable       | Read by  | Meaning                                     |
| -------------- | -------- | ------------------------------------------- |
| `DATABASE_URL` | backend  | Postgres connection string                  |
| `VITE_API_URL` | frontend | Base URL of the backend, used by `src/lib/` |

Both are set in `docker-compose.yml`. The backend has no default for `DATABASE_URL` and refuses
to start without it.

`VITE_API_URL` is read at **build time**, not at run time, and it is allowed to be empty. An
empty value builds a frontend that renders normally and reports that it has no backend, instead
of failing to boot — that is what makes the static deployment below possible. `src/lib/api.ts`
exports `apiConfigured` for this, and the UI disables its one writing control when it is false.

The deployment variables in `.env` are listed under *Deployment*.

---

## Deployment

`docker compose up` runs the whole system locally. The `Makefile` deploys the two applications
to AWS as two independent stacks:

| Stack                      | Template              | What it runs                                  |
| -------------------------- | --------------------- | --------------------------------------------- |
| `<PROJECT_NAME>-frontend`  | `infra/frontend.yaml` | S3 bucket + CloudFront distribution            |
| `<PROJECT_NAME>-backend`   | `infra/backend.yaml`  | Lambda + Aurora Serverless v2 PostgreSQL in a private VPC |

They are deliberately independent. The frontend can be deployed before the backend exists: with
no backend the site loads, renders and explains that it has no backend, instead of failing to
boot. Once the backend is deployed, `make frontend-deploy` routes `/api/*` on the frontend's
CloudFront distribution to it and builds the bundle with `VITE_API_URL=/`, so the browser calls
the API same-origin over HTTPS. `make deploy` does both, in that order.

### Credentials

Everything the deployment needs comes from `.env` at the root, which the `Makefile` includes and
exports. Copy `.env.example` to `.env` and fill it in. `.env` is in `.gitignore` and must never
be committed.

Either style of line works — `FOO=bar` or `export FOO='bar'`. The `Makefile` normalises the file
into `.env.make` before including it, stripping any `export` prefix and surrounding quotes,
because make itself does neither and would otherwise read `export FOO='bar'` as the value
`'bar'`, quotes included.

| Variable                | Required | Meaning                                                    |
| ----------------------- | -------- | ---------------------------------------------------------- |
| `AWS_ACCESS_KEY_ID`     | yes      | Checked by `make aws-check` before anything is created      |
| `AWS_SECRET_ACCESS_KEY` | yes      |                                                            |
| `AWS_SESSION_TOKEN`     | no       | Only for temporary STS or SSO credentials                   |
| `AWS_REGION`            | no       | Defaults to `us-east-1`. Where the bucket and stack live    |
| `PROJECT_NAME`          | no       | Defaults to `meetings`. Prefixes every resource name        |
| `VITE_API_URL`          | no       | Leave empty: same-origin `/api` once the backend exists     |

### `infra/frontend.yaml`

One CloudFormation stack, named `<PROJECT_NAME>-frontend`:

- **S3 bucket** `<project>-frontend-<account>-<region>` — private, encrypted, all public access
  blocked. It is never a website endpoint and is never readable from the internet.
- **Origin Access Control** — the only identity allowed to read the bucket.
- **CloudFront distribution** — HTTPS only (`redirect-to-https`), compressed, `index.html` as
  the default root object. A small CloudFront Function serves `/index.html` for any path without
  a file extension, because those belong to the single-page app, not to S3. (Custom error
  responses would do the same but also rewrite the API's own `404`s into HTML.)
- **`/api/*` behavior** — only when the backend is deployed (`ApiOriginDomain` parameter, taken
  from the backend stack by `make infra-deploy`). Forwards to the Lambda function URL uncached,
  with a 60-second origin timeout to cover a cold start that also wakes the database.
- **Bucket policy** — grants `s3:GetObject` to the CloudFront service principal, conditioned on
  this distribution's ARN. No other distribution, and no anonymous request, can read it.

The bucket deliberately does **not** carry `DeletionPolicy: Retain`. It holds only the built
bundle, which `make frontend-build` regenerates from source, so retaining it protects nothing —
while a retained bucket surviving a failed create orphans a name that collides with the next
attempt. `make frontend-destroy CONFIRM=yes` removes the stack and bucket together.

### Targets

| Target                       | What it does                                                    |
| ---------------------------- | --------------------------------------------------------------- |
| `make help`                  | Lists these, with the resolved variables                         |
| `make aws-check`             | Fails early if `.env`, the keys, or the CLI are missing; prints the caller identity |
| `make frontend-build`        | Builds the bundle in Docker and copies it to `frontend/dist`      |
| `make infra-deploy`          | Creates or updates the stack                                      |
| `make frontend-sync`         | Uploads `frontend/dist` to the bucket                             |
| `make frontend-invalidate`   | Invalidates the CloudFront cache                                  |
| `make frontend-deploy`       | All of the above, in order, then prints the URL                   |
| `make frontend-url`          | Prints the deployed URL                                           |
| `make frontend-status`       | Prints the stack's current status                                 |
| `make explain-failure`       | Prints why the last stack operation failed, and what to do        |
| `make purge-failed-stack`    | Clears a stack stuck in `ROLLBACK_COMPLETE`. Refuses any other state |
| `make frontend-events`       | Prints recent stack events, newest first — read this when a deploy fails |
| `make env-export`            | Prints the shell line that loads `.env` into your own terminal     |
| `make frontend-destroy`      | Empties the bucket and deletes the stack. Needs `CONFIRM=yes`     |
| `make clean`                 | Removes `frontend/dist`                                           |

### `infra/backend.yaml`

One CloudFormation stack, named `<PROJECT_NAME>-backend`, built to cost almost nothing while
nobody is using it:

- **Lambda function** running the same backend image compose runs. The
  [Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter), copied into the image
  as an extension, turns each invocation into an HTTP request to Uvicorn, so the app has no
  Lambda-specific code. Outside Lambda the extension never starts. Each cold start runs
  `alembic upgrade head` before Uvicorn, exactly as under compose.
- **Function URL** — the function's own HTTPS endpoint. The frontend reaches it through
  CloudFront at `/api`, not directly.
- **Aurora Serverless v2 PostgreSQL** — minimum capacity **0 ACU**, so it pauses after
  5 minutes idle and bills only storage while paused. The first request after a pause waits
  about 15 seconds while it resumes. The function sets `DB_KEEP_CONNECTIONS=false`, which makes
  the app open a connection per request instead of pooling: a pooled connection held by a
  frozen function would keep the database from ever pausing.
- **A VPC with two private subnets** and no internet gateway, NAT gateway or public IP. The
  function reaches the database inside the VPC and needs nothing else from the network.
- **Two security groups**: the database accepts connections only from the function.

The image is built for `linux/amd64` with `--provenance=false`: `make backend-push` may run on
Apple Silicon, and Lambda rejects the image index buildx produces when it attaches provenance.
The stack takes the image by digest, not `:latest`, so a new push is a change the stack sees.

HTTPS comes from CloudFront's default certificate, so no domain or ACM certificate is needed.

### Backend targets

| Target                     | What it does                                                     |
| -------------------------- | ---------------------------------------------------------------- |
| `make deploy`              | `backend-deploy`, then `frontend-deploy` wired to it              |
| `make backend-push`        | Builds the image, creates the ECR repository if needed, pushes it |
| `make backend-deploy`      | Pushes, deploys the stack, prints the function URL                |
| `make backend-url`         | Prints the function URL                                           |
| `make backend-status`      | Shows the function's state and whether the database is paused     |
| `make backend-redeploy`    | Pushes a new image and points the function at it                  |
| `make backend-logs`        | Tails the function's logs from CloudWatch                         |
| `make backend-destroy`     | Deletes the API, the database and the VPC. Needs `CONFIRM=yes`    |
| `make github-oidc`         | Creates the role GitHub Actions assumes. Run once                 |

### What this costs

Nothing in the stack bills by the hour while idle. Rough monthly figures for light use:

| Resource                        | Cost                                                        |
| ------------------------------- | ----------------------------------------------------------- |
| Aurora storage (a few MB–1 GB)  | **~$0.10** per GB-month, plus I/O and backups at cents      |
| Aurora compute                  | **$0** while paused; ~$0.12 per ACU-hour only while in use  |
| Lambda                          | **$0** at this scale — the free tier covers 1M requests/month |
| CloudFront, S3, ECR, logs       | Cents                                                        |

So well under **$1/month** when the app sits unused, against about $40 for the previous
load balancer + Fargate + RDS setup. The trade-off is the first request after a quiet spell,
which takes about 20 seconds while the function cold-starts and the database resumes.

Every resource carries the tag `Project=<PROJECT_NAME>`: the stacks are deployed with it and
CloudFormation copies it onto what they create, RDS copies it onto its snapshots, and
`make backend-push` tags the ECR repository it creates outside CloudFormation. Activate
`Project` under *Billing → Cost allocation tags* to see this app's spend on its own in Cost
Explorer.

`make frontend-build` needs no Node on the host. It builds the `build` stage of
`frontend/Dockerfile` and copies `/srv/dist` out of the image, which is why that Dockerfile has
three stages and why `dev` is last — `docker compose` builds the final stage by default and must
keep getting the dev server.

**Caching.** Hashed assets are uploaded `immutable` for a year; `index.html` is uploaded
`no-cache`, so a redeploy is visible as soon as the invalidation completes.

**A create that fails cannot be retried in place.** CloudFormation leaves a failed first create
in `ROLLBACK_COMPLETE`, which it will not update. `make infra-deploy` detects that state and
clears the stack before deploying, so a retry is just the same command again. On any failure it
runs `make explain-failure`, which prints the reasons CloudFormation recorded rather than the
CLI's "run this command to see the events".

**CloudFront needs an enabled account.** A new AWS account cannot create distributions until AWS
verifies it — `CREATE_FAILED … Your account must be verified before you can add new CloudFront
resources`. No template change works around it; it takes a support case, and until it clears
every deploy fails the same way.

**Running `aws` yourself.** `.env` reaches the CLI only through `make`, which exports it to the
commands it runs. A bare `aws` command in your own shell inherits nothing and fails with
`NoRegion`. Either pass `--region` explicitly, or load the file into your shell first:

```
set -a; source .env; set +a
```

---

## Continuous integration

Two workflows in `.github/workflows/`.

### `lint.yml`

Runs on every push to `main`, on every pull request, and on demand. Three independent jobs, so
one failure does not hide the others:

| Job        | What it checks                                                                  |
| ---------- | ------------------------------------------------------------------------------- |
| `backend`  | `ruff check` and `ruff format --check` over `backend/`                           |
| `frontend` | `tsc -b` then `npm run build` — a type error and a broken bundle both fail it     |
| `infra`    | `cfn-lint` over `infra/*.yaml`                                                   |

Ruff is configured in `backend/pyproject.toml`: line length 100, and the `E F I UP B SIM C4`
rule sets. `B008` is disabled because FastAPI's dependency injection is function calls in
argument defaults, which that rule would flag on every handler.

`cfn-lint` runs with `--ignore-checks W1011`, which asks for a Secrets Manager dynamic reference
instead of a `NoEcho` parameter for the database password. That is the better pattern. This
project passes the password from `.env` deliberately, so the rule is silenced knowingly rather
than left to fail.

The frontend job runs `npm install`, not `npm ci`, because no lockfile is committed.

### `deploy-backend.yml`

Manual only — `workflow_dispatch`, and it refuses to run unless you type `deploy` into the
confirmation box. Deploying bills money and changes a live system, so it does not happen as a
side effect of a push. A `concurrency` group keeps two runs from touching the stack at once.

It runs `make backend-deploy`, the same target used locally, so there is one deployment path
rather than two that drift, then makes one request to the API — which cold-starts the function,
wakes the database and applies any pending migrations. On failure it runs `make explain-failure`, printing the reason
CloudFormation recorded instead of leaving a bare red cross.

**Configuration.** No credentials are stored in GitHub. The workflow authenticates by OIDC:
GitHub mints a short-lived token for the run, AWS exchanges it for temporary credentials, and
they expire when the job ends. There is no access key to leak, rotate, or forget about.

| Kind     | Name                         | Required | Notes                                    |
| -------- | ---------------------------- | -------- | ---------------------------------------- |
| Variable | `AWS_ROLE_ARN`               | yes      | The role to assume. `make github-oidc` prints it |
| Variable | `AWS_REGION`, `PROJECT_NAME` | yes      |                                          |
| Variable | `CORS_ORIGINS`               | no       | Same meaning as in `.env`                |
| Secret   | `DB_PASSWORD`                | yes      | The only secret the workflow needs       |

The workflow fails immediately, with an explanation, if `AWS_ROLE_ARN` is unset — rather than
falling back to anything or failing later with an opaque AWS error.

### `infra/github-oidc.yaml`

Creates what OIDC needs, in one stack named `<PROJECT_NAME>-github-oidc`:

- **An IAM OIDC provider** for `token.actions.githubusercontent.com`. An account can hold only
  one per issuer, so `make github-oidc` checks whether it already exists and passes
  `CreateOidcProvider=no` if so. That makes the target safe to run in an account that already
  deploys something else from GitHub.
- **A role**, `<PROJECT_NAME>-github-deploy`, whose trust policy carries two conditions. The
  `aud` must be `sts.amazonaws.com`, and the `sub` must match `repo:<owner>/<name>:*`. The
  second is the line that matters: without it, *any* GitHub repository in the world could assume
  the role. Narrow `GitHubRef` from `*` to `ref:refs/heads/main` once the workflow is proven.

The attached policy is scoped where AWS allows it: CloudFormation only on stacks named
`<PROJECT_NAME>-*`, ECR only on repositories named `<PROJECT_NAME>-*`, and IAM only on roles
named `<PROJECT_NAME>-*` — which is what CloudFormation generates for this project's stacks.
The networking and managed services (`lambda`, `rds`, `ec2`, `logs`, `s3`, `cloudfront`) are granted on `*`, because their create calls name resources that do not
exist yet and cannot be scoped by ARN in advance. This is a deploy role; treat it as privileged.

Run it once:

```
make github-oidc GITHUB_REPO=owner/name
```

It prints the role ARN to paste into the `AWS_ROLE_ARN` repository variable. Set it as a
*variable*, not a secret: it is an identifier, not a credential, and variables are visible in
logs, which makes failures easier to read.

`make aws-check` works in both places: locally it reads `.env`, and in CI it uses whatever
credentials the environment already holds, so the same targets run either way.

---

## `docker-compose.yml`

Three services.

### `postgres`

- **Image:** `postgres:16.6-alpine`
- **Port:** listens on **5432** inside the compose network; published to the host on 5432 so a
  developer can attach a client.
- **Depends on:** nothing.
- **Readiness:** its own healthcheck runs `pg_isready` against the configured database. The
  service is not considered healthy until that command succeeds.
- **State:** a named volume holds the data directory, so data survives `docker compose down`.

### `backend`

- **Built from:** `backend/Dockerfile`
- **Port:** listens on **8000** inside the compose network; published to the host on 8000.
- **Depends on:** `postgres`, with `condition: service_healthy`. Compose will not start the
  backend container until the Postgres healthcheck passes, so the migration step never races
  the database's first boot.
- **Startup order inside the container:** `alembic upgrade head`, then Uvicorn.
- **Readiness:** its own healthcheck requests `GET /api/meetings` on port 8000. That succeeds
  only after migrations have applied and the API is serving, which is exactly the condition the
  frontend needs.
- **Environment:** `DATABASE_URL` points at the `postgres` service by its compose hostname.

### `frontend`

- **Built from:** `frontend/Dockerfile`
- **Port:** listens on **5173** (the Vite dev server) inside the compose network; published to
  the host on 5173. This is the URL the developer opens.
- **Depends on:** `backend`, with `condition: service_healthy`. The page therefore never loads
  against an API that is not yet answering.
- **Readiness:** nothing depends on the frontend, so it declares no healthcheck.
- **Environment:** `VITE_API_URL` points at the backend on the host port, because the request
  is made by the developer's browser, not by the container.

### Dependency summary

```
frontend ──depends on (healthy)──▶ backend ──depends on (healthy)──▶ postgres
  :5173                             :8000                             :5432
```

Each arrow is a compose `depends_on` with `condition: service_healthy`, and each waited-on
service proves its own readiness with a healthcheck: `pg_isready` for Postgres, a successful
`GET /api/meetings` for the backend.