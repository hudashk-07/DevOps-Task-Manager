// Regression tests for deployment configuration and run.sh edge cases.
// They need no database and no Docker daemon.
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const root = path.join(__dirname, "..");
const read = (f) => fs.readFileSync(path.join(root, f), "utf8");
const runSh = (args, env = {}) =>
  spawnSync("bash", [path.join(root, "run.sh"), ...args], {
    env: { ...process.env, ...env },
    encoding: "utf8",
    timeout: 20000
  });

// Text of one top-level service block of a compose file
const service = (file, name) => {
  const m = read(file).match(new RegExp(`^  ${name}:\\n((?:    .*\\n|\\n)+)`, "m"));
  return m ? m[1] : "";
};

describe("Docker Compose / MongoDB", () => {
  test("mongo is not published on host port 27017 by default", () => {
    const mongo = service("docker-compose.yml", "mongo");
    expect(mongo).not.toBe("");
    expect(mongo).not.toMatch(/^\s*ports:/m);
    expect(mongo).not.toMatch(/27017:27017/);
  });

  test("api reaches MongoDB over the internal network", () => {
    expect(read("docker-compose.yml")).toMatch(/MONGO_URI:\s*mongodb:\/\/mongo:27017\/devops_tasks/);
  });

  test("api host port is configurable", () => {
    expect(read("docker-compose.yml")).toMatch(/"\$\{API_HOST_PORT:-5000\}:5000"/);
  });

  test("dev override publishes MongoDB on loopback only, port configurable", () => {
    expect(read("docker-compose.dev.yml")).toMatch(/"127\.0\.0\.1:\$\{MONGO_HOST_PORT:-27017\}:27017"/);
  });

  test("no fixed container_name that can clash with existing containers", () => {
    expect(read("docker-compose.yml")).not.toMatch(/container_name:/);
  });
});

describe("Kubernetes manifests", () => {
  test("MongoDB uses Recreate (one mongod per ReadWriteOnce volume)", () => {
    expect(read("k8s/mongo-deployment.yaml")).toMatch(/strategy:\s*\n\s*type: Recreate/);
  });

  test("API has a startupProbe so slow MongoDB connects are not killed by liveness", () => {
    expect(read("k8s/api-deployment.yaml")).toMatch(/startupProbe:/);
  });

  test("no real credentials are committed in applied manifests", () => {
    expect(fs.existsSync(path.join(root, "k8s/secret.yaml"))).toBe(false);
    expect(read("k8s/examples/secret.example.yaml")).not.toMatch(/devops123/);
  });
});

// run.sh needs a POSIX bash; skip on Windows (README targets Docker Desktop there).
const canRunBash = process.platform !== "win32" && spawnSync("bash", ["--version"]).status === 0;
(canRunBash ? describe : describe.skip)("run.sh", () => {
  test("has valid bash syntax", () => {
    expect(spawnSync("bash", ["-n", path.join(root, "run.sh")]).status).toBe(0);
  });

  test("help exits 0 and lists every command", () => {
    const r = runSh(["help"]);
    expect(r.status).toBe(0);
    for (const c of ["start", "stop", "restart", "status", "logs", "check", "verify", "deploy"]) {
      expect(r.stdout).toMatch(new RegExp(`^  ${c}\\b`, "m"));
    }
  });

  test("unknown command exits 2", () => {
    expect(runSh(["frobnicate"]).status).toBe(2);
  });

  test("invalid API_HOST_PORT is rejected with exit 11 before touching Docker", () => {
    const r = runSh(["status"], { API_HOST_PORT: "99999", TM_LOG_DIR: fs.mkdtempSync("/tmp/tm-"), TM_RUN_DIR: fs.mkdtempSync("/tmp/tm-") });
    expect(r.status).toBe(11);
    expect(r.stderr).toMatch(/not a valid port/);
  });

  test("never deletes volumes or kills processes", () => {
    const src = read("run.sh").split("\n").filter((l) => !/^\s*#/.test(l)).join("\n");
    expect(src).not.toMatch(/down\s+(-v|--volumes)/);
    expect(src).not.toMatch(/volume\s+(rm|prune)/);
    expect(src).not.toMatch(/\bpkill\b|\bkillall\b|kill\s+-9|kill\s+-KILL/);
    expect(src).not.toMatch(/\b(kubectl|kube)\s+delete\b/);
  });
});
