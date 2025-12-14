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


def collect_images_from_compose(compose_path: Path, env: dict) -> set[str]:
    data = yaml.safe_load(compose_path.read_text(encoding="utf-8", errors="ignore"))
    images = set()
    services = (data or {}).get("services", {}) or {}
    for _, svc in services.items():
        img = svc.get("image")
        if not img:
            continue
        img = expand_vars(str(img), env).strip()
        images.add(img)
    return images


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", required=True)
    ap.add_argument("--compose", required=True)
    ap.add_argument("--base", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    env = parse_env(Path(args.env))

    images = set()
    images |= collect_images_from_compose(Path(args.compose), env)
    images |= collect_images_from_compose(Path(args.base), env)

    # Explicitly include key image vars from .env
    for k in ["RAGFLOW_IMAGE", "TEI_IMAGE_CPU", "TEI_IMAGE_GPU"]:
        if k in env and env[k]:
            images.add(env[k].strip())

    out = []
    for i in sorted(images):
        i = i.strip()
        if not i:
            continue

        # Filter out unresolved templates like ${VAR:-default}
        if "${" in i:
            print(f"[WARN] Unexpanded image skipped: {i}")
            continue

        # Keep only refs with tag or digest; default if no tag? (here we keep only with ':' or '@')
        if ":" not in i and "@" not in i:
            # if you want, you can default to :latest, but to be strict we skip
            print(f"[WARN] Untagged image skipped: {i}")
            continue

        out.append(i)

    Path(args.out).write_text(json.dumps(out, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Collected {len(out)} images")


if __name__ == "__main__":
    main()
