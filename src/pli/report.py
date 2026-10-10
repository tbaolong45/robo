"""Human-readable output: a rich table for the terminal, markdown for a file."""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Sequence
from datetime import datetime
from zoneinfo import ZoneInfo

from rich.console import Console
from rich.markup import escape
from rich.table import Table

from pli.models import Block, Slot, Task
from pli.planner.pack import PackResult

console = Console()


def _fmt(block: Block, tz: ZoneInfo) -> tuple[str, str]:
    start = block.start.astimezone(tz)
    end = block.end.astimezone(tz)
    return start.strftime("%H:%M"), end.strftime("%H:%M")


def render_plan(result: PackResult, *, tz: ZoneInfo, title: str = "Study week") -> None:
    by_day: dict[str, list[Block]] = defaultdict(list)
    for block in sorted(result.blocks, key=lambda b: b.start):
        by_day[block.start.astimezone(tz).strftime("%A %d %B")].append(block)

    table = Table(title=title, show_lines=False, header_style="bold")
    table.add_column("When", no_wrap=True)
    table.add_column("What")
    table.add_column("Min", justify="right", no_wrap=True)

    for day, blocks in by_day.items():
        table.add_row(f"[bold]{day}[/bold]", "", "")
        for block in blocks:
            start, end = _fmt(block, tz)
            # The subject is course and title run together, and a Rich *table
            # cell* parses markup just as an f-string does - a course called
            # "[revision] Probability" prints as " Probability" otherwise. Every
            # cell carrying data from Moodle or Teams is escaped for that reason;
            # `[bold]{day}[/bold]` above is the tool's own text and is not.
            table.add_row(f"  {start}-{end}", escape(block.subject), str(block.minutes))

    console.print(table)

    total = sum(b.minutes for b in result.blocks)
    summary = (
        f"{len(result.blocks)} blocks · {total // 60}h {total % 60}m across {len(by_day)} days"
    )
    console.print(f"[dim]{summary}[/dim]")

    if result.unscheduled:
        console.print("\n[yellow]Could not fit before the deadline:[/yellow]")
        for task, missing in result.unscheduled:
            # The course and title are escaped, `[yellow]` and `[red]` are not:
            # a course called "[STATS101] Probability" would otherwise lose its
            # code here, in the one list that says what will not get done.
            console.print(
                f"  [yellow]·[/yellow] {escape(task.course)} — {escape(task.title)} "
                f"([red]{missing // 60}h {missing % 60}m short[/red])"
            )
        console.print("[dim]Widen your study hours or free some time, then re-run.[/dim]")


def render_tasks(tasks: list[Task], *, tz: ZoneInfo) -> None:
    table = Table(title="Open work", header_style="bold")
    table.add_column("Due", no_wrap=True)
    table.add_column("Course", no_wrap=True)
    table.add_column("Task")
    table.add_column("Est", justify="right", no_wrap=True)
    table.add_column("Pri", justify="right", no_wrap=True)

    for task in sorted(tasks, key=lambda t: t.due_at):
        # Course and title are the user's own words, straight from Moodle and
        # sometimes bracketed ("[resit] Tutorial 3"); a table cell parses markup,
        # so unescaped they lose whatever Rich reads as a style tag.
        table.add_row(
            task.due_at.astimezone(tz).strftime("%a %d %b %H:%M"),
            escape(task.course),
            escape(task.title),
            f"{task.estimated_minutes}m",
            f"{task.priority:.2f}",
        )
    console.print(table)


def render_slots(
    slots: Sequence[Slot | Block | tuple[datetime, datetime]], *, tz: ZoneInfo
) -> None:
    """Print free windows - the one output worth eyeballing against Outlook."""
    table = Table(title="Free windows", header_style="bold")
    table.add_column("Day", no_wrap=True)
    table.add_column("Window", no_wrap=True)
    table.add_column("Hours", justify="right", no_wrap=True)

    total = 0
    for item in slots:
        # `free_slots` hands back `Slot`s. Checking `Block` alone is not enough:
        # a pydantic model iterates as (field, value) pairs, so unpacking one
        # directly silently yields string keys instead of datetimes.
        start, end = item if isinstance(item, tuple) else (item.start, item.end)
        local_start, local_end = start.astimezone(tz), end.astimezone(tz)
        minutes = int((end - start).total_seconds() // 60)
        total += minutes
        table.add_row(
            local_start.strftime("%a %d %b"),
            f"{local_start:%H:%M}-{local_end:%H:%M}",
            f"{minutes / 60:.1f}",
        )
    console.print(table)
    console.print(f"[dim]{total / 60:.1f}h free in this window[/dim]")


def to_markdown(result: PackResult, *, tz: ZoneInfo, title: str = "Study week") -> str:
    by_day: dict[str, list[Block]] = defaultdict(list)
    for block in sorted(result.blocks, key=lambda b: b.start):
        by_day[block.start.astimezone(tz).strftime("%A %d %B")].append(block)

    lines = [f"# {title}", ""]
    total = sum(b.minutes for b in result.blocks)
    lines.append(f"_{len(result.blocks)} blocks · {total // 60}h {total % 60}m_")
    lines.append("")

    for day, blocks in by_day.items():
        lines.append(f"## {day}")
        lines.append("")
        lines.append("| Time | Session | Min |")
        lines.append("|---|---|---|")
        for block in blocks:
            start, end = _fmt(block, tz)
            lines.append(f"| {start}-{end} | {block.subject} | {block.minutes} |")
        lines.append("")

    if result.unscheduled:
        lines.append("## Could not fit")
        lines.append("")
        for task, missing in result.unscheduled:
            lines.append(f"- {task.course} — {task.title} ({missing} min short)")
        lines.append("")

    return "\n".join(lines)
