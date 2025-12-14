import argparse, json, re
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

def expand_vars(s: str, env: dict) -> str:
    # 支持 ${VAR} / ${VAR:-default}
    def repl(m):
        body = m.group(1)
        if ":-" in body:
            var, default = body.split(":-", 1)
            return env.get(var, default)
        return env.get(body, m.group(0))
    return re.sub(r"\$\{([^}]+)\}", repl, s)

def collect_images_from_compose(compose_path: Path, env: dict) -> set[str]:
    # 用 yaml.safe_load 解析。上游 compose 可能是“压缩成一行”的 YAML，也能解析。
    data = yaml.safe_load(compose_path.read_text(encoding="utf-8", errors="ignore"))
    images = set()
    services = (data or {}).get("services", {}) or {}
    for _, svc in services.items():
        img = svc.get("image")
        if img:
            images.add(expand_vars(str(img), env))
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

    # 1) 从 compose/base 的 image 字段收集
    images |= collect_images_from_compose(Path(args.compose), env)
    images |= collect_images_from_compose(Path(args.base), env)

    # 2) 从 .env 里把关键镜像变量（RAGFLOW_IMAGE、TEI_IMAGE_*）也显式加入（防止 compose 某些 profile 不解析）
    for k in ["RAGFLOW_IMAGE", "TEI_IMAGE_CPU", "TEI_IMAGE_GPU"]:
        if k in env and env[k]:
            images.add(env[k])

    out = sorted(i for i in images if ":" in i)  # 仅保留带 tag 的
    Path(args.out).write_text(json.dumps(out, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Collected {len(out)} images")

if __name__ == "__main__":
    main()
