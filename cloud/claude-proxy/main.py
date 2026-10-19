"""Holds the real Anthropic key server-side so the app never ships it.

The app POSTs the same body it used to send straight to Anthropic; this
just checks a shared-secret header, adds the real x-api-key, and forwards
to api.anthropic.com. See DEPLOY.md.
"""

import json
import os
import urllib.error
import urllib.request

import functions_framework

ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
ANTHROPIC_VERSION = "2023-06-01"
MAX_BODY_BYTES = 8 * 1024 * 1024  # a cropped shelf JPEG is a few hundred KB


@functions_framework.http
def claude_proxy(request):
    if request.method != "POST":
        return ("Method not allowed", 405)

    # Not real auth — just a deterrent against drive-by hits on the bare
    # URL. The actual cost backstop is the spend limit on the Anthropic
    # key itself (console.anthropic.com -> Settings -> Limits).
    app_secret = os.environ.get("APP_SHARED_SECRET", "").strip()
    sent_secret = (request.headers.get("X-App-Secret") or "").strip()
    if app_secret and sent_secret != app_secret:
        return ("Forbidden", 403)

    body = request.get_data()
    if len(body) > MAX_BODY_BYTES:
        return ("Payload too large", 413)

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        return (json.dumps({"error": "server misconfigured"}), 500, {"Content-Type": "application/json"})

    req = urllib.request.Request(
        ANTHROPIC_URL,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": ANTHROPIC_VERSION,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=55) as resp:
            return (resp.read(), resp.status, {"Content-Type": "application/json"})
    except urllib.error.HTTPError as e:
        return (e.read(), e.code, {"Content-Type": "application/json"})
    except Exception as e:  # network blip, Anthropic down, etc.
        return (json.dumps({"error": str(e)}), 502, {"Content-Type": "application/json"})
