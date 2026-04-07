require("dotenv").config();
const express = require("express");
const path = require("path");
const { createApp } = require("./src/backend/app");

const app = createApp();
const PORT = Number(process.env.PORT || 3000);

// Serve Vercel/React built frontend files
app.use(express.static(path.join(__dirname, "frontend/dist")));

app.use((req, res) => {
  res.sendFile(path.join(__dirname, "frontend/dist", "index.html"));
});
app.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});
