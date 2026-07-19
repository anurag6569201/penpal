"""
Django settings for Penpal brain (Gemini).
"""

from pathlib import Path
import os
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")

def _flag(name: str, default: str = "false") -> bool:
    return os.getenv(name, default).strip().lower() in ("1", "true", "yes")


# PEN-25 — SECURE BY DEFAULT.
#
# This used to default to DEBUG=true, ALLOWED_HOSTS=["*"] and open CORS, so
# forgetting a single env var in production exposed everything. The default is
# now locked down; the permissive LAN setup is an explicit opt-in:
#
#     PENPAL_DEV=1 python manage.py runserver 0.0.0.0:8000
#
# The failure mode is inverted on purpose. Forgetting the flag now breaks your
# phone's connection — annoying and instantly obvious. The old default failed
# silently and unsafely, which is the one thing a security default must not do.
DEV_MODE = _flag("PENPAL_DEV")
DEBUG = DEV_MODE or _flag("DJANGO_DEBUG")

# NOTE: every security-critical decision below keys off DEV_MODE, never
# DEBUG. `.env` sets DJANGO_DEBUG and load_dotenv puts it in the environment,
# so a deployment that accidentally ships its .env would otherwise re-enable
# debug — and with it the insecure fallbacks — without anyone noticing.
# DEV_MODE can only be turned on from the command line, deliberately.
SECRET_KEY = os.getenv("DJANGO_SECRET_KEY", "")
if not SECRET_KEY:
    if DEV_MODE:
        SECRET_KEY = "django-insecure-dev-only-change-me"
    else:
        raise RuntimeError(
            "DJANGO_SECRET_KEY must be set when not running in dev mode. "
            "Generate one with: python -c "
            "'from django.core.management.utils import get_random_secret_key; "
            "print(get_random_secret_key())'"
        )

_raw_hosts = [
    h.strip()
    for h in os.getenv("ALLOWED_HOSTS", "localhost,127.0.0.1,0.0.0.0").split(",")
    if h.strip()
]
# Only dev mode gets the wildcard, so a phone can reach the Mac's LAN IP
# without editing .env every time the address changes.
ALLOWED_HOSTS = ["*"] if DEV_MODE else _raw_hosts

# Production hardening. Keyed off DEV_MODE for the reason above: a stray
# DJANGO_DEBUG=true in a shipped .env must not silently disable this.
if not DEV_MODE:
    SECURE_CONTENT_TYPE_NOSNIFF = True
    SECURE_REFERRER_POLICY = "same-origin"
    SESSION_COOKIE_SECURE = True
    CSRF_COOKIE_SECURE = True
    X_FRAME_OPTIONS = "DENY"
    if _flag("PENPAL_HTTPS", "true"):
        SECURE_SSL_REDIRECT = True
        SECURE_HSTS_SECONDS = 31536000
        SECURE_HSTS_INCLUDE_SUBDOMAINS = True

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "corsheaders",
    "rest_framework",
    "chat",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "corsheaders.middleware.CorsMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "backend.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "backend.wsgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": BASE_DIR / "db.sqlite3",
    }
}

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

LANGUAGE_CODE = "en-us"
TIME_ZONE = "UTC"
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# iOS Simulator / device talking to local Django. Wide-open CORS is dev-only;
# in production the allowed origins must be named explicitly.
CORS_ALLOW_ALL_ORIGINS = DEV_MODE
CORS_ALLOWED_ORIGINS = [
    o.strip() for o in os.getenv("CORS_ALLOWED_ORIGINS", "").split(",") if o.strip()
]
CORS_ALLOW_HEADERS = [
    "accept",
    "accept-encoding",
    "authorization",
    "content-type",
    "dnt",
    "origin",
    "user-agent",
    "x-csrftoken",
    "x-requested-with",
    "x-conversation-id",
]

REST_FRAMEWORK = {
    "DEFAULT_RENDERER_CLASSES": [
        "rest_framework.renderers.JSONRenderer",
    ],
    "DEFAULT_PARSER_CLASSES": [
        "rest_framework.parsers.JSONParser",
    ],
    "UNAUTHENTICATED_USER": None,
}

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "")
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-2.5-flash")
# PEN-29 — cheaper model for problems the CAS has already solved exactly.
# Defaults to empty, which routes everything to GEMINI_MODEL: the saving is
# opt-in, so nobody gets a quietly weaker answer without choosing it.
GEMINI_FAST_MODEL = os.getenv("GEMINI_FAST_MODEL", "")

# PEN-26 — access control.
#
# Comma-separated shared tokens. When empty AND dev mode is on, the API stays
# open for LAN testing. When empty and dev mode is OFF, the app refuses to
# start rather than quietly serving an unauthenticated, quota-spending API.
PENPAL_TOKENS = {
    t.strip() for t in os.getenv("PENPAL_TOKENS", "").split(",") if t.strip()
}
if not PENPAL_TOKENS and not DEV_MODE:
    raise RuntimeError(
        "PENPAL_TOKENS must be set when not running in dev mode — otherwise "
        "anyone who can reach this server can spend your Gemini quota. "
        "Set PENPAL_TOKENS=<random-string> (and the same value in the app), "
        "or run with PENPAL_DEV=1 for local testing."
    )

# Per-token limits. Solve requests are the expensive ones (solve + verify,
# sometimes + correction), so they get their own tighter budget.
RATE_LIMIT_PER_MINUTE = int(os.getenv("RATE_LIMIT_PER_MINUTE", "20"))
RATE_LIMIT_PER_DAY = int(os.getenv("RATE_LIMIT_PER_DAY", "500"))
