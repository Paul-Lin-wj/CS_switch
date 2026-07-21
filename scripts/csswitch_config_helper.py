#!/usr/bin/env python3
"""CSSwitch-Linux CLI config helper. Reads/writes ~/.csswitch/config.json (schema v2)."""
import argparse
import json
import os
import sys
from pathlib import Path
from tempfile import mkstemp

CURRENT_SCHEMA_VERSION = 2

DEFAULT_TEMPLATES = [
    {"id": "deepseek", "name": "DeepSeek", "category": "deepseek", "adapter": "deepseek",
     "api_format": "anthropic", "base_url": "https://api.deepseek.com/beta", "base_url_editable": False,
     "requires_model": False, "key_env": "DEEPSEEK_API_KEY", "builtin_models": ["deepseek-chat", "deepseek-reasoner"]},
    {"id": "qwen", "name": "Qwen (DashScope)", "category": "qwen", "adapter": "qwen",
     "api_format": "openai_chat", "base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1",
     "base_url_editable": False, "requires_model": False, "key_env": "DASHSCOPE_API_KEY",
     "builtin_models": ["qwen-max", "qwen-plus", "qwen-turbo"]},
    {"id": "kimi", "name": "Kimi", "category": "kimi", "adapter": "relay",
     "api_format": "anthropic", "base_url": "https://api.moonshot.cn/anthropic", "base_url_editable": True,
     "requires_model": True, "key_env": "CSSWITCH_RELAY_KEY", "builtin_models": ["kimi-k2.7-code"]},
    {"id": "minimax", "name": "MiniMax", "category": "minimax", "adapter": "relay",
     "api_format": "anthropic", "base_url": "https://api.minimaxi.com/anthropic", "base_url_editable": True,
     "requires_model": True, "key_env": "CSSWITCH_RELAY_KEY", "builtin_models": ["MiniMax-M3"]},
    {"id": "glm", "name": "GLM", "category": "glm", "adapter": "relay",
     "api_format": "anthropic", "base_url": "https://open.bigmodel.cn/api/anthropic", "base_url_editable": True,
     "requires_model": True, "key_env": "CSSWITCH_RELAY_KEY", "builtin_models": ["glm-5.2"]},
    {"id": "openrouter", "name": "OpenRouter", "category": "openrouter", "adapter": "relay",
     "api_format": "anthropic", "base_url": "https://openrouter.ai/api/anthropic", "base_url_editable": True,
     "requires_model": True, "key_env": "CSSWITCH_RELAY_KEY", "builtin_models": ["anthropic/claude-3.5-sonnet"]},
    {"id": "openai-custom", "name": "Custom OpenAI", "category": "openai-custom", "adapter": "openai-custom",
     "api_format": "openai_chat", "base_url": "", "base_url_editable": True,
     "requires_model": True, "key_env": "CSSWITCH_OPENAI_KEY", "builtin_models": []},
    {"id": "openai-responses", "name": "Custom OpenAI Responses", "category": "openai-responses",
     "adapter": "openai-responses", "api_format": "openai_responses", "base_url": "",
     "base_url_editable": True, "requires_model": True, "key_env": "CSSWITCH_OPENAI_KEY", "builtin_models": []},
    {"id": "relay", "name": "Relay / Custom Anthropic", "category": "relay", "adapter": "relay",
     "api_format": "anthropic", "base_url": "", "base_url_editable": True,
     "requires_model": True, "key_env": "CSSWITCH_RELAY_KEY", "builtin_models": []},
]


def config_path():
    return Path(os.environ.get("CSSWITCH_CONFIG", Path.home() / ".csswitch" / "config.json"))


def default_dir():
    return config_path().parent


def ensure_dir(path: Path):
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def assert_no_symlink_in_path(path: Path):
    for p in list(path.parents) + [path]:
        if p.is_symlink():
            raise ValueError(f"Refusing to follow symlink: {p}")


def load_config():
    p = config_path()
    if not p.exists():
        return default_config()
    assert_no_symlink_in_path(p)
    with open(p, "r", encoding="utf-8") as f:
        data = json.load(f)
    cfg = default_config()
    cfg.update(data)
    if cfg.get("schema_version", 0) > CURRENT_SCHEMA_VERSION:
        raise ValueError(f"Unsupported schema version: {cfg['schema_version']}")
    return cfg


def default_config():
    return {
        "schema_version": CURRENT_SCHEMA_VERSION,
        "profiles": [],
        "active_id": "",
        "proxy_port": 18991,
        "sandbox_port": 8990,
        "secret": "",
        "mode": "proxy",
    }


def save_config(cfg):
    p = config_path()
    assert_no_symlink_in_path(p)
    ensure_dir(p.parent)
    fd, tmp = mkstemp(dir=p.parent, prefix="config.json.tmp")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.replace(tmp, p)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def cmd_load(args):
    print(json.dumps(load_config(), ensure_ascii=False))
    return 0


def cmd_templates(args):
    print(json.dumps(DEFAULT_TEMPLATES, ensure_ascii=False))
    return 0


def cmd_list(args):
    cfg = load_config()
    print(json.dumps(cfg.get("profiles", []), ensure_ascii=False))
    return 0


def cmd_active(args):
    cfg = load_config()
    active = None
    for p in cfg.get("profiles", []):
        if p["id"] == cfg.get("active_id"):
            active = p
            break
    if active is None:
        print(json.dumps({"error": "no active profile"}, ensure_ascii=False))
        return 1
    print(json.dumps(active, ensure_ascii=False))
    return 0


def cmd_set_active(args):
    cfg = load_config()
    ids = {p["id"] for p in cfg.get("profiles", [])}
    if args.profile_id not in ids:
        print(json.dumps({"error": f"profile not found: {args.profile_id}"}, ensure_ascii=False))
        return 1
    cfg["active_id"] = args.profile_id
    save_config(cfg)
    print(json.dumps({"ok": True, "active_id": args.profile_id}, ensure_ascii=False))
    return 0


def main():
    parser = argparse.ArgumentParser(description="CSSwitch config helper")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("load", help="load full config as JSON")
    sub.add_parser("templates", help="list built-in templates as JSON")
    sub.add_parser("list", help="list profiles as JSON")
    sub.add_parser("active", help="show active profile as JSON")
    p_set = sub.add_parser("set-active", help="set active profile")
    p_set.add_argument("profile_id")
    args = parser.parse_args()
    handlers = {
        "load": cmd_load,
        "templates": cmd_templates,
        "list": cmd_list,
        "active": cmd_active,
        "set-active": cmd_set_active,
    }
    try:
        return handlers[args.cmd](args)
    except Exception as e:
        print(json.dumps({"error": str(e)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
