#!/usr/bin/env python3
"""CSSwitch-Linux CLI config helper. Reads/writes ~/.csswitch/config.json (schema v3)."""
import argparse
import json
import os
import sys
import uuid
from pathlib import Path
from tempfile import mkstemp

CURRENT_SCHEMA_VERSION = 3

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

# Static prefix map for multi-provider model ID namespacing.
# Each template_id gets a unique 2-char prefix prepended to model IDs in the
# Science model selector, enabling in-session provider switching.
PROVIDER_PREFIXES = {
    "deepseek": "ds",
    "qwen": "qw",
    "kimi": "km",
    "minimax": "mx",
    "glm": "gl",
    "openrouter": "or",
    "openai-custom": "oc",
    "openai-responses": "rs",
    "relay": "rl",
}

def prefix_for_template(template_id: str) -> str:
    """Return the 2-char model ID prefix for a template, or first 2 chars as fallback."""
    return PROVIDER_PREFIXES.get(template_id, template_id[:2].lower())


def templates_by_id():
    """Return templates indexed by id."""
    return {t["id"]: t for t in DEFAULT_TEMPLATES}


def config_path():
    return Path(os.environ.get("CSSWITCH_CONFIG", Path.home() / ".csswitch" / "config.json"))


def ensure_dir(path: Path):
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def assert_no_symlink_in_path(path: Path):
    for p in list(path.parents) + [path]:
        if p.is_symlink():
            raise ValueError(f"Refusing to follow symlink: {p}")


def load_config():
    p = config_path()
    assert_no_symlink_in_path(p)
    if not p.exists():
        return default_config()
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
        # Multi-provider fields (schema v3):
        # active_providers: list of profile IDs to expose simultaneously
        # default_provider: profile ID for bare claude-* requests (Science internals)
        "active_providers": [],
        "default_provider": "",
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
    p = config_path()
    cfg = load_config()
    if not p.exists():
        save_config(cfg)
    print(json.dumps(cfg, ensure_ascii=False))
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


def mask_key(k):
    if len(k) <= 4:
        return "****" if k else ""
    return "*" * (len(k) - 4) + k[-4:]


def cmd_add(args):
    cfg = load_config()
    tpl = next((t for t in DEFAULT_TEMPLATES if t["id"] == args.template), None)
    if tpl is None:
        print(json.dumps({"error": f"unknown template: {args.template}"}, ensure_ascii=False))
        return 1
    base_url = (args.base_url if args.base_url is not None else tpl["base_url"]).strip()
    model = (args.model or "").strip()
    if tpl["requires_model"] and not model:
        print(json.dumps({"error": "model is required for this provider"}, ensure_ascii=False))
        return 1
    if tpl["base_url_editable"] and not base_url:
        print(json.dumps({"error": "base_url is required for this provider"}, ensure_ascii=False))
        return 1
    profile = {
        "id": str(uuid.uuid4()),
        "name": args.name,
        "template_id": tpl["id"],
        "category": tpl["category"],
        "api_format": tpl["api_format"],
        "base_url": base_url,
        "api_key": args.key or "",
        "model": model,
        "website_url": None,
        "icon": None,
        "icon_color": None,
        "sort_index": None,
        "created_at": None,
        "notes": None,
    }
    cfg["profiles"].append(profile)
    cfg["active_id"] = profile["id"]
    save_config(cfg)
    out = {k: v for k, v in profile.items() if k != "api_key"}
    out["key"] = mask_key(profile["api_key"])
    print(json.dumps(out, ensure_ascii=False))
    return 0


def cmd_edit(args):
    cfg = load_config()
    profile = next((p for p in cfg.get("profiles", []) if p["id"] == args.profile_id), None)
    if profile is None:
        print(json.dumps({"error": f"profile not found: {args.profile_id}"}, ensure_ascii=False))
        return 1
    if args.name is not None:
        profile["name"] = args.name
    if args.base_url is not None:
        profile["base_url"] = args.base_url.strip()
    if args.model is not None:
        profile["model"] = args.model.strip()
    if args.key is not None and args.key != "":
        profile["api_key"] = args.key
    save_config(cfg)
    out = {k: v for k, v in profile.items() if k != "api_key"}
    out["key"] = mask_key(profile["api_key"])
    print(json.dumps(out, ensure_ascii=False))
    return 0


def cmd_delete(args):
    cfg = load_config()
    before = len(cfg.get("profiles", []))
    cfg["profiles"] = [p for p in cfg.get("profiles", []) if p["id"] != args.profile_id]
    if len(cfg["profiles"]) == before:
        print(json.dumps({"error": f"profile not found: {args.profile_id}"}, ensure_ascii=False))
        return 1
    if cfg.get("active_id") == args.profile_id:
        cfg["active_id"] = ""
    save_config(cfg)
    print(json.dumps({"ok": True}, ensure_ascii=False))
    return 0


def cmd_set_secret(args):
    cfg = load_config()
    cfg["secret"] = args.secret
    save_config(cfg)
    print(json.dumps({"ok": True}, ensure_ascii=False))
    return 0


def cmd_set_active_providers(args):
    """Set which profiles are active in multi-provider mode."""
    cfg = load_config()
    ids = {p["id"] for p in cfg.get("profiles", [])}
    requested = [x.strip() for x in args.profile_ids.split(",") if x.strip()]
    for pid in requested:
        if pid not in ids:
            print(json.dumps({"error": f"profile not found: {pid}"}, ensure_ascii=False))
            return 1
    cfg["active_providers"] = requested
    if not cfg.get("default_provider") or cfg["default_provider"] not in requested:
        cfg["default_provider"] = requested[0] if requested else ""
    cfg["mode"] = "multi" if len(requested) > 1 else "proxy"
    save_config(cfg)
    print(json.dumps({"ok": True, "active_providers": requested,
                       "default_provider": cfg["default_provider"],
                       "mode": cfg["mode"]}, ensure_ascii=False))
    return 0


def cmd_set_default_provider(args):
    """Set which profile handles bare claude-* requests in multi-provider mode."""
    cfg = load_config()
    ids = {p["id"] for p in cfg.get("profiles", [])}
    if args.profile_id not in ids:
        print(json.dumps({"error": f"profile not found: {args.profile_id}"}, ensure_ascii=False))
        return 1
    cfg["default_provider"] = args.profile_id
    save_config(cfg)
    print(json.dumps({"ok": True, "default_provider": args.profile_id}, ensure_ascii=False))
    return 0


def cmd_multi_config(args):
    """Return the full multi-provider config for the proxy launcher.

    Output includes all active provider profiles with their templates,
    prefix assignments, and the default provider ID.
    """
    cfg = load_config()
    templates = templates_by_id()
    profiles_by_id = {p["id"]: p for p in cfg.get("profiles", [])}
    active_ids = cfg.get("active_providers", [])
    # 清理指向不存在 profile 的过期 ID
    active_ids = [pid for pid in active_ids if pid in profiles_by_id]
    if not active_ids:
        # 回退到 active_id
        aid = cfg.get("active_id", "")
        if aid and aid in profiles_by_id:
            active_ids = [aid]
    providers = []
    for pid in active_ids:
        prof = profiles_by_id.get(pid)
        if not prof:
            continue
        tpl = templates.get(prof.get("template_id", ""), {})
        prefix = prefix_for_template(prof.get("template_id", ""))
        providers.append({
            "profile_id": pid,
            "name": prof.get("name", ""),
            "template_id": prof.get("template_id", ""),
            "adapter": tpl.get("adapter", prof.get("template_id", "")),
            "api_format": tpl.get("api_format", "anthropic"),
            "base_url": prof.get("base_url", ""),
            "api_key": prof.get("api_key", ""),
            "model": prof.get("model", ""),
            "key_env": tpl.get("key_env", ""),
            "prefix": prefix,
            "models": tpl.get("builtin_models", []),
            "base_url_editable": tpl.get("base_url_editable", False),
            "requires_model": tpl.get("requires_model", False),
        })
    default_pid = cfg.get("default_provider", "") or cfg.get("active_id", "") or (active_ids[0] if active_ids else "")
    # 如果 default_provider 指向不存在的 profile，回退到 active_id 或第一个 active provider
    if default_pid not in profiles_by_id:
        default_pid = cfg.get("active_id", "") or (active_ids[0] if active_ids else "")
    default_prefix = ""
    if default_pid in profiles_by_id:
        default_prefix = prefix_for_template(profiles_by_id[default_pid].get("template_id", ""))
    result = {
        "mode": cfg.get("mode", "proxy"),
        "proxy_port": cfg.get("proxy_port", 18991),
        "sandbox_port": cfg.get("sandbox_port", 8990),
        "secret": cfg.get("secret", ""),
        "default_provider": default_pid,
        "default_prefix": default_prefix,
        "providers": providers,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
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

    p_add = sub.add_parser("add", help="add a new profile")
    p_add.add_argument("--template", required=True)
    p_add.add_argument("--name", required=True)
    p_add.add_argument("--key", default="")
    p_add.add_argument("--base-url", default=None)
    p_add.add_argument("--model", default="")

    p_edit = sub.add_parser("edit", help="edit a profile")
    p_edit.add_argument("profile_id")
    p_edit.add_argument("--name", default=None)
    p_edit.add_argument("--key", default=None)
    p_edit.add_argument("--base-url", default=None)
    p_edit.add_argument("--model", default=None)

    p_del = sub.add_parser("delete", help="delete a profile")
    p_del.add_argument("profile_id")

    p_secret = sub.add_parser("set-secret", help="set the proxy auth secret")
    p_secret.add_argument("--secret", required=True)

    p_sap = sub.add_parser("set-active-providers", help="set active providers for multi-provider mode")
    p_sap.add_argument("profile_ids", help="comma-separated profile IDs")

    p_sdp = sub.add_parser("set-default-provider", help="set default provider for bare claude-* requests")
    p_sdp.add_argument("profile_id")

    sub.add_parser("multi-config", help="return multi-provider config for proxy launcher")

    args = parser.parse_args()
    handlers = {
        "load": cmd_load,
        "templates": cmd_templates,
        "list": cmd_list,
        "active": cmd_active,
        "set-active": cmd_set_active,
        "add": cmd_add,
        "edit": cmd_edit,
        "delete": cmd_delete,
        "set-secret": cmd_set_secret,
        "set-active-providers": cmd_set_active_providers,
        "set-default-provider": cmd_set_default_provider,
        "multi-config": cmd_multi_config,
    }
    try:
        return handlers[args.cmd](args)
    except Exception as e:
        print(json.dumps({"error": str(e)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
