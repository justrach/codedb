---
schema_version: 1
generated_at: 2026-05-21T00:00:00Z
generator: claude-sonnet-4-6
source_hash: blake2b:f2ce20335b78425f462c0fb1da4d3596
source_files:
  - src/flask/app.py
  - src/flask/__init__.py
  - src/flask/globals.py
  - src/flask/ctx.py
  - src/flask/sansio/app.py
  - src/flask/sansio/scaffold.py
  - src/flask/sansio/blueprints.py
  - src/flask/wrappers.py
  - src/flask/helpers.py
  - src/flask/sessions.py
loc_budget: 200
loc_actual: 107
---

# flask

WSGI micro-web-framework. `Flask(__name__)` is the application object, a WSGI callable built on werkzeug. Routing is decorator-driven; `Blueprint` provides namespace-scoped grouping of routes, error handlers, and template filters that register onto the app at startup.

## Layout

- `src/flask/` — installable package; `__init__.py` is the public re-export surface
  - `app.py` — `Flask` class (WSGI callable, request dispatch, context lifecycle)
  - `globals.py` — `current_app`, `request`, `session`, `g` (thread-local `LocalProxy` wrappers over `ContextVar`)
  - `ctx.py` — `AppContext` / `RequestContext`; pushed per-request, carries `g` and session
  - `blueprints.py` — thin shim; real logic in `sansio/blueprints.py`
  - `wrappers.py` — `Request` / `Response` subclassing werkzeug equivalents
  - `helpers.py` — `url_for`, `redirect`, `abort`, `flash`, `send_file`, `make_response`
  - `sessions.py` — `SessionInterface` + default `SecureCookieSession` (itsdangerous signed cookie)
  - `templating.py` — Jinja2 `Environment` subclass, `render_template`, `stream_template`
  - `cli.py` — Click-based `flask` CLI (`run`, `shell`, `routes`, custom commands via `@app.cli.command`)
  - `config.py` — `Config` (dict subclass) + `ConfigAttribute` descriptor
  - `sansio/` — I/O-agnostic base layer shared by sync and async Flask
    - `scaffold.py` — `Scaffold` base: route/error/hook registration, `@route`, `@before_request`, etc.
    - `app.py` — `App(Scaffold)`: URL map, blueprint registry, Jinja env wiring
    - `blueprints.py` — `Blueprint(Scaffold)` + `BlueprintSetupState` (deferred registration)
- `tests/` — pytest suite; `test_basic.py` (1971 L) covers the widest surface
- `examples/tutorial/flaskr/` — canonical "Flaskr" blog reference app

## Key concepts

- **Context locals** — `request`, `session`, `g`, `current_app` are `werkzeug.local.LocalProxy` objects backed by a `ContextVar[AppContext]`. Accessing them outside a pushed context raises `RuntimeError`.
- **Single merged context** — Flask 3.x collapsed `AppContext` and `RequestContext` into one `AppContext` object. `app_ctx` in `globals.py` holds both.
- **Dispatch pipeline** — `wsgi_app` pushes `AppContext`, calls `full_dispatch_request` → `preprocess_request` → `dispatch_request` → view → `process_response` → `ctx.pop()`. Each step is overridable.
- **Scaffold/App split** — `Scaffold` holds decorator-registration logic (identical for `Flask` and `Blueprint`). `App(Scaffold)` adds URL map + config. `Flask(App)` adds the WSGI execution layer. Blueprints defer registrations via `BlueprintSetupState` until `register_blueprint` is called.
- **`setupmethod` guard** — methods decorated with `@setupmethod` raise if called after first request, preventing accidental runtime mutation of routing tables.
- **Session interface** — swappable via `app.session_interface`; default uses itsdangerous to sign a cookie. Implement `open_session`/`save_session` to replace.
- **Error handlers** — registered per exception class (or HTTP code) on `Scaffold`. Blueprint error handlers scope to their blueprint unless registered with `app_errorhandler`.

## Entry points

- **Add a route** — `@app.route("/path")` or `app.add_url_rule()`; start in `sansio/scaffold.py:Scaffold.route`
- **Add a Blueprint** — define `Blueprint(__name__)`, add routes, then `app.register_blueprint(bp)` in the factory; see `sansio/blueprints.py:Blueprint.register`
- **Extend request lifecycle** — `@app.before_request` / `@app.after_request` in `sansio/scaffold.py`
- **Write a test** — `app.test_client()` returns `FlaskClient`; use `with app.test_request_context()` for context-only tests; see `tests/conftest.py`
- **Custom CLI command** — `@app.cli.command()` or `@app.cli.group()`; entry in `cli.py`
- **Replace session backend** — subclass `SessionInterface`, assign to `app.session_interface`

## Conventions

- `sansio/` modules must not import `wsgiref`, `socket`, or any I/O — sync/async agnostic
- `TYPE_CHECKING` guards on circular imports are pervasive; don't lift them
- Blueprint-scoped hooks use `self.{before,after}_request_funcs[self.name]`; app-scoped use `None` as the key
- Tests follow `test_<module>.py`; fixtures live in `tests/conftest.py`
- Public re-exports are exhaustive in `src/flask/__init__.py` — if it's not there, it's internal
