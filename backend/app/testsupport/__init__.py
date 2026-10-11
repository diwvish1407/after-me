"""Test support (TEST_PLAN §2): a movable clock and a mail reader for integration tests.

Everything here is off unless ``AFTERME_TEST_SUPPORT_ENABLED`` is set, and configuration refuses
it in production. With it on, the API **and** the worker run on :class:`OffsetDbClock`, so a test
that moves the clock moves it for both. It exists so that the real app can be driven through a
whole lifecycle (a missed check-in, a stage, an I'M SAFE) in minutes instead of days.
"""
