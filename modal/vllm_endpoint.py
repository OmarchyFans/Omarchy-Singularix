"""A dedicated OpenAI-compatible LLM endpoint on Modal, for the Omarchy Agent Launcher.

Deployed by `omarchy-agent-launcher backends deploy <id>` as

    OAL_APP=oal-<id> OAL_MODEL=Qwen/Qwen3-8B OAL_GPU=L4 OAL_GPU_COUNT=1 \
    OAL_SCALEDOWN_SECONDS=900 OAL_MAX_MODEL_LEN=32768 OAL_API_KEY=… modal deploy modal/vllm_endpoint.py

Everything is read from the environment at deploy time so the same file serves every
backend. The server is vLLM with tool calling enabled (Hermes-style parser, which Qwen,
Hermes and most open tool-capable models use). One container at most, scaled to zero
after OAL_SCALEDOWN_SECONDS idle; the next request wakes it (cold start: model load).

The API key travels as a Modal Secret built from the local environment at deploy time;
it is not baked into the image. Set HF_TOKEN in the environment for gated models.
Weights are cached in a Modal Volume so a wake-up does not re-download them.
"""

import os
import subprocess

import modal

APP = os.environ.get("OAL_APP", "oal-llm")
MODEL = os.environ.get("OAL_MODEL", "Qwen/Qwen3-8B")
GPU = os.environ.get("OAL_GPU", "L4")
GPU_COUNT = int(os.environ.get("OAL_GPU_COUNT", "1"))
SCALEDOWN = int(os.environ.get("OAL_SCALEDOWN_SECONDS", "900"))
MAX_MODEL_LEN = int(os.environ.get("OAL_MAX_MODEL_LEN", "32768"))
TOOL_PARSER = os.environ.get("OAL_TOOL_PARSER", "hermes")
VLLM_VERSION = os.environ.get("OAL_VLLM_VERSION", "")  # empty = latest release
PORT = 8000
MINUTES = 60

_secret_env = {"VLLM_API_KEY": os.environ.get("OAL_API_KEY", "")}
if os.environ.get("HF_TOKEN"):
    _secret_env["HF_TOKEN"] = os.environ["HF_TOKEN"]

image = (
    modal.Image.debian_slim(python_version="3.12")
    .pip_install("vllm" + (f"=={VLLM_VERSION}" if VLLM_VERSION else ""), "huggingface_hub[hf_transfer]")
    .env({"HF_HUB_ENABLE_HF_TRANSFER": "1"})
)

hf_cache = modal.Volume.from_name("oal-hf-cache", create_if_missing=True)
vllm_cache = modal.Volume.from_name("oal-vllm-cache", create_if_missing=True)

app = modal.App(APP)


@app.function(
    image=image,
    gpu=f"{GPU}:{GPU_COUNT}",
    scaledown_window=SCALEDOWN,
    timeout=24 * 60 * MINUTES,
    max_containers=1,
    volumes={"/root/.cache/huggingface": hf_cache, "/root/.cache/vllm": vllm_cache},
    secrets=[modal.Secret.from_dict(_secret_env)],
)
@modal.concurrent(max_inputs=32)
@modal.web_server(port=PORT, startup_timeout=15 * MINUTES)
def serve():
    cmd = [
        "vllm", "serve", MODEL,
        "--host", "0.0.0.0", "--port", str(PORT),
        "--served-model-name", MODEL,
        "--max-model-len", str(MAX_MODEL_LEN),
        "--tensor-parallel-size", str(GPU_COUNT),
        "--enable-auto-tool-choice", "--tool-call-parser", TOOL_PARSER,
    ]
    # VLLM_API_KEY (from the secret) makes vLLM require `Authorization: Bearer <key>`.
    subprocess.Popen(cmd)


@app.local_entrypoint()
def url():
    """Print the deployed endpoint's URL (used when deploy output could not be parsed)."""
    print(modal.Function.from_name(APP, "serve").get_web_url())
