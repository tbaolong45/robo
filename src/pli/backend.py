"""The calendar I/O seam.

`planner/apply.py` reconciles planned blocks against whatever calendar it is
given. That logic - the ledger, drift detection, adoption of orphaned events,
"never delete what is not ours" - is the part that must not be got wrong, and
none of it cares how the calendar is reached.

So the I/O is narrowed to these four calls. The browser backend implements them
by driving the Outlook web UI; tests implement them with a dictionary. Nothing
above this line knows which is which.

Every datetime crossing this boundary is timezone-aware UTC, per `pli.models`.
A backend is responsible for converting to whatever the calendar surface wants
and back; it must not leak a naive or local datetime upward.
"""

from __future__ import annotations

from datetime import datetime
from typing import Protocol, runtime_checkable

from pli.models import Block, RemoteEvent


@runtime_checkable
class CalendarBackend(Protocol):
    """Read and write a single calendar."""

    def list_events(self, start: datetime, end: datetime) -> list[RemoteEvent]:
        """Every event in [start, end), including ones this tool did not create.

        Both jobs depend on this being complete: the writer reconciles against
        it, and the free/busy pass treats it as the set of things that block
        study time. A backend that silently drops an event - a paginated view
        that stopped early, a filter that excluded a series - produces a plan
        that double-books the user's afternoon.
        """
        ...

    def create_event(self, block: Block) -> str:
        """Create `block` and return the calendar's own id for it.

        Called only for a block `CalendarWriter` could not find an event for:
        the writer reads the calendar and adopts by `block_key` before it
        creates anything (see `CalendarWriter.apply`), so an implementer needs
        no lookup of its own. That the ownership of this guarantee is the
        writer's is not a detail - the browser backend never implemented the
        per-key check this docstring used to require, and the test double did,
        so the double hid a real duplicate until the writer took it on.
        """
        ...

    def update_event(self, remote_id: str, block: Block) -> None:
        """Move or rename an existing event to match `block`."""
        ...

    def delete_event(self, remote_id: str) -> None:
        """Delete one event. Only ever called for events carrying our marker."""
        ...
