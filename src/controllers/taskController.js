const mongoose = require("mongoose");
const Task = require("../models/Task");

const ALLOWED_FIELDS = ["title", "description", "status", "priority"];

function validateId(id) {
  return mongoose.Types.ObjectId.isValid(id);
}

// Only allow known fields (prevents clients from writing arbitrary keys)
function pickFields(body) {
  const data = {};
  if (body && typeof body === "object") {
    for (const key of ALLOWED_FIELDS) {
      if (body[key] !== undefined) data[key] = body[key];
    }
  }
  return data;
}

async function createTask(req, res) {
  const task = await Task.create(pickFields(req.body));
  res.status(201).json(task);
}

async function getTasks(req, res) {
  const filter = {};

  // String() guards against query-operator injection such as ?status[$ne]=x
  if (req.query.status) {
    filter.status = String(req.query.status);
  }

  if (req.query.priority) {
    filter.priority = String(req.query.priority);
  }

  const tasks = await Task.find(filter).sort({ createdAt: -1 });
  res.json(tasks);
}

async function getTask(req, res) {
  if (!validateId(req.params.id)) {
    return res.status(400).json({ error: "Invalid task id" });
  }

  const task = await Task.findById(req.params.id);

  if (!task) {
    return res.status(404).json({ error: "Task not found" });
  }

  res.json(task);
}

async function updateTask(req, res) {
  if (!validateId(req.params.id)) {
    return res.status(400).json({ error: "Invalid task id" });
  }

  const task = await Task.findByIdAndUpdate(
    req.params.id,
    pickFields(req.body),
    { new: true, runValidators: true }
  );

  if (!task) {
    return res.status(404).json({ error: "Task not found" });
  }

  res.json(task);
}

async function deleteTask(req, res) {
  if (!validateId(req.params.id)) {
    return res.status(400).json({ error: "Invalid task id" });
  }

  const task = await Task.findByIdAndDelete(req.params.id);

  if (!task) {
    return res.status(404).json({ error: "Task not found" });
  }

  res.json({ message: "Task deleted successfully" });
}

module.exports = {
  createTask,
  getTasks,
  getTask,
  updateTask,
  deleteTask
};
