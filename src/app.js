const path = require("path");
const express = require("express");
const mongoose = require("mongoose");
const taskRoutes = require("./routes/taskRoutes");

const app = express();

app.disable("x-powered-by");
app.use(express.json({ limit: "100kb" }));
app.use(express.static(path.join(__dirname, "..", "public")));

app.get("/api", (req, res) => {
  res.json({
    name: "DevOps Task Manager API",
    version: "1.0.0",
    endpoints: {
      health: "GET /health",
      tasks: "GET|POST /api/tasks",
      task: "GET|PUT|DELETE /api/tasks/:id"
    }
  });
});

// Liveness: always 200 while the process is up. The database state is
// reported for information only, so Kubernetes does not restart the API
// just because MongoDB is briefly unavailable.
app.get("/health", (req, res) => {
  const states = ["disconnected", "connected", "connecting", "disconnecting"];
  res.status(200).json({
    status: "ok",
    service: "devops-task-manager",
    database: states[mongoose.connection.readyState] || "unknown"
  });
});

app.use("/api/tasks", taskRoutes);

app.use((req, res) => {
  res.status(404).json({ error: "Route not found" });
});

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  if (err.type === "entity.parse.failed") {
    return res.status(400).json({ error: "Invalid JSON body" });
  }

  if (err.name === "ValidationError") {
    const details = Object.values(err.errors).map((e) => e.message);
    return res.status(400).json({ error: "Validation failed", details });
  }

  if (err.name === "CastError") {
    return res.status(400).json({ error: `Invalid value for ${err.path}` });
  }

  console.error(err);
  res.status(500).json({ error: "Internal server error" });
});

module.exports = app;
