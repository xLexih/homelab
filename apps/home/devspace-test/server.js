const express = require('express');
const path = require('path');
const app = express();
const port = 3000;

// Serve static files from public/ with no caching (so changes appear instantly)
app.use(express.static(path.join(__dirname, 'public'), {
  etag: false,
  lastModified: false,
  setHeaders: (res) => {
    res.set('Cache-Control', 'no-store, no-cache, must-revalidate');
  }
}));

// API endpoint to prove the backend is also live-reloadable
app.get('/api/status', (req, res) => {
  res.json({
    status: 'running',
    time: new Date().toISOString(),
    message: 'Edit me in server.js and I update automatically!'
  });
});

app.listen(port, '0.0.0.0', () => {
  console.log(`Server running at http://localhost:${port}`);
});