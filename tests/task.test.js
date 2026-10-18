const mongoose = require("mongoose");
const request = require("supertest");
const { MongoMemoryServer } = require("mongodb-memory-server");

let mongoServer;
let app;

beforeAll(async () => {
  mongoServer = await MongoMemoryServer.create();
  process.env.MONGO_URI = mongoServer.getUri();

  await mongoose.connect(process.env.MONGO_URI);

  app = require("../src/app");
}, 120000);

afterEach(async () => {
  await mongoose.connection.db.dropDatabase();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongoServer.stop();
});

const createTask = (body) => request(app).post("/api/tasks").send(body);

describe("Health & misc", () => {
  test("GET /health returns healthy response", async () => {
    const res = await request(app).get("/health");
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe("ok");
    expect(res.body.database).toBe("connected");
  });

  test("GET /api returns API info", async () => {
    const res = await request(app).get("/api");
    expect(res.statusCode).toBe(200);
    expect(res.body.name).toMatch(/Task Manager/);
  });

  test("GET / serves the web UI", async () => {
    const res = await request(app).get("/");
    expect(res.statusCode).toBe(200);
    expect(res.text).toMatch(/DevOps Task Manager/);
  });

  test("unknown route returns 404", async () => {
    const res = await request(app).get("/nope");
    expect(res.statusCode).toBe(404);
  });
});

describe("Create", () => {
  test("creates a task with defaults", async () => {
    const res = await createTask({ title: "Learn Docker" });
    expect(res.statusCode).toBe(201);
    expect(res.body.status).toBe("pending");
    expect(res.body.priority).toBe("medium");
  });

  test("creates a task with all fields", async () => {
    const res = await createTask({
      title: "Docker task",
      description: "Containerize the API",
      priority: "high"
    });
    expect(res.statusCode).toBe(201);
    expect(res.body.title).toBe("Docker task");
    expect(res.body.priority).toBe("high");
  });

  test("rejects a missing title with 400", async () => {
    const res = await createTask({ description: "no title" });
    expect(res.statusCode).toBe(400);
    expect(res.body.error).toBe("Validation failed");
  });

  test("rejects an invalid priority with 400", async () => {
    const res = await createTask({ title: "Bad", priority: "urgent" });
    expect(res.statusCode).toBe(400);
  });

  test("rejects malformed JSON with 400", async () => {
    const res = await request(app)
      .post("/api/tasks")
      .set("Content-Type", "application/json")
      .send("{bad json");
    expect(res.statusCode).toBe(400);
  });

  test("ignores unknown fields", async () => {
    const res = await createTask({ title: "Safe task", isAdmin: true });
    expect(res.statusCode).toBe(201);
    expect(res.body.isAdmin).toBeUndefined();
  });
});

describe("Read", () => {
  test("lists tasks", async () => {
    await createTask({ title: "Kubernetes task" });
    const res = await request(app).get("/api/tasks");
    expect(res.statusCode).toBe(200);
    expect(res.body).toHaveLength(1);
  });

  test("filters by status and priority", async () => {
    await createTask({ title: "One", priority: "high" });
    await createTask({ title: "Two", priority: "low", status: "completed" });

    const byPriority = await request(app).get("/api/tasks?priority=high");
    expect(byPriority.body).toHaveLength(1);
    expect(byPriority.body[0].title).toBe("One");

    const byStatus = await request(app).get("/api/tasks?status=completed");
    expect(byStatus.body).toHaveLength(1);
    expect(byStatus.body[0].title).toBe("Two");
  });

  test("query operators in filters are not interpreted (?status[$ne]=x)", async () => {
    await createTask({ title: "Pending one" });
    const res = await request(app).get("/api/tasks?status[$ne]=completed");
    expect(res.statusCode).toBe(200);
    expect(res.body).toHaveLength(0);
  });

  test("gets one task by id", async () => {
    const created = await createTask({ title: "Find me" });
    const res = await request(app).get(`/api/tasks/${created.body._id}`);
    expect(res.statusCode).toBe(200);
    expect(res.body.title).toBe("Find me");
  });

  test("returns 400 for an invalid id", async () => {
    const res = await request(app).get("/api/tasks/not-an-id");
    expect(res.statusCode).toBe(400);
  });

  test("returns 404 for a missing id", async () => {
    const res = await request(app).get("/api/tasks/507f1f77bcf86cd799439011");
    expect(res.statusCode).toBe(404);
  });
});

describe("Update", () => {
  test("updates a task status", async () => {
    const created = await createTask({ title: "Update me" });
    const res = await request(app)
      .put(`/api/tasks/${created.body._id}`)
      .send({ status: "completed" });
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe("completed");
  });

  test("rejects an invalid status with 400", async () => {
    const created = await createTask({ title: "Update me" });
    const res = await request(app)
      .put(`/api/tasks/${created.body._id}`)
      .send({ status: "done-ish" });
    expect(res.statusCode).toBe(400);
  });

  test("returns 404 when updating a missing task", async () => {
    const res = await request(app)
      .put("/api/tasks/507f1f77bcf86cd799439011")
      .send({ status: "completed" });
    expect(res.statusCode).toBe(404);
  });
});

describe("Delete", () => {
  test("deletes a task", async () => {
    const created = await createTask({ title: "Delete me" });
    const res = await request(app).delete(`/api/tasks/${created.body._id}`);
    expect(res.statusCode).toBe(200);

    const after = await request(app).get(`/api/tasks/${created.body._id}`);
    expect(after.statusCode).toBe(404);
  });

  test("returns 404 when deleting a missing task", async () => {
    const res = await request(app).delete("/api/tasks/507f1f77bcf86cd799439011");
    expect(res.statusCode).toBe(404);
  });
});
