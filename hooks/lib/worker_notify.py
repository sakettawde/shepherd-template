"""Notification hook: one record per notification, kind on stdout for the
shell wrapper's toast decision. See shepherd_status.py."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shepherd_status as st  # noqa: E402


def main():
    data, why = st.read_input()
    if why:
        st.hook_error("notify", why)
        return 0
    kind = (data.get("notification_type") or data.get("matcher")
            or data.get("hook_event_name") or "unknown")
    # The docs show the body in two shapes for this one event: flat
    # `message`/`title` and nested under `notification_data` (Notification
    # reference, https://code.claude.com/docs/en/hooks, read 2026-08-23 and
    # re-read 2026-09-02). Read both - the kind alone does not say WHICH
    # permission, and that is what the operator needs.
    nested = data.get("notification_data")
    nested = nested if isinstance(nested, dict) else {}
    message = (data.get("message") or data.get("title")
               or nested.get("message") or nested.get("title") or "")
    st.emit("notify", st.record("notification", kind=str(kind), message=st.clip(message, 200)))
    sys.stdout.write(str(kind))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - report, never block the worker
        st.hook_error("notify", "unexpected: %r" % (exc,))
        sys.exit(0)
