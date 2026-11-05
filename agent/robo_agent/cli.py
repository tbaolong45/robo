"""robo-agent serve | skills list | skills remove NAME | memory list | memory forget ID"""

from __future__ import annotations

import argparse
import asyncio
import sys

from . import config


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="robo-agent", description="Robo's agent service.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("serve", help="serve the app's API on 127.0.0.1")
    skills = sub.add_parser("skills", help="the skills robo learned").add_subparsers(
        dest="action", required=True)
    skills.add_parser("list")
    skills.add_parser("remove").add_argument("name")
    memory = sub.add_parser("memory", help="what robo remembers").add_subparsers(
        dest="action", required=True)
    memory.add_parser("list")
    memory.add_parser("forget").add_argument("id")
    args = parser.parse_args(argv)
    cfg = config.load()

    if args.cmd == "serve":
        from .server import serve

        serve(cfg)
        return 0
    from . import learn
    from .memory import Store

    if args.cmd == "skills":
        folder = learn.learned_skills_dir(cfg.root)
        if args.action == "list":
            for skill in learn.list_learned(folder):
                print(f"{skill['name']}: {skill['description']}")
            return 0
        if learn.remove_learned(folder, args.name):
            print(f"removed {args.name}")
            return 0
        print(f"no learned skill {args.name}", file=sys.stderr)
        return 1
    store = Store(cfg.root, cfg.key("supermemory_key", "SUPERMEMORY_API_KEY") or None)
    if args.action == "list":
        for fact in store.all():
            print(f"{fact['id']} [{fact['kind']}] {fact['text']}")
        return 0
    if not store.forget(args.id):
        print(f"no memory {args.id}", file=sys.stderr)
        return 1
    key = cfg.key("api_key", "DEEPSEEK_API_KEY")
    if key:  # rewrite the profile without the forgotten fact (without a key: the plain summary)
        from .harness import make_llm

        asyncio.run(learn.consolidate(store, make_llm(key)))
    print(f"forgot {args.id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
