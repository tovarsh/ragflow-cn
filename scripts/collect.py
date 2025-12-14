import argparse
import json
import re
from pathlib import Path

import yaml


def parse_env(env_path: Path) -> dict:
    env = {}
    for line in env_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()
    return env


_VAR_PATTERN = re.compile(r"\$\{([^}]+)\}")


def expand_vars(s: str, env: dict) -> str:
    """
    Expand docker-compose style variables:
      - ${VAR}
      - ${VAR:-default}  (use default if VAR is unset OR empty)
      - ${VAR-default}   (use default if VAR is unset)
    """
    def repl(m: re.Match) -> str:
        body = m.group(1)

        # ${VAR:-default} -> default if env[var] is missing OR empty
        if ":-" in body:
            var, default = body.split(":-", 1)
            val = env.get(var, "")
            return val if val else default

        # ${VAR-default} -> default if env[var] is missing (empty string counts as set)
        if "-" in body:
            var, default = body.split("-", 1)
            if var in env:
                return env[var]
            return default

        # ${VAR}
        return env.get(body, m.group(0))

    prev = None
    cur = s
    # repeat a few times to resolve multiple vars in one string
    for _ in range(5):
        if cur == prev:
            break
        prev = cur
        cur = _VAR_PATTERN.sub(repl, cur)
    return cur


def _collect_images_from_env_value(val: str, env: dict) -> set[str]:
    """
    Heuristically extract image refs from an environment value.
    This is to catch cases like:
      SANDBOX_BASE_PYTHON_IMAGE=${SANDBOX_BASE_PYTHON_IMAGE:-infiniflow/sandbox-base-python:latest}
    or direct:
      FOO_IMAGE=infiniflow/xxx:tag
    """
    images = set()

    s = expand_vars(str(val), env).strip()
    if not s:
        return images

    # common case: the whole value is an image ref
    if "${" not in s and ((":" in s) or ("@" in s)):
        # but avoid obvious non-image URLs or file paths if needed; keep simple here
        images.add(s)
        return images

    # If value contains multiple tokens, try split by whitespace/commas
    for tok in re.split(r"[\s,]+", s):
        tok = tok.strip()
        if not tok or "${" in tok:
            continue
        if (":" in tok) or ("@" in tok):
            images.add(tok)

    return images


def collect_images_from_compose(compose_path: Path, env: dict) -> set[str]:
    """
    Collect images from:
      - services.*.image
      - services.*.environment values (to catch hidden image refs)
    """
    data = yaml.safe_load(compose_path.read_text(encoding="utf-8", errors="ignore"))
    images: set[str] = set()

    services = (data or {}).get("services", {}) or {}
    for _, svc in services.items():
        # 1) explicit image:
        img = svc.get("image")
        if img:
            img = expand_vars(str(img), env).strip()
            if img:
                images.add(img)

        # 2) environment values may contain image refs (e.g., sandbox base images)
        env_block = svc.get("environment")
        if not env_block:
            continue

        if isinstance(env_block, dict):
            for _, v in env_block.items():
                if v is None:
                    continue
                images |= _collect_images_from_env_value(str(v), env)

        elif isinstance(env_block, list):
            # list entries: KEY=VALUE or just KEY (rare)
            for item in env_block:
                if item is None:
                    continue
                item = str(item).strip()
                if not item:
                    continue
                if "=" in item:
                    _, v = item.split("=", 1)
                    images |= _collect_images_from_env_value(v, env)

    return images


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", required=True)
    ap.add_argument("--compose", required=True)
    ap.add_argument("--base", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    env = parse_env(Path(args.env))

    images: set[str] = set()

    # 1) from compose/base
    images |= collect_images_from_compose(Path(args.compose), env)
    images |= collect_images_from_compose(Path(args.base), env)

    # 2) Explicitly include key image vars from .env
    #    (These are known to be relevant even if compose profiles not enabled)
    for k in [
        "RAGFLOW_IMAGE",
        "TEI_IMAGE_CPU",
        "TEI_IMAGE_GPU",
        # sandbox base images (官方 .env 中明确提示预拉取)
        "SANDBOX_BASE_PYTHON_IMAGE",
        "SANDBOX_BASE_NODEJS_IMAGE",
    ]:
        if k in env and env[k]:
            # env may itself contain ${VAR:-default}
            v = expand_vars(env[k].strip(), env).strip()
            if v:
                images.add(v)

    out = []
    for i in sorted(images):
        i = i.strip()
        if not i:
            continue

        # Filter out unresolved templates like ${VAR:-default}
        if "${" in i:
            print(f"[WARN] Unexpanded image skipped: {i}")
            continue

        # Keep only refs with tag or digest
        if ":" not in i and "@" not in i:
            print(f"[WARN] Untagged image skipped: {i}")
            continue

        out.append(i)

    Path(args.out).write_text(json.dumps(out, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Collected {len(out)} images")


if __name__ == "__main__":
    main()
