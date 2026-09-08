"""A sandboxed LLM on Modal, for the Omarchy Agent Launcher.

Started by `omarchy-agent-launcher backends start <id>` as

    OAL_APP=oal-<id> OAL_MODEL=… OAL_GPU=H100 OAL_GPU_COUNT=1 OAL_TIMEOUT_SECONDS=14400 \
    OAL_SCALEDOWN_SECONDS=900 OAL_MAX_MODEL_LEN=32768 OAL_API_KEY=… modal run modal/vllm_sandbox.py::start

Unlike the deployed endpoint (vllm_endpoint.py), a Sandbox is one isolated container that
you own for a fixed lifetime: nothing else runs in it, it never scales or shares, and it is
billed from start until it exits or you terminate it (`backends stop`). It ends on its own
after OAL_TIMEOUT_SECONDS (max 24 h) or after OAL_SCALEDOWN_SECONDS without traffic.

The vLLM server inside is reached through an encrypted Modal tunnel; the URL and the
sandbox id are printed as one JSON line for the launcher to record.
"""

import json
import os

import modal

APP = os.environ.get("OAL_APP", "oal-llm-sandbox")
MODEL = os.environ.get("OAL_MODEL", "Qwen/Qwen3-8B")
GPU = os.environ.get("OAL_GPU", "L4")
GPU_COUNT = int(os.environ.get("OAL_GPU_COUNT", "1"))
TIMEOUT = min(int(os.environ.get("OAL_TIMEOUT_SECONDS", str(4 * 3600))), 24 * 3600)
IDLE = int(os.environ.get("OAL_SCALEDOWN_SECONDS", "900"))
MAX_MODEL_LEN = int(os.environ.get("OAL_MAX_MODEL_LEN", "32768"))
TOOL_PARSER = os.environ.get("OAL_TOOL_PARSER", "hermes")
VLLM_VERSION = os.environ.get("OAL_VLLM_VERSION", "")
PORT = 8000

image = (
    modal.Image.debian_slim(python_version="3.12")
    .pip_install("vllm" + (f"=={VLLM_VERSION}" if VLLM_VERSION else ""), "huggingface_hub[hf_transfer]")
    .env({"HF_HUB_ENABLE_HF_TRANSFER": "1"})
)

app = modal.App(APP)


@app.local_entrypoint()
def start():
    secret_env = {"VLLM_API_KEY": os.environ.get("OAL_API_KEY", "")}
    if os.environ.get("HF_TOKEN"):
        secret_env["HF_TOKEN"] = os.environ["HF_TOKEN"]
    sb_app = modal.App.lookup(APP, create_if_missing=True)
    sb = modal.Sandbox.create(
        "vllm", "serve", MODEL,
        "--host", "0.0.0.0", "--port", str(PORT),
        "--served-model-name", MODEL,
        "--max-model-len", str(MAX_MODEL_LEN),
        "--tensor-parallel-size", str(GPU_COUNT),
        "--enable-auto-tool-choice", "--tool-call-parser", TOOL_PARSER,
        app=sb_app,
        image=image,
        gpu=f"{GPU}:{GPU_COUNT}",
        timeout=TIMEOUT,
        idle_timeout=IDLE,
        encrypted_ports=[PORT],
        secrets=[modal.Secret.from_dict(secret_env)],
        volumes={"/root/.cache/huggingface": modal.Volume.from_name("oal-hf-cache", create_if_missing=True)},
    )
    tunnel = sb.tunnels()[PORT]
    print(json.dumps({"sandbox_id": sb.object_id, "url": tunnel.url, "app": APP, "model": MODEL, "gpu": f"{GPU}:{GPU_COUNT}"}))


@app.local_entrypoint()
def stop():
    """Terminate the sandbox named by OAL_SANDBOX_ID (the launcher normally uses `modal sandbox terminate`)."""
    sb = modal.Sandbox.from_id(os.environ["OAL_SANDBOX_ID"])
    sb.terminate(wait=True)
    print(json.dumps({"terminated": os.environ["OAL_SANDBOX_ID"]}))
