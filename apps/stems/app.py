import os
import uuid
import subprocess
import threading
from pathlib import Path
from flask import Flask, request, jsonify, send_file
from flask_cors import CORS

app = Flask(__name__)
CORS(app, origins=["http://localhost:3001", "http://localhost:3002", "https://slowreverb.unocloud.us"])

WORK_DIR = Path("/tmp/stems-work")
WORK_DIR.mkdir(exist_ok=True)

jobs = {}  # in-memory job store

def run_demucs(job_id: str, input_path: str, output_dir: str):
    jobs[job_id]["status"] = "processing"
    try:
        result = subprocess.run([
            "/home/uno/.local/bin/demucs", "--mp3", "-d", "cuda",
            "--out", output_dir,
            input_path
        ], capture_output=True, text=True, timeout=300)

        if result.returncode != 0:
            jobs[job_id]["status"] = "failed"
            jobs[job_id]["error"] = result.stderr[-500:]
            return

        # Find output folder (demucs creates htdemucs/trackname/)
        stem_dir = None
        for d in Path(output_dir).glob("htdemucs/*"):
            if d.is_dir():
                stem_dir = d
                break

        if not stem_dir:
            jobs[job_id]["status"] = "failed"
            jobs[job_id]["error"] = "Could not find output directory"
            return

        stems = {}
        for stem_file in stem_dir.glob("*.mp3"):
            stem_name = stem_file.stem  # vocals, drums, bass, other
            stems[stem_name] = str(stem_file)

        jobs[job_id]["status"] = "done"
        jobs[job_id]["stems"] = stems

    except subprocess.TimeoutExpired:
        jobs[job_id]["status"] = "failed"
        jobs[job_id]["error"] = "Timed out"
    except Exception as e:
        jobs[job_id]["status"] = "failed"
        jobs[job_id]["error"] = str(e)
    finally:
        # Clean up input
        try:
            os.remove(input_path)
        except:
            pass

@app.route("/health")
def health():
    return jsonify({"status": "ok"})

@app.route("/separate", methods=["POST"])
def separate():
    if "file" not in request.files:
        return jsonify({"error": "missing file"}), 400

    f = request.files["file"]
    job_id = str(uuid.uuid4())
    job_dir = WORK_DIR / job_id
    job_dir.mkdir()

    input_path = str(job_dir / f"input{Path(f.filename).suffix}")
    f.save(input_path)

    jobs[job_id] = {
        "id": job_id,
        "status": "pending",
        "stems": {},
        "error": None
    }

    thread = threading.Thread(
        target=run_demucs,
        args=(job_id, input_path, str(job_dir))
    )
    thread.daemon = True
    thread.start()

    return jsonify(jobs[job_id]), 202

@app.route("/separate/<job_id>")
def get_job(job_id):
    job = jobs.get(job_id)
    if not job:
        return jsonify({"error": "not found"}), 404
    return jsonify(job)

@app.route("/separate/<job_id>/stem/<stem_name>")
def get_stem(job_id, stem_name):
    job = jobs.get(job_id)
    if not job or job["status"] != "done":
        return jsonify({"error": "not ready"}), 404

    stem_path = job["stems"].get(stem_name)
    if not stem_path or not Path(stem_path).exists():
        return jsonify({"error": "stem not found"}), 404

    return send_file(stem_path, mimetype="audio/mpeg")

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8090))
    print(f"Stems API listening on :{port}")
    app.run(host="0.0.0.0", port=port, debug=False)
