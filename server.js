require("dotenv").config();
const { createApp } = require("./src/backend/app");

const app = createApp();
const PORT = Number(process.env.PORT || 3000);
app.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});
