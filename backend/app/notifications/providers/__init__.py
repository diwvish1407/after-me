"""Real providers behind the email and push interfaces (ARCHITECTURE §4.7).

Every adapter turns its provider's answers into one of the four error kinds of
:mod:`app.notifications.errors`, so the dispatcher never has to know which provider it is
talking to, and never sees an address, a token or a message body in an error.
"""
