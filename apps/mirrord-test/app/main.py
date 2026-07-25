import os
import socket
from flask import Flask, jsonify

app = Flask(__name__)

@app.route('/')
def index():
    return jsonify({
        "hostname": socket.gethostname(),
        "pod_ip": os.environ.get('POD_IP', 'unknown'),
        "version": "v1.0.0-CLUSTER-CHANGED",  # Changes locally
        "secret_local_marker": "🔥 I AM RUNNING ON YOUR LOCAL MACHINE",
        "timestamp": __import__('datetime').datetime.now().isoformat()
    })

@app.route('/health')
def health():
    return jsonify({"status": "healthy"})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
