"""A small interactive agent that reads what you point it at and tells you what matters.

Read-only by construction: there is no tool here that writes to a mailbox, a calendar or
an outside tracker. The only things it writes are its own notes on this computer (the
deadline list you tick off, and the counts `pli watch` keeps), in files only you can read.
Code owns the loop, Jev only picks from lists code supplied, and mail text never reaches
the step that chooses what to do next.
"""
