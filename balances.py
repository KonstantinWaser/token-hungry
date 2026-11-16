#!/usr/bin/env python3
# Plugins for providers that bill per token and have an API to ask what money
# is left. Each provider is one entry in PROVIDERS and one two-line plugin file
# (see deepseekusage.5m.py) that calls show() with its name.
#
# An entry has the environment variable holding the API key, the URL to ask
# with it as a Bearer token, a function from the answer to (currency, amount)
# pairs and whether the money still covers calls, the page to manage it on
# and the icon its Minecraft stack starts with (see minecraft.CURRENCIES).
import contextlib
import io
import json
import os
import urllib.request

import minecraft

PROVIDERS = {
    # https://api-docs.deepseek.com/api/get-user-balance
    "DeepSeek": dict(
        key="DEEPSEEK_API_KEY",
        url="https://api.deepseek.com/user/balance",
        read=lambda answer: ([(i["currency"], i["total_balance"]) for i in answer["balance_infos"]],
                             answer["is_available"]),
        page="https://platform.deepseek.com/usage",
        icon="emerald",
    ),
    # https://openrouter.ai/docs/api-reference/get-credits (needs a management key)
    "OpenRouter": dict(
        key="OPENROUTER_API_KEY",
        url="https://openrouter.ai/api/v1/credits",
        read=lambda answer: ([("USD", answer["data"]["total_credits"] - answer["data"]["total_usage"])],
                             answer["data"]["total_credits"] > answer["data"]["total_usage"]),
        page="https://openrouter.ai/settings/credits",
        icon="gold_ingot",
    ),
}
SYMBOLS = {"USD": "$", "CNY": "¥", "EUR": "€"}
GREEN, RED = "#22c55e", "#ef4444"


def money(currency, value):
    return f"{SYMBOLS.get(currency, currency + ' ')}{float(value):.2f}"


# Prints the menu: the title shows the first balance, red once the provider
# says the money no longer covers calls.
def render(name, balances, available):
    color = GREEN if available else RED
    total = money(*balances[0]) if balances else "?"
    print(f"{name[0]} {total} | color={color}")
    print("---")
    for currency, value in balances:
        print(f"{'Balance':<10}{money(currency, value):>10} | font=Menlo size=13 color={color}")


def show(name):
    provider = PROVIDERS[name]
    with contextlib.redirect_stdout(io.StringIO()) as output:
        try:
            key = os.environ.get(provider["key"])
            if not key:
                raise RuntimeError(f"Set {provider['key']} to your {name} API key")
            request = urllib.request.Request(provider["url"], headers={"Authorization": f"Bearer {key}"})
            with urllib.request.urlopen(request, timeout=20) as response:
                render(name, *provider["read"](json.load(response)))
            print("---")
            print(f"Usage | href={provider['page']}")
        except Exception as error:
            print(f"{name[0]} ⚠︎")
            print("---")
            print(error)
        print("Refresh | refresh=true")
    print(minecraft.menu(name, output.getvalue(), provider["icon"]), end="")
