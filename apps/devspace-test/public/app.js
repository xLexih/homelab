let count = 0;

function increment() {
  count++;
  document.getElementById('count').textContent = count;
}

async function fetchStatus() {
  try {
    const res = await fetch('/api/status');
    const data = await res.json();
    document.getElementById('api-response').textContent =
      JSON.stringify(data, null, 2);
  } catch (err) {
    document.getElementById('api-response').textContent =
      'Error: ' + err.message;
  }
}

// Poll the API every 3 seconds so you can see server.js changes live
fetchStatus();
setInterval(fetchStatus, 3000);