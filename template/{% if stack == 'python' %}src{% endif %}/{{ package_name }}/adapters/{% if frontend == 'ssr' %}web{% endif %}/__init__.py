"""Web UI adapter (driving side, ADR 0005).

Server-rendered HTML form over the same use case as the other adapters: decodes and validates
the form, checks the CSRF token, calls the use case and renders the result. No business rules here.
"""
