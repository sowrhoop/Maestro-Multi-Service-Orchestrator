const express = require("express");
const app = express();
const port = parseInt(process.env.PORT || "9090", 10);
const serviceAUrl = process.env.SERVICE_A_URL || "";

app.get("/", async (req, res) => {
  const info = { service: "B", status: "ok" };
  if (serviceAUrl) {
    try {
      const r = await fetch(serviceAUrl + "/");
      info.serviceA = await r.json();
    } catch (e) {
      info.serviceA = { error: "unreachable" };
    }
  }
  res.json(info);
});

app.listen(port, () => {
  console.log(`Service B listening on :${port}`);
});

