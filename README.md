# DevOps Task Manager — Docker + Kubernetes + GitHub Actions

A task-management app (Node.js + Express + MongoDB, with a web UI and REST API) used to demonstrate:

- **Experiment 5** – Docker (Dockerfile, image, container, Docker Compose)
- **Experiment 7** – Kubernetes (Deployment, Service, ConfigMap, Secret, PVC, replicas, self-healing)
- **Experiment 8** – GitHub Actions CI/CD (test → Docker build → deploy to a temporary Kubernetes cluster → publish image)

This guide is written for a **Windows 10/11 PC**.

---

## 1. What you need to install (Windows)

| # | Software | Needed for | Download / install |
|---|---|---|---|
| 1 | **Git** | Cloning / pushing code | https://git-scm.com/download/win |
| 2 | **Node.js 20 LTS or newer** (includes npm) | Running the app and tests | https://nodejs.org (choose **LTS**) |
| 3 | **Docker Desktop** | Docker, Docker Compose, MongoDB container | https://www.docker.com/products/docker-desktop/ |
| 4 | **kubectl** | Kubernetes commands | `winget install Kubernetes.kubectl` (Docker Desktop also bundles it) |
| 5 | **Minikube** | Local Kubernetes cluster | `winget install Kubernetes.minikube` |
| 6 | A **GitHub account** | GitHub Actions (Option D only) | https://github.com |

Notes:
- Docker Desktop needs **WSL 2** (the installer will offer to enable it) and **virtualization enabled in BIOS**. Restart the PC if the installer asks.
- You do **not** need to install MongoDB on Windows; it runs inside Docker.
- Open a **new** PowerShell window after installing, so the commands are found.

Verify everything (PowerShell):

```powershell
git --version
node --version        # must be v20.6.0 or higher
npm --version
docker --version
docker compose version
kubectl version --client
minikube version
```

Make sure **Docker Desktop is running** (whale icon in the system tray) before using any `docker` command.

---

## 2. Get the project

```powershell
cd $HOME\Desktop
# if you have the zip: right-click -> Extract All, then
cd DevOps-Task-Manager-main
```

All commands below are run from this project folder.

---

## 3. Choose how to run it

### Option A — Easiest: Docker Compose (API + MongoDB in containers)

```powershell
docker compose up --build
```

(or double-click **`run-docker.bat`**)

Open **http://localhost:5000** — you get the web UI. Stop with `Ctrl+C`, then:

```powershell
docker compose down        # stop (the database volume is kept)
docker compose down -v     # DANGER: also deletes the database data
```

MongoDB is **not** published on your PC any more: the API talks to it over Docker's internal network
(`mongodb://mongo:27017/devops_tasks`), so a MongoDB already running on port 27017 can no longer clash.
The API's host port is configurable: `API_HOST_PORT=5001 docker compose up --build` (or put it in `.env`).

### Option B — Run the API directly with Node.js (MongoDB in Docker)

```powershell
copy .env.example .env
npm install
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d mongo
npm run start:local
```

The `docker-compose.dev.yml` override publishes MongoDB on `127.0.0.1:27017` only. If 27017 is busy, use
`MONGO_HOST_PORT=27018` and set the same port in `MONGO_URI` inside `.env`.

(or double-click **`run-local.bat`**, which does all of this)

Open **http://localhost:5000**. For auto-restart while editing code use `npm run dev`.
Stop MongoDB afterwards with `docker compose down`.

### Option C — Kubernetes with Minikube

1. Start Docker Desktop, then in PowerShell:

```powershell
minikube start --driver=docker
kubectl get nodes                      # STATUS should be Ready
```

2. Build the image **inside Minikube** (so Kubernetes can find it without a registry):

```powershell
minikube docker-env --shell powershell | Invoke-Expression
docker build -t devops-task-manager:1.0 .
```

> This `docker-env` setting only lasts for the current PowerShell window. Use the same window for the next steps (or rerun the command in a new one).

3. Deploy everything. The MongoDB password is **not** stored in the repository; create the Secret once (never re-create it later, MongoDB only reads the password when its volume is first created):

```powershell
kubectl apply -f k8s/namespace.yaml
kubectl create secret generic task-manager-secret -n devops-task-manager --from-literal=MONGO_USERNAME=admin --from-literal=MONGO_PASSWORD=ChooseLettersAndDigits123
kubectl apply -f k8s/
kubectl get pods -n devops-task-manager
kubectl rollout status deployment/task-manager-api -n devops-task-manager
```

4. Open the app (keep this window open — it tunnels the port):

```powershell
minikube service task-manager-api -n devops-task-manager
```

Everything above (including the random Secret) is automated by **`deploy-k8s.bat`**.

Cleanup:

```powershell
kubectl delete namespace devops-task-manager
minikube stop
```

### Option D — GitHub Actions

```powershell
git init
git add .
git commit -m "Initial DevOps Task Manager project"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/devops-task-manager.git
git push -u origin main
```

Then open your repository → **Actions** tab. The workflow (`.github/workflows/ci-cd.yml`) runs:

1. **Test** – `npm ci` + `npm test`
2. **Docker build** – builds the image
3. **Kubernetes deploy test** – creates a temporary `kind` cluster, deploys all `k8s/` manifests, waits for rollout and smoke-tests the API
4. **Publish** (push to `main` only) – pushes the image to GitHub Container Registry: `ghcr.io/YOUR_USERNAME/devops-task-manager:latest`

No secrets need to be configured; it uses GitHub's built-in `GITHUB_TOKEN`. If the publish job fails with a permission error, enable **Settings → Actions → General → Workflow permissions → Read and write**. Pull requests from forks never publish.

### Option E — Linux / macOS / WSL: `run.sh`

```bash
./run.sh check            # read-only prerequisite check
./run.sh start            # build + start API and MongoDB, wait until healthy
./run.sh status | logs [-f] [api|mongo] | verify [--smoke]
./run.sh stop [--remove]  # stop (data kept); --remove also removes containers
./run.sh deploy k8s       # build image, load into minikube/kind/docker-desktop, apply k8s/, wait for rollout
./run.sh help
```

`run.sh` never kills other processes, never deletes volumes, and only reports success after the API answers
`/health` with `"database":"connected"`. Logs: `logs/launcher.log`, `logs/compose-up.log`. Exit codes are listed in `./run.sh help`.
Use `--expose-db` to also publish MongoDB on `127.0.0.1:$MONGO_HOST_PORT` (default 27017).

---

## 4. Run the tests

```powershell
npm install
npm test
```

The tests use an in-memory MongoDB. **The first run downloads a MongoDB binary (~100 MB), so internet access is required** and it can take a minute.

---

## 5. Using the app

**Web UI:** http://localhost:5000 (in Minikube use the URL opened by `minikube service`). Add tasks with a priority, change status, filter, delete. The terminal panel at the bottom shows each API call.

**REST API** (PowerShell examples — use `curl.exe`, not `curl`, which is an alias in PowerShell):

```powershell
curl.exe http://localhost:5000/health

curl.exe -X POST http://localhost:5000/api/tasks -H "Content-Type: application/json" -d "{\"title\":\"Learn Docker\",\"priority\":\"high\"}"

curl.exe http://localhost:5000/api/tasks
curl.exe "http://localhost:5000/api/tasks?status=pending&priority=high"

curl.exe -X PUT http://localhost:5000/api/tasks/TASK_ID -H "Content-Type: application/json" -d "{\"status\":\"completed\"}"

curl.exe -X DELETE http://localhost:5000/api/tasks/TASK_ID
```

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Health check |
| GET | `/api` | API info |
| GET / POST | `/api/tasks` | List (filters: `status`, `priority`) / create |
| GET / PUT / DELETE | `/api/tasks/:id` | Read / update / delete |

Task fields: `title` (2–120 chars, required), `description` (≤500), `status` (`pending`, `in-progress`, `completed`), `priority` (`low`, `medium`, `high`). Invalid input returns HTTP 400 with details.

---

## 6. Kubernetes demonstrations

```powershell
# Show resources
kubectl get all -n devops-task-manager

# Replicas (API starts with 2)
kubectl get pods -n devops-task-manager
kubectl scale deployment task-manager-api --replicas=3 -n devops-task-manager
kubectl scale deployment task-manager-api --replicas=2 -n devops-task-manager

# Self-healing: delete a pod and watch a new one appear
kubectl delete pod POD_NAME -n devops-task-manager
kubectl get pods -n devops-task-manager -w     # Ctrl+C to stop watching

# Logs
kubectl logs deployment/task-manager-api -n devops-task-manager
kubectl logs deployment/mongodb -n devops-task-manager
```

---

## 7. Project structure

```text
├── src/                    Express API (app, server, db config, routes, controller, model)
├── public/index.html       Web UI
├── tests/task.test.js      Jest + Supertest tests (in-memory MongoDB)
├── tests/deploy-config.test.js  Compose / Kubernetes / run.sh regression tests (no DB needed)
├── k8s/                    Namespace, ConfigMap, PVC, MongoDB & API Deployments/Services (+ examples/ Secret template)
├── .github/workflows/      GitHub Actions CI/CD
├── Dockerfile              API image (node:20-alpine, non-root, healthcheck)
├── docker-compose.yml      API + MongoDB for local use (MongoDB internal only)
├── docker-compose.dev.yml  Optional override: publish MongoDB on 127.0.0.1
├── run.sh                  Linux/macOS launcher: start/stop/status/logs/check/verify/deploy
├── .env.example            Settings for Option B
├── run-local.bat / run-docker.bat / deploy-k8s.bat   Windows helper scripts
└── package.json
```

---

## 8. Troubleshooting (Windows)

| Problem | Fix |
|---|---|
| `docker: error during connect` / `Cannot connect to the Docker daemon` | Start **Docker Desktop** and wait until it says *Engine running*. |
| Docker Desktop asks for WSL 2 / won't start | Run `wsl --install` in an *Administrator* PowerShell, restart, and enable virtualization in BIOS. |
| `Port 5000 is already in use` | Stop the other program, or choose another host port: `API_HOST_PORT=5001` (environment or `.env`) and use http://localhost:5001. |
| `Port 27017 is already in use` | Only happens with the dev override (Option B). Use `MONGO_HOST_PORT=27018`, or skip the override: the Docker setup (Option A) needs no host MongoDB port. |
| Old tasks are missing after updating | Earlier versions used a differently named Docker volume (`<folder>_mongo_data`). It is untouched; `docker volume ls` shows it. `./run.sh start` warns about such volumes. |
| `npm run start:local` → "bad option: --env-file" | Node is too old. Install Node 20.6+ (`node --version`). |
| API logs "MongoDB connection failed (attempt …)" | MongoDB isn't running. Option B: `docker compose up -d mongo`. The API retries for ~30 s automatically. |
| `curl` shows odd errors in PowerShell | Use `curl.exe` and escape quotes as `\"` (shown above), or use the web UI. |
| `ImagePullBackOff` / `ErrImageNeverPull` in Minikube | The image wasn't built inside Minikube. Rerun `minikube docker-env --shell powershell \| Invoke-Expression`, then `docker build -t devops-task-manager:1.0 .`, then `kubectl rollout restart deployment/task-manager-api -n devops-task-manager`. |
| Pods `Pending` | `kubectl describe pod POD_NAME -n devops-task-manager` and `kubectl get events -n devops-task-manager`. Minikube may need more memory: `minikube delete` then `minikube start --driver=docker --memory=3072`. |
| `npm test` fails downloading MongoDB | Check internet/proxy/firewall; the first run must download the binary. |
| Scripts: "running scripts is disabled" | Applies to `.ps1` only; this project uses `.bat` files, which are not affected. |

---

## 9. Security note

No credentials are stored in the repository. The Kubernetes Secret is created at deploy time with a random password (`run.sh deploy k8s`, `deploy-k8s.bat`, CI); `k8s/examples/secret.example.yaml` only shows the shape and is not applied by `kubectl apply -f k8s/`. For anything real, use GitHub encrypted secrets / an external secret manager, enable TLS and authentication, and use a managed database.

---

## 10. Viva quick reference

- **Docker image vs container:** an image is a read-only template; a container is a running instance of it.
- **Pod:** smallest deployable Kubernetes unit. **Deployment:** manages replicated Pods, rolling updates and self-healing. **Service:** stable network endpoint for a set of Pods. **ConfigMap / Secret:** configuration / sensitive configuration injected into Pods. **PVC:** persistent storage request (keeps MongoDB data).
- **Self-healing:** if a Pod dies, the Deployment controller creates a replacement to keep the desired replica count.
- **CI:** automatically build and test every push. **CD:** automatically deliver/deploy after CI passes (here: deploy to a temporary kind cluster + publish image to GHCR).


Testing Github Actions