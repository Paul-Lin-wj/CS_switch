"""Tests for multi-provider prefix routing and model resolution."""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'proxy'))

import provider_policy


def test_parse_prefixed_model():
    """Test model ID prefix parsing."""
    # With valid prefix
    assert provider_policy.parse_prefixed_model("ds-claude-opus-4-8") == ("ds", "claude-opus-4-8")
    assert provider_policy.parse_prefixed_model("qw-claude-haiku-4-5") == ("qw", "claude-haiku-4-5")
    assert provider_policy.parse_prefixed_model("km-claude-sonnet-5") == ("km", "claude-sonnet-5")
    assert provider_policy.parse_prefixed_model("rl-gpt-4o") == ("rl", "gpt-4o")
    # Without prefix (bare claude-*)
    assert provider_policy.parse_prefixed_model("claude-opus-4-8") == (None, "claude-opus-4-8")
    assert provider_policy.parse_prefixed_model("claude-haiku-4-5") == (None, "claude-haiku-4-5")
    # Edge cases
    assert provider_policy.parse_prefixed_model("") == (None, "")
    assert provider_policy.parse_prefixed_model(None) == (None, None)
    # Not a real prefix
    assert provider_policy.parse_prefixed_model("xx-claude-opus-4-8") == (None, "xx-claude-opus-4-8")


def test_strip_prefix():
    """Test prefix stripping."""
    assert provider_policy.strip_prefix("ds-claude-opus-4-8", "ds") == "claude-opus-4-8"
    assert provider_policy.strip_prefix("qw-claude-haiku-4-5", "qw") == "claude-haiku-4-5"
    assert provider_policy.strip_prefix("claude-opus-4-8", "ds") == "claude-opus-4-8"  # no prefix
    assert provider_policy.strip_prefix("", "ds") == ""


def test_prefix_coverage():
    """All 9 providers have unique prefixes."""
    prefixes = list(provider_policy.PROVIDER_PREFIXES.values())
    assert len(prefixes) == len(set(prefixes)), "duplicate prefixes"
    assert len(prefixes) == 9


def test_prefix_to_template_reverse():
    """PREFIX_TO_TEMPLATE is the exact reverse of PROVIDER_PREFIXES."""
    for tpl, pfx in provider_policy.PROVIDER_PREFIXES.items():
        assert provider_policy.PREFIX_TO_TEMPLATE[pfx] == tpl


def test_resolve_model_single_provider():
    """resolve_model works correctly in single-provider mode (backward compat)."""
    state = provider_policy.ProviderState(
        policy=provider_policy.Policy(
            passthrough=False,
            force_model_override=False,
            default_model="deepseek-v4-flash",
            model_map={
                "claude-opus-4-8": "deepseek-v4-pro",
                "claude-haiku-4-5": "deepseek-v4-flash",
            },
            models=[("claude-opus-4-8", "DeepSeek V4 Pro")],
            model_caps={},
            default_cap=None,
        ),
        prov_name="deepseek",
        relay_force_model=None,
        relay_models=[],
        relay_thinking=None,
        shim_mode="off",
    )
    assert provider_policy.resolve_model("claude-opus-4-8", state) == "deepseek-v4-pro"
    assert provider_policy.resolve_model("claude-haiku-4-5", state) == "deepseek-v4-flash"
    assert provider_policy.resolve_model("claude-sonnet-5", state) == "deepseek-v4-flash"
    assert provider_policy.resolve_model(None, state) == "deepseek-v4-flash"
    assert provider_policy.resolve_model("unknown-model", state) == "deepseek-v4-flash"


def test_resolve_model_with_prefix_stripping():
    """After prefix stripping, resolve_model should work as if bare model was passed."""
    state = provider_policy.ProviderState(
        policy=provider_policy.Policy(
            passthrough=False,
            force_model_override=False,
            default_model="qwen-plus",
            model_map={
                "claude-opus-4-8": "qwen-max",
                "claude-haiku-4-5": "qwen-turbo",
            },
            models=[("claude-opus-4-8", "Qwen Max")],
            model_caps={},
            default_cap=None,
        ),
        prov_name="qwen",
        relay_force_model=None,
        relay_models=[],
        relay_thinking=None,
        shim_mode="off",
    )
    # Simulate multi-provider: prefix stripped before calling resolve_model
    _, bare = provider_policy.parse_prefixed_model("qw-claude-opus-4-8")
    assert bare == "claude-opus-4-8"
    assert provider_policy.resolve_model(bare, state) == "qwen-max"


def test_resolve_model_relay_passthrough():
    """Relay mode: resolve_model passes through model names."""
    state = provider_policy.ProviderState(
        policy=provider_policy.Policy(
            passthrough=True,
            force_model_override=False,
            default_model="claude-opus-4-8",
            model_map={},
            models=[],
            model_caps={},
            default_cap=None,
        ),
        prov_name="relay",
        relay_force_model=None,
        relay_models=["claude-opus-4-8-20250101", "claude-haiku-4-5-20250101"],
        relay_thinking=None,
        shim_mode="off",
    )
    # Should snap to real upstream model
    result = provider_policy.resolve_model("claude-opus-4-8", state)
    assert result == "claude-opus-4-8-20250101"


if __name__ == "__main__":
    test_parse_prefixed_model()
    test_strip_prefix()
    test_prefix_coverage()
    test_prefix_to_template_reverse()
    test_resolve_model_single_provider()
    test_resolve_model_with_prefix_stripping()
    test_resolve_model_relay_passthrough()
    print("ALL MULTI-PROVIDER TESTS PASSED")


def test_model_route_cross_provider():
    """MODEL_ROUTE maps specific claude-* models to different providers."""
    import csswitch_proxy
    # Simulate multi-mode setup
    csswitch_proxy.MULTI_MODE = True
    csswitch_proxy.MODEL_ROUTE = {
        "claude-opus-4-8": {"prefix": "km", "target_model": "kimi-for-coding"},
        "claude-sonnet-5": {"prefix": "rl", "target_model": "mimo-v2.5-pro"},
        "claude-haiku-4-5-20251001": {"prefix": "rl", "target_model": "mimo-v2.5"},
    }
    csswitch_proxy.DEFAULT_PREFIX = "rl"
    csswitch_proxy.MULTI_REGISTRY = {
        "km": {"prov_name": "kimi"},
        "rl": {"prov_name": "relay"},
    }

    # Simulate _handle_multi routing logic (extracted for unit test)
    def route(model_id):
        prefix, bare_model = provider_policy.parse_prefixed_model(model_id)
        if not prefix:
            route_entry = csswitch_proxy.MODEL_ROUTE.get(model_id)
            if route_entry:
                prefix = route_entry["prefix"]
                bare_model = route_entry["target_model"]
            else:
                prefix = csswitch_proxy.DEFAULT_PREFIX
        return prefix, bare_model

    # Test cross-provider routing
    assert route("claude-opus-4-8") == ("km", "kimi-for-coding")
    assert route("claude-sonnet-5") == ("rl", "mimo-v2.5-pro")
    assert route("claude-haiku-4-5-20251001") == ("rl", "mimo-v2.5")
    # Prefix overrides still work
    assert route("km-claude-sonnet-5") == ("km", "claude-sonnet-5")
    assert route("rl-claude-opus-4-8") == ("rl", "claude-opus-4-8")
    # Unknown bare model falls back to default
    assert route("claude-unknown") == ("rl", "claude-unknown")

    # Cleanup
    csswitch_proxy.MULTI_MODE = False
    csswitch_proxy.MODEL_ROUTE = {}
    csswitch_proxy.MULTI_REGISTRY = {}
    csswitch_proxy.DEFAULT_PREFIX = ""


if __name__ == "__main__":
    test_parse_prefixed_model()
    test_strip_prefix()
    test_prefix_coverage()
    test_prefix_to_template_reverse()
    test_resolve_model_single_provider()
    test_resolve_model_with_prefix_stripping()
    test_resolve_model_relay_passthrough()
    test_model_route_cross_provider()
    print("ALL MULTI-PROVIDER TESTS PASSED")
