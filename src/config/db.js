const mongoose = require("mongoose");

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Retries so the API survives starting before MongoDB is ready
// (common with docker compose and Kubernetes).
async function connectDB(retries = 10, delayMs = 3000) {
  const uri = process.env.MONGO_URI || "mongodb://localhost:27017/devops_tasks";

  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      await mongoose.connect(uri, { serverSelectionTimeoutMS: 5000 });
      console.log("MongoDB connected");
      return;
    } catch (error) {
      console.error(
        `MongoDB connection failed (attempt ${attempt}/${retries}): ${error.message}`
      );
      if (attempt === retries) throw error;
      await sleep(delayMs);
    }
  }
}

module.exports = connectDB;
